defmodule Nshkr.Runtime.ObjectStore.CredentialProvider do
  @moduledoc "Transient S3 credential provider contract."

  @callback fetch(keyword()) ::
              {:ok,
               %{
                 required(:access_key_id) => binary(),
                 required(:secret_access_key) => binary(),
                 optional(:session_token) => binary()
               }}
              | {:error, term()}
end

defmodule Nshkr.Runtime.ObjectStore.VaultCredentialProvider do
  @moduledoc "Retrieves bounded MinIO credentials through the supervised Vault client."

  @behaviour Nshkr.Runtime.ObjectStore.CredentialProvider

  alias Nshkr.Runtime.SecretStore.{Material, VaultKvV2}

  @impl true
  def fetch(opts) do
    with path when is_binary(path) <- Keyword.get(opts, :path),
         {:ok, %Material{} = secret} <- fetch_material(path, opts),
         payload <- Material.material(secret),
         access_key when is_binary(access_key) <- value(payload, "access_key_id"),
         secret_key when is_binary(secret_key) <- value(payload, "secret_access_key") do
      {:ok,
       %{
         access_key_id: access_key,
         secret_access_key: secret_key,
         session_token: value(payload, "session_token")
       }}
    else
      nil -> {:error, :object_store_credential_missing}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_object_store_credential}
    end
  end

  defp fetch_material(path, opts) do
    case Keyword.fetch(opts, :vault_options) do
      {:ok, vault_options} when is_list(vault_options) -> VaultKvV2.fetch(path, vault_options)
      :error -> VaultKvV2.read(path, Keyword.get(opts, :vault_server, VaultKvV2))
      _other -> {:error, :invalid_vault_options}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
end

defmodule Nshkr.Runtime.ObjectStore.MinioS3 do
  @moduledoc "Supervised, SigV4-authenticated MinIO S3 object client."

  use GenServer

  @service "s3"
  @empty_hash Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec probe(keyword()) :: :ok | {:error, term()}
  def probe(opts) do
    with {:ok, probe_opts} <- probe_options(opts) do
      case request(probe_opts, :head, nil, <<>>) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, {:object_store_probe_rejected, status}}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec put(String.t(), iodata(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(key, body, opts \\ []) when is_binary(key) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:put, key, IO.iodata_to_binary(body)})
  end

  @spec get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def get(key, opts \\ []) when is_binary(key) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:get, key})
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) when is_binary(key) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:delete, key})
  end

  @impl true
  def init(opts) do
    case validate_options(opts) do
      :ok -> {:ok, %{opts: opts}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:put, key, body}, _from, state) do
    reply =
      case request(state.opts, :put, key, body) do
        {:ok, %Req.Response{status: status, headers: headers}} when status in 200..299 ->
          {:ok, %{key: key, etag: header(headers, "etag")}}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:object_store_put_rejected, status}}

        {:error, _reason} = error ->
          error
      end

    {:reply, reply, state}
  end

  def handle_call({:get, key}, _from, state) do
    reply =
      case request(state.opts, :get, key, <<>>) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, IO.iodata_to_binary(body)}

        {:ok, %Req.Response{status: 404}} ->
          {:error, :object_not_found}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:object_store_get_rejected, status}}

        {:error, _reason} = error ->
          error
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, key}, _from, state) do
    reply =
      case request(state.opts, :delete, key, <<>>) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, {:object_store_delete_rejected, status}}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  defp validate_options(opts) do
    required = [:endpoint, :bucket, :region, :credential_provider, :credential_options]

    if Keyword.keyword?(opts) and Enum.all?(required, &Keyword.has_key?(opts, &1)) and
         Keyword.keyword?(Keyword.get(opts, :credential_options)),
       do: :ok,
       else: {:error, :invalid_object_store_configuration}
  end

  defp probe_options(opts) do
    case Keyword.fetch(opts, :preflight_credential_options) do
      {:ok, credential_options} when is_list(credential_options) ->
        if Keyword.keyword?(credential_options),
          do: {:ok, Keyword.put(opts, :credential_options, credential_options)},
          else: {:error, :invalid_object_store_preflight_credentials}

      :error ->
        {:ok, opts}

      _other ->
        {:error, :invalid_object_store_preflight_credentials}
    end
  end

  defp request(opts, method, key, body) do
    with :ok <- validate_options(opts),
         {:ok, credentials} <- credentials(opts),
         {:ok, request} <- signed_request(opts, credentials, method, key, body) do
      case Req.request(request) do
        {:ok, %Req.Response{} = response} -> {:ok, response}
        {:error, exception} -> {:error, {:object_store_transport, exception.__struct__}}
      end
    end
  end

  defp credentials(opts) do
    module = Keyword.fetch!(opts, :credential_provider)

    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :fetch, 1) do
      module.fetch(Keyword.fetch!(opts, :credential_options))
    else
      {:error, :invalid_object_store_credential_provider}
    end
  end

  defp signed_request(opts, credentials, method, key, body) do
    endpoint = URI.parse(Keyword.fetch!(opts, :endpoint))
    bucket = Keyword.fetch!(opts, :bucket)
    region = Keyword.fetch!(opts, :region)

    with true <- endpoint.scheme in ["http", "https"] and is_binary(endpoint.host),
         {:ok, path} <- object_path(endpoint.path, bucket, key) do
      now = DateTime.utc_now()
      amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      short_date = Calendar.strftime(now, "%Y%m%d")

      payload_hash =
        if(method == :get or method == :head or method == :delete,
          do: @empty_hash,
          else: sha256(body)
        )

      host = host_header(endpoint)

      base_headers = [
        {"host", host},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date}
      ]

      headers = maybe_session_token(base_headers, Map.get(credentials, :session_token))
      {canonical_headers, signed_headers} = canonical_headers(headers)

      canonical_request =
        [
          method |> Atom.to_string() |> String.upcase(),
          path,
          "",
          canonical_headers,
          signed_headers,
          payload_hash
        ]
        |> Enum.join("\n")

      scope = "#{short_date}/#{region}/#{@service}/aws4_request"
      string_to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{sha256(canonical_request)}"

      signature =
        signing_key(credentials.secret_access_key, short_date, region) |> hmac_hex(string_to_sign)

      authorization =
        "AWS4-HMAC-SHA256 Credential=#{credentials.access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

      url = URI.to_string(%{endpoint | path: path, query: nil, fragment: nil})

      request = [
        method: method,
        url: url,
        headers: [{"authorization", authorization} | headers],
        body: body,
        retry: false,
        decode_body: false
      ]

      {:ok, Keyword.merge(request, Keyword.get(opts, :request_options, []))}
    else
      false -> {:error, :invalid_object_store_endpoint}
      {:error, _reason} = error -> error
    end
  end

  defp object_path(base_path, bucket, nil) do
    {:ok, join_path(base_path, [bucket])}
  end

  defp object_path(base_path, bucket, key) when is_binary(key) and key != "" do
    segments = String.split(key, "/", trim: true)

    if segments == [],
      do: {:error, :invalid_object_key},
      else: {:ok, join_path(base_path, [bucket | segments])}
  end

  defp object_path(_base_path, _bucket, _key), do: {:error, :invalid_object_key}

  defp join_path(base_path, segments) do
    prefix = base_path || ""

    encoded =
      Enum.map_join(segments, "/", fn segment ->
        URI.encode(segment, &URI.char_unreserved?/1)
      end)

    String.trim_trailing(prefix, "/") <> "/" <> encoded
  end

  defp host_header(%URI{host: host, port: nil}), do: host
  defp host_header(%URI{scheme: "http", host: host, port: 80}), do: host
  defp host_header(%URI{scheme: "https", host: host, port: 443}), do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp maybe_session_token(headers, token) when is_binary(token) and token != "",
    do: [{"x-amz-security-token", token} | headers]

  defp maybe_session_token(headers, _token), do: headers

  defp canonical_headers(headers) do
    normalized = Enum.sort_by(headers, &elem(&1, 0))

    canonical =
      Enum.map_join(normalized, "", fn {key, value} -> "#{key}:#{String.trim(value)}\n" end)

    signed = Enum.map_join(normalized, ";", &elem(&1, 0))
    {canonical, signed}
  end

  defp signing_key(secret, date, region) do
    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hmac_hex(key, data), do: key |> hmac(data) |> Base.encode16(case: :lower)
  defp sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  defp header(headers, key) do
    headers
    |> Enum.find_value(fn
      {^key, [value | _]} -> value
      {^key, value} when is_binary(value) -> value
      _other -> nil
    end)
  end
end
