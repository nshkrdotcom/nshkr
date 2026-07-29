defmodule Nshkr.Runtime.ProductEndpoint do
  @moduledoc """
  Starts the loaded Synapse applications only after NSHKR preflight succeeds.

  The release keeps both Synapse applications in `:load` mode. This supervised
  boundary starts their dependency graph after durable owners and AppKit are
  proven, monitors the product supervisor, and stops both applications when
  the composed endpoint leaves the NSHKR supervision tree.
  """

  use GenServer

  @synapse_apps [:synapse_core, :synapse_web]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec probe(keyword()) :: :ok | {:error, atom()}
  def probe(opts) when is_list(opts) do
    endpoint = Keyword.get(opts, :endpoint, SynapseWeb.Endpoint)

    with :ok <- ensure_modules(endpoint),
         :ok <- ensure_apps_stopped(),
         :ok <- validate_product_config(Application.get_env(:synapse_core, Synapse.Config)),
         :ok <- validate_endpoint_config(Application.get_env(:synapse_web, endpoint)) do
      :ok
    end
  end

  @spec validate_endpoint_config(term()) :: :ok | {:error, atom()}
  def validate_endpoint_config(config) when is_list(config) do
    url = Keyword.get(config, :url)
    http = Keyword.get(config, :http)
    live_view = Keyword.get(config, :live_view)
    render_errors = Keyword.get(config, :render_errors)
    secret_key_base = Keyword.get(config, :secret_key_base)

    cond do
      Keyword.get(config, :server) != true ->
        {:error, :product_endpoint_server_disabled}

      Keyword.get(config, :adapter) != Bandit.PhoenixAdapter ->
        {:error, :product_endpoint_adapter_unavailable}

      Keyword.get(config, :pubsub_server) != Synapse.PubSub ->
        {:error, :product_endpoint_pubsub_unavailable}

      not valid_url?(url) ->
        {:error, :invalid_product_endpoint_url}

      not valid_http?(http) ->
        {:error, :invalid_product_endpoint_http}

      not valid_live_view?(live_view) ->
        {:error, :invalid_product_endpoint_live_view}

      not Keyword.keyword?(render_errors) ->
        {:error, :invalid_product_endpoint_render_errors}

      not (is_binary(secret_key_base) and byte_size(secret_key_base) >= 64) ->
        {:error, :invalid_product_endpoint_secret}

      true ->
        :ok
    end
  end

  def validate_endpoint_config(_config), do: {:error, :invalid_product_endpoint_config}

  @impl true
  def init(opts) do
    endpoint = Keyword.get(opts, :endpoint, SynapseWeb.Endpoint)

    with {:ok, core_started} <- ensure_started(:synapse_core),
         {:ok, web_started} <- ensure_started(:synapse_web),
         supervisor when is_pid(supervisor) <- Process.whereis(SynapseWeb.Supervisor) do
      monitor_ref = Process.monitor(supervisor)

      {:ok,
       %{
         endpoint: endpoint,
         monitor_ref: monitor_ref,
         core_started?: core_started,
         web_started?: web_started
       }}
    else
      _reason ->
        stop_synapse_apps()
        {:stop, :product_endpoint_start_failed}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %{monitor_ref: monitor_ref} = state
      ) do
    {:stop, :product_endpoint_supervisor_down, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.web_started?, do: Application.stop(:synapse_web)
    if state.core_started?, do: Application.stop(:synapse_core)
    :ok
  end

  defp ensure_modules(endpoint) do
    modules = [
      Synapse.Application,
      SynapseWeb.Application,
      endpoint
    ]

    if Enum.all?(modules, &Code.ensure_loaded?/1),
      do: :ok,
      else: {:error, :product_endpoint_module_unavailable}
  end

  defp ensure_apps_stopped do
    started = Application.started_applications() |> MapSet.new(&elem(&1, 0))

    if Enum.any?(@synapse_apps, &MapSet.member?(started, &1)),
      do: {:error, :product_endpoint_started_before_preflight},
      else: :ok
  end

  defp validate_product_config(config) when is_list(config) do
    required = [
      :tenant_id,
      :product_slug,
      :product_name,
      :product_family,
      :pack_version,
      :default_installation_id,
      :bootstrap_mode
    ]

    if Enum.all?(required, &Keyword.has_key?(config, &1)),
      do: :ok,
      else: {:error, :invalid_product_endpoint_product_config}
  end

  defp validate_product_config(_config),
    do: {:error, :invalid_product_endpoint_product_config}

  defp valid_url?(url) when is_list(url) do
    case Keyword.get(url, :host) do
      host when is_binary(host) and host != "" -> true
      _other -> false
    end
  end

  defp valid_url?(_url), do: false

  defp valid_http?(http) when is_list(http) do
    port = Keyword.get(http, :port)
    ip = Keyword.get(http, :ip)

    is_integer(port) and port in 1..65_535 and is_tuple(ip) and tuple_size(ip) in [4, 8]
  end

  defp valid_http?(_http), do: false

  defp valid_live_view?(live_view) when is_list(live_view) do
    case Keyword.get(live_view, :signing_salt) do
      salt when is_binary(salt) and byte_size(salt) >= 8 -> true
      _other -> false
    end
  end

  defp valid_live_view?(_live_view), do: false

  defp ensure_started(app) do
    already_started? =
      Application.started_applications()
      |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)

    case Application.ensure_all_started(app, :temporary) do
      {:ok, _apps} -> {:ok, not already_started?}
      {:error, _reason} -> {:error, :product_endpoint_application_start_failed}
    end
  end

  defp stop_synapse_apps do
    Application.stop(:synapse_web)
    Application.stop(:synapse_core)
    :ok
  end
end
