defmodule Nshkr.Runtime.Profile do
  @moduledoc "Immutable production composition selected once during release boot."

  alias Nshkr.Runtime.Contracts.ProductionProfile
  alias Nshkr.Runtime.Service

  @ordered_roles [
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
  @p01_durable_owners ~w(mezzanine citadel outer_brain jido_integration)
  @required_singular_roles [
    :secret_store,
    :object_store,
    :temporal,
    :capability_truth
  ]
  @optional_singular_roles [:app_kit_backend_stack, :product_endpoint]
  @enforce_keys [:topology, :services, :migration_plan]
  defstruct [:topology, :services, :migration_plan]

  @type migration :: %{
          required(:owner) => String.t(),
          required(:repo) => module(),
          required(:otp_app) => atom(),
          required(:migration_path) => String.t()
        }
  @type t :: %__MODULE__{
          topology: ProductionProfile.t(),
          services: [Service.t()],
          migration_plan: [migration()]
        }

  @spec load!() :: t()
  def load! do
    case Application.fetch_env(:nshkr_runtime, :production_profile) do
      {:ok, attrs} -> new!(attrs)
      :error -> raise "NSHKR production profile is not materialized"
    end
  end

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, topology} <- ProductionProfile.new(fetch(attrs, :topology)),
         {:ok, services} <- build_services(fetch(attrs, :services)),
         :ok <- validate_service_shape(services),
         {:ok, migration_plan} <- build_migration_plan(fetch(attrs, :migration_plan)) do
      {:ok, %__MODULE__{topology: topology, services: services, migration_plan: migration_plan}}
    end
  end

  def new(_attrs), do: {:error, :invalid_profile}

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, "invalid NSHKR profile: #{inspect(reason)}"
    end
  end

  @spec child_specs(t()) :: [Supervisor.child_spec()]
  def child_specs(%__MODULE__{services: services}) do
    services
    |> Enum.sort_by(&role_rank(&1.role))
    |> Enum.map(&Service.child_spec/1)
  end

  def ordered_roles, do: @ordered_roles

  defp build_services(services) when is_list(services) do
    Enum.reduce_while(services, {:ok, []}, fn attrs, {:ok, acc} ->
      case Service.new(attrs) do
        {:ok, service} -> {:cont, {:ok, [service | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end)
  end

  defp build_services(_services), do: {:error, :invalid_services}

  defp validate_service_shape(services) do
    ids = Enum.map(services, & &1.id)
    counts = Enum.frequencies_by(services, & &1.role)

    cond do
      services == [] ->
        {:error, :empty_services}

      Enum.uniq(ids) != ids ->
        {:error, :duplicate_service_id}

      Enum.any?(@required_singular_roles, &(Map.get(counts, &1, 0) != 1)) ->
        {:error, :invalid_singular_service_count}

      Enum.any?(@optional_singular_roles, &(Map.get(counts, &1, 0) > 1)) ->
        {:error, :invalid_optional_service_count}

      Map.get(counts, :postgres_repo, 0) == 0 ->
        {:error, :missing_postgres_repo}

      Map.get(counts, :owner_store, 0) == 0 ->
        {:error, :missing_owner_store}

      Map.get(counts, :outbox_dispatcher, 0) == 0 ->
        {:error, :missing_outbox_dispatcher}

      true ->
        :ok
    end
  end

  defp build_migration_plan(plan) when is_list(plan) do
    owners = MapSet.new(ProductionProfile.database_owners())

    Enum.reduce_while(plan, {:ok, []}, fn entry, {:ok, acc} ->
      entry = Map.new(entry)
      owner = fetch(entry, :owner)
      repo = fetch(entry, :repo)
      otp_app = fetch(entry, :otp_app)
      migration_path = fetch(entry, :migration_path)

      if owner in owners and is_atom(repo) and is_atom(otp_app) and is_binary(migration_path) and
           migration_path != "" do
        {:cont,
         {:ok,
          [%{owner: owner, repo: repo, otp_app: otp_app, migration_path: migration_path} | acc]}}
      else
        {:halt, {:error, :invalid_migration_plan}}
      end
    end)
    |> then(fn
      {:ok, built} -> validate_migration_owners(Enum.reverse(built), owners)
      error -> error
    end)
  end

  defp build_migration_plan(_plan), do: {:error, :invalid_migration_plan}

  defp validate_migration_owners(plan, owners) do
    plan_owners = Enum.map(plan, & &1.owner)
    required_owners = MapSet.new(@p01_durable_owners)
    plan_owner_set = MapSet.new(plan_owners)

    if MapSet.subset?(required_owners, plan_owner_set) and MapSet.subset?(plan_owner_set, owners) and
         Enum.uniq(plan_owners) == plan_owners,
       do: {:ok, plan},
       else: {:error, :invalid_migration_owners}
  end

  defp role_rank(role), do: Enum.find_index(@ordered_roles, &(&1 == role))

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
