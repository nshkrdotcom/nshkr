defmodule Nshkr.Runtime.GovernedCodexEffect do
  @moduledoc """
  Composes one accepted Synapse review into a governed local Codex file effect.

  AppKit is the product boundary, Mezzanine owns the durable review/effect
  lifecycle, Citadel owns exact authority, Jido owns the managed account and
  credential lease, and ASM owns the finite Codex session. The only file effect
  admitted here is create-or-replace of one reviewed relative text file.
  """

  alias AppKit.Core.RequestContext
  alias AppKit.Core.SurfaceError
  alias AppKit.EffectSurface
  alias Citadel.Governance.ToolEffectAuthority
  alias Citadel.PolicyPacks.ToolEffectPolicy
  alias Jido.Integration.V2.Auth
  alias Jido.Integration.V2.MaterializationRequest
  alias Jido.Integration.V2.ControlPlane
  alias Mezzanine.Reviews
  alias OuterBrain.Persistence.Store, as: OuterBrainStore
  alias OuterBrain.Prompting.SemanticTurnArtifacts

  @capability_id "codex.session.turn"
  @effect_mode "managed_account_local_effect"
  @provider_family "codex"
  @default_account_ref "provider-account://nshkr/developer-local/codex/primary"
  @default_installation_ref "installation://nshkr/developer-local"
  @system_instruction """
  Execute only the reviewed create-or-replace operation for the one named file.
  Do not modify any other file. Report the completed relative path succinctly.
  """
  @allowed_fields ~w(
    actor_ref idempotency_key installation_ref relative_path reviewed_content
    review_unit_id run_id run_ref subject_id tenant_ref trace_ref turn_ref
    workspace_ref workspace_root
  )a
  @readback_fields ~w(idempotency_key installation_ref tenant_ref)a
  @required_fields ~w(
    relative_path reviewed_content review_unit_id run_id run_ref subject_id
    tenant_ref turn_ref workspace_ref workspace_root
  )a
  @forbidden_keys ~w(
    access_token api_key auth_json authorization callback codex_home credential
    credential_material env environment password private_key secret secrets token
  )
  @max_reviewed_content_bytes 65_536

  @spec capability_id() :: String.t()
  def capability_id, do: @capability_id

  @spec propose(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def propose(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs, @allowed_fields),
         :ok <- validate_execute_attrs(attrs),
         {:ok, context} <- request_context(attrs),
         refs = refs(attrs) do
      fetch_or_propose_effect(attrs, context, refs)
    end
  rescue
    error in [ArgumentError] ->
      {:error, {:invalid_governed_codex_effect, Exception.message(error)}}
  end

  def propose(_attrs), do: {:error, :invalid_governed_codex_effect}

  @spec execute(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def execute(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs, @allowed_fields),
         :ok <- validate_execute_attrs(attrs),
         {:ok, context} <- request_context(attrs),
         refs = refs(attrs),
         {:ok, proposed} <- fetch_or_propose_effect(attrs, context, refs) do
      execute_proposed(attrs, context, refs, proposed)
    end
  rescue
    error in [ArgumentError] ->
      {:error, {:invalid_governed_codex_effect, Exception.message(error)}}
  end

  def execute(_attrs), do: {:error, :invalid_governed_codex_effect}

  defp execute_proposed(attrs, _context, _refs, %{status: "completed"}) do
    readback(Map.take(attrs, @readback_fields))
  end

  defp execute_proposed(attrs, context, refs, %{status: "authorized"} = proposed) do
    with {:ok, review} <- accepted_review(attrs, refs),
         now = now(),
         {:ok, account, account_ref} <- ensure_account(attrs, now),
         refs = bind_account(refs, account),
         {:ok, lease, lease_context} <- request_lease(attrs, refs, account_ref, now),
         refs = Map.put(refs, :credential_lease_ref, lease.lease_id),
         {:ok, grant, input_digest, policy} <-
           issue_grant(attrs, review, refs, account, lease, now),
         :ok <- verify_grant(attrs, review, refs, account, lease, grant, input_digest, policy),
         {:ok, prompt} <- prepare_prompt(attrs, refs),
         {:ok, prompt} <-
           OuterBrainStore.record_prompt_context(
             prompt,
             tenant_id: attrs.tenant_ref,
             repo: OuterBrain.Persistence.Repo
           ),
         {:ok, dispatching} <- begin_dispatch(context, proposed),
         materialization_request =
           materialization_request(lease, account_ref, refs, account, now),
         result <-
           invoke_codex(
             attrs,
             refs,
             account,
             lease,
             materialization_request,
             lease_context,
             grant,
             dispatching,
             context,
             prompt
           ) do
      result
    end
  end

  defp execute_proposed(_attrs, _context, _refs, effect),
    do: {:error, {:governed_effect_already_started, effect.status}}

  @spec readback(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def readback(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs, @readback_fields),
         {:ok, tenant_ref} <- required_string(attrs, :tenant_ref),
         {:ok, idempotency_key} <- required_string(attrs, :idempotency_key),
         {:ok, context} <-
           request_context(
             Map.merge(attrs, %{
               actor_ref: "actor://synapse/operator",
               trace_ref: "trace://nshkr/p04/readback/#{token(idempotency_key)}"
             })
           ),
         {:ok, effect} <-
           EffectSurface.get_effect_by_idempotency(
             context,
             idempotency_key,
             effect_options()
           ),
         true <- effect.status == "completed" or {:error, {:effect_not_completed, effect.status}},
         {:ok, attempt} <- ControlPlane.fetch_attempt(effect.attempt_ref),
         {:ok, grant} <- ToolEffectAuthority.fetch_grant(effect.grant_ref),
         publication when not is_nil(publication) <-
           OuterBrainStore.latest_publication(
             tenant_ref,
             effect.turn_ref,
             repo: OuterBrain.Persistence.Repo
           ) do
      {:ok,
       %{
         capability_id: @capability_id,
         effect: effect,
         attempt: attempt,
         grant: grant,
         publication: publication
       }}
    else
      nil -> {:error, :effect_continuation_not_found}
      false -> {:error, :invalid_governed_codex_readback}
      :error -> {:error, :governed_codex_attempt_not_found}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_governed_codex_readback}
    end
  end

  def readback(_attrs), do: {:error, :invalid_governed_codex_readback}

  defp accepted_review(attrs, refs) do
    with {:ok, %{review_unit: review, decisions: decisions}} <-
           Reviews.review_detail(attrs.tenant_ref, attrs.review_unit_id),
         true <- review.work_object_id == attrs.subject_id,
         true <- review.run_id == attrs.run_id,
         true <- review.status == :accepted,
         true <- Enum.any?(decisions, &exact_acceptance?(&1, attrs, refs)) do
      {:ok, review}
    else
      false -> {:error, :accepted_exact_review_required}
      {:error, _reason} = error -> error
      _other -> {:error, :accepted_exact_review_required}
    end
  end

  defp exact_acceptance?(decision, attrs, refs) do
    payload = Map.get(decision, :payload, %{})
    manifest = map_value(payload, :pinned_tool_manifest, %{})
    operation = map_value(payload, :reviewed_operation, %{})

    Map.get(decision, :decision) == :accept and Map.get(decision, :actor_kind) == :human and
      map_value(payload, :effect_ref) == refs.effect_ref and
      map_value(manifest, :manifest_ref) == refs.manifest_ref and
      map_value(manifest, :manifest_hash) == refs.manifest_hash and
      map_value(manifest, :action_ids) == ["create_or_replace_one_named_text_file"] and
      map_value(operation, :operation) == "create_or_replace" and
      map_value(operation, :workspace_ref) == attrs.workspace_ref and
      map_value(operation, :file_ref) == refs.file_ref and
      map_value(operation, :relative_path) == attrs.relative_path and
      map_value(operation, :content_digest) == refs.reviewed_content_digest
  end

  defp ensure_account(attrs, now) do
    account_ref = Map.get(attrs, :account_ref, @default_account_ref)

    case Auth.fetch_managed_account(account_ref) do
      {:ok, account} ->
        validate_account(account, attrs)

      {:error, :unknown_managed_account} ->
        with {:ok, %{account: account, account_ref: managed_ref}} <-
               Auth.register_managed_account(%{
                 provider_family: @provider_family,
                 account_ref: account_ref,
                 tenant_id: attrs.tenant_ref,
                 connector_id: "codex_cli",
                 endpoint_ref: "endpoint://codex/app-server",
                 quota_scope_ref: "quota://codex/nshkr-primary",
                 credential_handle_ref: "credential-handle://codex/nshkr-primary/v1",
                 secret_provider_ref: "vault://nshkr/kv-v2",
                 secret_binding_ref: "vault-secret://codex/primary",
                 subject: "nshkr-codex-runtime",
                 actor_id: "nshkr-runtime",
                 scopes: ["session:execute", "session:control", "session:tools"],
                 lease_fields: ["auth_json"],
                 now: now
               }) do
          {:ok, account, managed_ref}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_account(account, attrs) do
    cond do
      account.provider_family != @provider_family ->
        {:error, :managed_account_provider_mismatch}

      account.tenant_id != attrs.tenant_ref ->
        {:error, :managed_account_tenant_mismatch}

      account.state != :active ->
        {:error, :managed_account_not_active}

      true ->
        {:ok, account, Jido.Integration.V2.Auth.ManagedAccount.ref(account)}
    end
  end

  defp request_lease(attrs, refs, account_ref, now) do
    context = %{
      tenant_id: attrs.tenant_ref,
      actor_id: "nshkr-runtime",
      actor_ref: attrs.actor_ref,
      subject_ref: refs.subject_ref,
      required_scopes: ["session:execute"],
      ttl_seconds: 180,
      now: now,
      provider_family: @provider_family,
      provider_ref: @provider_family,
      provider_account_ref: refs.account_ref,
      connector_instance_ref: refs.connector_instance_ref,
      connector_binding_ref: refs.connector_binding_ref,
      credential_ref: "credential://codex/nshkr-primary",
      credential_handle_ref: refs.credential_handle_ref,
      operation_class: "cli",
      execution_context_ref: refs.execution_context_ref,
      context_digest: refs.reviewed_content_digest,
      target_ref: refs.target_ref,
      target_posture_ref: "target-posture://nshkr/local-provider-effect",
      attach_grant_ref: refs.attach_grant_ref,
      operation_policy_ref: refs.policy_ref,
      policy_revision_ref: refs.policy_revision_ref,
      target_grant_revision: refs.target_grant_revision,
      rotation_epoch: refs.credential_generation,
      fence_token: refs.fence_token,
      authority_ref: refs.grant_ref,
      authority_decision_ref: refs.decision_ref,
      authority_scope: ["session:execute"],
      installation_revision: "#{attrs.installation_ref}/v1",
      effect_ref: refs.effect_ref,
      operation_ref: refs.operation_ref,
      endpoint_ref: refs.endpoint_ref,
      max_calls: 1,
      max_tokens: 4_096,
      allowed_models: ["codex-default"],
      network_policy: :provider_only,
      requested_model: "codex-default",
      requested_tokens: 2_048,
      network_target: :provider,
      current_policy_revision_ref: refs.policy_revision_ref,
      current_rotation_epoch: refs.credential_generation,
      current_target_grant_revision: refs.target_grant_revision,
      current_installation_revision: "#{attrs.installation_ref}/v1",
      requested_authority_scope: ["session:execute"],
      service_identity_ref: "service-identity://nshkr/runtime",
      service_principal_ref: "service-principal://nshkr/runtime"
    }

    with {:ok, lease} <- Auth.request_managed_lease(account_ref, context) do
      {:ok, lease, context}
    end
  end

  defp issue_grant(attrs, review, refs, account, lease, now) do
    policy = ToolEffectPolicy.synapse_codex_reviewed_write!()
    grant_attrs = grant_attrs(attrs, review, refs, account, lease, now)

    with {:ok, input_digest} <- ToolEffectAuthority.input_digest(grant_attrs),
         {:ok, %{result: :permit_with_review, grant: grant}} <-
           ToolEffectAuthority.evaluate_and_persist(grant_attrs, policy) do
      {:ok, grant, input_digest, policy}
    end
  end

  defp verify_grant(attrs, review, refs, account, lease, grant, input_digest, policy) do
    binding =
      grant_attrs(attrs, review, refs, account, lease, grant.issued_at)
      |> Map.drop([:session_ref, :grant_ref, :issued_at, :expires_at])
      |> Map.merge(%{
        input_digest: input_digest,
        policy_ref: policy.artifact_ref,
        policy_version: policy.policy_version
      })

    ToolEffectAuthority.verify_grant(grant.grant_ref, binding, now())
  end

  defp grant_attrs(attrs, _review, refs, account, lease, now) do
    %{
      session_ref: refs.authority_session_ref,
      decision_ref: refs.decision_ref,
      grant_ref: refs.grant_ref,
      tenant_ref: attrs.tenant_ref,
      actor_ref: attrs.actor_ref,
      subject_ref: refs.subject_ref,
      provider_family: @provider_family,
      provider_account_ref: account.account_ref,
      credential_lease_ref: lease.lease_id,
      credential_generation: account.generation,
      managed_session_ref: refs.managed_session_ref,
      session_generation: refs.session_generation,
      review_ref: refs.review_ref,
      workspace_policy: "isolated_disposable_workspace",
      workspace_ref: attrs.workspace_ref,
      workspace_root_digest: refs.workspace_root_digest,
      relative_path: attrs.relative_path,
      operation_ref: refs.operation_ref,
      operation_class: "create_or_replace",
      capability_id: @capability_id,
      reviewed_content_digest: refs.reviewed_content_digest,
      target_ref: refs.target_ref,
      attempt_ref: refs.attempt_ref,
      effect_ref: refs.effect_ref,
      issued_at: now,
      expires_at: earliest(DateTime.add(now, 180, :second), lease.expires_at)
    }
  end

  defp propose_effect(attrs, context, refs) do
    EffectSurface.propose_effect(
      context,
      %{
        effect_ref: refs.effect_ref,
        run_ref: attrs.run_ref,
        turn_ref: attrs.turn_ref,
        command_ref: refs.command_ref,
        decision_ref: refs.decision_ref,
        grant_ref: refs.grant_ref,
        review_ref: refs.review_ref,
        subject_id: attrs.subject_id,
        run_id: attrs.run_id,
        review_unit_id: attrs.review_unit_id,
        target_ref: refs.target_ref,
        attempt_ref: refs.attempt_ref,
        capability_id: @capability_id,
        effect_mode: @effect_mode,
        pinned_tool_manifest: %{
          manifest_ref: refs.manifest_ref,
          manifest_hash: refs.manifest_hash,
          action_ids: ["create_or_replace_one_named_text_file"]
        },
        reviewed_operation: %{
          operation: "create_or_replace",
          workspace_ref: attrs.workspace_ref,
          file_ref: refs.file_ref,
          relative_path: attrs.relative_path,
          content_digest: refs.reviewed_content_digest
        }
      },
      effect_options()
    )
  end

  defp fetch_or_propose_effect(attrs, context, refs) do
    case EffectSurface.get_effect_by_idempotency(
           context,
           attrs.idempotency_key,
           effect_options()
         ) do
      {:ok, effect} ->
        if same_effect_command?(effect, attrs, refs),
          do: {:ok, effect},
          else: {:error, :effect_idempotency_conflict}

      {:error, %SurfaceError{code: "effect_not_found"}} ->
        propose_effect(attrs, context, refs)

      {:error, _reason} = error ->
        error
    end
  end

  defp same_effect_command?(effect, attrs, refs) do
    manifest = Map.get(effect, :pinned_tool_manifest, %{})
    operation = Map.get(effect, :reviewed_operation, %{})
    review = Map.get(effect, :review)

    effect.effect_ref == refs.effect_ref and
      effect.run_ref == attrs.run_ref and
      effect.turn_ref == attrs.turn_ref and
      effect.command_ref == refs.command_ref and
      effect.decision_ref == refs.decision_ref and
      effect.grant_ref == refs.grant_ref and
      effect.target_ref == refs.target_ref and
      map_value(manifest, :manifest_ref) == refs.manifest_ref and
      map_value(manifest, :manifest_hash) == refs.manifest_hash and
      map_value(manifest, :action_ids) == ["create_or_replace_one_named_text_file"] and
      map_value(operation, :operation) == "create_or_replace" and
      map_value(operation, :workspace_ref) == attrs.workspace_ref and
      map_value(operation, :file_ref) == refs.file_ref and
      map_value(operation, :relative_path) == attrs.relative_path and
      map_value(operation, :content_digest) == refs.reviewed_content_digest and
      map_value(review, :review_unit_id) == attrs.review_unit_id
  end

  defp begin_dispatch(context, proposed) do
    EffectSurface.begin_dispatch(
      context,
      proposed.owner_execution_ref,
      %{expected_row_version: proposed.row_version},
      effect_options()
    )
  end

  defp prepare_prompt(attrs, refs) do
    SemanticTurnArtifacts.prepare_prompt(%{
      tenant_ref: attrs.tenant_ref,
      installation_ref: attrs.installation_ref,
      workspace_ref: attrs.workspace_ref,
      project_ref: "project://synapse/default",
      environment_ref: "environment://nshkr/developer-local",
      authority_packet_ref: refs.authority_packet_ref,
      permission_decision_ref: refs.decision_ref,
      idempotency_key: "#{attrs.idempotency_key}:outer-brain",
      trace_id: attrs.trace_ref,
      correlation_id: "correlation://nshkr/codex/#{refs.token}",
      release_manifest_ref: "release://nshkr/p04",
      input_claim_check_ref: "claim-check://nshkr/codex/#{refs.token}/input",
      output_claim_check_ref: "claim-check://nshkr/codex/#{refs.token}/output",
      redaction_policy_ref: "redaction://nshkr/codex/v1",
      normalizer_version: "outer-brain-normalizer-v1",
      run_ref: attrs.run_ref,
      turn_ref: attrs.turn_ref,
      model_profile_ref: "model-profile://nshkr/codex-default",
      provider_ref: @provider_family,
      model_ref: "model://openai/codex/default",
      producing_operation_ref: "operation://outer-brain/context/#{refs.token}",
      principal_ref: attrs.actor_ref,
      source_artifacts: [
        %{
          artifact_ref: "artifact://nshkr/p04/system-instruction/v1",
          content_digest: digest(@system_instruction),
          role: "system_instruction"
        },
        %{
          artifact_ref: "artifact://nshkr/p04/reviewed-content/#{refs.token}",
          content_digest: refs.reviewed_content_digest,
          role: "user_input"
        }
      ],
      memory_snapshot_refs: [],
      allowed_reader_refs: ["reader://synapse/runtime"],
      allowed_operation_refs: ["operation://synapse/read"]
    })
  end

  defp materialization_request(lease, account_ref, refs, account, now) do
    MaterializationRequest.new!(%{
      materialization_ref: refs.materialization_ref,
      lease_id: lease.lease_id,
      account: account_ref,
      effect_ref: refs.effect_ref,
      operation_ref: refs.operation_ref,
      authority_ref: refs.grant_ref,
      endpoint_ref: account.endpoint_ref,
      target_ref: refs.target_ref,
      issued_at: now,
      expires_at: earliest(DateTime.add(now, 120, :second), lease.expires_at)
    })
  end

  defp invoke_codex(
         attrs,
         refs,
         account,
         lease,
         materialization_request,
         lease_context,
         grant,
         dispatching,
         context,
         prompt
       ) do
    input = %{
      prompt: codex_prompt(attrs, refs),
      workspace: %{
        workspace_ref: attrs.workspace_ref,
        relative_path: attrs.relative_path,
        content_digest: refs.reviewed_content_digest
      },
      provider_metadata: %{app_server: true, skip_git_repo_check: true},
      authority_metadata: %{
        grant_ref: grant.grant_ref,
        decision_ref: grant.decision_ref,
        review_ref: refs.review_ref,
        effect_ref: refs.effect_ref
      }
    }

    opts = [
      credential_lease: lease,
      materialization_request: materialization_request,
      materialization_context: materialization_context(lease_context),
      workspace_root: attrs.workspace_root,
      workspace_ref: attrs.workspace_ref,
      managed_session_ref: refs.managed_session_ref,
      managed_session_generation: refs.session_generation,
      operation_policy_ref: refs.policy_ref,
      authority_decision_ref: refs.decision_ref,
      actor_id: "nshkr-runtime",
      tenant_id: attrs.tenant_ref,
      environment: :prod,
      trace_id: context.trace_id,
      run_id: refs.jido_run_id,
      cost_meter_ref: "meter://nshkr/codex/#{refs.token}",
      budget_refs: ["budget://nshkr/codex/#{refs.token}/per-run"],
      allowed_operations: [@capability_id],
      sandbox: %{
        level: :strict,
        egress: :restricted,
        approvals: :manual,
        file_scope: attrs.workspace_root,
        allowed_tools: [@capability_id]
      }
    ]

    case safe_invoke(input, opts) do
      {:ok, result} ->
        complete_effect(attrs, refs, account, lease, result, dispatching, context, prompt)

      {:error, %{attempt: attempt} = failure} when not is_nil(attempt) ->
        fail_effect(attrs, refs, lease, failure, dispatching, context)

      {:error, failure} ->
        ambiguous_effect(attrs, refs, lease, failure, dispatching, context, %{})
    end
  end

  defp safe_invoke(input, opts) do
    ControlPlane.invoke_managed_session(@capability_id, input, opts)
  rescue
    error -> {:error, {:provider_invocation_exception, error.__struct__}}
  catch
    kind, reason -> {:error, {:provider_invocation_exit, kind, durable_reason(reason)}}
  end

  defp complete_effect(attrs, refs, _account, lease, result, dispatching, context, prompt) do
    case verify_jido_result(result, refs) do
      :ok ->
        case record_accepted(context, dispatching, result, refs) do
          {:ok, running} ->
            complete_running_effect(
              attrs,
              refs,
              lease,
              result,
              running,
              context,
              prompt
            )

          {:error, reason} ->
            ambiguous_effect(
              attrs,
              refs,
              lease,
              {:acceptance_receipt_not_durable, reason},
              dispatching,
              context,
              result.output
            )
        end

      {:error, reason} ->
        ambiguous_effect(
          attrs,
          refs,
          lease,
          {:provider_result_verification_failed, reason},
          dispatching,
          context,
          result.output
        )
    end
  end

  defp complete_running_effect(attrs, refs, lease, result, running, context, prompt) do
    with {:ok, lease_cleanup} <- cleanup_lease(lease, refs),
         {:ok, file_body} <- verify_reviewed_file(attrs, refs),
         {:ok, continuation} <-
           SemanticTurnArtifacts.prepare_reply(prompt, %{
             attempt_ref: refs.attempt_ref,
             assistant_reply: continuation_text(result, attrs, refs),
             dedupe_key: "#{attrs.turn_ref}:codex-effect-final",
             published_at: now(),
             allowed_reader_refs: ["reader://synapse/runtime"],
             allowed_operation_refs: ["operation://synapse/read"]
           }) do
      commit_completed_effect(
        attrs,
        refs,
        lease,
        result,
        running,
        context,
        continuation,
        lease_cleanup,
        file_body
      )
    else
      {:error, reason} ->
        ambiguous_effect(
          attrs,
          refs,
          lease,
          {:post_dispatch_verification_failed, reason},
          running,
          context,
          result.output
        )
    end
  end

  defp commit_completed_effect(
         attrs,
         refs,
         lease,
         result,
         running,
         context,
         continuation,
         lease_cleanup,
         file_body
       ) do
    case record_completed(
           context,
           running,
           result,
           refs,
           lease_cleanup,
           continuation.reply_artifact.descriptor.artifact_ref
         ) do
      {:ok, completed} ->
        finalize_completed_effect(
          attrs,
          refs,
          lease,
          result,
          completed,
          context,
          continuation,
          file_body
        )

      {:error, reason} ->
        reconcile_terminal_write(
          attrs,
          refs,
          lease,
          result,
          running,
          context,
          continuation,
          file_body,
          reason
        )
    end
  end

  defp reconcile_terminal_write(
         attrs,
         refs,
         lease,
         result,
         running,
         context,
         continuation,
         file_body,
         write_reason
       ) do
    case EffectSurface.get_effect(context, running.owner_execution_ref, effect_options()) do
      {:ok, %{status: "completed"} = completed} ->
        finalize_completed_effect(
          attrs,
          refs,
          lease,
          result,
          completed,
          context,
          continuation,
          file_body
        )

      {:ok, %{status: "running"} = current} ->
        ambiguous_effect(
          attrs,
          refs,
          lease,
          {:terminal_receipt_not_durable, write_reason},
          current,
          context,
          result.output
        )

      {:ok, current} ->
        {:error, {:unexpected_governed_effect_state, current.status}}

      {:error, read_reason} ->
        {:error,
         {:governed_effect_terminal_reconciliation_failed, durable_reason(write_reason),
          durable_reason(read_reason)}}
    end
  end

  defp finalize_completed_effect(
         attrs,
         refs,
         lease,
         result,
         completed,
         context,
         continuation,
         file_body
       ) do
    with {:ok, publication} <-
           OuterBrainStore.publish_reply_continuation(
             continuation,
             tenant_id: attrs.tenant_ref,
             repo: OuterBrain.Persistence.Repo
           ),
         {:ok, effect} <-
           EffectSurface.get_effect(
             context,
             completed.owner_execution_ref,
             effect_options()
           ),
         {:ok, events} <- jido_events(refs.jido_run_id) do
      {:ok,
       %{
         capability_id: @capability_id,
         effect: effect,
         grant_ref: refs.grant_ref,
         credential_lease_ref: lease.lease_id,
         attempt: result.attempt,
         jido_events: events,
         provider_output: result.output,
         verified_file_digest: digest(file_body),
         publication: publication
       }}
    end
  end

  defp fail_effect(attrs, refs, lease, failure, dispatching, context) do
    cleanup = cleanup_evidence(lease, refs, failure.attempt.output)

    with {:ok, running} <-
           EffectSurface.record_accepted(
             context,
             dispatching.owner_execution_ref,
             %{
               expected_row_version: dispatching.row_version,
               attempt_ref: refs.attempt_ref,
               external_ref: failure.attempt.runtime_ref_id,
               accepted_receipt_ref: refs.accepted_receipt_ref
             },
             effect_options()
           ),
         {:ok, failed} <-
           EffectSurface.record_receipt(
             context,
             running.owner_execution_ref,
             %{
               expected_row_version: running.row_version,
               receipt_ref: refs.failed_receipt_ref,
               receipt_state: "failed",
               artifact_refs: [],
               continuation_target: %{
                 kind: "owner_command",
                 owner: "outer_brain",
                 command: "continue_after_effect_failure",
                 idempotency_key: "#{attrs.idempotency_key}:failed-continuation"
               },
               cleanup: cleanup
             },
             effect_options()
           ) do
      {:error, {:governed_codex_effect_failed, durable_reason(failure.reason), failed}}
    end
  end

  defp ambiguous_effect(attrs, refs, lease, failure, current, context, output) do
    cleanup = cleanup_evidence(lease, refs, output)

    case EffectSurface.record_receipt(
           context,
           current.owner_execution_ref,
           %{
             expected_row_version: current.row_version,
             receipt_ref: refs.ambiguous_receipt_ref,
             receipt_state: "ambiguous",
             ambiguity_state: "outcome_unknown",
             artifact_refs: [],
             continuation_target: %{
               kind: "owner_command",
               owner: "jido_integration",
               command: "reconcile_effect_outcome",
               idempotency_key: "#{attrs.idempotency_key}:reconcile"
             },
             cleanup: cleanup
           },
           effect_options()
         ) do
      {:ok, ambiguous} ->
        {:error, {:governed_codex_effect_ambiguous, durable_reason(failure), ambiguous}}

      {:error, reason} ->
        {:error,
         {:governed_codex_effect_ambiguity_record_failed, durable_reason(failure), reason}}
    end
  end

  defp record_accepted(context, dispatching, result, refs) do
    EffectSurface.record_accepted(
      context,
      dispatching.owner_execution_ref,
      %{
        expected_row_version: dispatching.row_version,
        attempt_ref: refs.attempt_ref,
        external_ref: result.attempt.runtime_ref_id,
        accepted_receipt_ref: refs.accepted_receipt_ref
      },
      effect_options()
    )
  end

  defp record_completed(context, running, result, refs, lease_cleanup, artifact_ref) do
    EffectSurface.record_receipt(
      context,
      running.owner_execution_ref,
      %{
        expected_row_version: running.row_version,
        receipt_ref: refs.completed_receipt_ref,
        receipt_state: "completed",
        result_artifact_ref: artifact_ref,
        artifact_refs: [artifact_ref],
        continuation_target: %{
          kind: "owner_command",
          owner: "outer_brain",
          command: "publish_effect_continuation",
          idempotency_key: "#{running.effect_ref}:outer-brain"
        },
        cleanup: %{
          status: "completed",
          cleanup_ref: lease_cleanup.cleanup_ref,
          managed_session_ref: refs.managed_session_ref,
          credential_lease_ref: lease_cleanup.lease_id,
          materialization_ref: refs.materialization_ref,
          session_terminated: cleanup_status(result.output, :session) == "completed",
          materialization_removed: cleanup_status(result.output, :materialization) == "completed",
          credential_lease_released: lease_cleanup.status == :cleaned
        }
      },
      effect_options()
    )
  end

  defp verify_jido_result(result, refs) do
    cond do
      result.run.run_id != refs.jido_run_id ->
        {:error, :jido_run_identity_mismatch}

      result.attempt.attempt_id != refs.attempt_ref ->
        {:error, :jido_attempt_identity_mismatch}

      result.run.status != :completed ->
        {:error, {:jido_run_not_completed, result.run.status}}

      result.attempt.status != :completed ->
        {:error, {:jido_attempt_not_completed, result.attempt.status}}

      cleanup_status(result.output, :session) != "completed" ->
        {:error, :codex_session_cleanup_failed}

      cleanup_status(result.output, :materialization) != "completed" ->
        {:error, :codex_materialization_cleanup_failed}

      true ->
        :ok
    end
  end

  defp cleanup_lease(lease, refs) do
    cleanup_ref = "cleanup://jido/codex/#{refs.token}"

    with {:ok, receipt} <-
           Auth.cleanup_lease(lease.lease_id, %{
             cleanup_ref: cleanup_ref,
             actor_id: "nshkr-runtime",
             tenant_id: lease.tenant_id,
             now: now()
           }) do
      {:ok,
       %{
         cleanup_ref: cleanup_ref,
         lease_id: lease.lease_id,
         status: Map.get(receipt, :status)
       }}
    end
  end

  defp cleanup_evidence(lease, refs, output) do
    lease_cleaned? =
      match?({:ok, _receipt}, cleanup_lease(lease, refs))

    %{
      status:
        if(
          cleanup_status(output, :session) == "completed" and
            cleanup_status(output, :materialization) == "completed" and lease_cleaned?,
          do: "completed",
          else: "partial"
        ),
      cleanup_ref: "cleanup://jido/codex/#{refs.token}",
      managed_session_ref: refs.managed_session_ref,
      credential_lease_ref: lease.lease_id,
      materialization_ref: refs.materialization_ref,
      session_terminated: cleanup_status(output, :session) == "completed",
      materialization_removed: cleanup_status(output, :materialization) == "completed",
      credential_lease_released: lease_cleaned?
    }
  end

  defp verify_reviewed_file(attrs, refs) do
    path = Path.join(attrs.workspace_root, attrs.relative_path)

    with true <- inside_workspace?(path, attrs.workspace_root),
         {:ok, body} <- File.read(path),
         true <- digest(body) == refs.reviewed_content_digest,
         true <- body == attrs.reviewed_content do
      {:ok, body}
    else
      false -> {:error, :reviewed_file_verification_failed}
      {:error, reason} -> {:error, {:reviewed_file_unavailable, reason}}
    end
  end

  defp jido_events(run_id) do
    case ControlPlane.events(run_id) do
      events when is_list(events) -> {:ok, events}
      {:ok, events} when is_list(events) -> {:ok, events}
      other -> {:error, {:invalid_jido_event_readback, durable_reason(other)}}
    end
  end

  defp materialization_context(context) do
    %{
      tenant_id: context.tenant_id,
      provider_family: context.provider_family,
      connector_instance_ref: context.connector_instance_ref,
      provider_account_ref: context.provider_account_ref,
      credential_handle_ref: context.credential_handle_ref,
      operation_class: context.operation_class,
      target_ref: context.target_ref,
      attach_grant_ref: context.attach_grant_ref,
      operation_policy_ref: context.operation_policy_ref,
      current_policy_revision_ref: context.policy_revision_ref,
      current_rotation_epoch: context.rotation_epoch,
      current_target_grant_revision: context.target_grant_revision,
      fence_token: context.fence_token,
      current_installation_revision: context.installation_revision,
      requested_authority_scope: context.authority_scope,
      requested_model: context.requested_model,
      requested_tokens: context.requested_tokens,
      network_target: context.network_target,
      now: now()
    }
  end

  defp request_context(attrs) do
    installation_ref = Map.get(attrs, :installation_ref, @default_installation_ref)
    idempotency_key = Map.get(attrs, :idempotency_key, "nshkr:p04:#{token(inspect(attrs))}")
    trace_ref = Map.get(attrs, :trace_ref, "trace://nshkr/p04/#{token(idempotency_key)}")

    RequestContext.new(%{
      trace_id: trace_id(trace_ref),
      actor_ref: %{id: Map.get(attrs, :actor_ref, "actor://synapse/operator"), kind: :human},
      tenant_ref: %{id: Map.get(attrs, :tenant_ref)},
      installation_ref: %{
        id: installation_ref,
        pack_slug: "synapse",
        status: :active,
        compiled_pack_revision: 1
      },
      causation_id: "cause://nshkr/p04/#{token(idempotency_key)}",
      request_id: "request://nshkr/p04/#{token(idempotency_key)}",
      idempotency_key: idempotency_key
    })
  end

  defp refs(attrs) do
    token =
      token(
        Enum.join(
          [
            attrs.tenant_ref,
            attrs.run_ref,
            attrs.turn_ref,
            attrs.review_unit_id,
            attrs.workspace_ref,
            attrs.relative_path,
            digest(attrs.reviewed_content)
          ],
          "|"
        )
      )

    jido_run_id = "jido-run://nshkr/codex/#{token}"
    manifest_hash = digest("codex-app-server:create_or_replace_one_named_text_file:v1")

    %{
      token: token,
      subject_ref: "mezzanine-work-object://#{attrs.subject_id}",
      authority_session_ref: "session://citadel/codex/#{token}",
      decision_ref: "decision://citadel/tool-effect/#{token}",
      grant_ref: "grant://citadel/tool-effect/#{token}",
      review_ref: "review://mezzanine/#{attrs.review_unit_id}",
      effect_ref: "effect://nshkr/codex/#{token}",
      command_ref: "command://nshkr/codex/#{token}",
      operation_ref: "operation://codex/create-or-replace/#{token}",
      target_ref: "target://nshkr/local/codex/#{token}",
      file_ref: "file-ref://nshkr/codex/#{token}",
      workspace_root_digest: digest(attrs.workspace_root),
      reviewed_content_digest: digest(attrs.reviewed_content),
      manifest_ref: "manifest://codex/app-server/file-effect/v1",
      manifest_hash: manifest_hash,
      authority_packet_ref: "authority-packet://nshkr/codex/#{token}",
      policy_ref: "policy-artifact://citadel/synapse/codex-reviewed-write/v1",
      policy_revision_ref: "policy-revision://citadel/codex-reviewed-write/v1",
      target_grant_revision: "target-grant-revision://nshkr/codex/#{token}/v1",
      attach_grant_ref: "attach-grant://nshkr/codex/#{token}",
      managed_session_ref: "managed-session://nshkr/codex/#{token}",
      session_generation: 1,
      materialization_ref: "materialization://jido/codex/#{token}",
      execution_context_ref: "execution-context://jido/codex/#{token}",
      connector_instance_ref: "connector-instance://codex/nshkr-primary",
      connector_binding_ref: "connector-binding://codex/nshkr/#{token}",
      jido_run_id: jido_run_id,
      attempt_ref: Jido.Integration.V2.Contracts.attempt_id(jido_run_id, 1),
      accepted_receipt_ref: "receipt://jido/codex/#{token}/accepted",
      completed_receipt_ref: "receipt://nshkr/codex/#{token}/completed",
      failed_receipt_ref: "receipt://nshkr/codex/#{token}/failed",
      ambiguous_receipt_ref: "receipt://nshkr/codex/#{token}/ambiguous"
    }
  end

  defp bind_account(refs, account) do
    Map.merge(refs, %{
      account_ref: account.account_ref,
      credential_handle_ref: account.credential_handle_ref,
      credential_generation: account.generation,
      endpoint_ref: account.endpoint_ref,
      fence_token: "#{account.account_ref}:fence:#{account.fence}"
    })
  end

  defp codex_prompt(attrs, refs) do
    """
    Perform exactly one reviewed operation in the current workspace.
    Create or replace only the relative file #{inspect(attrs.relative_path)}.
    The final UTF-8 file bytes must be exactly the JSON string value below,
    with no extra newline or formatting:
    #{Jason.encode!(attrs.reviewed_content)}
    Expected SHA-256: #{refs.reviewed_content_digest}
    Do not modify any other file. After verifying the bytes, report completion.
    """
  end

  defp continuation_text(result, attrs, refs) do
    case map_value(result.output, :text) do
      value when is_binary(value) and value != "" -> value
      _other -> "Verified #{attrs.relative_path} at #{refs.reviewed_content_digest}."
    end
  end

  defp cleanup_status(output, key) do
    output
    |> map_value(:cleanup, %{})
    |> map_value(key)
  end

  defp effect_options do
    [backend_stack: Nshkr.Runtime.AppKitBackendStack.backend_stack()]
  end

  defp validate_execute_attrs(attrs) do
    missing = Enum.reject(@required_fields, &present?(Map.get(attrs, &1)))

    cond do
      missing != [] ->
        {:error, {:missing_governed_codex_fields, missing}}

      forbidden_key(attrs) ->
        {:error, {:forbidden_governed_codex_field, forbidden_key(attrs)}}

      not valid_uuid?(attrs.subject_id) or not valid_uuid?(attrs.run_id) or
          not valid_uuid?(attrs.review_unit_id) ->
        {:error, :invalid_governed_codex_owner_identity}

      not safe_workspace_root?(attrs.workspace_root) ->
        {:error, :invalid_governed_codex_workspace}

      not safe_relative_path?(attrs.relative_path) ->
        {:error, :invalid_governed_codex_relative_path}

      not safe_workspace_target?(attrs.workspace_root, attrs.relative_path) ->
        {:error, :unsafe_governed_codex_workspace_target}

      not is_binary(attrs.reviewed_content) or not String.valid?(attrs.reviewed_content) or
          byte_size(attrs.reviewed_content) > @max_reviewed_content_bytes ->
        {:error, :invalid_governed_codex_reviewed_content}

      true ->
        :ok
    end
  end

  defp normalize_attrs(attrs, allowed) do
    attrs = Map.new(attrs)

    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_key(key, allowed) do
        nil -> {:halt, {:error, {:unknown_governed_codex_field, key}}}
        normalized -> {:cont, {:ok, Map.put(acc, normalized, value)}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok,
         normalized
         |> Map.put_new(:actor_ref, "actor://synapse/operator")
         |> Map.put_new(:installation_ref, @default_installation_ref)
         |> Map.put_new_lazy(:idempotency_key, fn ->
           "nshkr:p04:#{token(inspect(normalized))}"
         end)
         |> Map.put_new_lazy(:trace_ref, fn ->
           "trace://nshkr/p04/#{token(inspect(normalized))}"
         end)}

      {:error, _reason} = error ->
        error
    end
  rescue
    _error -> {:error, :invalid_governed_codex_effect}
  end

  defp normalize_key(key, allowed) when is_atom(key), do: if(key in allowed, do: key)

  defp normalize_key(key, allowed) when is_binary(key),
    do: Enum.find(allowed, &(Atom.to_string(&1) == key))

  defp normalize_key(_key, _allowed), do: nil

  defp forbidden_key(value) when is_map(value) do
    Enum.find_value(value, fn {key, nested} ->
      normalized = key |> to_string() |> String.downcase()
      if normalized in @forbidden_keys, do: normalized, else: forbidden_key(nested)
    end)
  end

  defp forbidden_key(values) when is_list(values), do: Enum.find_value(values, &forbidden_key/1)
  defp forbidden_key(_value), do: nil

  defp safe_workspace_root?(path) when is_binary(path) do
    expanded = Path.expand(path)

    Path.type(path) == :absolute and expanded == path and File.dir?(expanded) and
      expanded not in ["/", "/home", "/home/home"]
  end

  defp safe_workspace_root?(_path), do: false

  defp safe_relative_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and
      path
      |> Path.split()
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp safe_relative_path?(_path), do: false

  defp safe_workspace_target?(root, relative_path) do
    components = Path.split(relative_path)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(root) do
      components
      |> Enum.with_index()
      |> Enum.reduce_while(root, fn {component, index}, parent ->
        path = Path.join(parent, component)
        final? = index == length(components) - 1

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} when not final? ->
            {:cont, path}

          {:ok, %File.Stat{type: :regular}} when final? ->
            {:cont, path}

          {:error, :enoent} ->
            {:halt, true}

          _other ->
            {:halt, false}
        end
      end)
      |> then(&(&1 == true or is_binary(&1)))
    else
      _other -> false
    end
  end

  defp inside_workspace?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)
    expanded_path != expanded_root and String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_governed_codex_field, key}}
    end
  end

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp trace_id(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp token(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp digest(value) when is_binary(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp earliest(left, right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp map_value(map, key, default \\ nil)

  defp map_value(nil, _key, default), do: default

  defp map_value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp map_value(_value, _key, default), do: default

  defp durable_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp durable_reason({tag, _details}) when is_atom(tag), do: Atom.to_string(tag)
  defp durable_reason(%{__struct__: module}) when is_atom(module), do: Atom.to_string(module)
  defp durable_reason(_reason), do: "redacted_error"
end
