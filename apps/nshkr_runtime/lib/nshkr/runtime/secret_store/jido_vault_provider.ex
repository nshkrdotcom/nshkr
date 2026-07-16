defmodule Nshkr.Runtime.SecretStore.JidoVaultProvider do
  @moduledoc "Bridges Jido managed-account materialization to the supervised NSHKR Vault owner."

  @behaviour Jido.Integration.Secrets.Provider

  alias Jido.Integration.Secrets.SecretHandle
  alias Nshkr.Runtime.SecretStore.{Material, VaultKvV2}

  @impl true
  def materialize(lease_ref, scope, opts)
      when is_binary(lease_ref) and lease_ref != "" and is_map(scope) and is_list(opts) do
    vault_module = Keyword.get(opts, :vault_module, VaultKvV2)
    vault_server = Keyword.get(opts, :vault_server, VaultKvV2)

    with {:ok, mount} <- required_scope(scope, :mount),
         {:ok, path} <- required_scope(scope, :path),
         true <- valid_vault_module?(vault_module),
         {:ok, %Material{} = secret} <- vault_module.read(path, vault_server),
         material when is_map(material) and map_size(material) > 0 <- Material.material(secret) do
      provider_ref = "vault-kv-v2://#{mount}/#{path}?version=#{secret.version}"

      SecretHandle.new(
        lease_ref: lease_ref,
        provider_ref: provider_ref,
        audit_ref: audit_ref(%{lease_ref: lease_ref, provider_ref: provider_ref}),
        material: select_material(material, scope),
        scope: Map.drop(scope, [:material, "material"]),
        metadata: %{version: secret.version, source: :vault_kv_v2}
      )
    else
      false -> {:error, :vault_owner_unavailable}
      {:error, _reason} -> {:error, :managed_secret_materialization_failed}
      _other -> {:error, :managed_secret_materialization_failed}
    end
  end

  def materialize(_lease_ref, _scope, _opts),
    do: {:error, :managed_secret_materialization_failed}

  @doc false
  @spec managed_scope(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def managed_scope(account, lease, _request) when is_map(account) and is_map(lease) do
    with {:ok, provider_uri} <- parse_uri(value(account, :secret_provider_ref)),
         {:ok, binding_uri} <- parse_uri(value(account, :secret_binding_ref)),
         :ok <- validate_uri(provider_uri, "vault", :secret_provider_ref),
         :ok <- validate_uri(binding_uri, "vault-secret", :secret_binding_ref),
         true <- provider_uri.path == "/kv-v2" or {:error, :unsupported_vault_engine},
         {:ok, path} <- binding_path(binding_uri) do
      {:ok,
       %{
         mount: provider_uri.host,
         path: path,
         fields: Map.get(lease, :lease_fields, Map.get(lease, "lease_fields", []))
       }}
    end
  end

  def managed_scope(_account, _lease, _request), do: {:error, :invalid_vault_binding}

  @impl true
  def rotate(binding_ref, opts) when is_binary(binding_ref) and is_list(opts) do
    case Keyword.get(opts, :next_binding_ref) do
      next when is_binary(next) and next != "" ->
        {:ok,
         %{
           binding_ref: binding_ref,
           next_binding_ref: next,
           status: :rotation_requested,
           audit_ref: audit_ref(%{binding_ref: binding_ref, next_binding_ref: next})
         }}

      _missing ->
        {:error, :next_binding_ref_required}
    end
  end

  @impl true
  def revoke(lease_ref, _opts) when is_binary(lease_ref) do
    {:ok,
     %{
       lease_ref: lease_ref,
       status: :materialization_scope_closed,
       audit_ref: audit_ref(%{lease_ref: lease_ref, operation: :close})
     }}
  end

  @impl true
  def audit_ref(%SecretHandle{} = handle), do: handle.audit_ref

  def audit_ref(attrs) when is_map(attrs) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(attrs)) |> Base.encode16(case: :lower)
    "secret-audit://nshkr-vault/#{digest}"
  end

  defp valid_vault_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :read, 2)
  end

  defp valid_vault_module?(_module), do: false

  defp required_scope(scope, key) do
    case value(scope, key) do
      value when is_binary(value) and value != "" ->
        if String.contains?(value, ".."),
          do: {:error, {:invalid_vault_scope, key}},
          else: {:ok, String.trim(value, "/")}

      _missing ->
        {:error, {:invalid_vault_scope, key}}
    end
  end

  defp parse_uri(value) when is_binary(value) and value != "", do: {:ok, URI.parse(value)}
  defp parse_uri(_value), do: {:error, :invalid_vault_binding}

  defp validate_uri(uri, scheme, field) do
    if uri.scheme == scheme and present_string?(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment),
       do: :ok,
       else: {:error, {:invalid_vault_binding, field}}
  end

  defp binding_path(uri) do
    path = Enum.join([uri.host, String.trim(uri.path || "", "/")], "/")

    if present_string?(path) and not String.contains?(path, ".."),
      do: {:ok, path},
      else: {:error, {:invalid_vault_binding, :secret_binding_ref}}
  end

  defp select_material(material, scope) do
    case value(scope, :fields) do
      fields when is_list(fields) and fields != [] ->
        fields = MapSet.new(Enum.map(fields, &to_string/1))
        Map.filter(material, fn {key, _value} -> MapSet.member?(fields, to_string(key)) end)

      _all ->
        material
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
