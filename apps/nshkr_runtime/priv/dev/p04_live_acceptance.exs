unless System.get_env("NSHKR_P04_LIVE") == "1" do
  raise "set NSHKR_P04_LIVE=1 to run the bounded P04 Codex effect acceptance"
end

defmodule Nshkr.Runtime.P04LiveAcceptance do
  @moduledoc false

  require Ash.Query

  alias AppKit.BackendStack
  alias AppKit.Bridges.MezzanineBridge.AgentIntakeAdapter
  alias AppKit.Core.AgentIntake.AgentRunRequest
  alias AppKit.Core.RequestContext
  alias Mezzanine.Review.ReviewUnit
  alias Mezzanine.Runs.{Run, RunSeries}
  alias Mezzanine.Work.WorkObject
  alias Nshkr.Runtime.{AppKitBackendStack, GovernedCodexEffect}

  def run! do
    start_runtime!()

    case System.fetch_env!("NSHKR_P04_MODE") do
      "execute" -> execute!()
      "readback" -> readback!()
      _other -> raise "NSHKR_P04_MODE must be execute or readback"
    end
  end

  defp execute! do
    token = System.fetch_env!("NSHKR_P04_RUN_TOKEN")
    tenant_ref = System.fetch_env!("NSHKR_P04_TENANT_REF")
    workspace_root = System.fetch_env!("NSHKR_P04_WORKSPACE_ROOT") |> Path.expand()
    relative_path = System.fetch_env!("NSHKR_P04_RELATIVE_PATH")
    reviewed_content = System.fetch_env!("NSHKR_P04_REVIEWED_CONTENT")

    :ok = File.mkdir_p(workspace_root)
    future = accept_run!(token, tenant_ref)
    {run, work_object, review} = effect_owners!(future.run_ref, tenant_ref)
    context = request_context!(token, tenant_ref)

    attrs = %{
      tenant_ref: tenant_ref,
      actor_ref: "actor://synapse/operator",
      installation_ref: "installation://nshkr/developer-local",
      idempotency_key: "nshkr:p04:codex:#{token}",
      trace_ref: "trace://nshkr/p04/codex/#{token}",
      subject_id: work_object.id,
      run_id: run.id,
      review_unit_id: review.id,
      run_ref: future.run_ref,
      turn_ref: Map.fetch!(future.governed_effect_refs, "turn_ref"),
      workspace_root: workspace_root,
      workspace_ref: "workspace://nshkr/p04/#{token}",
      relative_path: relative_path,
      reviewed_content: reviewed_content
    }

    {:ok, proposed} = GovernedCodexEffect.propose(attrs)
    accept_review!(context, work_object, review, proposed, token)

    case GovernedCodexEffect.execute(attrs) do
      {:ok, result} ->
        incremental_event_count =
          Enum.count(result.jido_events, &(event_type(&1) == "assistant_delta"))

        if incremental_event_count == 0 do
          raise "P04 governed Codex effect produced no incremental assistant output"
        end

        cleanup = result.effect.receipt.cleanup

        unless cleanup.status == "completed" and cleanup.session_terminated and
                 cleanup.materialization_removed and cleanup.credential_lease_released do
          raise "P04 governed Codex effect cleanup was not complete"
        end

        IO.puts("status=#{result.effect.status}")
        IO.puts("effect_ref=#{result.effect.effect_ref}")
        IO.puts("owner_execution_ref=#{result.effect.owner_execution_ref}")
        IO.puts("attempt_ref=#{result.effect.attempt_ref}")
        IO.puts("grant_ref=#{result.effect.grant_ref}")
        IO.puts("receipt_ref=#{result.effect.receipt.receipt_ref}")
        IO.puts("continuation_ref=#{result.effect.continuation.continuation_ref}")
        IO.puts("provider_event_count=#{length(result.jido_events)}")
        IO.puts("incremental_event_count=#{incremental_event_count}")
        IO.puts("verified_file_digest=#{result.verified_file_digest}")

      {:error, reason} ->
        raise "P04 governed Codex effect failed: #{inspect(reason)}"
    end
  end

  defp readback! do
    token = System.fetch_env!("NSHKR_P04_RUN_TOKEN")
    tenant_ref = System.fetch_env!("NSHKR_P04_TENANT_REF")

    case GovernedCodexEffect.readback(%{
           tenant_ref: tenant_ref,
           installation_ref: "installation://nshkr/developer-local",
           idempotency_key: "nshkr:p04:codex:#{token}"
         }) do
      {:ok, result} ->
        IO.puts("status=#{result.effect.status}")
        IO.puts("effect_ref=#{result.effect.effect_ref}")
        IO.puts("attempt_ref=#{result.attempt.attempt_id}")
        IO.puts("grant_ref=#{result.grant.grant_ref}")
        IO.puts("receipt_ref=#{result.effect.receipt.receipt_ref}")
        IO.puts("publication_ref=#{result.publication.publication_id}")

      {:error, reason} ->
        raise "P04 governed Codex readback failed: #{inspect(reason)}"
    end
  end

  defp start_runtime! do
    path = System.fetch_env!("NSHKR_PROFILE_FILE")
    state = Nshkr.Runtime.ConfigProvider.init(path: path)
    config = Nshkr.Runtime.ConfigProvider.load([], state)

    Enum.each(config, fn {application, entries} ->
      Enum.each(entries, fn {key, value} ->
        Application.put_env(application, key, value, persistent: true)
      end)
    end)

    {:ok, _started} = Application.ensure_all_started(:nshkr_runtime)
  end

  defp accept_run!(token, tenant_ref) do
    context = request_context!(token, tenant_ref)
    run_ref = "run://mezzanine/nshkr-p04-codex-#{token}"
    subject_ref = "subject://synapse/p04/codex/#{token}"

    request =
      AgentRunRequest.new!(%{
        tenant_ref: tenant_ref,
        installation_ref: "installation://nshkr/developer-local",
        subject_ref: subject_ref,
        actor_ref: "actor://synapse/operator",
        profile_bundle: %{
          source_profile_ref: :p04_source,
          runtime_profile_ref: :p04_codex_local,
          tool_scope_ref: :p04_one_reviewed_file,
          evidence_profile_ref: :p04_durable,
          publication_profile_ref: :p04_outer_brain,
          review_profile_ref: :p04_human_review,
          memory_profile_ref: :p04_context,
          projection_profile_ref: :p04_durable
        },
        tool_catalog_ref: "tool-catalog://synapse/codex-reviewed-file/v1",
        budget_ref: "budget://synapse/p04",
        recall_scope_ref: "recall-scope://synapse/p04",
        idempotency_key: "nshkr:p04:accept:#{token}",
        trace_id: "trace://nshkr/p04/accept/#{token}",
        correlation_id: "correlation://nshkr/p04/#{token}",
        submission_dedupe_key: "nshkr-p04-codex-#{token}",
        initial_input_ref: "artifact://synapse/p04/#{token}/reviewed-operation",
        params: %{
          run_ref: run_ref,
          authority_context_ref: "authority-context://nshkr/p04/#{token}"
        }
      })

    case AgentIntakeAdapter.start_agent_run(
           context,
           request,
           agent_intake_service: Mezzanine.WorkflowRuntime.Store,
           program_id: System.fetch_env!("NSHKR_SYNAPSE_PROGRAM_ID"),
           work_class_id: System.fetch_env!("NSHKR_SYNAPSE_WORK_CLASS_ID")
         ) do
      {:ok, future} -> future
      {:error, reason} -> raise "P04 AppKit run acceptance failed: #{inspect(reason)}"
    end
  end

  defp effect_owners!(run_ref, tenant_ref) do
    run =
      Run
      |> Ash.Query.set_tenant(tenant_ref)
      |> Ash.Query.filter(external_ref == ^run_ref)
      |> Ash.read!(authorize?: false, domain: Mezzanine.Runs)
      |> List.first()
      |> case do
        nil -> raise "P04 canonical Mezzanine run not found"
        value -> value
      end

    run_series =
      Ash.get!(RunSeries, run.run_series_id,
        tenant: tenant_ref,
        authorize?: false,
        domain: Mezzanine.Runs
      )

    work_object =
      Ash.get!(WorkObject, run_series.work_object_id,
        tenant: tenant_ref,
        authorize?: false,
        domain: Mezzanine.Work
      )

    review =
      ReviewUnit
      |> Ash.Query.set_tenant(tenant_ref)
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read!(authorize?: false, domain: Mezzanine.Review)
      |> Enum.find(&(&1.status in [:pending, :in_review, :accepted]))
      |> case do
        nil -> create_review!(tenant_ref, work_object, run)
        value -> value
      end

    {run, work_object, review}
  end

  defp create_review!(tenant_ref, work_object, run) do
    {:ok, review} =
      ReviewUnit.create_review_unit(
        %{
          work_object_id: work_object.id,
          run_id: run.id,
          review_kind: :code_review,
          required_by:
            DateTime.utc_now()
            |> DateTime.add(3_600, :second)
            |> DateTime.truncate(:second),
          decision_profile: %{"required_decisions" => 1},
          reviewer_actor: %{"kind" => "human", "ref" => "actor://synapse/operator"}
        },
        actor: %{tenant_id: tenant_ref},
        tenant: tenant_ref
      )

    review
  end

  defp accept_review!(_context, _work_object, %{status: :accepted}, _effect, _token), do: :ok

  defp accept_review!(context, work_object, review, effect, token) do
    stack = AppKitBackendStack.backend_stack()
    {:ok, backend} = BackendStack.fetch(stack, :review_backend)

    case backend.record_decision_by_id(
           context,
           review.id,
           %{
             decision: :accept,
             reason: "Authorized exact P04 named-file content and target",
             expected_row_version: review.row_version,
             trace_id: "trace://nshkr/p04/review/#{token}",
             causation_id: "cause://nshkr/p04/review/#{token}",
             idempotency_key: "nshkr:p04:review:#{token}",
             payload: %{
               effect_ref: effect.effect_ref,
               pinned_tool_manifest: effect.pinned_tool_manifest,
               reviewed_operation: effect.reviewed_operation
             }
           },
           program_id: work_object.program_id,
           backend_stack: stack
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> raise "P04 AppKit review acceptance failed: #{inspect(reason)}"
    end
  end

  defp request_context!(token, tenant_ref) do
    {:ok, context} =
      RequestContext.new(%{
        trace_id: sha256(token) |> binary_part(0, 32),
        actor_ref: %{id: "actor://synapse/operator", kind: :human},
        tenant_ref: %{id: tenant_ref},
        installation_ref: %{
          id: "installation://nshkr/developer-local",
          pack_slug: "synapse",
          status: :active,
          compiled_pack_revision: 1
        },
        idempotency_key: "nshkr:p04:#{token}"
      })

    context
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp event_type(event) when is_map(event),
    do: Map.get(event, :type, Map.get(event, "type"))
end

Nshkr.Runtime.P04LiveAcceptance.run!()
