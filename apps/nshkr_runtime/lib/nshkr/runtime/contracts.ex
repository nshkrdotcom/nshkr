defmodule Nshkr.Runtime.Contracts.Support do
  @moduledoc false

  @sensitive_keys MapSet.new(~w(
    access_token api_key authorization client_secret credential material password
    private_key raw_credential refresh_token secret token
  ))

  def attrs(value) when is_list(value), do: Map.new(value)
  def attrs(value) when is_map(value), do: value
  def attrs(_value), do: %{}

  def value(attrs, key, default \\ nil)

  def value(attrs, key, default) when is_atom(key),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  def value(attrs, key, default) when is_binary(key), do: Map.get(attrs, key, default)

  def string?(value), do: is_binary(value) and String.trim(value) != ""
  def string_list?(values), do: is_list(values) and Enum.all?(values, &string?/1)
  def positive_integer?(value), do: is_integer(value) and value > 0

  def known_fields?(attrs, fields) do
    allowed = MapSet.new(Enum.flat_map(fields, &[&1, Atom.to_string(&1)]))
    Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1))
  end

  def safe_term?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      normalized = key |> to_string() |> String.downcase()
      not sensitive_key?(normalized) and safe_term?(nested)
    end)
  end

  def safe_term?(values) when is_list(values), do: Enum.all?(values, &safe_term?/1)

  def safe_term?(value)
      when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
      do: true

  def safe_term?(_value), do: false

  defp sensitive_key?(key),
    do: MapSet.member?(@sensitive_keys, key) or String.starts_with?(key, "raw_")
end

defmodule Nshkr.Runtime.Contracts.ProductionProfile do
  @moduledoc "Immutable substrate and owner topology selected once at NSHKR boot."

  alias Nshkr.Runtime.Contracts.Support, as: S

  @modes ~w(developer_local production_monolith)
  @database_owners ~w(mezzanine citadel outer_brain jido_integration execution_plane chassis)
  @required_task_queues ~w(
    mezzanine_agent_run outer_brain_semantic chassis_reconcile extravaganza_issue_pr
  )
  @fields [
    :contract_version,
    :profile_ref,
    :mode,
    :postgres,
    :temporal,
    :object_store,
    :secret_store,
    :semantic_index,
    :migration_owners
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = S.attrs(attrs)

    profile = %__MODULE__{
      contract_version: S.value(attrs, :contract_version, 1),
      profile_ref: S.value(attrs, :profile_ref),
      mode: attrs |> S.value(:mode) |> normalize_string(),
      postgres: S.value(attrs, :postgres),
      temporal: S.value(attrs, :temporal),
      object_store: S.value(attrs, :object_store),
      secret_store: S.value(attrs, :secret_store),
      semantic_index: S.value(attrs, :semantic_index),
      migration_owners: S.value(attrs, :migration_owners)
    }

    with true <- S.known_fields?(attrs, @fields),
         true <- profile.contract_version == 1,
         true <- S.string?(profile.profile_ref),
         true <- profile.mode in @modes,
         true <- S.safe_term?(profile.postgres),
         true <- S.safe_term?(profile.temporal),
         true <- S.safe_term?(profile.object_store),
         true <- S.safe_term?(profile.secret_store),
         true <- S.safe_term?(profile.semantic_index),
         true <- S.safe_term?(profile.migration_owners),
         :ok <- validate_postgres(profile.postgres),
         :ok <- validate_temporal(profile.temporal),
         :ok <- validate_object_store(profile.object_store),
         :ok <- validate_secret_store(profile.secret_store),
         :ok <- validate_semantic_index(profile.semantic_index),
         :ok <- validate_migration_owners(profile.migration_owners) do
      {:ok, profile}
    else
      _other -> {:error, :invalid_production_profile}
    end
  end

  def new(_attrs), do: {:error, :invalid_production_profile}

  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  def database_owners, do: @database_owners
  def required_task_queues, do: @required_task_queues

  defp validate_postgres(postgres) do
    databases = S.value(postgres, :databases, %{})

    if S.value(postgres, :provider) == "postgresql" and S.string?(S.value(postgres, :cluster_ref)) and
         Enum.all?(@database_owners, &S.string?(S.value(databases, &1))) do
      :ok
    else
      {:error, :invalid_postgres_topology}
    end
  end

  defp validate_temporal(temporal) do
    queues = S.value(temporal, :task_queues, %{})

    if S.value(temporal, :provider) == "temporal" and
         S.string?(S.value(temporal, :namespace)) and
         Enum.all?(@required_task_queues, &S.string?(S.value(queues, &1))) do
      :ok
    else
      {:error, :invalid_temporal_topology}
    end
  end

  defp validate_object_store(object_store) do
    required = [:endpoint_ref, :bucket_ref, :tenant_prefix, :encryption]

    if S.value(object_store, :provider) == "minio_s3" and
         Enum.all?(required, &(object_store |> S.value(&1) |> S.string?())) do
      :ok
    else
      {:error, :invalid_object_store}
    end
  end

  defp validate_secret_store(secret_store) do
    required = [:endpoint_ref, :mount_ref, :auth_role_ref]

    if S.value(secret_store, :provider) == "hashicorp_vault_kv_v2" and
         S.value(secret_store, :lease_required) == true and
         Enum.all?(required, &(secret_store |> S.value(&1) |> S.string?())) do
      :ok
    else
      {:error, :invalid_secret_store}
    end
  end

  defp validate_semantic_index(semantic_index) do
    if S.value(semantic_index, :provider) == "postgresql_pgvector" and
         S.value(semantic_index, :rebuildable) == true and
         S.value(semantic_index, :source_of_truth) == false do
      :ok
    else
      {:error, :invalid_semantic_index}
    end
  end

  defp validate_migration_owners(owners) do
    if Enum.all?(@database_owners, fn owner ->
         case S.value(owners, owner) do
           %{} = entry ->
             S.string?(S.value(entry, :repository)) and S.string?(S.value(entry, :migration_path))

           _other ->
             false
         end
       end) do
      :ok
    else
      {:error, :invalid_migration_owners}
    end
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end

defmodule Nshkr.Runtime.Contracts.CapabilityDescriptor do
  @moduledoc "Executable composition truth for one exact advertised capability mode."

  alias Nshkr.Runtime.Contracts.Support, as: S

  @modes ~w(managed_account_local_effect runtime_admitted_effect)
  @readiness ~w(absent ready degraded)
  @health ~w(unknown healthy degraded unhealthy)
  @fields [
    :contract_version,
    :capability_ref,
    :capability_id,
    :producer_revision,
    :adapter_revision,
    :runtime_revision,
    :contract_revisions,
    :mode,
    :required_components,
    :optional_features,
    :readiness,
    :health,
    :absence_reason,
    :release_ref,
    :evidence_refs
  ]
  @required @fields -- [:absence_reason]
  @enforce_keys @required
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = S.attrs(attrs)

    descriptor = %__MODULE__{
      contract_version: S.value(attrs, :contract_version, 1),
      capability_ref: S.value(attrs, :capability_ref),
      capability_id: S.value(attrs, :capability_id),
      producer_revision: S.value(attrs, :producer_revision),
      adapter_revision: S.value(attrs, :adapter_revision),
      runtime_revision: S.value(attrs, :runtime_revision),
      contract_revisions: S.value(attrs, :contract_revisions),
      mode: attrs |> S.value(:mode) |> normalize_string(),
      required_components: S.value(attrs, :required_components, []),
      optional_features: S.value(attrs, :optional_features, []),
      readiness: attrs |> S.value(:readiness) |> normalize_string(),
      health: attrs |> S.value(:health) |> normalize_string(),
      absence_reason: S.value(attrs, :absence_reason),
      release_ref: S.value(attrs, :release_ref),
      evidence_refs: S.value(attrs, :evidence_refs, [])
    }

    strings = [
      descriptor.capability_ref,
      descriptor.capability_id,
      descriptor.producer_revision,
      descriptor.adapter_revision,
      descriptor.runtime_revision,
      descriptor.release_ref
    ]

    with true <- S.known_fields?(attrs, @fields),
         true <- descriptor.contract_version == 1,
         true <- Enum.all?(strings, &S.string?/1),
         true <- S.safe_term?(descriptor.contract_revisions),
         true <- descriptor.mode in @modes,
         true <- S.string_list?(descriptor.required_components),
         true <- descriptor.required_components != [],
         true <- S.string_list?(descriptor.optional_features),
         true <- descriptor.readiness in @readiness,
         true <- descriptor.health in @health,
         true <- S.string_list?(descriptor.evidence_refs),
         true <- coherent_state?(descriptor) do
      {:ok, descriptor}
    else
      _other -> {:error, :invalid_capability_descriptor}
    end
  end

  def new(_attrs), do: {:error, :invalid_capability_descriptor}

  def new!(attrs) do
    case new(attrs) do
      {:ok, descriptor} -> descriptor
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  def executable?(%__MODULE__{readiness: "ready", health: "healthy", absence_reason: nil}),
    do: true

  def executable?(%__MODULE__{}), do: false

  defp coherent_state?(%__MODULE__{readiness: "ready", health: "healthy", absence_reason: nil}),
    do: true

  defp coherent_state?(%__MODULE__{readiness: "absent", absence_reason: reason}),
    do: S.string?(reason)

  defp coherent_state?(%__MODULE__{readiness: "degraded", health: health, absence_reason: nil}),
    do: health in ~w(degraded unhealthy)

  defp coherent_state?(_descriptor), do: false

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end
