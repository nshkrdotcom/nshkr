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

%{
  deps: %{
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
    jido_integration_secrets_provider:
      internal.("jido_integration", "core/secrets_provider"),
    jido_integration_v2_auth: internal.("jido_integration", "core/auth"),
    jido_integration_v2_control_plane:
      internal.("jido_integration", "core/control_plane"),
    jido_integration_v2_store_postgres:
      internal.("jido_integration", "core/store_postgres"),
    mezzanine_core: internal.("mezzanine", "core/mezzanine_core"),
    mezzanine_workflow_runtime: internal.("mezzanine", "core/workflow_runtime"),
    outer_brain_runtime: internal.("outer_brain", "core/outer_brain_runtime")
  }
}
