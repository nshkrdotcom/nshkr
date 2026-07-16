defmodule Nshkr.Runtime.CapabilityTruth.Source do
  @moduledoc "Durable capability-truth source owned by the composed control plane."

  @callback list(keyword()) ::
              {:ok, [map() | Nshkr.Runtime.Contracts.CapabilityDescriptor.t()]}
              | {:error, term()}
end

defmodule Nshkr.Runtime.CapabilityTruth.ReleaseManifestSource do
  @moduledoc "Capability truth loaded from a digest-pinned release artifact."

  @behaviour Nshkr.Runtime.CapabilityTruth.Source

  @impl true
  def list(opts) do
    with path when is_binary(path) <- Keyword.get(opts, :path),
         expected when is_binary(expected) <- Keyword.get(opts, :sha256),
         {:ok, bytes} <- File.read(resolve_path(path)),
         true <- secure_compare(sha256(bytes), String.downcase(expected)),
         {:ok, %{"schema" => "nshkr.release-capabilities.v1", "capabilities" => values}}
         when is_list(values) <- Jason.decode(bytes) do
      {:ok, values}
    else
      nil -> {:error, :capability_manifest_not_configured}
      false -> {:error, :capability_manifest_digest_mismatch}
      {:ok, _other} -> {:error, :invalid_capability_manifest}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_capability_manifest}
    end
  end

  defp resolve_path("priv/" <> _rest = path),
    do: Application.app_dir(:nshkr_runtime, path)

  defp resolve_path(path), do: Path.expand(path)

  defp sha256(bytes),
    do: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false
end

defmodule Nshkr.Runtime.CapabilityTruth do
  @moduledoc "Read-through projection of durable, executable capability truth."

  use GenServer

  alias Nshkr.Runtime.Contracts.CapabilityDescriptor

  @refresh :refresh_capability_truth

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec probe(keyword()) :: :ok | {:error, term()}
  def probe(opts) do
    with {:ok, descriptors} <- load(opts),
         :ok <- validate_activation(descriptors, Keyword.get(opts, :allowed_active, [])) do
      :ok
    end
  end

  @spec list(GenServer.server()) :: [CapabilityDescriptor.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @spec fetch(String.t(), GenServer.server()) :: {:ok, CapabilityDescriptor.t()} | :error
  def fetch(capability_id, server \\ __MODULE__) do
    GenServer.call(server, {:fetch, capability_id})
  end

  @impl true
  def init(opts) do
    with {:ok, descriptors} <- load(opts),
         :ok <- validate_activation(descriptors, Keyword.get(opts, :allowed_active, [])) do
      state = %{
        descriptors: Map.new(descriptors, &{&1.capability_id, &1}),
        opts: opts,
        refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, 30_000),
        timer_ref: nil
      }

      {:ok, schedule_refresh(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.descriptors |> Map.values() |> Enum.sort_by(& &1.capability_id), state}
  end

  def handle_call({:fetch, capability_id}, _from, state) do
    {:reply, Map.fetch(state.descriptors, capability_id), state}
  end

  @impl true
  def handle_info(@refresh, state) do
    with {:ok, descriptors} <- load(state.opts),
         :ok <- validate_activation(descriptors, Keyword.get(state.opts, :allowed_active, [])) do
      next = %{state | descriptors: Map.new(descriptors, &{&1.capability_id, &1})}
      {:noreply, schedule_refresh(next)}
    else
      {:error, reason} -> {:stop, {:capability_truth_unavailable, reason}, state}
    end
  end

  defp load(opts) do
    with source when is_atom(source) <- Keyword.get(opts, :source),
         true <- Code.ensure_loaded?(source) and function_exported?(source, :list, 1),
         {:ok, descriptors} when is_list(descriptors) <-
           source.list(Keyword.get(opts, :source_options, [])),
         {:ok, built} <- build_descriptors(descriptors),
         true <- unique_capability_ids?(built) do
      {:ok, built}
    else
      false -> {:error, :invalid_capability_source}
      nil -> {:error, :missing_capability_source}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_capability_truth}
    end
  end

  defp build_descriptors(descriptors) do
    Enum.reduce_while(descriptors, {:ok, []}, fn
      %CapabilityDescriptor{} = descriptor, {:ok, acc} ->
        {:cont, {:ok, [descriptor | acc]}}

      attrs, {:ok, acc} ->
        case CapabilityDescriptor.new(attrs) do
          {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> then(fn
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end)
  end

  defp validate_activation(descriptors, allowed_active) do
    unexpected =
      descriptors
      |> Enum.filter(&CapabilityDescriptor.executable?/1)
      |> Enum.map(& &1.capability_id)
      |> Enum.reject(&(&1 in allowed_active))

    if unexpected == [], do: :ok, else: {:error, {:unadmitted_capabilities, unexpected}}
  end

  defp unique_capability_ids?(descriptors) do
    ids = Enum.map(descriptors, & &1.capability_id)
    Enum.uniq(ids) == ids
  end

  defp schedule_refresh(%{refresh_interval_ms: interval} = state) when interval > 0 do
    %{state | timer_ref: Process.send_after(self(), @refresh, interval)}
  end

  defp schedule_refresh(state), do: state
end
