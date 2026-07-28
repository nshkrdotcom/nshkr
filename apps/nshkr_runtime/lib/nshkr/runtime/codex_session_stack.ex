defmodule Nshkr.Runtime.CodexSessionStack do
  @moduledoc """
  Owns the production registration of the governed local Codex session lane.

  The lower applications are release dependencies. This process binds their
  executable runtime adapter and connector manifest only after the durable Jido
  owner has started, and re-establishes that binding if this child restarts.
  """

  use GenServer

  alias Jido.Integration.V2.ControlPlane
  alias Jido.Integration.V2.ControlPlane.RuntimeConfig
  alias Jido.Integration.V2.Connectors.CodexCli
  alias Jido.Integration.V2.RuntimeRouter

  @capability_id "codex.session.turn"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(_opts) do
    materializer =
      Application.get_env(:jido_integration_v2_control_plane, :codex_materializer, [])

    command = Keyword.get(materializer, :command)
    session_root_parent = Keyword.get(materializer, :session_root_parent)

    with true <- Code.ensure_loaded?(RuntimeRouter),
         true <- Code.ensure_loaded?(CodexCli),
         true <- function_exported?(RuntimeRouter, :start!, 0),
         true <- function_exported?(CodexCli, :manifest, 0),
         true <- trusted_command?(command),
         true <- safe_session_root?(session_root_parent),
         true <- Enum.any?(CodexCli.manifest().operations, &(&1.operation_id == @capability_id)) do
      {:ok,
       %{
         capability_id: @capability_id,
         runtime_class: :session,
         runtime_adapter: RuntimeRouter,
         connector: CodexCli
       }}
    else
      _other -> {:error, :codex_session_runtime_unavailable}
    end
  end

  @spec health() :: {:ok, map()} | {:error, term()}
  def health do
    with true <- RuntimeRouter.available?(),
         %{non_direct_runtime_adapter: RuntimeRouter} <- RuntimeConfig.current(),
         {:ok, capability} <- ControlPlane.fetch_capability(@capability_id),
         true <- capability.runtime_class == :session do
      {:ok, %{capability_id: capability.id, runtime_class: capability.runtime_class}}
    else
      false -> {:error, :codex_session_runtime_unavailable}
      {:error, _reason} = error -> error
      _other -> {:error, :codex_session_runtime_invalid}
    end
  end

  @impl true
  def init(:ok) do
    :ok = RuntimeRouter.start!()
    :ok = RuntimeConfig.put(:non_direct_runtime_adapter, RuntimeRouter)
    :ok = ControlPlane.register_connector(CodexCli)
    {:ok, %{}}
  end

  defp trusted_command?(command) when is_binary(command) do
    with true <- Path.type(command) == :absolute,
         true <- File.regular?(command),
         {:ok, %{mode: mode}} <- File.stat(command) do
      Bitwise.band(mode, 0o111) != 0
    else
      _other -> false
    end
  end

  defp trusted_command?(_command), do: false

  defp safe_session_root?(path) when is_binary(path) do
    expanded = Path.expand(path)

    Path.type(path) == :absolute and expanded == path and
      expanded not in ["/", "/home", "/home/home"]
  end

  defp safe_session_root?(_path), do: false
end
