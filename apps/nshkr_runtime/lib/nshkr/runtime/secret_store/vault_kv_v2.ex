defmodule Nshkr.Runtime.SecretStore.VaultAuth do
  @moduledoc "Transient machine-identity authentication for Vault."

  @callback login(keyword()) ::
              {:ok,
               %{
                 required(:token) => binary(),
                 required(:lease_duration_seconds) => non_neg_integer(),
                 required(:renewable) => boolean()
               }}
              | {:error, term()}
end

defmodule Nshkr.Runtime.SecretStore.VaultKubernetesAuth do
  @moduledoc "Vault Kubernetes auth using a service-account JWT file."

  @behaviour Nshkr.Runtime.SecretStore.VaultAuth

  @impl true
  def login(opts) do
    with endpoint when is_binary(endpoint) <- Keyword.get(opts, :endpoint),
         role when is_binary(role) <- Keyword.get(opts, :role),
         jwt_path when is_binary(jwt_path) <- Keyword.get(opts, :jwt_path),
         {:ok, jwt} <- File.read(jwt_path),
         {:ok, response} <-
           request(
             :post,
             endpoint,
             "/v1/auth/#{Keyword.get(opts, :mount, "kubernetes")}/login",
             json: %{role: role, jwt: String.trim(jwt)},
             headers: namespace_headers(opts),
             request_options: Keyword.get(opts, :request_options, [])
           ),
         {:ok, auth} <- authentication(response) do
      {:ok, auth}
    else
      nil -> {:error, :vault_kubernetes_auth_not_configured}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_vault_kubernetes_auth}
    end
  end

  defp authentication(%Req.Response{status: status, body: body}) when status in 200..299 do
    auth = value(body, "auth", %{})
    token = value(auth, "client_token")
    lease = value(auth, "lease_duration", 0)
    renewable = value(auth, "renewable", false)

    if is_binary(token) and token != "" and is_integer(lease) and lease >= 0 and
         is_boolean(renewable) do
      {:ok, %{token: token, lease_duration_seconds: lease, renewable: renewable}}
    else
      {:error, :invalid_vault_auth_response}
    end
  end

  defp authentication(%Req.Response{status: status}), do: {:error, {:vault_auth_rejected, status}}

  defp request(method, endpoint, path, opts) do
    url = String.trim_trailing(endpoint, "/") <> path
    request_options = Keyword.get(opts, :request_options, [])

    options =
      [method: method, url: url, retry: false]
      |> Keyword.merge(Keyword.delete(opts, :request_options))
      |> Keyword.merge(request_options)

    case Req.request(options) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, {:vault_transport, exception.__struct__}}
    end
  end

  defp namespace_headers(opts) do
    case Keyword.get(opts, :namespace) do
      namespace when is_binary(namespace) and namespace != "" ->
        [{"x-vault-namespace", namespace}]

      _other ->
        []
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, String.to_atom(key), default))

  defp value(_value, _key, default), do: default
end

defmodule Nshkr.Runtime.SecretStore.VaultAppRoleAuth do
  @moduledoc "Vault AppRole auth using role and secret identifiers mounted as files."

  @behaviour Nshkr.Runtime.SecretStore.VaultAuth

  @impl true
  def login(opts) do
    with endpoint when is_binary(endpoint) <- Keyword.get(opts, :endpoint),
         role_id_path when is_binary(role_id_path) <- Keyword.get(opts, :role_id_path),
         secret_id_path when is_binary(secret_id_path) <- Keyword.get(opts, :secret_id_path),
         {:ok, role_id} <- File.read(role_id_path),
         {:ok, secret_id} <- File.read(secret_id_path),
         {:ok, response} <- request(opts, endpoint, String.trim(role_id), String.trim(secret_id)),
         {:ok, auth} <- authentication(response) do
      {:ok, auth}
    else
      nil -> {:error, :vault_approle_auth_not_configured}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_vault_approle_auth}
    end
  end

  defp request(opts, endpoint, role_id, secret_id) do
    path = "/v1/auth/#{Keyword.get(opts, :mount, "approle")}/login"

    request_options = Keyword.get(opts, :request_options, [])

    options =
      [
        method: :post,
        url: String.trim_trailing(endpoint, "/") <> path,
        json: %{role_id: role_id, secret_id: secret_id},
        headers: namespace_headers(opts),
        retry: false
      ]
      |> Keyword.merge(request_options)

    case Req.request(options) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, {:vault_transport, exception.__struct__}}
    end
  end

  defp authentication(%Req.Response{status: status, body: body}) when status in 200..299 do
    auth = value(body, "auth", %{})
    token = value(auth, "client_token")
    lease = value(auth, "lease_duration", 0)
    renewable = value(auth, "renewable", false)

    if is_binary(token) and token != "" and is_integer(lease) and lease >= 0 and
         is_boolean(renewable) do
      {:ok, %{token: token, lease_duration_seconds: lease, renewable: renewable}}
    else
      {:error, :invalid_vault_auth_response}
    end
  end

  defp authentication(%Req.Response{status: status}), do: {:error, {:vault_auth_rejected, status}}

  defp namespace_headers(opts) do
    case Keyword.get(opts, :namespace) do
      namespace when is_binary(namespace) and namespace != "" ->
        [{"x-vault-namespace", namespace}]

      _other ->
        []
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, String.to_atom(key), default))

  defp value(_value, _key, default), do: default
end

defmodule Nshkr.Runtime.SecretStore.Material do
  @moduledoc false

  @derive {Inspect, only: [:path, :version, :lease_ref]}
  @enforce_keys [:path, :version, :lease_ref, :payload]
  defstruct [:path, :version, :lease_ref, :payload]

  def material(%__MODULE__{payload: payload}), do: payload
end

defimpl Jason.Encoder, for: Nshkr.Runtime.SecretStore.Material do
  def encode(_material, _opts), do: raise(ArgumentError, "secret material is transient")
end

defmodule Nshkr.Runtime.SecretStore.VaultToken do
  @moduledoc false

  @derive {Inspect, only: [:lease_duration_seconds, :renewable]}
  @enforce_keys [:token, :lease_duration_seconds, :renewable]
  defstruct [:token, :lease_duration_seconds, :renewable]
end

defmodule Nshkr.Runtime.SecretStore.VaultKvV2 do
  @moduledoc "Supervised HashiCorp Vault KV v2 client with transient tokens only."

  use GenServer

  alias Nshkr.Runtime.SecretStore.{Material, VaultToken}

  @renew :renew_vault_token

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec probe(keyword()) :: :ok | {:error, term()}
  def probe(opts) do
    with {:ok, auth} <- authenticate(opts),
         {:ok, %Req.Response{status: status}} <- token_lookup(opts, auth.token),
         true <- status in 200..299 do
      :ok
    else
      false -> {:error, :vault_token_lookup_rejected}
      {:ok, %Req.Response{status: status}} -> {:error, {:vault_token_lookup_rejected, status}}
      {:error, _reason} = error -> error
    end
  end

  @spec read(String.t(), GenServer.server()) :: {:ok, Material.t()} | {:error, term()}
  def read(path, server \\ __MODULE__) when is_binary(path) do
    GenServer.call(server, {:read, path})
  end

  @spec fetch(String.t(), keyword()) :: {:ok, Material.t()} | {:error, term()}
  def fetch(path, opts) when is_binary(path) and is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, auth} <- authenticate(opts) do
      read_secret(opts, auth.token, path)
    end
  end

  @impl true
  def init(opts) do
    with :ok <- validate_options(opts),
         {:ok, auth} <- authenticate(opts) do
      state = %{opts: opts, auth: auth, timer_ref: nil}
      {:ok, schedule_renewal(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:read, path}, _from, state) do
    case read_secret(state.opts, state.auth.token, path) do
      {:ok, material} ->
        {:reply, {:ok, material}, state}

      {:error, :vault_token_expired} ->
        with {:ok, auth} <- authenticate(state.opts),
             {:ok, material} <- read_secret(state.opts, auth.token, path) do
          {:reply, {:ok, material}, schedule_renewal(%{state | auth: auth})}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(@renew, state) do
    case authenticate(state.opts) do
      {:ok, auth} -> {:noreply, schedule_renewal(%{state | auth: auth, timer_ref: nil})}
      {:error, reason} -> {:stop, {:vault_reauthentication_failed, reason}, state}
    end
  end

  defp validate_options(opts) do
    required = [:endpoint, :mount, :auth_module, :auth_options]

    if Keyword.keyword?(opts) and Enum.all?(required, &Keyword.has_key?(opts, &1)),
      do: :ok,
      else: {:error, :invalid_vault_configuration}
  end

  defp authenticate(opts) do
    module = Keyword.get(opts, :auth_module)
    auth_opts = Keyword.get(opts, :auth_options, [])

    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :login, 1) do
      case module.login(Keyword.put_new(auth_opts, :endpoint, Keyword.get(opts, :endpoint))) do
        {:ok, %{token: token, lease_duration_seconds: seconds, renewable: renewable}}
        when is_binary(token) and is_integer(seconds) and seconds >= 0 and is_boolean(renewable) ->
          {:ok,
           %VaultToken{
             token: token,
             lease_duration_seconds: seconds,
             renewable: renewable
           }}

        {:error, _reason} = error ->
          error

        _other ->
          {:error, :invalid_vault_auth_result}
      end
    else
      {:error, :invalid_vault_auth_module}
    end
  end

  defp token_lookup(opts, token) do
    request(opts, :get, "/v1/auth/token/lookup-self", token, [])
  end

  defp read_secret(opts, token, path) do
    mount = Keyword.fetch!(opts, :mount)
    encoded_path = path |> String.split("/", trim: true) |> Enum.map_join("/", &URI.encode/1)

    case request(opts, :get, "/v1/#{mount}/data/#{encoded_path}", token, []) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        data = value(value(body, "data", %{}), "data")
        metadata = value(value(body, "data", %{}), "metadata", %{})
        version = value(metadata, "version")

        if is_map(data) and is_integer(version) do
          {:ok,
           %Material{
             path: path,
             version: version,
             lease_ref: "vault-kv-v2://#{mount}/#{path}?version=#{version}",
             payload: data
           }}
        else
          {:error, :invalid_vault_secret_response}
        end

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :vault_token_expired}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :secret_not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:vault_read_rejected, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp request(opts, method, path, token, request_opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)

    headers =
      [{"x-vault-token", token}]
      |> maybe_namespace(Keyword.get(opts, :namespace))

    options =
      [
        method: method,
        url: String.trim_trailing(endpoint, "/") <> path,
        headers: headers,
        retry: false
      ]
      |> Keyword.merge(request_opts)
      |> Keyword.merge(Keyword.get(opts, :request_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, {:vault_transport, exception.__struct__}}
    end
  end

  defp maybe_namespace(headers, namespace) when is_binary(namespace) and namespace != "",
    do: [{"x-vault-namespace", namespace} | headers]

  defp maybe_namespace(headers, _namespace), do: headers

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, String.to_atom(key), default))

  defp value(_value, _key, default), do: default

  defp schedule_renewal(%{auth: %{lease_duration_seconds: seconds}} = state) when seconds > 0 do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    delay = max(div(seconds * 1_000, 2), 1_000)
    %{state | timer_ref: Process.send_after(self(), @renew, delay)}
  end

  defp schedule_renewal(state), do: state
end
