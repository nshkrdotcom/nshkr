defmodule Nshkr.Runtime.CodexAttemptObserver do
  @moduledoc """
  Observation-only recovery binding for previously dispatched ASM Codex sessions.

  The stable external operation reference is the ASM session id. Recovery may
  inspect, cancel, clean, or stop that exact session, but this module has no
  provider dispatch path.
  """

  @behaviour Jido.Integration.V2.ControlPlane.AttemptObserver

  @impl true
  def status(session_id, %{run_id: run_id})
      when is_binary(session_id) and is_binary(run_id) do
    with {:ok, session} <- lookup_session(session_id),
         {:ok, state} <- session_state(session) do
      cond do
        Map.has_key?(state.active_runs, run_id) ->
          {:ok, :active}

        queued_run?(state.run_queue, run_id) ->
          {:ok, :active}

        true ->
          {:error, :outcome_unknown}
      end
    end
  end

  def status(_session_id, _context), do: {:error, :invalid_attempt_observation}

  @impl true
  def cancel(session_id, %{run_id: run_id})
      when is_binary(session_id) and is_binary(run_id) do
    with {:ok, session} <- lookup_session(session_id) do
      safe_call(fn -> ASM.interrupt(session, run_id) end, :attempt_cancel_failed)
    end
  end

  def cancel(_session_id, _context), do: {:error, :invalid_attempt_cancel}

  @impl true
  def cleanup(session_id, _context) when is_binary(session_id) do
    cleanup_result =
      safe_call(
        fn -> ASM.cleanup_managed_session(session_id, :attempt_recovery_scope_closed) end,
        :attempt_materialization_cleanup_failed
      )

    stop_result =
      safe_call(fn -> ASM.stop_session(session_id) end, :attempt_session_stop_failed)

    case {cleanup_result, stop_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _stop} -> {:error, reason}
      {_cleanup, {:error, reason}} -> {:error, reason}
    end
  end

  def cleanup(_session_id, _context), do: {:error, :invalid_attempt_cleanup}

  defp lookup_session(session_id) do
    case Registry.lookup(:asm_sessions, {session_id, :server}) do
      [{session, _value}] when is_pid(session) -> {:ok, session}
      [] -> {:error, :not_found}
      _other -> {:error, :ambiguous_session_identity}
    end
  rescue
    _error -> {:error, :not_found}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp session_state(session) do
    case ASM.Session.Server.get_state(session) do
      %{active_runs: active_runs, run_queue: run_queue} = state
      when is_map(active_runs) and not is_nil(run_queue) ->
        {:ok, state}

      _other ->
        {:error, :invalid_session_state}
    end
  rescue
    _error -> {:error, :session_observation_failed}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp queued_run?(queue, run_id) do
    queue
    |> :queue.to_list()
    |> Enum.any?(fn
      %{run_id: ^run_id} -> true
      _other -> false
    end)
  rescue
    _error -> false
  end

  defp safe_call(callback, failure_reason) do
    case callback.() do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, failure_reason}
      _other -> {:error, failure_reason}
    end
  rescue
    _error -> {:error, failure_reason}
  catch
    :exit, _reason -> {:error, failure_reason}
  end
end
