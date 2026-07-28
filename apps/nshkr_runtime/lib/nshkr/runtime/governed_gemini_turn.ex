defmodule Nshkr.Runtime.GovernedGeminiTurn do
  @moduledoc """
  Composes one accepted Synapse turn through the governed local Gemini effect.

  The caller supplies the already-accepted Mezzanine run and turn references
  plus the current prompt. Credentials are resolved only through the durable
  Jido managed-account lease and the supervised Vault materializer.
  """

  alias Citadel.Governance.ModelAuthority
  alias Citadel.PolicyPacks.ModelInvocationPolicy
  alias Jido.Integration.V2.Auth
  alias Jido.Integration.V2.Auth.SecretGuard
  alias Jido.Integration.V2.ControlPlane
  alias Jido.Integration.V2.InferenceRequest
  alias Jido.Integration.V2.MaterializationRequest
  alias Mezzanine.WorkflowRuntime.Store, as: MezzanineStore
  alias OuterBrain.Persistence.ArtifactAccess
  alias OuterBrain.Persistence.Store, as: OuterBrainStore
  alias OuterBrain.Prompting.SemanticTurnArtifacts

  @model "gemini-2.5-flash"
  @model_ref "model://google/gemini-2.5-flash"
  @provider_family "gemini"
  @provider_base_url "https://generativelanguage.googleapis.com/v1beta"
  @system_instruction "You are the governed NSHKR Synapse Gemini execution lane."
  @default_account_ref "provider-account://nshkr/developer-local/gemini/primary"
  @allowed_fields ~w(
    account_ref actor_ref input_artifact_ref memory_snapshot_refs operation prompt
    run_ref subject_ref tenant_ref trace_ref correlation_ref turn_ref
  )a
  @required_fields ~w(input_artifact_ref prompt run_ref subject_ref tenant_ref turn_ref)a

  @type operation :: :completion | :stream

  @spec execute(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def execute(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs),
         :ok <- SecretGuard.validate_durable(attrs),
         :ok <- validate_fields(attrs),
         {:ok, operation} <- operation(attrs),
         {:ok, prompt} <- required_string(attrs, :prompt),
         {:ok, turn_state} <- admit_turn(attrs),
         {:ok, result} <- execute_new_turn(attrs, prompt, operation, turn_state) do
      {:ok, result}
    end
  end

  def execute(_attrs), do: {:error, :invalid_governed_gemini_turn}

  @spec readback(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def readback(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, tenant_ref} <- required_string(attrs, :tenant_ref),
         {:ok, turn_ref} <- required_string(attrs, :turn_ref),
         {:ok, turn} <-
           MezzanineStore.fetch_model_turn(turn_ref, repo: Mezzanine.OpsDomain.Repo),
         true <- turn.state == "completed" or {:error, {:model_turn_not_completed, turn.state}},
         {:ok, events} <-
           MezzanineStore.list_provider_events(
             turn_ref,
             0,
             repo: Mezzanine.OpsDomain.Repo,
             limit: 1_000
           ),
         {:ok, cursor} <-
           MezzanineStore.read_model_turn_cursor(turn_ref, repo: Mezzanine.OpsDomain.Repo),
         {:ok, attempt} <- ControlPlane.fetch_attempt(turn.provider_attempt_ref),
         {:ok, grant} <- ModelAuthority.fetch_grant(turn.grant_ref),
         publication when not is_nil(publication) <-
           OuterBrainStore.latest_publication(
             tenant_ref,
             turn_ref,
             repo: OuterBrain.Persistence.Repo
           ),
         {:ok, reply} <-
           resolve_reply(tenant_ref, publication.reply_artifact_ref, turn.operation_ref) do
      {:ok,
       %{
         turn: turn,
         provider_events: events,
         cursor: cursor,
         attempt: attempt,
         grant: grant,
         publication: publication,
         reply_text: reply.payload
       }}
    else
      nil -> {:error, :reply_publication_not_found}
      {:error, _reason} = error -> error
      false -> {:error, :invalid_model_turn_readback}
    end
  end

  def readback(_attrs), do: {:error, :invalid_governed_gemini_readback}

  @spec capability_id() :: String.t()
  def capability_id, do: "model.gemini.managed-account.local-effect"

  @spec model() :: String.t()
  def model, do: @model

  defp execute_new_turn(attrs, prompt_text, operation, :new) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    refs = refs(attrs, operation)

    with {:ok, prompt} <- prepare_prompt(attrs, prompt_text, refs),
         {:ok, prompt} <-
           OuterBrainStore.record_prompt_context(
             prompt,
             tenant_id: value(attrs, :tenant_ref),
             repo: OuterBrain.Persistence.Repo
           ),
         refs = bind_prompt(refs, prompt),
         {:ok, account, account_ref} <- ensure_account(attrs, now),
         refs = bind_account(refs, account),
         {:ok, grant, input_digest} <- issue_grant(attrs, prompt, refs, now),
         {:ok, lease, lease_context} <-
           request_lease(attrs, account_ref, refs, grant, input_digest, now),
         materialization_request = materialization_request(lease, account_ref, refs, now),
         :ok <- start_model_turn(attrs, prompt, refs),
         {:ok, inference} <-
           invoke(
             attrs,
             prompt_text,
             operation,
             lease,
             materialization_request,
             lease_context,
             refs,
             now
           ),
         {:ok, provider_events} <- record_provider_events(attrs, inference, refs),
         {:ok, continuation} <- publish_reply(attrs, prompt, inference, refs),
         {:ok, completed_turn} <- complete_model_turn(attrs, continuation, refs) do
      {:ok,
       %{
         capability_id: capability_id(),
         operation: operation,
         model: @model,
         account_ref: account.account_ref,
         grant_ref: grant.grant_ref,
         credential_lease_ref: lease.lease_id,
         provider_attempt_ref: refs.provider_attempt_ref,
         provider_events: provider_events,
         inference: inference,
         continuation: continuation,
         turn: completed_turn
       }}
    end
  end

  defp execute_new_turn(attrs, _prompt_text, _operation, :completed), do: readback(attrs)

  defp admit_turn(attrs) do
    case MezzanineStore.fetch_model_turn(
           value(attrs, :turn_ref),
           repo: Mezzanine.OpsDomain.Repo
         ) do
      {:error, :not_found} -> {:ok, :new}
      {:ok, %{state: "completed"}} -> {:ok, :completed}
      {:ok, %{state: state}} -> {:error, {:model_turn_already_started, state}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_prompt(attrs, prompt_text, refs) do
    SemanticTurnArtifacts.prepare_prompt(%{
      tenant_ref: value(attrs, :tenant_ref),
      installation_ref: "installation://nshkr/developer-local",
      workspace_ref: "workspace://synapse/default",
      project_ref: "project://synapse/default",
      environment_ref: "environment://nshkr/developer-local",
      authority_packet_ref: refs.authority_packet_ref,
      permission_decision_ref: refs.permission_decision_ref,
      idempotency_key: "nshkr:gemini:#{refs.token}",
      trace_id: value(attrs, :trace_ref, "trace://nshkr/gemini/#{refs.token}"),
      correlation_id: value(attrs, :correlation_ref, "correlation://nshkr/gemini/#{refs.token}"),
      release_manifest_ref: "release://nshkr/p03",
      input_claim_check_ref: "claim-check://nshkr/gemini/#{refs.token}/input",
      output_claim_check_ref: "claim-check://nshkr/gemini/#{refs.token}/output",
      redaction_policy_ref: refs.redaction_ref,
      normalizer_version: "outer-brain-normalizer-v1",
      run_ref: value(attrs, :run_ref),
      turn_ref: value(attrs, :turn_ref),
      model_profile_ref: "model-profile://nshkr/gemini-2.5-flash",
      provider_ref: @provider_family,
      model_ref: @model_ref,
      producing_operation_ref: "operation://outer-brain/context/#{refs.token}",
      principal_ref: value(attrs, :actor_ref, "actor://synapse/operator"),
      source_artifacts: [
        %{
          artifact_ref: "artifact://nshkr/p03/system-instruction/v1",
          content_digest: digest(@system_instruction),
          role: "system_instruction"
        },
        %{
          artifact_ref: value(attrs, :input_artifact_ref),
          content_digest: digest(prompt_text),
          role: "user_input"
        }
      ],
      memory_snapshot_refs: value(attrs, :memory_snapshot_refs, []),
      allowed_reader_refs: ["reader://synapse/runtime"],
      allowed_operation_refs: ["operation://synapse/read"]
    })
  end

  defp ensure_account(attrs, now) do
    account_ref = value(attrs, :account_ref, @default_account_ref)

    case Auth.fetch_managed_account(account_ref) do
      {:ok, account} ->
        validate_account(account, attrs)

      {:error, :unknown_managed_account} ->
        with {:ok, %{account: account, account_ref: managed_ref}} <-
               Auth.register_managed_account(%{
                 provider_family: @provider_family,
                 account_ref: account_ref,
                 tenant_id: value(attrs, :tenant_ref),
                 connector_id: "gemini",
                 endpoint_ref: "endpoint://gemini/generate-content",
                 quota_scope_ref: "quota://gemini/nshkr-primary",
                 credential_handle_ref: "credential-handle://gemini/nshkr-primary/v1",
                 secret_provider_ref: "vault://nshkr/kv-v2",
                 secret_binding_ref: "vault-secret://gemini/primary",
                 subject: "nshkr-runtime",
                 actor_id: "nshkr-runtime",
                 scopes: ["model:invoke"],
                 lease_fields: ["api_key"],
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

      account.tenant_id != value(attrs, :tenant_ref) ->
        {:error, :managed_account_tenant_mismatch}

      account.state != :active ->
        {:error, :managed_account_not_active}

      true ->
        {:ok, account, Jido.Integration.V2.Auth.ManagedAccount.ref(account)}
    end
  end

  defp issue_grant(attrs, prompt, refs, now) do
    policy = ModelInvocationPolicy.synapse_gemini_turn!()

    grant_attrs = %{
      session_ref: refs.session_ref,
      decision_ref: refs.decision_ref,
      grant_ref: refs.grant_ref,
      tenant_ref: value(attrs, :tenant_ref),
      actor_ref: value(attrs, :actor_ref, "actor://synapse/operator"),
      subject_ref: value(attrs, :subject_ref),
      provider_family: @provider_family,
      account_ref: refs.account_ref,
      model_ref: @model,
      operation_ref: refs.operation_ref,
      operation_class: refs.operation_class,
      context_ref: prompt.context_artifact.descriptor.artifact_ref,
      context_digest: prompt.context_artifact.descriptor.content_digest,
      attempt_ref: refs.provider_attempt_ref,
      effect_ref: refs.effect_ref,
      fence_token: refs.fence_token,
      issued_at: now,
      expires_at: DateTime.add(now, 90, :second)
    }

    case ModelAuthority.fetch_grant(refs.grant_ref) do
      {:ok, grant} ->
        with :ok <-
               ModelAuthority.verify_grant(
                 grant.grant_ref,
                 grant_binding(grant_attrs, grant, policy),
                 now
               ) do
          {:ok, grant, grant.input_digest}
        end

      {:error, :grant_not_found} ->
        with {:ok, input_digest} <- ModelAuthority.input_digest(grant_attrs),
             {:ok, %{result: :permitted, grant: grant}} <-
               ModelAuthority.evaluate_and_persist(grant_attrs, policy) do
          {:ok, grant, input_digest}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp grant_binding(attrs, grant, policy) do
    attrs
    |> Map.take([
      :decision_ref,
      :tenant_ref,
      :actor_ref,
      :subject_ref,
      :provider_family,
      :account_ref,
      :model_ref,
      :operation_ref,
      :operation_class,
      :context_ref,
      :context_digest,
      :attempt_ref,
      :effect_ref,
      :fence_token
    ])
    |> Map.merge(%{
      input_digest: grant.input_digest,
      policy_ref: policy.artifact_ref,
      policy_version: policy.policy_version
    })
  end

  defp request_lease(attrs, account_ref, refs, grant, input_digest, now) do
    context =
      %{
        tenant_id: value(attrs, :tenant_ref),
        actor_id: "nshkr-runtime",
        actor_ref: value(attrs, :actor_ref, "actor://synapse/operator"),
        subject_ref: value(attrs, :subject_ref),
        required_scopes: ["model:invoke"],
        ttl_seconds: 90,
        now: now,
        provider_family: @provider_family,
        provider_ref: @provider_family,
        provider_account_ref: refs.account_ref,
        connector_instance_ref: "connector-instance://gemini/nshkr-primary",
        connector_binding_ref: "connector-binding://gemini/nshkr-primary",
        credential_ref: "credential://gemini/nshkr-primary",
        credential_handle_ref: refs.credential_handle_ref,
        operation_class: "inference",
        execution_context_ref: refs.context_ref,
        context_digest: refs.context_digest,
        target_ref: refs.target_ref,
        target_posture_ref: "target-posture://nshkr/local-provider-effect",
        attach_grant_ref: "attach-grant://nshkr/gemini/#{refs.token}",
        operation_policy_ref: grant.policy_ref,
        policy_revision_ref: "policy-revision://citadel/gemini-turn/v1",
        target_grant_revision: "target-grant-revision://nshkr/gemini/#{refs.token}/v1",
        rotation_epoch: refs.generation,
        fence_token: refs.fence_token,
        authority_ref: grant.grant_ref,
        authority_decision_ref: grant.decision_ref,
        authority_scope: ["model:invoke"],
        installation_revision: "installation://nshkr/developer-local/v1",
        effect_ref: refs.effect_ref,
        operation_ref: refs.operation_ref,
        endpoint_ref: refs.endpoint_ref,
        max_calls: 1,
        max_tokens: 512,
        allowed_models: [@model],
        network_policy: :provider_only,
        requested_model: @model,
        requested_tokens: 256,
        network_target: :provider,
        current_policy_revision_ref: "policy-revision://citadel/gemini-turn/v1",
        current_rotation_epoch: refs.generation,
        current_target_grant_revision: "target-grant-revision://nshkr/gemini/#{refs.token}/v1",
        current_installation_revision: "installation://nshkr/developer-local/v1",
        requested_authority_scope: ["model:invoke"],
        service_identity_ref: "service-identity://nshkr/runtime",
        service_principal_ref: "service-principal://nshkr/runtime",
        model_ref: @model,
        redaction_ref: refs.redaction_ref,
        model_grant_input_digest: input_digest,
        model_grant_operation_class: refs.operation_class,
        model_grant_policy_ref: grant.policy_ref,
        model_grant_policy_version: grant.policy_version
      }

    with {:ok, lease} <- Auth.request_managed_lease(account_ref, context) do
      {:ok, lease, context}
    end
  end

  defp materialization_request(lease, account_ref, refs, now) do
    MaterializationRequest.new!(%{
      materialization_ref: refs.materialization_ref,
      lease_id: lease.lease_id,
      account: account_ref,
      effect_ref: refs.effect_ref,
      operation_ref: refs.operation_ref,
      authority_ref: refs.grant_ref,
      endpoint_ref: refs.endpoint_ref,
      target_ref: refs.target_ref,
      issued_at: now,
      expires_at: earliest(DateTime.add(now, 60, :second), lease.expires_at)
    })
  end

  defp start_model_turn(attrs, prompt, refs) do
    MezzanineStore.start_model_turn(
      %{
        tenant_ref: value(attrs, :tenant_ref),
        run_ref: value(attrs, :run_ref),
        turn_ref: value(attrs, :turn_ref),
        context_artifact_ref: prompt.context_artifact.descriptor.artifact_ref,
        context_digest: prompt.context_artifact.descriptor.content_digest,
        prompt_artifact_ref: prompt.prompt_artifact.descriptor.artifact_ref,
        decision_ref: refs.decision_ref,
        grant_ref: refs.grant_ref,
        provider_attempt_ref: refs.provider_attempt_ref,
        provider_family: @provider_family,
        model_ref: @model_ref,
        operation_ref: refs.operation_ref
      },
      repo: Mezzanine.OpsDomain.Repo
    )
    |> ok()
  end

  defp invoke(
         attrs,
         prompt_text,
         operation,
         lease,
         materialization_request,
         materialization_context,
         refs,
         now
       ) do
    request =
      InferenceRequest.new!(%{
        request_id: "request://jido/inference/#{refs.token}",
        operation: if(operation == :stream, do: :stream_text, else: :generate_text),
        messages: [
          %{role: "system", content: @system_instruction},
          %{role: "user", content: prompt_text}
        ],
        prompt: nil,
        model_preference: %{
          provider: @provider_family,
          id: @model,
          base_url: @provider_base_url
        },
        target_preference: %{
          target_class: "cloud_provider",
          management_mode: :jido_managed
        },
        stream?: operation == :stream,
        tool_policy: %{},
        output_constraints: %{temperature: 0.1, max_tokens: 256},
        metadata: %{
          tenant_id: value(attrs, :tenant_ref),
          prompt_artifact_ref: refs.prompt_artifact_ref
        }
      })

    ControlPlane.invoke_inference(request,
      run_id: refs.jido_run_id,
      decision_ref: refs.decision_ref,
      authority_ref: refs.grant_ref,
      credential_lease: lease,
      materialization_request: materialization_request,
      materialization_context: Map.put(materialization_context, :now, now),
      model_grant_ref: refs.grant_ref,
      now: now,
      require_artifact_refs?: true,
      trace_id: value(attrs, :trace_ref, "trace://nshkr/gemini/#{refs.token}"),
      correlation_id: value(attrs, :correlation_ref, "correlation://nshkr/gemini/#{refs.token}")
    )
  end

  defp record_provider_events(attrs, inference, refs) do
    stream_events =
      case inference.stream do
        %{checkpoints: checkpoints} when is_list(checkpoints) ->
          checkpoints
          |> Enum.with_index(1)
          |> Enum.map(fn {checkpoint, sequence} ->
            %{
              event_type: "inference.stream_delta",
              payload_ref:
                "jido://v2/attempt/#{URI.encode_www_form(refs.provider_attempt_ref)}/stream/checkpoint/#{sequence}",
              payload_digest: digest(Jason.encode!(checkpoint))
            }
          end)

        _other ->
          []
      end

    terminal = %{
      event_type: "inference.attempt_completed",
      payload_ref: "jido://v2/attempt/#{URI.encode_www_form(refs.provider_attempt_ref)}/result",
      payload_digest: response_digest(inference)
    }

    (stream_events ++ [terminal])
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {event, sequence}, {:ok, acc} ->
      event_ref = "event://jido/gemini/#{refs.token}/#{sequence}"

      attrs = %{
        event_ref: event_ref,
        run_ref: value(attrs, :run_ref),
        turn_ref: value(attrs, :turn_ref),
        provider_attempt_ref: refs.provider_attempt_ref,
        sequence: sequence,
        event_type: event.event_type,
        stream: "assistant",
        payload_ref: event.payload_ref,
        payload_digest: event.payload_digest,
        observed_at:
          DateTime.utc_now()
          |> DateTime.add(sequence, :millisecond)
          |> DateTime.truncate(:microsecond)
      }

      with {:ok, provisional} <-
             MezzanineStore.append_provider_event(
               attrs,
               repo: Mezzanine.OpsDomain.Repo
             ),
           {:ok, committed} <-
             MezzanineStore.commit_provider_event(
               provisional.event_ref,
               repo: Mezzanine.OpsDomain.Repo
             ) do
        {:cont, {:ok, [committed | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp publish_reply(attrs, prompt, inference, refs) do
    with response when is_binary(response) and response != "" <- inference.response_text,
         {:ok, continuation} <-
           SemanticTurnArtifacts.prepare_reply(prompt, %{
             attempt_ref: refs.provider_attempt_ref,
             assistant_reply: response,
             dedupe_key: "#{value(attrs, :turn_ref)}:final",
             published_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
             allowed_reader_refs: ["reader://synapse/runtime"],
             allowed_operation_refs: ["operation://synapse/read"]
           }),
         {:ok, continuation} <-
           OuterBrainStore.publish_reply_continuation(
             continuation,
             tenant_id: value(attrs, :tenant_ref),
             repo: OuterBrain.Persistence.Repo
           ) do
      {:ok, continuation}
    else
      _other -> {:error, :invalid_gemini_reply}
    end
  end

  defp complete_model_turn(attrs, continuation, refs) do
    MezzanineStore.complete_model_turn(
      %{
        turn_ref: value(attrs, :turn_ref),
        provider_attempt_ref: refs.provider_attempt_ref,
        reply_publication_ref: continuation.publication.publication_id,
        reply_artifact_ref: continuation.reply_artifact.descriptor.artifact_ref,
        continuation_context_ref: continuation.next_context_artifact.descriptor.artifact_ref,
        continuation_context_digest: continuation.next_context_artifact.descriptor.content_digest
      },
      repo: Mezzanine.OpsDomain.Repo
    )
  end

  defp resolve_reply(tenant_ref, reply_artifact_ref, operation_ref) do
    with {:ok, authority_packet_ref} <- authority_packet_ref(operation_ref),
         {:ok, access} <-
           ArtifactAccess.new(%{
             tenant_ref: tenant_ref,
             reader_ref: "reader://synapse/runtime",
             operation_ref: "operation://synapse/read",
             authority_packet_ref: authority_packet_ref
           }) do
      OuterBrainStore.resolve_artifact_payload(reply_artifact_ref, access,
        repo: OuterBrain.Persistence.Repo
      )
    end
  end

  defp refs(attrs, operation) do
    token =
      digest("#{value(attrs, :run_ref)}|#{value(attrs, :turn_ref)}|#{operation}")
      |> String.replace_prefix("sha256:", "")
      |> binary_part(0, 24)

    operation_class =
      if operation == :stream, do: "stream_generate_content", else: "generate_content"

    jido_run_id = "jido-run://nshkr/gemini/#{token}"

    %{
      token: token,
      operation_class: operation_class,
      session_ref: "session://nshkr/gemini/#{token}",
      decision_ref: "decision://citadel/model/#{token}",
      grant_ref: "grant://citadel/model/#{token}",
      permission_decision_ref: "permission-decision://citadel/model/#{token}",
      authority_packet_ref: "authority-packet://nshkr/gemini/#{token}",
      operation_ref: "operation://gemini/#{operation_class}/#{token}",
      effect_ref: "effect://nshkr/gemini/#{token}",
      target_ref: "target://nshkr/local/gemini",
      redaction_ref: "redaction://nshkr/gemini/v1",
      materialization_ref: "materialization://jido/gemini/#{token}",
      jido_run_id: jido_run_id,
      provider_attempt_ref: Jido.Integration.V2.Contracts.attempt_id(jido_run_id, 1)
    }
  end

  defp bind_account(refs, account) do
    Map.merge(refs, %{
      account_ref: account.account_ref,
      credential_handle_ref: account.credential_handle_ref,
      endpoint_ref: account.endpoint_ref,
      generation: account.generation,
      fence_token: "#{account.account_ref}:fence:#{account.fence}"
    })
  end

  defp bind_prompt(refs, prompt) do
    Map.merge(refs, %{
      context_ref: prompt.context_artifact.descriptor.artifact_ref,
      context_digest: prompt.context_artifact.descriptor.content_digest,
      prompt_artifact_ref: prompt.prompt_artifact.descriptor.artifact_ref
    })
  end

  defp authority_packet_ref(operation_ref) when is_binary(operation_ref) do
    case operation_ref |> String.split("/", trim: true) |> List.last() do
      token when is_binary(token) and byte_size(token) == 24 ->
        {:ok, "authority-packet://nshkr/gemini/#{token}"}

      _other ->
        {:error, :invalid_gemini_operation_ref}
    end
  end

  defp normalize_attrs(attrs) do
    attrs = Map.new(attrs)
    {:ok, Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)}
  rescue
    _error -> {:error, :invalid_governed_gemini_turn}
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case Enum.find(@allowed_fields, &(Atom.to_string(&1) == key)) do
      nil -> key
      field -> field
    end
  end

  defp normalize_key(key), do: key

  defp validate_fields(attrs) do
    unknown = Map.keys(attrs) -- @allowed_fields
    missing = Enum.reject(@required_fields, &present_string?(value(attrs, &1)))

    cond do
      unknown != [] -> {:error, {:unknown_governed_gemini_fields, Enum.sort(unknown)}}
      missing != [] -> {:error, {:missing_governed_gemini_fields, Enum.sort(missing)}}
      true -> :ok
    end
  end

  defp operation(attrs) do
    case value(attrs, :operation, :completion) do
      :completion -> {:ok, :completion}
      "completion" -> {:ok, :completion}
      :stream -> {:ok, :stream}
      "stream" -> {:ok, :stream}
      _other -> {:error, :invalid_governed_gemini_operation}
    end
  end

  defp required_string(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_governed_gemini_field, key}}
    end
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp digest(value) when is_binary(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp response_digest(inference) do
    metadata = inference.inference_result.metadata
    artifact = Map.get(metadata, "text_artifact_ref", Map.get(metadata, :text_artifact_ref, %{}))

    case Map.get(artifact, "content_hash", Map.get(artifact, :content_hash)) do
      "sha256:" <> _digest = content_hash -> content_hash
      _missing -> digest(inference.response_text)
    end
  end

  defp earliest(left, right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end

  defp ok({:ok, _value}), do: :ok
  defp ok({:error, _reason} = error), do: error
end
