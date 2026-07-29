import Config

config :synapse_core, Synapse.Config,
  tenant_id: "default",
  product_slug: "nshkr-agent",
  product_name: "NSHKR Agent",
  product_family: "agent_workspace",
  pack_version: "0.1.0",
  default_installation_id: "default",
  bootstrap_mode: :disabled,
  execution_timeout_ms: 300_000,
  operator_surface_enabled?: true

config :synapse_core, :dns_cluster_query, :ignore

config :synapse_web,
  generators: [context_app: :synapse_core]

config :synapse_web, SynapseWeb.Endpoint,
  url: [host: "127.0.0.1"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SynapseWeb.ErrorHTML, json: SynapseWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Synapse.PubSub,
  live_view: [signing_salt: "nshkr-synapse-live-view"],
  server: false

config :phoenix, :json_library, Jason
