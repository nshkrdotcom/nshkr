defmodule Nshkr.Build.WorkspaceContract do
  @moduledoc false

  @repo_root Path.expand("..", __DIR__)
  @siblings_root Path.expand("..", @repo_root)
  @brainstorms_root Path.expand("../j/jido_brainstorm", @siblings_root)

  @package_paths ["apps/nshkr_runtime"]
  @active_project_globs [".", "apps/*"]

  @compile_matrix_layout [
    {"agent_session_manager", []},
    {"app_kit", ["bridges", "core", "examples", "web"]},
    {"blitz", []},
    {"chassis",
     [
       "adapters",
       "bootstrap",
       "core",
       "evolution",
       "governance",
       "host",
       "manager",
       "model",
       "observability",
       "proof",
       "secrets"
     ]},
    {"citadel", ["apps", "bridges", "core", "surfaces"]},
    {"claude_agent_sdk", ["examples"]},
    {"cli_subprocess_core", []},
    {"codex_sdk", []},
    {"execution_plane",
     ["core", "packaging/weld/execution_plane", "protocols", "runtimes", "streaming"]},
    {"extravaganza", ["apps"]},
    {"gemini_ex", []},
    {"ground_plane", ["core", "examples"]},
    {"inference", ["apps"]},
    {"jido_integration", ["apps", "connectors", "core", "scaffolds"]},
    {"mezzanine", ["bridges", "core"]},
    {"outer_brain", ["apps", "bridges", "core", "examples"]},
    {"pristine", ["apps"]},
    {"prompt_runner_sdk", []},
    {"stack_lab", ["bridges", "examples", "support"]},
    {"synapse", ["apps"]},
    {"temporalex", []},
    {"weld", []}
  ]

  @compile_matrix_repositories [
    %{repo: "nshkr", path: @repo_root},
    %{repo: "brainstorms", path: @brainstorms_root},
    %{repo: "app_kit", path: Path.join(@siblings_root, "app_kit")},
    %{repo: "mezzanine", path: Path.join(@siblings_root, "mezzanine")},
    %{repo: "citadel", path: Path.join(@siblings_root, "citadel")},
    %{repo: "outer_brain", path: Path.join(@siblings_root, "outer_brain")},
    %{repo: "jido_integration", path: Path.join(@siblings_root, "jido_integration")},
    %{repo: "execution_plane", path: Path.join(@siblings_root, "execution_plane")},
    %{repo: "chassis", path: Path.join(@siblings_root, "chassis")},
    %{repo: "ground_plane", path: Path.join(@siblings_root, "ground_plane")},
    %{repo: "inference", path: Path.join(@siblings_root, "inference")},
    %{repo: "pristine", path: Path.join(@siblings_root, "pristine")},
    %{repo: "gemini_ex", path: Path.join(@siblings_root, "gemini_ex")},
    %{repo: "synapse", path: Path.join(@siblings_root, "synapse")},
    %{repo: "extravaganza", path: Path.join(@siblings_root, "extravaganza")},
    %{repo: "agent_session_manager", path: Path.join(@siblings_root, "agent_session_manager")},
    %{repo: "cli_subprocess_core", path: Path.join(@siblings_root, "cli_subprocess_core")},
    %{repo: "codex_sdk", path: Path.join(@siblings_root, "codex_sdk")},
    %{repo: "claude_agent_sdk", path: Path.join(@siblings_root, "claude_agent_sdk")},
    %{repo: "blitz", path: Path.join(@siblings_root, "blitz")},
    %{repo: "prompt_runner_sdk", path: Path.join(@siblings_root, "prompt_runner_sdk")},
    %{repo: "stack_lab", path: Path.join(@siblings_root, "stack_lab")},
    %{repo: "temporalex", path: Path.join(@siblings_root, "temporalex")},
    %{repo: "weld", path: Path.join(@siblings_root, "weld")}
  ]

  def package_paths, do: @package_paths
  def active_project_globs, do: @active_project_globs

  def compile_matrix_project_globs do
    [".", "apps/*"] ++
      Enum.flat_map(@compile_matrix_layout, fn {repository, groups} ->
        root = Path.join(@siblings_root, repository)
        [root | Enum.map(groups, &Path.join([root, &1, "*"]))]
      end)
  end

  def compile_matrix_repositories, do: @compile_matrix_repositories

  def compile_matrix_repo(path) do
    expanded = Path.expand(path)

    @compile_matrix_repositories
    |> Enum.sort_by(&(byte_size(&1.path) * -1))
    |> Enum.find(fn repository ->
      expanded == repository.path or String.starts_with?(expanded, repository.path <> "/")
    end)
    |> case do
      nil -> "unknown"
      repository -> repository.repo
    end
  end
end
