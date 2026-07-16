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
      DependencySources.dep(:citadel_governance, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_secrets_provider, @repo_root, runtime: false),
      DependencySources.dep(:jido_integration_v2_store_postgres, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_core, @repo_root, runtime: false),
      DependencySources.dep(:mezzanine_workflow_runtime, @repo_root, runtime: false),
      DependencySources.dep(:outer_brain_runtime, @repo_root, runtime: false),
      {:ecto_sql, "~> 3.13"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.22"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.20", only: :test}
    ]
  end

  defp releases do
    [
      nshkr: [
        include_executables_for: [:unix],
        applications: [
          citadel_governance: :load,
          jido_integration_secrets_provider: :load,
          jido_integration_v2_store_postgres: :load,
          mezzanine_core: :load,
          mezzanine_workflow_runtime: :load,
          outer_brain_runtime: :load
        ],
        config_providers: [
          {Nshkr.Runtime.ConfigProvider, path: {:system, "NSHKR_PROFILE_FILE"}}
        ]
      ]
    ]
  end
end
