unless System.get_env("NSHKR_P06_ACCEPTANCE") == "1" do
  raise "set NSHKR_P06_ACCEPTANCE=1 to run the bounded P06 product acceptance"
end

defmodule Nshkr.Runtime.P06ProductAcceptance do
  @moduledoc false

  @poll_attempts 400
  @poll_interval_ms 25

  def run! do
    token = System.fetch_env!("NSHKR_P06_RUN_TOKEN")

    assert!(is_pid(Process.whereis(Nshkr.Runtime.ProductEndpoint)), :product_endpoint_not_started)
    assert!(is_pid(Process.whereis(SynapseWeb.Endpoint)), :synapse_endpoint_not_started)

    case System.fetch_env!("NSHKR_P06_MODE") do
      "write" -> write!(token)
      "readback" -> readback!(token)
      _other -> raise "NSHKR_P06_MODE must be write or readback"
    end
  end

  defp write!(token) do
    acceptance =
      case Synapse.AgentRuns.start_run(
             %{
               title: "P06 product acceptance #{token}",
               goal_summary: "Prove durable Synapse run and follow-up turn composition.",
               team_template_ref: "standard_implementation"
             },
             run_token: token
           ) do
        {:ok, acceptance} ->
          acceptance

        {:error, reason} ->
          if idempotency_conflict?(reason),
            do: existing_run!(token),
            else: raise("P06 run acceptance failed: #{inspect(reason)}")
      end

    current =
      wait_for_run!(acceptance.ref, fn detail ->
        length(detail.turns) in [1, 2] and detail.cursor.last_seq_seen > 0
      end)

    {detail, turn_command_ref} = ensure_follow_up!(acceptance.ref, current, token)

    assert_product_surfaces!(detail)

    IO.puts("mode=write")
    print_detail(detail)
    IO.puts("turn_command_ref=#{turn_command_ref}")
  end

  defp ensure_follow_up!(_run_ref, %{turns: [_, _]} = detail, _token),
    do: {detail, "already-committed"}

  defp ensure_follow_up!(run_ref, %{turns: [_]} = initial, token) do
    {:ok, turn_result} =
      Synapse.Turns.submit_turn(
        run_ref,
        %{
          kind: "user_input",
          input_summary: "Continue the P06 durable product journey.",
          payload_ref: "payload://synapse/p06/#{token}/follow-up"
        },
        submission_token: "p06-follow-up-#{token}",
        cursor_ref: initial.cursor.cursor_ref
      )

    assert!(turn_result.accepted? == true, :follow_up_turn_not_accepted)

    detail =
      wait_for_run!(run_ref, fn current ->
        length(current.turns) == 2 and
          current.cursor.last_seq_seen > initial.cursor.last_seq_seen
      end)

    {detail, turn_result.command_ref}
  end

  defp readback!(token) do
    run = existing_run!(token)

    detail =
      wait_for_run!(run.ref, fn current ->
        length(current.turns) == 2 and current.cursor.last_seq_seen > 1
      end)

    assert_product_surfaces!(detail)

    IO.puts("mode=readback")
    print_detail(detail)
  end

  defp existing_run!(token) do
    case System.get_env("NSHKR_P06_RUN_REF") do
      run_ref when is_binary(run_ref) and run_ref != "" ->
        %{ref: run_ref}

      _missing ->
        subject_ref = "subject://synapse/#{token}"
        {:ok, runs} = Synapse.AgentRuns.list_runs()

        Enum.find(runs, &(&1.subject_ref == subject_ref)) ||
          raise("P06 durable run not found")
    end
  end

  defp idempotency_conflict?(%{code: "idempotency_conflict"}), do: true
  defp idempotency_conflict?(:idempotency_conflict), do: true
  defp idempotency_conflict?(_reason), do: false

  defp assert_product_surfaces!(detail) do
    assert_listed_run!(detail)
    assert!(detail.persistence_posture.durable? == true, :run_projection_not_durable)
    assert!(detail.surface == "AppKit.AgentIntake", :run_surface_bypassed_app_kit)
    assert!(ordered_sequences?(detail.turns, :sequence), :turn_sequence_not_ordered)
    assert!(ordered_sequences?(detail.events, :event_seq), :event_sequence_not_ordered)

    max_event_seq =
      detail.events
      |> Enum.map(& &1.event_seq)
      |> Enum.max(fn -> 0 end)

    assert!(detail.cursor.last_seq_seen >= max_event_seq, :cursor_behind_durable_events)

    catalog = Synapse.Catalog.catalog()
    assert!(catalog.status == :available, :capability_catalog_unavailable)
    assert!(catalog.entries != [], :capability_catalog_empty)

    assert!(
      Enum.all?(catalog.entries, &(&1.status == :available)),
      :inactive_capability_advertised
    )

    operations = Synapse.Evidence.operations(run_ref: detail.ref)
    assert!(operations.status in [:available, :degraded], :operations_surface_unavailable)
    assert!(operations.source == "AppKit.ProductSurface", :operations_surface_bypassed_app_kit)

    {:ok, reviews} = Synapse.Reviews.list_pending()
    assert!(reviews.availability == :available, :review_surface_unavailable)

    {:ok, memories} = Synapse.Memory.list_memories()
    assert!(memories != [], :memory_surface_empty)
    assert!(Enum.all?(memories, &(&1.redaction_policy_ref == "refs_only")), :memory_not_refs_only)

    {:ok, context_packs} = Synapse.ContextPacks.list_context_packs()
    assert!(context_packs != [], :context_surface_empty)

    assert!(
      Enum.all?(context_packs, &(&1.feature_status == :durable_retrieval_snapshot)),
      :context_snapshot_not_durable
    )
  end

  defp assert_listed_run!(detail) do
    {:ok, runs} = Synapse.AgentRuns.list_runs()
    assert!(Enum.any?(runs, &(&1.ref == detail.ref)), :run_missing_from_durable_list)
  end

  defp wait_for_run!(run_ref, predicate, attempts \\ @poll_attempts)

  defp wait_for_run!(_run_ref, _predicate, 0),
    do: raise("P06 durable run projection timed out")

  defp wait_for_run!(run_ref, predicate, attempts) do
    case Synapse.AgentRuns.get_run(run_ref) do
      {:ok, detail} ->
        if predicate.(detail) do
          detail
        else
          Process.sleep(@poll_interval_ms)
          wait_for_run!(run_ref, predicate, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(@poll_interval_ms)
        wait_for_run!(run_ref, predicate, attempts - 1)
    end
  end

  defp ordered_sequences?(items, field) do
    sequences = Enum.map(items, &Map.fetch!(&1, field))
    sequences == Enum.sort(sequences) and length(sequences) == length(Enum.uniq(sequences))
  end

  defp print_detail(detail) do
    IO.puts("run_ref=#{detail.ref}")
    IO.puts("turn_count=#{length(detail.turns)}")
    IO.puts("event_count=#{length(detail.events)}")
    IO.puts("cursor_seq=#{detail.cursor.last_seq_seen}")
    IO.puts("persistence_posture=durable")
    IO.puts("surface=#{detail.surface}")
  end

  defp assert!(true, _reason), do: :ok
  defp assert!(false, reason), do: raise("P06 acceptance assertion failed: #{reason}")
end

Nshkr.Runtime.P06ProductAcceptance.run!()
