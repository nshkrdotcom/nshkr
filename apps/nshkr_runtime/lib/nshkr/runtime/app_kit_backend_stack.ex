defmodule Nshkr.Runtime.AppKitBackendStack do
  @moduledoc "Supervised production selection of the AppKit Mezzanine backend stack."

  use GenServer

  alias AppKit.BackendStack

  @agent_intake_backend AppKit.Bridges.MezzanineBridge.AgentIntakeAdapter
  @effect_surface_backend AppKit.Bridges.MezzanineBridge.EffectAdapter
  @headless_backend AppKit.Bridges.MezzanineBridge
  @operator_backend AppKit.Bridges.MezzanineBridge.OperatorAdapter
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
      operator_backend: @operator_backend,
      review_backend: @review_backend,
      headless_backend: @headless_backend
    )
  end

  @spec probe(keyword()) :: {:ok, map()} | {:error, :app_kit_agent_intake_unavailable}
  def probe(opts) when is_list(opts) do
    expected_backend = Keyword.get(opts, :agent_intake_backend, @agent_intake_backend)
    program_id = Keyword.get(opts, :program_id)
    work_class_id = Keyword.get(opts, :work_class_id)
    memory_proof_token_ref = Keyword.get(opts, :memory_proof_token_ref)
    control_authority_ref = Keyword.get(opts, :control_authority_ref)
    control_permission_decision_ref = Keyword.get(opts, :control_permission_decision_ref)
    memory_read_query = Keyword.get(opts, :memory_read_query)
    memory_provenance_query = Keyword.get(opts, :memory_provenance_query)

    with %BackendStack{} = stack <- backend_stack(),
         true <- owner_id?(program_id),
         true <- owner_id?(work_class_id),
         true <- present_ref?(memory_proof_token_ref),
         true <- present_ref?(control_authority_ref),
         true <- present_ref?(control_permission_decision_ref),
         {:ok, ^expected_backend} <- BackendStack.fetch(stack, :agent_intake_backend),
         {:ok, @effect_surface_backend} <- BackendStack.fetch(stack, :effect_surface_backend),
         {:ok, @operator_backend} <- BackendStack.fetch(stack, :operator_backend),
         {:ok, @review_backend} <- BackendStack.fetch(stack, :review_backend),
         {:ok, @headless_backend} <- BackendStack.fetch(stack, :headless_backend),
         true <- Code.ensure_loaded?(expected_backend),
         true <- Code.ensure_loaded?(@effect_surface_backend),
         true <- Code.ensure_loaded?(@operator_backend),
         true <- Code.ensure_loaded?(@review_backend),
         true <- Code.ensure_loaded?(@headless_backend),
         true <- memory_query?(memory_read_query, :list_fragments_by_proof_token, 3),
         true <- memory_query?(memory_provenance_query, :fragment_provenance, 2),
         true <- function_exported?(expected_backend, :start_agent_run, 3),
         true <- function_exported?(expected_backend, :await_agent_outcome, 4),
         true <- function_exported?(expected_backend, :catch_up_agent_events, 3),
         true <- function_exported?(@effect_surface_backend, :propose_effect, 3),
         true <- function_exported?(@effect_surface_backend, :record_receipt, 4),
         true <- function_exported?(@operator_backend, :list_memory_fragments, 3),
         true <- function_exported?(@operator_backend, :memory_fragment_provenance, 3),
         true <- function_exported?(@operator_backend, :apply_action, 4),
         true <- function_exported?(@review_backend, :record_decision_by_id, 4),
         true <- function_exported?(@headless_backend, :runtime_run_detail, 4) do
      {:ok,
       %{
         agent_intake_backend: expected_backend,
         effect_surface_backend: @effect_surface_backend,
         headless_backend: @headless_backend,
         operator_backend: @operator_backend,
         review_backend: @review_backend,
         durable_owner: Mezzanine.OpsDomain.Repo,
         memory_proof_token_ref: memory_proof_token_ref,
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

  defp present_ref?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_ref?(_value), do: false

  defp memory_query?(module, function, arity) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp memory_query?(_module, _function, _arity), do: false
end
