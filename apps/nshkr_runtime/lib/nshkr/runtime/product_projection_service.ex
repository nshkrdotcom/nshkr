defmodule Nshkr.Runtime.ProductProjectionService do
  @moduledoc """
  Root-owned composition of durable owner facts into AppKit product projections.

  Mezzanine remains the run, turn, timeline, and control owner. CapabilityTruth
  remains the digest-pinned executable catalog owner. This service joins those
  facts for the AppKit ProductSurface without copying payload content or
  creating product-local state.
  """

  alias AppKit.Core.AgentIntake.{AgentRunCursor, AgentRunEvent}
  alias AppKit.Core.PersistencePosture

  alias AppKit.Core.ProductSurface.{
    ArtifactProjection,
    CapabilityProjection,
    ControlProjection,
    OperationProjection,
    RunProjection,
    TurnProjection
  }

  alias AppKit.Core.RequestContext
  alias Nshkr.Runtime.Contracts.CapabilityDescriptor

  @run_contract_ref "contract://mezzanine/run-acceptance/v1"
  @model_turn_contract_ref "contract://mezzanine/model-turn-lineage/v1"
  @capability_contract_ref "contract://nshkr/release-capabilities/v1"

  @spec run_projection(RequestContext.t(), String.t(), keyword()) ::
          {:ok, RunProjection.t()} | {:error, term()}
  def run_projection(%RequestContext{} = context, run_ref, opts)
      when is_binary(run_ref) and run_ref != "" and is_list(opts) do
    store = Keyword.get(opts, :run_store, Mezzanine.WorkflowRuntime.Store)

    with {:ok, projection} <- owner_call(store, :fetch_projection, [run_ref, store_opts(opts)]),
         :ok <- authorize_projection(context, run_ref, projection),
         {:ok, turns} <- owner_call(store, :list_turns, [run_ref, store_opts(opts)]),
         :ok <- authorize_turns(context, run_ref, turns),
         {:ok, events} <- owner_call(store, :list_events, [run_ref, nil, store_opts(opts)]),
         {:ok, cursor} <- owner_call(store, :read_cursor, [run_ref, store_opts(opts)]),
         {:ok, capabilities} <- capability_projections(context, %{}, opts),
         {:ok, turn_projections, artifacts, operations} <-
           build_turn_projections(store, turns, events, opts),
         {:ok, event_projections} <- build_event_projections(events),
         {:ok, cursor_projection} <- build_cursor(context, cursor),
         {:ok, control} <- build_control(run_ref, projection),
         {:ok, run} <-
           RunProjection.new(%{
             run_ref: run_ref,
             subject_ref: value(projection, :subject_ref),
             workflow_ref: workflow_ref(projection),
             owner_projection_ref: projection_ref("run", run_ref),
             source_contract_ref: @run_contract_ref,
             state: control.state,
             updated_at: value(projection, :updated_at),
             cursor: cursor_projection,
             control: control,
             turns: turn_projections,
             events: event_projections,
             artifacts: artifacts,
             operations: operations,
             capabilities: capabilities,
             persistence_posture: PersistencePosture.durable(:runtime_projection),
             availability: availability_for_control(control)
           }) do
      {:ok, run}
    end
  end

  def run_projection(_context, _run_ref, _opts),
    do: {:error, :invalid_product_run_projection_request}

  @spec capability_projections(RequestContext.t(), map(), keyword()) ::
          {:ok, [CapabilityProjection.t()]} | {:error, term()}
  def capability_projections(%RequestContext{} = context, request, opts)
      when is_map(request) and is_list(opts) do
    with {:ok, descriptors} <- list_capabilities(opts),
         {:ok, projections} <- build_capability_projections(context, descriptors) do
      {:ok, filter_capability_request(projections, request)}
    end
  end

  def capability_projections(_context, _request, _opts),
    do: {:error, :invalid_product_capability_projection_request}

  defp build_turn_projections(store, turns, events, opts) do
    Enum.reduce_while(turns, {:ok, [], [], []}, fn turn, {:ok, built, artifacts, operations} ->
      case build_turn_projection(store, turn, events, opts) do
        {:ok, turn_projection, turn_artifacts, turn_operations} ->
          {:cont,
           {:ok, [turn_projection | built], turn_artifacts ++ artifacts,
            turn_operations ++ operations}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, turns, artifacts, operations} ->
        {:ok, Enum.reverse(turns), Enum.reverse(artifacts), Enum.reverse(operations)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_projection(store, turn, events, opts) do
    with {:ok, model_turn} <- model_turn(store, turn, opts),
         {:ok, state, output_ref} <- turn_state(turn, model_turn),
         {:ok, artifacts} <- turn_artifacts(turn, model_turn),
         {:ok, operation} <- turn_operation(turn, model_turn, events),
         artifact_refs <- Enum.map(artifacts, & &1.artifact_ref),
         {:ok, projection} <-
           TurnProjection.new(%{
             turn_ref: turn.turn_ref,
             run_ref: turn.run_ref,
             owner_projection_ref: projection_ref("turn", turn.turn_ref),
             source_contract_ref: @run_contract_ref,
             sequence: turn.sequence,
             state: state,
             input_ref: turn.input_artifact_ref,
             output_artifact_ref: output_ref,
             usage_ref: usage_ref(model_turn),
             event_refs: turn_event_refs(turn, events),
             artifact_refs: artifact_refs,
             availability: :available
           }) do
      {:ok, projection, artifacts, List.wrap(operation)}
    end
  end

  defp model_turn(_store, %{provider_attempt_ref: nil}, _opts), do: {:ok, nil}

  defp model_turn(store, turn, opts) do
    case owner_call(store, :fetch_model_turn, [turn.turn_ref, store_opts(opts)]) do
      {:ok, model_turn} -> {:ok, model_turn}
      {:error, :not_found} -> {:error, :model_turn_projection_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp turn_state(%{status: "accepted"}, nil), do: {:ok, :accepted, nil}
  defp turn_state(%{status: "running"}, _model_turn), do: {:ok, :invoking, nil}

  defp turn_state(%{status: "completed"}, model_turn) when is_map(model_turn) do
    case value(model_turn, :reply_artifact_ref) do
      ref when is_binary(ref) and ref != "" -> {:ok, :completed, ref}
      _missing -> {:error, :turn_output_projection_missing}
    end
  end

  defp turn_state(%{status: "failed"}, _model_turn), do: {:ok, :failed, nil}
  defp turn_state(%{status: "cancelled"}, _model_turn), do: {:ok, :cancelled, nil}
  defp turn_state(_turn, _model_turn), do: {:error, :unsupported_turn_projection_state}

  defp turn_artifacts(turn, model_turn) do
    with {:ok, input} <-
           ArtifactProjection.new(%{
             artifact_ref: turn.input_artifact_ref,
             owner_projection_ref: projection_ref("turn-input", turn.turn_ref),
             source_contract_ref: @run_contract_ref,
             kind: :turn_input,
             status: :unavailable,
             retained?: false,
             availability: {:unavailable, :owner_unavailable}
           }),
         {:ok, output} <- output_artifact(turn, model_turn) do
      {:ok, [input | List.wrap(output)]}
    end
  end

  defp output_artifact(_turn, nil), do: {:ok, nil}

  defp output_artifact(turn, model_turn) do
    case value(model_turn, :reply_artifact_ref) do
      ref when is_binary(ref) and ref != "" ->
        ArtifactProjection.new(%{
          artifact_ref: ref,
          owner_projection_ref: projection_ref("turn-output", turn.turn_ref),
          source_contract_ref: @model_turn_contract_ref,
          kind: :turn_output,
          status: :committed,
          retained?: true,
          content_ref: ref,
          evidence_refs: compact_refs([value(model_turn, :reply_publication_ref)]),
          lineage_refs: compact_refs([turn.input_artifact_ref]),
          availability: :available
        })

      _missing ->
        {:ok, nil}
    end
  end

  defp turn_operation(_turn, nil, _events), do: {:ok, nil}

  defp turn_operation(turn, model_turn, events) do
    state = operation_state(value(model_turn, :state))
    receipt_ref = value(model_turn, :reply_publication_ref)

    attrs = %{
      operation_ref: value(model_turn, :operation_ref),
      run_ref: turn.run_ref,
      turn_ref: turn.turn_ref,
      owner_projection_ref: projection_ref("model-operation", turn.turn_ref),
      source_contract_ref: @model_turn_contract_ref,
      kind: :model_invocation,
      state: state,
      attempt_ref: value(model_turn, :provider_attempt_ref) || turn.provider_attempt_ref,
      external_operation_ref: value(model_turn, :provider_attempt_ref),
      receipt_ref: receipt_ref,
      artifact_refs: compact_refs([value(model_turn, :reply_artifact_ref)]),
      evidence_refs: turn_event_refs(turn, events),
      availability: :available
    }

    OperationProjection.new(attrs)
  end

  defp operation_state(state) when state in ["completed", :completed], do: :completed
  defp operation_state(state) when state in ["failed", :failed], do: :failed
  defp operation_state(state) when state in ["cancelled", :cancelled], do: :cancelled
  defp operation_state(_state), do: :running

  defp build_event_projections(events) do
    events
    |> Enum.map(&build_event_projection/1)
    |> collect()
  end

  defp build_event_projection(event) do
    with {:ok, event_kind, summary} <- event_presentation(event.event_type) do
      AgentRunEvent.new(%{
        event_ref: event.event_ref,
        ledger_ref: event.run_ref,
        event_seq: event.sequence,
        event_kind: event_kind,
        visibility: :product,
        observed_at: DateTime.to_iso8601(event.recorded_at),
        summary: summary,
        payload_ref: event.payload_ref
      })
    end
  end

  defp event_presentation("run_accepted"), do: {:ok, :run_started, "Run accepted"}
  defp event_presentation("turn_accepted"), do: {:ok, :conversation_delta, "Turn accepted"}

  defp event_presentation("provider_event_committed"),
    do: {:ok, :conversation_delta, "Provider event committed"}

  defp event_presentation("turn_completed"),
    do: {:ok, :conversation_delta, "Turn completed"}

  defp event_presentation("run_control_updated"),
    do: {:ok, :execution_update, "Run control updated"}

  defp event_presentation("workflow_start_requested"),
    do: {:ok, :execution_update, "Workflow start requested"}

  defp event_presentation("workflow_started"),
    do: {:ok, :execution_update, "Workflow started"}

  defp event_presentation(_event_type), do: {:error, :unsupported_owner_event_type}

  defp build_cursor(context, cursor) do
    AgentRunCursor.new(%{
      cursor_ref: cursor.last_event_ref,
      ledger_ref: cursor.run_ref,
      tenant_ref: context.tenant_ref.id,
      actor_ref: context.actor_ref.id,
      last_seq_seen: cursor.sequence,
      visibility: :product
    })
  end

  defp build_control(run_ref, projection) do
    control = value(projection, :control, %{})

    with {:ok, state} <- control_state(value(control, :state)),
         {:ok, availability} <- control_availability(state, control),
         {:ok, product} <-
           ControlProjection.new(%{
             run_ref: run_ref,
             owner_projection_ref: projection_ref("control", run_ref),
             source_contract_ref: "contract://mezzanine/recovery-control/v1",
             row_version: value(control, :row_version),
             state: state,
             available_actions: available_control_actions(state, value(control, :state)),
             external_operation_ref: value(control, :external_operation_ref),
             deadline_at: value(control, :deadline_at),
             terminal_receipt_ref: value(control, :terminal_receipt_ref),
             availability: availability
           }) do
      {:ok, product}
    end
  end

  defp control_state(state)
       when state in ~w(
              accepted running pause_requested paused resume_requested failed cancelled
              completed operator_required outcome_unknown reconciling
            ),
       do: {:ok, String.to_existing_atom(state)}

  defp control_state(state) when state in [:accepted, :running, :pause_requested, :paused],
    do: {:ok, state}

  defp control_state(state)
       when state in [
              :resume_requested,
              :failed,
              :cancelled,
              :completed,
              :operator_required,
              :outcome_unknown,
              :reconciling
            ],
       do: {:ok, state}

  defp control_state(state) when state in ["cancel_requested", :cancel_requested],
    do: {:ok, :running}

  defp control_state(state)
       when state in [
              "retry_requested",
              :retry_requested,
              "supersede_requested",
              :supersede_requested
            ],
       do: {:ok, :reconciling}

  defp control_state(_state), do: {:error, :unsupported_control_projection_state}

  defp control_availability(:operator_required, control) do
    case value(control, :operator_task_ref) do
      ref when is_binary(ref) and ref != "" -> {:ok, {:operator_required, ref}}
      _missing -> {:error, :operator_task_projection_missing}
    end
  end

  defp control_availability(:outcome_unknown, control) do
    case value(control, :external_operation_ref) do
      ref when is_binary(ref) and ref != "" -> {:ok, {:outcome_unknown, ref}}
      _missing -> {:error, :outcome_unknown_operation_projection_missing}
    end
  end

  defp control_availability(_state, _control), do: {:ok, :available}

  defp available_control_actions(:accepted, _owner_state), do: [:cancel, :supersede]

  defp available_control_actions(:running, owner_state) when owner_state in ~w(cancel_requested),
    do: []

  defp available_control_actions(:running, _owner_state), do: [:pause, :cancel, :supersede]
  defp available_control_actions(:pause_requested, _owner_state), do: [:cancel]
  defp available_control_actions(:paused, _owner_state), do: [:resume, :cancel, :supersede]
  defp available_control_actions(:resume_requested, _owner_state), do: [:cancel]
  defp available_control_actions(:failed, _owner_state), do: [:retry, :supersede]

  defp available_control_actions(:operator_required, _owner_state),
    do: [:retry, :cancel, :supersede]

  defp available_control_actions(_state, _owner_state), do: []

  defp availability_for_control(%ControlProjection{availability: availability}), do: availability

  defp list_capabilities(opts) do
    truth = Keyword.get(opts, :capability_truth, Nshkr.Runtime.CapabilityTruth)
    server = Keyword.get(opts, :capability_truth_server, truth)

    case owner_call(truth, :list, [server]) do
      {:ok, descriptors} when is_list(descriptors) -> {:ok, descriptors}
      {:ok, _other} -> {:error, :invalid_capability_projection_owner_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_capability_projections(context, descriptors) do
    descriptors
    |> Enum.map(&build_capability_projection(context, &1))
    |> collect()
  end

  defp build_capability_projection(context, %CapabilityDescriptor{} = descriptor) do
    executable? = CapabilityDescriptor.executable?(descriptor)

    CapabilityProjection.new(%{
      capability_ref: descriptor.capability_ref,
      owner_projection_ref: projection_ref("capability", descriptor.capability_id),
      source_contract_ref: @capability_contract_ref,
      producer_revision_ref: "revision://#{descriptor.producer_revision}",
      contract_version: Integer.to_string(descriptor.contract_version),
      kind: capability_kind(descriptor.capability_id),
      configured_mode: capability_mode(descriptor.mode),
      advertised?: executable?,
      health_ref: "health://nshkr/capability/#{descriptor.capability_id}/#{descriptor.health}",
      operation_refs:
        if(executable?,
          do: ["operation-class://nshkr/#{descriptor.capability_id}"],
          else: []
        ),
      scope_refs: [context.tenant_ref.id, capability_scope(descriptor.mode)],
      availability: capability_availability(descriptor)
    })
  end

  defp build_capability_projection(_context, _descriptor),
    do: {:error, :invalid_capability_descriptor}

  defp capability_kind("model." <> _rest), do: :model
  defp capability_kind("codex." <> _rest), do: :tool
  defp capability_kind("execution." <> _rest), do: :execution_lane
  defp capability_kind(_id), do: :connector

  defp capability_mode("managed_account_local_effect"), do: :local_effect
  defp capability_mode("runtime_admitted_effect"), do: :runtime_admitted

  defp capability_scope("managed_account_local_effect"),
    do: "scope://nshkr/managed-account-local-effect"

  defp capability_scope("runtime_admitted_effect"), do: "scope://nshkr/runtime-admitted-effect"

  defp capability_availability(%CapabilityDescriptor{} = descriptor) do
    cond do
      CapabilityDescriptor.executable?(descriptor) ->
        :available

      descriptor.readiness == "degraded" or descriptor.health == "degraded" ->
        {:degraded,
         "reason://nshkr/capability/#{descriptor.capability_id}/#{descriptor.readiness}-#{descriptor.health}"}

      descriptor.mode == "runtime_admitted_effect" ->
        {:unavailable, :not_admitted}

      true ->
        {:unavailable, :not_configured}
    end
  end

  defp filter_capability_request(projections, request) do
    case value(request, :advertised_only, false) do
      true -> Enum.filter(projections, & &1.advertised?)
      _other -> projections
    end
  end

  defp authorize_projection(context, run_ref, projection) do
    cond do
      value(projection, :run_ref) != run_ref ->
        {:error, :cursor_run_mismatch}

      value(projection, :tenant_ref) != context.tenant_ref.id ->
        {:error, :unauthorized_lower_read}

      true ->
        :ok
    end
  end

  defp authorize_turns(context, run_ref, turns) when is_list(turns) do
    if Enum.all?(turns, fn turn ->
         turn.run_ref == run_ref and turn.tenant_ref == context.tenant_ref.id
       end) do
      :ok
    else
      {:error, :unauthorized_lower_read}
    end
  end

  defp authorize_turns(_context, _run_ref, _turns),
    do: {:error, :invalid_turn_projection_owner_response}

  defp workflow_ref(projection) do
    projection
    |> value(:projection, %{})
    |> value(:acceptance, %{})
    |> value(:workflow_ref)
  end

  defp usage_ref(nil), do: nil

  defp usage_ref(model_turn) do
    case value(model_turn, :provider_attempt_ref) do
      ref when is_binary(ref) and ref != "" ->
        "usage://nshkr/provider-attempt/#{digest_token(ref)}"

      _missing ->
        nil
    end
  end

  defp turn_event_refs(turn, events) do
    events
    |> Enum.filter(fn event ->
      event.payload_ref == turn.input_artifact_ref or
        value(event, :causation_ref) == turn.turn_ref or
        value(event, :command_ref) == turn.turn_ref
    end)
    |> Enum.map(& &1.event_ref)
  end

  defp compact_refs(values),
    do: Enum.filter(values, &(is_binary(&1) and String.trim(&1) != ""))

  defp projection_ref(kind, source_ref),
    do: "projection://nshkr/#{kind}/#{digest_token(source_ref)}"

  defp digest_token(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp value(attrs, key, default \\ nil)
  defp value(%_{} = attrs, key, default), do: Map.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp value(_attrs, _key, default), do: default

  defp store_opts(opts), do: Keyword.get(opts, :run_store_options, [])

  defp owner_call(module, function, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      case apply(module, function, args) do
        {:ok, _value} = success -> success
        value when function == :list and is_list(value) -> {:ok, value}
        {:error, _reason} = error -> error
        _other -> {:error, :invalid_product_projection_owner_response}
      end
    else
      {:error, :product_projection_owner_not_configured}
    end
  rescue
    _error -> {:error, :product_projection_owner_unavailable}
  catch
    :exit, _reason -> {:error, :product_projection_owner_unavailable}
  end

  defp collect(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end
end
