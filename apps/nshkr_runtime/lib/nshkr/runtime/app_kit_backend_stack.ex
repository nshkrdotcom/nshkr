defmodule Nshkr.Runtime.AppKitBackendStack do
  @moduledoc "Supervised production selection of the AppKit Mezzanine agent-intake backend."

  use GenServer

  alias AppKit.BackendStack

  @agent_intake_backend AppKit.Bridges.MezzanineBridge.AgentIntakeAdapter
  @effect_surface_backend AppKit.Bridges.MezzanineBridge.EffectAdapter
  @headless_backend AppKit.Bridges.MezzanineBridge
  @review_backend AppKit.Bridges.MezzanineBridge.ReviewAdapter

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec backend_stack() :: BackendStack.t()
  def backend_stack do
    BackendStack.new!(
      agent_intake_backend: @agent_intake_backend,
      effect_surface_backend: @effect_surface_backend,
      review_backend: @review_backend,
      headless_backend: @headless_backend
    )
  end

  @spec probe(keyword()) :: {:ok, map()} | {:error, :app_kit_agent_intake_unavailable}
  def probe(opts) when is_list(opts) do
    expected_backend = Keyword.get(opts, :agent_intake_backend, @agent_intake_backend)
    program_id = Keyword.get(opts, :program_id)
    work_class_id = Keyword.get(opts, :work_class_id)

    with %BackendStack{} = stack <- backend_stack(),
         true <- owner_id?(program_id),
         true <- owner_id?(work_class_id),
         {:ok, ^expected_backend} <- BackendStack.fetch(stack, :agent_intake_backend),
         {:ok, @effect_surface_backend} <- BackendStack.fetch(stack, :effect_surface_backend),
         {:ok, @review_backend} <- BackendStack.fetch(stack, :review_backend),
         {:ok, @headless_backend} <- BackendStack.fetch(stack, :headless_backend),
         true <- Code.ensure_loaded?(expected_backend),
         true <- Code.ensure_loaded?(@effect_surface_backend),
         true <- Code.ensure_loaded?(@review_backend),
         true <- Code.ensure_loaded?(@headless_backend),
         true <- function_exported?(expected_backend, :start_agent_run, 3),
         true <- function_exported?(expected_backend, :await_agent_outcome, 4),
         true <- function_exported?(expected_backend, :catch_up_agent_events, 3),
         true <- function_exported?(@effect_surface_backend, :propose_effect, 3),
         true <- function_exported?(@effect_surface_backend, :record_receipt, 4),
         true <- function_exported?(@review_backend, :record_decision_by_id, 4),
         true <- function_exported?(@headless_backend, :runtime_run_detail, 4) do
      {:ok,
       %{
         agent_intake_backend: expected_backend,
         effect_surface_backend: @effect_surface_backend,
         headless_backend: @headless_backend,
         review_backend: @review_backend,
         durable_owner: Mezzanine.OpsDomain.Repo,
         program_id: program_id,
         work_class_id: work_class_id
       }}
    else
      _other -> {:error, :app_kit_agent_intake_unavailable}
    end
  end

  @impl true
  def init(:ok), do: {:ok, backend_stack()}

  defp owner_id?(value) when is_binary(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp owner_id?(_value), do: false
end
