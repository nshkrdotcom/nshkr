defmodule Nshkr.Runtime.Service do
  @moduledoc "A single production child and its fail-closed preflight probe."

  alias Nshkr.Runtime.Contracts.Support

  @roles [
    :postgres_repo,
    :secret_store,
    :object_store,
    :owner_store,
    :temporal,
    :outbox_dispatcher,
    :capability_truth,
    :app_kit_backend_stack,
    :product_endpoint
  ]
  @enforce_keys [:id, :role, :module, :options, :probe]
  defstruct [:id, :role, :module, :options, :probe]

  @type probe :: {module(), atom(), [term()]}
  @type t :: %__MODULE__{
          id: String.t(),
          role: atom(),
          module: module(),
          options: keyword(),
          probe: probe()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :invalid_service}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Support.attrs(attrs)

    service = %__MODULE__{
      id: Support.value(attrs, :id),
      role: normalize_role(Support.value(attrs, :role)),
      module: Support.value(attrs, :module),
      options: Support.value(attrs, :options, []),
      probe: Support.value(attrs, :probe)
    }

    if valid?(service), do: {:ok, service}, else: {:error, :invalid_service}
  end

  def new(_attrs), do: {:error, :invalid_service}

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, service} -> service
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{id: id, module: module, options: options}) do
    Supervisor.child_spec({module, options}, id: id)
  end

  @spec probe(t()) :: :ok | {:error, term()}
  def probe(%__MODULE__{probe: {module, function, args}, options: options}) do
    case apply(module, function, [options | args]) do
      :ok -> :ok
      {:ok, _details} -> :ok
      {:error, reason} -> {:error, safe_reason(reason)}
      other -> {:error, {:invalid_probe_result, safe_reason(other)}}
    end
  rescue
    error -> {:error, {:probe_exception, error.__struct__}}
  catch
    kind, reason -> {:error, {:probe_failure, kind, safe_reason(reason)}}
  end

  def roles, do: @roles

  defp valid?(%__MODULE__{} = service) do
    Support.string?(service.id) and service.role in @roles and is_atom(service.module) and
      Keyword.keyword?(service.options) and valid_probe?(service.probe)
  end

  defp valid_probe?({module, function, args}),
    do: is_atom(module) and is_atom(function) and is_list(args)

  defp valid_probe?(_probe), do: false

  defp normalize_role(role) when is_binary(role) do
    Enum.find(@roles, &(Atom.to_string(&1) == role))
  end

  defp normalize_role(role), do: role

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({left, _right}) when is_atom(left), do: left
  defp safe_reason(_reason), do: :redacted
end
