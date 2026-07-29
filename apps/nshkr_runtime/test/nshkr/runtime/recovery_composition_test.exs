defmodule Nshkr.Runtime.RecoveryCompositionTest do
  use ExUnit.Case, async: false

  alias Nshkr.Runtime.{AttemptRecoveryBinding, CodexAttemptObserver}

  defmodule FixtureState do
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            attempt_reconciliation: nil,
            startup_calls: 0,
            due_calls: 0
          }
        end,
        name: __MODULE__
      )
    end
  end

  defmodule RuntimeConfigFixture do
    def put(:attempt_reconciliation, config) do
      Agent.update(FixtureState, &Map.put(&1, :attempt_reconciliation, config))
    end

    def current do
      Agent.get(FixtureState, fn state ->
        %{attempt_reconciliation: state.attempt_reconciliation}
      end)
    end
  end

  defmodule ControlPlaneFixture do
    def reconcile_attempts_on_start(_observer, _opts) do
      Agent.update(FixtureState, &Map.update!(&1, :startup_calls, fn count -> count + 1 end))

      {:ok, %{discovered: 1, reconciled: 0, deferred: 0, operator_required: 1}}
    end

    def reconcile_attempts_now do
      Agent.update(FixtureState, &Map.update!(&1, :due_calls, fn count -> count + 1 end))
      {:ok, %{discovered: 0, reconciled: 0, deferred: 0, operator_required: 0}}
    end
  end

  defmodule SessionFixture do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def replace_runs(server, active_runs),
      do: GenServer.call(server, {:replace_runs, active_runs})

    @impl true
    def init(opts) do
      session_id = Keyword.fetch!(opts, :session_id)
      {:ok, _owner} = Registry.register(:asm_sessions, {session_id, :server}, nil)

      {:ok,
       %{
         active_runs: Keyword.get(opts, :active_runs, %{}),
         run_queue: :queue.new()
       }}
    end

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, state, state}

    def handle_call({:replace_runs, active_runs}, _from, state),
      do: {:reply, :ok, %{state | active_runs: active_runs}}
  end

  setup do
    start_supervised!(FixtureState)
    :ok
  end

  test "killed binding restarts from durable startup reconciliation without enabling replay" do
    name = :nshkr_attempt_recovery_binding_test

    child =
      {AttemptRecoveryBinding,
       [
         name: name,
         observer: CodexAttemptObserver,
         control_plane: ControlPlaneFixture,
         runtime_config: RuntimeConfigFixture,
         interval_ms: 25,
         max_retries: 2
       ]}

    first = start_supervised!(child)
    assert {:ok, %{effect_retry: :prohibited}} = wait_for_health(name)

    first_ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^first_ref, :process, ^first, :killed}, 1_000

    second = wait_for_replacement(name, first)
    assert is_pid(second)
    assert {:ok, %{effect_retry: :prohibited}} = wait_for_health(name)

    state = Agent.get(FixtureState, & &1)
    assert state.startup_calls == 2
    assert state.due_calls == 2
    assert state.attempt_reconciliation.observer == CodexAttemptObserver
    assert state.attempt_reconciliation.max_retries == 2
  end

  test "ambiguous or missing ASM state fails closed for Jido operator recovery" do
    session_id = "asm-session://nshkr/recovery-test"
    run_id = "jido-run://nshkr/recovery-test"

    session =
      start_supervised!(
        {SessionFixture, session_id: session_id, active_runs: %{run_id => self()}}
      )

    assert {:ok, :active} = CodexAttemptObserver.status(session_id, %{run_id: run_id})

    assert :ok = SessionFixture.replace_runs(session, %{})

    assert {:error, :outcome_unknown} =
             CodexAttemptObserver.status(session_id, %{run_id: run_id})

    assert :ok = stop_supervised(SessionFixture)

    assert {:error, :not_found} =
             CodexAttemptObserver.status(session_id, %{run_id: run_id})

    refute function_exported?(CodexAttemptObserver, :dispatch, 2)
    refute function_exported?(CodexAttemptObserver, :invoke, 2)
  end

  defp wait_for_health(server, attempts \\ 50)

  defp wait_for_health(_server, 0), do: {:error, :timeout}

  defp wait_for_health(server, attempts) do
    case AttemptRecoveryBinding.health(server) do
      {:ok, _health} = result ->
        result

      {:error, _reason} ->
        Process.sleep(10)
        wait_for_health(server, attempts - 1)
    end
  end

  defp wait_for_replacement(name, old, attempts \\ 50)

  defp wait_for_replacement(_name, _old, 0), do: nil

  defp wait_for_replacement(name, old, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_replacement(name, old, attempts - 1)
    end
  end
end
