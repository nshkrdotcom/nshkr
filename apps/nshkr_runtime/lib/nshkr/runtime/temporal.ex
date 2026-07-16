defmodule Nshkr.Runtime.Temporal do
  @moduledoc "Supervises the real Mezzanine Temporal workers selected by the release profile."

  use Supervisor

  alias Mezzanine.WorkflowRuntime.TemporalSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec probe(keyword()) :: :ok | {:error, term()}
  def probe(opts) do
    temporal = Keyword.fetch!(opts, :temporal)

    with true <- Keyword.get(temporal, :enabled?) == true,
         namespace when is_binary(namespace) and namespace != "" <-
           Keyword.get(temporal, :namespace),
         specs when is_list(specs) and specs != [] <-
           TemporalSupervisor.task_queue_specs(temporal),
         true <- Enum.any?(specs, &(&1.task_queue == "nshkr.mezzanine.agent-run.v1")),
         {:ok, runtime} <- Temporalex.Native.create_runtime(),
         {:ok, _client} <-
           Temporalex.Native.connect_client(
             runtime,
             address(Keyword.fetch!(temporal, :address)),
             Keyword.get(temporal, :api_key, ""),
             Keyword.get(temporal, :headers, [])
           ) do
      :ok
    else
      false -> {:error, :temporal_profile_incomplete}
      nil -> {:error, :temporal_namespace_missing}
      [] -> {:error, :temporal_task_queues_missing}
      {:error, reason} -> {:error, {:temporal_unreachable, safe_reason(reason)}}
      _other -> {:error, :invalid_temporal_profile}
    end
  rescue
    error -> {:error, {:temporal_probe_exception, error.__struct__}}
  end

  @impl true
  def init(opts) do
    opts
    |> Keyword.fetch!(:temporal)
    |> TemporalSupervisor.child_specs()
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp address("http://" <> _rest = address), do: address
  defp address("https://" <> _rest = address), do: address
  defp address(address), do: "http://" <> address

  defp safe_reason(%{__struct__: module}), do: module
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :redacted
end
