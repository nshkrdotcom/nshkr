defmodule Nshkr.Runtime.ProductEndpointTest do
  use ExUnit.Case, async: false

  alias Nshkr.Runtime.ProductEndpoint

  setup do
    endpoint_config = Application.get_env(:synapse_web, SynapseWeb.Endpoint)
    product_config = Application.get_env(:synapse_core, Synapse.Config)

    on_exit(fn ->
      restore_env(:synapse_web, SynapseWeb.Endpoint, endpoint_config)
      restore_env(:synapse_core, Synapse.Config, product_config)
      Application.stop(:synapse_web)
      Application.stop(:synapse_core)
    end)

    :ok
  end

  test "validates fail-closed endpoint configuration" do
    config = endpoint_config(4410)

    assert :ok = ProductEndpoint.validate_endpoint_config(config)

    assert {:error, :product_endpoint_server_disabled} =
             config
             |> Keyword.put(:server, false)
             |> ProductEndpoint.validate_endpoint_config()

    assert {:error, :invalid_product_endpoint_secret} =
             config
             |> Keyword.put(:secret_key_base, "short")
             |> ProductEndpoint.validate_endpoint_config()
  end

  test "starts loaded Synapse applications behind the composed service" do
    Application.put_env(:synapse_web, SynapseWeb.Endpoint, endpoint_config(44_11))

    assert Code.ensure_loaded?(AppKit.ReviewSurface)
    refute started?(:synapse_core)
    refute started?(:synapse_web)
    assert :ok = ProductEndpoint.probe(endpoint: SynapseWeb.Endpoint)

    assert {:ok, product_endpoint} =
             ProductEndpoint.start_link(name: nil, endpoint: SynapseWeb.Endpoint)

    assert started?(:synapse_core)
    assert started?(:synapse_web)
    assert is_pid(Process.whereis(Synapse.Supervisor))
    assert is_pid(Process.whereis(SynapseWeb.Supervisor))
    assert is_pid(Process.whereis(SynapseWeb.Endpoint))

    GenServer.stop(product_endpoint)

    refute started?(:synapse_web)
    refute started?(:synapse_core)
  end

  defp endpoint_config(port) do
    [
      url: [scheme: "http", host: "127.0.0.1", port: port],
      adapter: Bandit.PhoenixAdapter,
      render_errors: [
        formats: [html: SynapseWeb.ErrorHTML, json: SynapseWeb.ErrorJSON],
        layout: false
      ],
      pubsub_server: Synapse.PubSub,
      live_view: [signing_salt: "test-live-view-salt"],
      http: [ip: {127, 0, 0, 1}, port: port],
      server: true,
      secret_key_base: String.duplicate("s", 64)
    ]
  end

  defp started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
