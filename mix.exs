unless Code.ensure_loaded?(DependencySources) do
  Code.require_file("build_support/dependency_sources.exs", __DIR__)
end

Code.require_file("build_support/workspace_contract.exs", __DIR__)

defmodule Nshkr.Workspace.MixProject do
  use Mix.Project

  alias Nshkr.Build.WorkspaceContract

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/nshkr"
  @description "NSHKR is the production Elixir/OTP composition and release workspace for a governed AI operations platform, wiring durable workflows, cognitive context, provider accounts, policy decisions, execution runtimes, cluster reconciliation, Synapse, and Extravaganza into reproducible monolith and distributed deployments."

  def project do
    [
      app: :nshkr_workspace,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: false,
      deps: deps(),
      aliases: aliases(),
      blitz_workspace: blitz_workspace(),
      source_url: @source_url,
      homepage_url: @source_url,
      name: "NSHKR Workspace",
      description: @description,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [
      preferred_envs: [
        ci: :test,
        "monorepo.test": :test,
        "monorepo.credo": :test,
        "monorepo.docs": :dev
      ]
    ]
  end

  defp deps do
    [
      DependencySources.dep(:blitz, __DIR__, runtime: false),
      DependencySources.dep(:weld, __DIR__, only: [:dev, :test], runtime: false),
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    monorepo_aliases = [
      "monorepo.deps.get": ["blitz.workspace.impact deps_get --"],
      "monorepo.format": ["blitz.workspace.impact format --"],
      "monorepo.compile": ["blitz.workspace.impact compile --"],
      "monorepo.test": ["blitz.workspace.impact test --"],
      "monorepo.credo": ["blitz.workspace.impact credo --"],
      "monorepo.docs": ["blitz.workspace.impact docs --"]
    ]

    [
      ci: [
        "deps.get",
        "monorepo.deps.get",
        "monorepo.format --check-formatted",
        "monorepo.compile",
        "monorepo.test",
        "monorepo.credo --strict",
        "monorepo.docs",
        "weld.verify"
      ],
      "docs.root": ["docs"]
    ] ++ monorepo_aliases
  end

  defp blitz_workspace do
    [
      root: __DIR__,
      projects: WorkspaceContract.active_project_globs(),
      isolation: [
        deps_path: true,
        build_path: true,
        lockfile: true,
        hex_home: "_build/hex"
      ],
      parallelism: [
        max_concurrency: nil,
        multiplier: :auto,
        base: [deps_get: 2, format: 2, compile: 2, test: 2, credo: 2, docs: 2],
        overrides: []
      ],
      tasks: [
        deps_get: [args: ["deps.get"], preflight?: false],
        format: [args: ["format"]],
        compile: [args: ["compile", "--warnings-as-errors"]],
        test: [args: ["test"], mix_env: "test", color: true],
        credo: [args: ["credo"]],
        docs: [args: ["docs"]]
      ]
    ]
  end

  defp docs do
    [
      main: "workspace_readme",
      name: "NSHKR Workspace",
      logo: "assets/nshkr.svg",
      assets: %{"assets" => "assets"},
      source_ref: "main",
      source_url: @source_url,
      homepage_url: @source_url,
      extras: [
        {"README.md", filename: "workspace_readme"},
        "LICENSE"
      ],
      groups_for_extras: [Overview: ["README.md"], Project: ["LICENSE"]]
    ]
  end
end
