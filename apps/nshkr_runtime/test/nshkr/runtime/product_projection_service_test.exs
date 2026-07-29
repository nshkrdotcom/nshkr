defmodule Nshkr.Runtime.ProductProjectionServiceTest do
  use ExUnit.Case, async: true

  alias AppKit.Core.ProductSurface.RunProjection
  alias AppKit.Core.RequestContext
  alias Mezzanine.Runs.{Event, EventCursor, TurnProjection}
  alias Nshkr.Runtime.Contracts.CapabilityDescriptor
  alias Nshkr.Runtime.ProductProjectionService

  @run_ref "run://mezzanine/product-test"
  @tenant_ref "tenant://synapse/product-test"
  @hash "sha256:" <> String.duplicate("a", 64)
  @now ~U[2026-07-28 20:00:00Z]

  defmodule FakeStore do
    def fetch_projection(run_ref, opts) do
      {:ok, Keyword.fetch!(opts, :projection) |> Map.put(:run_ref, run_ref)}
    end

    def list_turns(_run_ref, opts), do: {:ok, Keyword.fetch!(opts, :turns)}
    def list_events(_run_ref, _cursor, opts), do: {:ok, Keyword.fetch!(opts, :events)}
    def read_cursor(_run_ref, opts), do: {:ok, Keyword.fetch!(opts, :cursor)}
  end

  defmodule FakeCapabilityTruth do
    def list(descriptors), do: descriptors
  end

  test "joins ordered durable turns, timeline, control, and executable catalog truth" do
    assert {:ok, %RunProjection{} = run} =
             ProductProjectionService.run_projection(context(), @run_ref, options())

    assert run.run_ref == @run_ref
    assert run.subject_ref == "subject://synapse/product-test"
    assert run.state == :accepted
    assert run.cursor.last_seq_seen == 2
    assert Enum.map(run.turns, & &1.sequence) == [1, 2]

    assert Enum.map(run.turns, & &1.input_ref) == [
             "artifact://synapse/product-test/turn-1",
             "artifact://synapse/product-test/turn-2"
           ]

    assert Enum.all?(run.artifacts, &(&1.status == :unavailable))
    assert Enum.map(run.events, & &1.event_seq) == [1, 2]
    assert [%{advertised?: true}, %{advertised?: false}] = run.capabilities
  end

  test "rejects cross-tenant owner projection and can filter advertised capabilities" do
    projection =
      options()
      |> Keyword.fetch!(:run_store_options)
      |> Keyword.fetch!(:projection)
      |> Map.put(:tenant_ref, "tenant://synapse/other")

    opts =
      Keyword.update!(options(), :run_store_options, &Keyword.put(&1, :projection, projection))

    assert {:error, :unauthorized_lower_read} =
             ProductProjectionService.run_projection(context(), @run_ref, opts)

    assert {:ok, [only]} =
             ProductProjectionService.capability_projections(
               context(),
               %{advertised_only: true},
               options()
             )

    assert only.advertised?
    assert only.capability_ref == "capability://nshkr/model.gemini"
  end

  defp context do
    {:ok, context} =
      RequestContext.new(%{
        trace_id: "11111111111111111111111111111111",
        actor_ref: %{id: "actor://synapse/operator", kind: :human},
        tenant_ref: %{id: @tenant_ref}
      })

    context
  end

  defp options do
    [
      run_store: FakeStore,
      run_store_options: [
        projection: %{
          tenant_ref: @tenant_ref,
          subject_ref: "subject://synapse/product-test",
          status: "accepted",
          updated_at: @now,
          control: %{
            state: "accepted",
            row_version: 1,
            external_operation_ref: nil,
            deadline_at: nil,
            terminal_receipt_ref: nil
          }
        },
        turns: turns(),
        events: events(),
        cursor:
          EventCursor.new!(%{
            run_ref: @run_ref,
            last_event_ref: "event://mezzanine/product-test/2",
            sequence: 2
          })
      ],
      capability_truth: FakeCapabilityTruth,
      capability_truth_server: capabilities()
    ]
  end

  defp turns do
    [
      turn(1, "turn-1", "artifact://synapse/product-test/turn-1"),
      turn(2, "turn-2", "artifact://synapse/product-test/turn-2")
    ]
  end

  defp turn(sequence, token, input_ref) do
    TurnProjection.new!(%{
      turn_ref: "turn://mezzanine/product-test/#{token}",
      run_ref: @run_ref,
      tenant_ref: @tenant_ref,
      subject_ref: "subject://synapse/product-test",
      input_artifact_ref: input_ref,
      payload_digest: @hash,
      sequence: sequence,
      status: "accepted",
      provider_attempt_ref: nil,
      row_version: 1,
      updated_at: @now
    })
  end

  defp events do
    [
      event(1, "run_accepted", "artifact://synapse/product-test/turn-1"),
      event(2, "turn_accepted", "artifact://synapse/product-test/turn-2")
    ]
  end

  defp event(sequence, event_type, payload_ref) do
    Event.new!(%{
      event_ref: "event://mezzanine/product-test/#{sequence}",
      run_ref: @run_ref,
      tenant_ref: @tenant_ref,
      event_type: event_type,
      event_version: 1,
      sequence: sequence,
      command_ref: "command://mezzanine/product-test/#{sequence}",
      causation_ref: nil,
      correlation_ref: "correlation://synapse/product-test",
      payload_ref: payload_ref,
      payload_digest: @hash,
      recorded_at: @now,
      row_version: 1
    })
  end

  defp capabilities do
    [
      capability(%{
        capability_ref: "capability://nshkr/model.gemini",
        capability_id: "model.gemini.managed-account.local-effect",
        readiness: "ready",
        health: "healthy",
        absence_reason: nil
      }),
      capability(%{
        capability_ref: "capability://nshkr/execution.http",
        capability_id: "execution.http.runtime-admitted-effect",
        mode: "runtime_admitted_effect",
        readiness: "absent",
        health: "unknown",
        absence_reason: "separate_effect_node_not_composed"
      })
    ]
  end

  defp capability(overrides) do
    CapabilityDescriptor.new!(
      Map.merge(
        %{
          contract_version: 1,
          capability_ref: "capability://nshkr/default",
          capability_id: "default",
          producer_revision: "producer",
          adapter_revision: "adapter",
          runtime_revision: "runtime",
          contract_revisions: %{},
          mode: "managed_account_local_effect",
          required_components: ["nshkr_runtime"],
          optional_features: [],
          readiness: "absent",
          health: "unknown",
          absence_reason: "not_composed",
          release_ref: "release://nshkr/0.1.0",
          evidence_refs: []
        },
        overrides
      )
    )
  end
end
