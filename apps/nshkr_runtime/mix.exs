if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule Nshkr.Runtime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/nshkr"

  def project do
    [
      app: :nshkr_runtime,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      source_url: @source_url,
      homepage_url: @source_url,
      name: "NSHKR Runtime",
      description: "Production OTP composition and release application for NSHKR"
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger] ++ test_applications(Mix.env())] ++
      runtime_application(Mix.env())
  end

  defp test_applications(:test), do: [:plug]
  defp test_applications(_env), do: []

  defp runtime_application(:test), do: []
  defp runtime_application(_env), do: [mod: {Nshkr.Runtime.Application, []}]

  defp deps do
    [
      workspace_dep({:agent_session_manager, "~> 0.17.3", override: true}),
      workspace_dep({:app_kit_core, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:app_kit_mezzanine_bridge, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:app_kit_review_surface, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:citadel_governance, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:cli_subprocess_core, "~> 0.9.3", override: true}),
      workspace_dep({:codex_sdk, "~> 0.21.3", override: true}),
      workspace_dep({:execution_plane, "~> 0.3.0", override: true, runtime: false}),
      workspace_dep({:gemini_ex, "~> 0.18.0", override: true}),
      workspace_dep(
        {:jido_integration_secrets_provider, "~> 0.1.0", override: true, runtime: false}
      ),
      workspace_dep({:jido_integration_v2_auth, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep(
        {:jido_integration_v2_asm_runtime_bridge, "~> 0.1.0", override: true, runtime: false}
      ),
      workspace_dep({:jido_integration_v2_codex_cli, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep(
        {:jido_integration_v2_control_plane, "~> 0.1.0", override: true, runtime: false}
      ),
      workspace_dep(
        {:jido_integration_v2_runtime_router, "~> 0.1.0", override: true, runtime: false}
      ),
      workspace_dep(
        {:jido_integration_v2_store_postgres, "~> 0.1.0", override: true, runtime: false}
      ),
      workspace_dep({:mezzanine_archival_engine, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:mezzanine_audit_engine, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:mezzanine_core, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:mezzanine_execution_engine, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:mezzanine_ops_domain, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:mezzanine_workflow_runtime, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:outer_brain_runtime, "~> 0.1.0", override: true, runtime: false}),
      workspace_dep({:pristine, "~> 0.4.0", override: true}),
      {:synapse_core, "~> 0.1.0", override: true, runtime: false},
      {:synapse_web, "~> 0.1.0", override: true, runtime: false},
      {:ecto_sql, "~> 3.14.0"},
      {:jason, "~> 1.4.5"},
      {:postgrex, "~> 0.22.4"},
      {:req, "~> 0.7.4"},
      {:plug, "~> 1.20.3"}
    ]
  end

  defp workspace_dep(committed) do
    if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
      do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
      else: committed
  end

  defp releases do
    [
      nshkr: [
        include_executables_for: [:unix],
        applications: [
          app_kit_core: :load,
          app_kit_mezzanine_bridge: :load,
          app_kit_review_surface: :load,
          citadel_governance: :load,
          jido_integration_secrets_provider: :load,
          jido_integration_v2_auth: :load,
          jido_integration_v2_control_plane: :load,
          jido_integration_v2_store_postgres: :load,
          mezzanine_archival_engine: :load,
          mezzanine_audit_engine: :load,
          mezzanine_core: :load,
          mezzanine_execution_engine: :load,
          mezzanine_ops_domain: :load,
          mezzanine_workflow_runtime: :load,
          outer_brain_runtime: :load,
          synapse_core: :load,
          synapse_web: :load
        ],
        config_providers: [
          {Nshkr.Runtime.ConfigProvider, path: {:system, "NSHKR_PROFILE_FILE"}}
        ]
      ]
    ]
  end
end
