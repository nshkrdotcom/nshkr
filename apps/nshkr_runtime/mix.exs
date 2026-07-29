unless Code.ensure_loaded?(DependencySources) do
  Code.require_file("../../build_support/dependency_sources.exs", __DIR__)
end

defmodule Nshkr.Runtime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/nshkr"
  @repo_root Path.expand("../..", __DIR__)

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
      DependencySources.dep(:agent_session_manager, @repo_root),
      DependencySources.dep(:app_kit_core, @repo_root, runtime: false),
      DependencySources.dep(:app_kit_mezzanine_bridge, @repo_root, runtime: false),
      DependencySources.dep(:app_kit_review_surface, @repo_root, runtime: false),
      DependencySources.dep(:citadel_governance, @repo_root, runtime: false),
      DependencySources.dep(:cli_subprocess_core, @repo_root),
      DependencySources.dep(:codex_sdk, @repo_root),
      DependencySources.dep(:execution_plane, @repo_root, runtime: false),
      DependencySources.dep(:gemini_ex, @repo_root),
      DependencySources.dep(:jido_integration_secrets_provider, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_v2_auth, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_v2_asm_runtime_bridge, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_v2_codex_cli, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_v2_control_plane, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_v2_runtime_router, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_v2_store_postgres, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_archival_engine, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_audit_engine, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_core, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_execution_engine, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_ops_domain, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_workflow_runtime, @repo_root, runtime: false),
      DependencySources.dep(:outer_brain_runtime, @repo_root, runtime: false),
      DependencySources.dep(:synapse_core, @repo_root, runtime: false),
      DependencySources.dep(:synapse_web, @repo_root, runtime: false),
      {:ecto_sql, "~> 3.13"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.22"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.20"}
    ]
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
