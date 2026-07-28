unless System.get_env("NSHKR_P03_LIVE") == "1" do
  raise "set NSHKR_P03_LIVE=1 to run the bounded P03 provider acceptance"
end

defmodule Nshkr.Runtime.P03LiveAcceptance do
  @moduledoc false

  alias AppKit.Bridges.MezzanineBridge.AgentIntakeAdapter
  alias AppKit.Core.AgentIntake.AgentRunRequest
  alias AppKit.Core.RequestContext
  alias Nshkr.Runtime.GovernedGeminiTurn

  def run! do
    start_runtime!()
    token = System.fetch_env!("NSHKR_P03_RUN_TOKEN")
    tenant_ref = System.fetch_env!("NSHKR_P03_TENANT_REF")
    operation = operation!()

    scenarios = [
      completion:
        "Respond with exactly this text and nothing else: NSHKR P03 completion accepted.",
      stream: "Respond with one short sentence confirming the NSHKR P03 stream is incremental."
    ]

    scenarios
    |> Keyword.take([operation])
    |> Enum.each(fn {operation, prompt} ->
      future = accept_run!(operation, token, tenant_ref)
      turn_ref = Map.fetch!(future.governed_effect_refs, "turn_ref")

      result =
        execute!(%{
          operation: operation,
          tenant_ref: tenant_ref,
          run_ref: future.run_ref,
          turn_ref: turn_ref,
          subject_ref: "subject://synapse/p03/#{operation}/#{token}",
          input_artifact_ref: "artifact://synapse/p03/#{operation}/#{token}/input",
          prompt: prompt,
          trace_ref: "trace://nshkr/p03/#{operation}/#{token}",
          correlation_ref: "correlation://nshkr/p03/#{operation}/#{token}"
        })

      IO.puts("operation=#{operation}")
      IO.puts("run_ref=#{future.run_ref}")
      IO.puts("turn_ref=#{turn_ref}")
      IO.puts("provider_attempt_ref=#{result.provider_attempt_ref}")
      IO.puts("provider_event_count=#{length(result.provider_events)}")
      IO.puts("turn_state=#{result.turn.state}")
    end)
  end

  defp operation! do
    case System.fetch_env!("NSHKR_P03_OPERATION") do
      "completion" -> :completion
      "stream" -> :stream
      _other -> raise "NSHKR_P03_OPERATION must be completion or stream"
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

  defp accept_run!(operation, token, tenant_ref) do
    run_ref = "run://mezzanine/nshkr-p03-live-#{operation}-#{token}"
    subject_ref = "subject://synapse/p03/#{operation}/#{token}"
    trace_hex = sha256("#{operation}:#{token}") |> binary_part(0, 32)

    {:ok, context} =
      RequestContext.new(%{
        trace_id: trace_hex,
        actor_ref: %{id: "actor://synapse/operator", kind: :human},
        tenant_ref: %{id: tenant_ref},
        installation_ref: %{
          id: "installation://nshkr/developer-local",
          pack_slug: "synapse",
          status: :active
        }
      })

    request =
      AgentRunRequest.new!(%{
        tenant_ref: tenant_ref,
        installation_ref: "installation://nshkr/developer-local",
        subject_ref: subject_ref,
        actor_ref: "actor://synapse/operator",
        profile_bundle: %{
          source_profile_ref: :p03_source,
          runtime_profile_ref: :p03_gemini_local,
          tool_scope_ref: :none,
          evidence_profile_ref: :p03_durable,
          publication_profile_ref: :p03_outer_brain,
          review_profile_ref: :none,
          memory_profile_ref: :p03_context,
          projection_profile_ref: :p03_durable
        },
        tool_catalog_ref: "tool-catalog://synapse/default",
        budget_ref: "budget://synapse/p03",
        recall_scope_ref: "recall-scope://synapse/p03",
        idempotency_key: "nshkr:p03:#{operation}:#{token}",
        trace_id: "trace://nshkr/p03/#{operation}/#{token}",
        correlation_id: "correlation://nshkr/p03/#{operation}/#{token}",
        submission_dedupe_key: "nshkr-p03-#{operation}-#{token}",
        initial_input_ref: "artifact://synapse/p03/#{operation}/#{token}/input",
        params: %{
          run_ref: run_ref,
          authority_context_ref: "authority-context://nshkr/p03/#{operation}/#{token}"
        }
      })

    {:ok, future} =
      AgentIntakeAdapter.start_agent_run(
        context,
        request,
        agent_intake_service: Mezzanine.WorkflowRuntime.Store,
        program_id: System.fetch_env!("NSHKR_SYNAPSE_PROGRAM_ID"),
        work_class_id: System.fetch_env!("NSHKR_SYNAPSE_WORK_CLASS_ID")
      )

    future
  end

  defp execute!(attrs) do
    case GovernedGeminiTurn.execute(attrs) do
      {:ok, result} -> result
      {:error, reason} -> raise "P03 governed Gemini turn failed: #{inspect(reason)}"
    end
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end

Nshkr.Runtime.P03LiveAcceptance.run!()
