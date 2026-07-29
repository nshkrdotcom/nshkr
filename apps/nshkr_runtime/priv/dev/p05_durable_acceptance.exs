unless System.get_env("NSHKR_P05_ACCEPTANCE") == "1" do
  raise "set NSHKR_P05_ACCEPTANCE=1 to run the bounded P05 durable acceptance"
end

defmodule Nshkr.Runtime.P05DurableAcceptance do
  @moduledoc false

  alias AppKit.BackendStack
  alias AppKit.Core.{MemoryFragmentListRequest, RequestContext}
  alias Jido.Integration.V2.{Attempt, CredentialRef, Run}
  alias Jido.Integration.V2.ControlPlane
  alias Jido.Integration.V2.ControlPlane.Stores
  alias Mezzanine.Audit.{MemoryProofToken, MemoryProofTokenStore}
  alias Nshkr.Runtime.{AppKitBackendStack, Profile}
  alias OuterBrain.{MemoryProvenance, MemoryRecord}
  alias OuterBrain.Persistence.Store

  @installation_ref "installation://nshkr/developer-local"

  def run! do
    profile = load_config!()
    migrate!(profile)
    {:ok, _started} = Application.ensure_all_started(:nshkr_runtime)
    wait_for_recovery_binding!()

    case System.fetch_env!("NSHKR_P05_MODE") do
      "write" -> write!()
      "readback" -> readback!()
      _other -> raise "NSHKR_P05_MODE must be write or readback"
    end
  end

  defp write! do
    refs = refs()
    recorded_at = ~U[2026-07-29 06:00:00.000000Z]

    {:ok, provenance} =
      MemoryProvenance.new(%{
        source_ref: "artifact://synapse/p05/#{refs.token}/source",
        producer_ref: "producer://outer-brain/demanded-memory",
        authority_ref: System.fetch_env!("NSHKR_SYNAPSE_CONTROL_AUTHORITY_REF"),
        trace_ref: refs.trace_ref,
        causal_parent_refs: ["turn://synapse/p05/#{refs.token}"],
        recording_operation_ref: "operation://outer-brain/memory/write-private"
      })

    {:ok, memory} =
      MemoryRecord.new(%{
        memory_ref: refs.memory_ref,
        tenant_ref: refs.tenant_ref,
        subject_ref: refs.subject_ref,
        class: :working,
        content_artifact_ref: "artifact://outer-brain/p05/#{refs.token}/content",
        content_digest: digest("p05-durable-content-#{refs.token}"),
        provenance: provenance,
        recorded_at: recorded_at
      })

    {:ok, persisted_memory} =
      Store.record_memory(memory,
        tenant_id: refs.tenant_ref,
        repo: OuterBrain.Persistence.Repo,
        indexed_at: recorded_at
      )

    commit_lsn =
      OuterBrain.Persistence.Repo.query!("SELECT pg_current_wal_lsn()::text").rows
      |> List.first()
      |> List.first()

    token =
      MemoryProofToken.new!(%{
        proof_hash_version: "m7a.v1",
        proof_id: refs.proof_ref,
        kind: :recall,
        tenant_ref: refs.tenant_ref,
        installation_id: @installation_ref,
        subject_id: refs.subject_ref,
        execution_id: "execution://synapse/p05/#{refs.token}",
        user_ref: "actor://synapse/operator",
        agent_ref: "agent://synapse/p05",
        t_event: recorded_at,
        epoch_used: 1,
        source_node_ref: "node://outer-brain/developer-local",
        commit_lsn: commit_lsn,
        commit_hlc: %{
          "w" => DateTime.to_unix(recorded_at, :nanosecond),
          "l" => 0,
          "n" => "node://outer-brain/developer-local"
        },
        policy_refs: [%{id: "policy://nshkr/p05/demanded-memory", version: 1}],
        fragment_ids: [refs.memory_ref],
        transform_hashes: [],
        access_projection_hashes: [],
        trace_id: refs.trace_ref,
        evidence_refs: [%{"ref" => "evidence://nshkr/p05/#{refs.token}/memory-record"}],
        governance_decision_ref: %{
          "ref" => System.fetch_env!("NSHKR_SYNAPSE_CONTROL_PERMISSION_DECISION_REF")
        },
        metadata: %{"status" => "admitted", "effect_retry" => "prohibited"}
      })

    {:ok, persisted_token} = MemoryProofTokenStore.emit(token)
    :ok = MemoryProofToken.verify_hash(persisted_token)
    projection = app_kit_projection!(refs)
    {run, attempt} = put_recoverable_attempt!(refs)

    assert!(persisted_memory.memory_ref == refs.memory_ref, :memory_ref_mismatch)
    assert!(projection.fragment_ref == refs.memory_ref, :app_kit_memory_ref_mismatch)
    assert!(projection.proof_token_ref == refs.proof_ref, :app_kit_proof_ref_mismatch)
    assert!(projection.redaction_posture == "refs_only", :unsafe_app_kit_redaction_posture)

    IO.puts("mode=write")
    IO.puts("memory_ref=#{persisted_memory.memory_ref}")
    IO.puts("proof_token_ref=#{persisted_token.proof_id}")
    IO.puts("proof_hash=sha256:#{persisted_token.proof_hash}")
    IO.puts("run_id=#{run.run_id}")
    IO.puts("attempt_id=#{attempt.attempt_id}")
    IO.puts("effect_retry=prohibited")
  end

  defp readback! do
    refs = refs()
    projection = app_kit_projection!(refs)

    {:ok, provenance} =
      operator_backend!().memory_fragment_provenance(
        request_context!(refs),
        refs.memory_ref,
        operator_options!()
      )

    {attempt, recovery_task} = wait_for_recovery!(refs)
    {:ok, run} = ControlPlane.fetch_run(attempt.run_id)

    assert!(projection.fragment_ref == refs.memory_ref, :memory_ref_mismatch)
    assert!(projection.proof_token_ref == refs.proof_ref, :proof_ref_mismatch)
    assert!(projection.redaction_posture == "refs_only", :unsafe_app_kit_redaction_posture)
    assert!(provenance.fragment_ref == refs.memory_ref, :provenance_ref_mismatch)
    assert!(provenance.proof_token_ref == refs.proof_ref, :provenance_proof_ref_mismatch)
    assert!(attempt.status == :failed, :attempt_not_failed_closed)
    assert!(run.status == :failed, :run_not_failed_closed)
    assert!(recovery_task.status == :quarantined, :recovery_not_quarantined)

    assert!(
      recovery_task.metadata["reason"] == "external_operation_not_found",
      :unexpected_recovery_reason
    )

    assert!(recovery_task.metadata["effect_retry"] == "prohibited", :effect_retry_not_prohibited)

    IO.puts("mode=readback")
    IO.puts("memory_ref=#{projection.fragment_ref}")
    IO.puts("proof_token_ref=#{projection.proof_token_ref}")
    IO.puts("redaction_posture=#{projection.redaction_posture}")
    IO.puts("attempt_status=#{attempt.status}")
    IO.puts("run_status=#{run.status}")
    IO.puts("recovery_status=#{recovery_task.status}")
    IO.puts("recovery_reason=#{recovery_task.metadata["reason"]}")
    IO.puts("effect_retry=#{recovery_task.metadata["effect_retry"]}")
  end

  defp app_kit_projection!(refs) do
    {:ok, request} =
      MemoryFragmentListRequest.new(%{
        proof_token_ref: refs.proof_ref,
        include_provenance?: true
      })

    case operator_backend!().list_memory_fragments(
           request_context!(refs),
           request,
           operator_options!()
         ) do
      {:ok, [projection]} -> projection
      other -> raise "unexpected AppKit demanded-memory projection: #{inspect(other)}"
    end
  end

  defp operator_options! do
    stack = AppKitBackendStack.backend_stack()

    [
      operator_backend: operator_backend!(),
      backend_stack: stack
    ] ++ Application.fetch_env!(:synapse_core, :app_kit_backend_options)
  end

  defp operator_backend! do
    {:ok, operator_backend} =
      AppKitBackendStack.backend_stack()
      |> BackendStack.fetch(:operator_backend)

    operator_backend
  end

  defp request_context!(refs) do
    {:ok, context} =
      RequestContext.new(%{
        trace_id:
          digest(refs.token) |> String.replace_prefix("sha256:", "") |> binary_part(0, 32),
        actor_ref: %{id: "actor://synapse/operator", kind: :human},
        tenant_ref: %{id: refs.tenant_ref},
        installation_ref: %{
          id: @installation_ref,
          pack_slug: "synapse",
          status: :active,
          compiled_pack_revision: 1
        },
        request_id: "request://nshkr/p05/#{refs.token}/memory",
        idempotency_key: "nshkr:p05:memory:#{refs.token}"
      })

    context
  end

  defp put_recoverable_attempt!(refs) do
    run =
      Run.new!(%{
        run_id: "run-nshkr-p05-#{refs.token}",
        capability_id: "codex.session.turn",
        runtime_class: :session,
        status: :running,
        input: %{"input_ref" => "artifact://nshkr/p05/#{refs.token}/reviewed-input"},
        credential_ref:
          CredentialRef.new!(%{
            id: "credential-ref-nshkr-p05-#{refs.token}",
            subject: "actor://synapse/operator",
            scopes: ["provider:run"]
          })
      })

    attempt =
      Attempt.new!(%{
        run_id: run.run_id,
        attempt: 1,
        runtime_class: :session,
        status: :running,
        runtime_ref_id: "asm-session-nshkr-p05-missing-#{refs.token}"
      })

    :ok = Stores.run_store().put_run(run)
    :ok = Stores.attempt_store().put_attempt(attempt)
    {run, attempt}
  end

  defp wait_for_recovery!(refs, tries \\ 200)

  defp wait_for_recovery!(_refs, 0), do: raise("P05 startup attempt reconciliation timed out")

  defp wait_for_recovery!(refs, tries) do
    run_id = "run-nshkr-p05-#{refs.token}"
    attempt_id = Jido.Integration.V2.Contracts.attempt_id(run_id, 1)

    with {:ok, %{status: :failed} = attempt} <- ControlPlane.fetch_attempt(attempt_id),
         [%{status: :quarantined} = task] <-
           ControlPlane.recovery_tasks(%{attempt_id: attempt_id}) do
      {attempt, task}
    else
      _other ->
        Process.sleep(25)
        wait_for_recovery!(refs, tries - 1)
    end
  end

  defp wait_for_recovery_binding!(tries \\ 200)

  defp wait_for_recovery_binding!(0), do: raise("P05 recovery binding did not become healthy")

  defp wait_for_recovery_binding!(tries) do
    case Nshkr.Runtime.AttemptRecoveryBinding.health() do
      {:ok, _health} ->
        :ok

      _other ->
        Process.sleep(25)
        wait_for_recovery_binding!(tries - 1)
    end
  end

  defp migrate!(profile) do
    Enum.each(profile.migration_plan, fn migration ->
      result =
        Ecto.Migrator.with_repo(migration.repo, fn repo ->
          Ecto.Migrator.run(repo, migration.migration_path, :up, all: true)
        end)

      case result do
        {:ok, _versions, _started_apps} -> :ok
        other -> raise "migration failed for #{migration.owner}: #{inspect(other)}"
      end
    end)
  end

  defp load_config! do
    path = System.fetch_env!("NSHKR_PROFILE_FILE")
    state = Nshkr.Runtime.ConfigProvider.init(path: path)
    config = Nshkr.Runtime.ConfigProvider.load([], state)

    Enum.each(config, fn {application, entries} ->
      Enum.each(entries, fn {key, value} ->
        Application.put_env(application, key, value, persistent: true)
      end)
    end)

    Profile.load!()
  end

  defp refs do
    token = System.fetch_env!("NSHKR_P05_RUN_TOKEN")

    %{
      token: token,
      tenant_ref: System.fetch_env!("NSHKR_P05_TENANT_REF"),
      subject_ref: "subject://synapse/p05/#{token}",
      memory_ref: "memory://outer-brain/p05/#{token}/working",
      proof_ref: System.fetch_env!("NSHKR_SYNAPSE_MEMORY_PROOF_TOKEN_REF"),
      trace_ref: "trace://nshkr/p05/#{token}"
    }
  end

  defp assert!(true, _reason), do: :ok
  defp assert!(false, reason), do: raise("P05 acceptance assertion failed: #{reason}")

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end
end

Nshkr.Runtime.P05DurableAcceptance.run!()
