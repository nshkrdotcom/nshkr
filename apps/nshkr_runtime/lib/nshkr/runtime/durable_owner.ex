defmodule Nshkr.Runtime.DurableOwner do
  @moduledoc "Supervises continuous liveness for a stateless durable owner facade."

  use GenServer

  @default_interval_ms 15_000

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec probe(keyword()) :: :ok | {:error, term()}
  def probe(opts) when is_list(opts) do
    with module when is_atom(module) <- Keyword.get(opts, :owner_module),
         function when is_atom(function) <- Keyword.get(opts, :health_function),
         args when is_list(args) <- Keyword.get(opts, :health_args, []),
         true <-
           Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      case apply(module, function, args) do
        :ok -> :ok
        {:ok, _health} -> :ok
        {:error, reason} -> {:error, safe_reason(reason)}
        _other -> {:error, :invalid_owner_health_result}
      end
    else
      _other -> {:error, :invalid_owner_health_configuration}
    end
  rescue
    error -> {:error, {:owner_health_exception, error.__struct__}}
  catch
    :exit, _reason -> {:error, :owner_health_exit}
  end

  @impl true
  def init(opts) do
    case probe(opts) do
      :ok -> {:ok, schedule(%{opts: opts, timer_ref: nil})}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:check_owner_health, state) do
    case probe(state.opts) do
      :ok -> {:noreply, schedule(%{state | timer_ref: nil})}
      {:error, reason} -> {:stop, {:durable_owner_unavailable, reason}, state}
    end
  end

  defp schedule(state) do
    interval = Keyword.get(state.opts, :health_interval_ms, @default_interval_ms)

    if is_integer(interval) and interval > 0 do
      %{state | timer_ref: Process.send_after(self(), :check_owner_health, interval)}
    else
      state
    end
  end

  defp safe_reason(%{__struct__: module}), do: module
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({left, _right}) when is_atom(left), do: left
  defp safe_reason(_reason), do: :redacted
end
