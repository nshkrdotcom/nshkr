repo_root = Path.expand("..", __DIR__)
siblings_root = Path.expand("..", repo_root)

internal = fn repository, subdir ->
  %{
    path: Path.join(siblings_root, "#{repository}/#{subdir}"),
    github: %{repo: "nshkrdotcom/#{repository}", branch: "main", subdir: subdir},
    hex: "~> 0.1.0",
    opts: [override: true],
    default_order: [:path, :github, :hex],
    publish_order: [:hex]
  }
end

root_package = fn repository, hex_requirement ->
  %{
    path: Path.join(siblings_root, repository),
    github: %{repo: "nshkrdotcom/#{repository}", branch: "main"},
    hex: hex_requirement,
    opts: [override: true],
    default_order: [:path, :github, :hex],
    publish_order: [:hex]
  }
end

%{
  deps: %{
    agent_session_manager: root_package.("agent_session_manager", "~> 0.12.0"),
    app_kit_core: internal.("app_kit", "core/app_kit_core"),
    app_kit_mezzanine_bridge: internal.("app_kit", "bridges/mezzanine_bridge"),
    blitz: %{
      hex: "~> 0.3.0",
      default_order: [:hex],
      publish_order: [:hex]
    },
    weld: %{
      hex: "~> 0.8.4",
      default_order: [:hex],
      publish_order: [:hex]
    },
    citadel_governance: internal.("citadel", "core/citadel_governance"),
    cli_subprocess_core: root_package.("cli_subprocess_core", "~> 0.4.0"),
    codex_sdk: root_package.("codex_sdk", "~> 0.18.0"),
    execution_plane: internal.("execution_plane", "core/execution_plane"),
    gemini_ex: %{
      path: Path.join(siblings_root, "gemini_ex"),
      github: %{repo: "nshkrdotcom/gemini_ex", branch: "main"},
      hex: "~> 0.15.0",
      opts: [override: true],
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    jido_integration_secrets_provider: internal.("jido_integration", "core/secrets_provider"),
    jido_integration_v2_auth: internal.("jido_integration", "core/auth"),
    jido_integration_v2_asm_runtime_bridge:
      internal.("jido_integration", "core/asm_runtime_bridge"),
    jido_integration_v2_codex_cli: internal.("jido_integration", "connectors/codex_cli"),
    jido_integration_v2_control_plane: internal.("jido_integration", "core/control_plane"),
    jido_integration_v2_runtime_router: internal.("jido_integration", "core/runtime_router"),
    jido_integration_v2_store_postgres: internal.("jido_integration", "core/store_postgres"),
    mezzanine_core: internal.("mezzanine", "core/mezzanine_core"),
    mezzanine_execution_engine: internal.("mezzanine", "core/execution_engine"),
    mezzanine_ops_domain: internal.("mezzanine", "core/ops_domain"),
    mezzanine_workflow_runtime: internal.("mezzanine", "core/workflow_runtime"),
    outer_brain_runtime: internal.("outer_brain", "core/outer_brain_runtime")
  }
}
