defmodule Nshkr.Runtime.AttemptRecoveryBinding do
  @moduledoc """
  Supervised NSHKR binding for Jido's durable attempt reconciler.

  Jido owns reconciliation state and scheduling. This process supplies the
  concrete ASM observer, performs the one restart scan, and re-establishes the
  binding after an NSHKR supervisor restart.
  """

  use GenServer

  alias Jido.Integration.V2.ControlPlane
  alias Jido.Integration.V2.ControlPlane.RuntimeConfig

  @default_interval_ms 5_000
  @default_observer Nshkr.Runtime.CodexAttemptObserver

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(opts) when is_list(opts) do
    observer = Keyword.get(opts, :observer, @default_observer)
    control_plane = Keyword.get(opts, :control_plane, ControlPlane)
    runtime_config = Keyword.get(opts, :runtime_config, RuntimeConfig)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    with true <- valid_observer?(observer),
         true <- interval_ms > 0,
         true <- exports?(control_plane, :reconcile_attempts_on_start, 2),
         true <- exports?(control_plane, :reconcile_attempts_now, 0),
         true <- exports?(runtime_config, :put, 2),
         true <- exports?(runtime_config, :current, 0) do
      {:ok,
       %{
         observer: observer,
         interval_ms: interval_ms,
         effect_retry: :prohibited,
         dispatch_capability: false
       }}
    else
      _other -> {:error, :attempt_recovery_binding_unavailable}
    end
  end

  @spec health(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health)
  catch
    :exit, _reason -> {:error, :attempt_recovery_binding_unavailable}
  end

  @impl true
  def init(opts) do
    state = %{
      observer: Keyword.get(opts, :observer, @default_observer),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      recovery_opts: Keyword.take(opts, [:limit, :claim_ttl_ms, :retry_delay_ms, :max_retries]),
      control_plane: Keyword.get(opts, :control_plane, ControlPlane),
      runtime_config: Keyword.get(opts, :runtime_config, RuntimeConfig),
      summary: nil
    }

    {:ok, state, {:continue, :bind}}
  end

  @impl true
  def handle_continue(:bind, state) do
    config =
      state.recovery_opts
      |> Map.new()
      |> Map.merge(%{observer: state.observer, interval_ms: state.interval_ms})

    with :ok <- state.runtime_config.put(:attempt_reconciliation, config),
         {:ok, summary} <-
           state.control_plane.reconcile_attempts_on_start(
             state.observer,
             state.recovery_opts
           ),
         {:ok, _due_summary} <- state.control_plane.reconcile_attempts_now() do
      {:noreply, %{state | summary: summary}}
    else
      {:error, reason} ->
        {:stop, {:attempt_recovery_binding_failed, durable_reason(reason)}, state}

      other ->
        {:stop, {:invalid_attempt_recovery_binding_result, durable_reason(other)}, state}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    configured = state.runtime_config.current().attempt_reconciliation

    if is_map(configured) and Map.get(configured, :observer) == state.observer and
         not is_nil(state.summary) do
      {:reply,
       {:ok,
        %{
          observer: state.observer,
          startup_summary: state.summary,
          effect_retry: :prohibited
        }}, state}
    else
      {:reply, {:error, :attempt_recovery_binding_unavailable}, state}
    end
  end

  defp valid_observer?(observer) do
    exports?(observer, :status, 2) and exports?(observer, :cancel, 2) and
      exports?(observer, :cleanup, 2)
  end

  defp exports?(module, function, arity) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp durable_reason(reason) when is_atom(reason), do: reason
  defp durable_reason({reason, _detail}) when is_atom(reason), do: reason
  defp durable_reason(%{__struct__: module}), do: module
  defp durable_reason(_reason), do: :redacted
end
