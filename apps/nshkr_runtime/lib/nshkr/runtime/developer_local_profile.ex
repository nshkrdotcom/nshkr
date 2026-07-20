defmodule Nshkr.Runtime.DeveloperLocalProfile do
  @moduledoc "Materializes the real single-host developer profile without embedding credentials."

  alias Nshkr.Runtime.CapabilityTruth
  alias Nshkr.Runtime.DurableOwner
  alias Nshkr.Runtime.ObjectStore.{MinioS3, VaultCredentialProvider}
  alias Nshkr.Runtime.SecretStore.{JidoVaultProvider, VaultAppRoleAuth, VaultKvV2}

  @capability_manifest_sha256 "e5f05518213070a0f2949b5866afd4550cc7f75f3142a86135739be5226b099c"
  @temporal_task_queue "nshkr.mezzanine.agent-run.v1"

  @spec document(map()) :: %{production_profile: map(), runtime_config: keyword()}
  def document(env) when is_map(env) do
    urls = %{
      mezzanine: required(env, "NSHKR_MEZZANINE_DATABASE_URL"),
      citadel: required(env, "NSHKR_CITADEL_DATABASE_URL"),
      outer_brain: required(env, "NSHKR_OUTER_BRAIN_DATABASE_URL"),
      jido_integration: required(env, "NSHKR_JIDO_DATABASE_URL")
    }

    vault_options = vault_options(env)
    temporal_options = temporal_options(env)
    app_kit_backend_options = app_kit_backend_options(env)

    %{
      production_profile: %{
        topology: topology(),
        services: services(env, vault_options, temporal_options, app_kit_backend_options),
        migration_plan: migration_plan()
      },
      runtime_config: runtime_config(urls, temporal_options, app_kit_backend_options)
    }
  end

  defp topology do
    owners = Nshkr.Runtime.Contracts.ProductionProfile.database_owners()

    %{
      contract_version: 1,
      profile_ref: "profile://nshkr/developer-local/v1",
      mode: "developer_local",
      postgres: %{
        "provider" => "postgresql",
        "cluster_ref" => "postgres://nshkr/developer-local",
        "databases" => %{
          "mezzanine" => "nshkr_mezzanine",
          "citadel" => "nshkr_citadel",
          "outer_brain" => "nshkr_outer_brain",
          "jido_integration" => "nshkr_jido_integration",
          "execution_plane" => "not-composed-p01",
          "chassis" => "not-composed-p01"
        }
      },
      temporal: %{
        "provider" => "temporal",
        "namespace" => "default",
        "task_queues" => %{
          "mezzanine_agent_run" => @temporal_task_queue,
          "outer_brain_semantic" => "nshkr.outer-brain.semantic.v1",
          "chassis_reconcile" => "nshkr.chassis.reconcile.v1",
          "extravaganza_issue_pr" => "nshkr.extravaganza.issue-pr.v1"
        }
      },
      object_store: %{
        "provider" => "minio_s3",
        "endpoint_ref" => "endpoint://minio/developer-local",
        "bucket_ref" => "bucket://nshkr/artifacts",
        "tenant_prefix" => "tenants/{tenant_ref}/",
        "encryption" => "server_side"
      },
      secret_store: %{
        "provider" => "hashicorp_vault_kv_v2",
        "endpoint_ref" => "endpoint://vault/developer-local",
        "mount_ref" => "vault-mount://nshkr/kv-v2",
        "auth_role_ref" => "vault-role://nshkr/runtime",
        "lease_required" => true
      },
      semantic_index: %{
        "provider" => "postgresql_pgvector",
        "rebuildable" => true,
        "source_of_truth" => false
      },
      migration_owners:
        Map.new(owners, fn owner ->
          {owner,
           %{
             "repository" => "/srv/nshkr/#{owner}",
             "migration_path" => "priv/repo/migrations"
           }}
        end)
    }
  end

  defp services(env, vault_options, temporal_options, app_kit_backend_options) do
    mezzanine_health = [repo: Mezzanine.OpsDomain.Repo]

    jido_options = [
      name: Jido.Integration.V2.StorePostgres.DurableRuntime,
      repo_mode: :external,
      repo_options: [],
      persistence_profile: :integration_postgres,
      credential_materializers: %{
        "codex" => Jido.Integration.Secrets.ManagedCredentialMaterializer,
        "gemini" => Jido.Integration.Secrets.ManagedCredentialMaterializer
      }
    ]

    [
      service(
        "mezzanine-postgres",
        :postgres_repo,
        Mezzanine.OpsDomain.Repo,
        [],
        {Nshkr.Runtime.Probes, :postgres, [Mezzanine.OpsDomain.Repo]}
      ),
      service(
        "citadel-postgres",
        :postgres_repo,
        Citadel.Governance.Repo,
        [],
        {Nshkr.Runtime.Probes, :postgres, [Citadel.Governance.Repo]}
      ),
      service(
        "outer-brain-postgres",
        :postgres_repo,
        OuterBrain.Persistence.Repo,
        [],
        {Nshkr.Runtime.Probes, :postgres, [OuterBrain.Persistence.Repo]}
      ),
      service(
        "jido-postgres",
        :postgres_repo,
        Jido.Integration.V2.StorePostgres.Repo,
        [],
        {Nshkr.Runtime.Probes, :postgres, [Jido.Integration.V2.StorePostgres.Repo]}
      ),
      service("vault-kv-v2", :secret_store, VaultKvV2, vault_options, {VaultKvV2, :probe, []}),
      service(
        "minio-s3",
        :object_store,
        MinioS3,
        minio_options(env, vault_options),
        {MinioS3, :probe, []}
      ),
      durable_owner(
        "mezzanine-run-store",
        Mezzanine.WorkflowRuntime.Store,
        :health,
        [mezzanine_health],
        Mezzanine.OpsDomain.Repo
      ),
      durable_owner(
        "citadel-authority-store",
        Citadel.Governance.Persistence,
        :preflight,
        [],
        Citadel.Governance.Repo
      ),
      service(
        "outer-brain-owner-store",
        :owner_store,
        OuterBrain.Persistence.DurableSupervisor,
        [profile: :durable_redacted, repo_mode: :external, repo_options: []],
        {Nshkr.Runtime.Probes, :outer_brain, []}
      ),
      service(
        "jido-owner-store",
        :owner_store,
        Jido.Integration.V2.StorePostgres.DurableRuntime,
        jido_options,
        {Nshkr.Runtime.Probes, :jido_owner, []}
      ),
      service(
        "temporal-workers",
        :temporal,
        Nshkr.Runtime.Temporal,
        [name: Nshkr.Runtime.Temporal, temporal: temporal_options],
        {Nshkr.Runtime.Temporal, :probe, []}
      ),
      service(
        "mezzanine-run-outbox",
        :outbox_dispatcher,
        Mezzanine.WorkflowRuntime.RunOutboxDispatcher,
        [
          name: Mezzanine.WorkflowRuntime.RunOutboxDispatcher,
          store: Mezzanine.WorkflowRuntime.Store,
          store_opts: mezzanine_health,
          runtime: Mezzanine.WorkflowRuntime.TemporalexAdapter
        ],
        {Nshkr.Runtime.Probes, :owner_store,
         [
           Mezzanine.OpsDomain.Repo,
           Mezzanine.WorkflowRuntime.Store,
           :health,
           [mezzanine_health]
         ]}
      ),
      service(
        "capability-truth",
        :capability_truth,
        CapabilityTruth,
        [
          name: CapabilityTruth,
          source: CapabilityTruth.ReleaseManifestSource,
          source_options: [
            path: "priv/release_capabilities.json",
            sha256: @capability_manifest_sha256
          ],
          allowed_active: []
        ],
        {CapabilityTruth, :probe, []}
      ),
      service(
        "app-kit-backend-stack",
        :app_kit_backend_stack,
        Nshkr.Runtime.AppKitBackendStack,
        [name: Nshkr.Runtime.AppKitBackendStack] ++ app_kit_backend_options,
        {Nshkr.Runtime.AppKitBackendStack, :probe, []}
      )
    ]
  end

  defp durable_owner(id, module, function, args, repo) do
    options = [
      name: Module.concat(DurableOwner, Macro.camelize(String.replace(id, "-", "_"))),
      owner_module: module,
      health_function: function,
      health_args: args
    ]

    service(
      id,
      :owner_store,
      DurableOwner,
      options,
      {Nshkr.Runtime.Probes, :owner_store, [repo, module, function, args]}
    )
  end

  defp service(id, role, module, options, probe) do
    %{id: id, role: role, module: module, options: options, probe: probe}
  end

  defp migration_plan do
    [
      migration("mezzanine", Mezzanine.OpsDomain.Repo, :mezzanine_ops_domain),
      migration("citadel", Citadel.Governance.Repo, :citadel_governance),
      migration("outer_brain", OuterBrain.Persistence.Repo, :outer_brain_persistence),
      migration(
        "jido_integration",
        Jido.Integration.V2.StorePostgres.Repo,
        :jido_integration_v2_store_postgres
      )
    ]
  end

  defp migration(owner, repo, otp_app) do
    %{
      owner: owner,
      repo: repo,
      otp_app: otp_app,
      migration_path: Application.app_dir(otp_app, "priv/repo/migrations")
    }
  end

  defp runtime_config(urls, temporal_options, app_kit_backend_options) do
    [
      mezzanine_core: [run_store: Mezzanine.WorkflowRuntime.Store.Postgres],
      mezzanine_ops_domain:
        repo_runtime(Mezzanine.OpsDomain.Repo, urls.mezzanine) ++
          [ecto_repos: [Mezzanine.OpsDomain.Repo], start_runtime_children?: false],
      mezzanine_workflow_runtime: [temporal: temporal_options],
      citadel_governance:
        repo_runtime(Citadel.Governance.Repo, urls.citadel) ++
          [ecto_repos: [Citadel.Governance.Repo]],
      outer_brain_persistence:
        repo_runtime(OuterBrain.Persistence.Repo, urls.outer_brain) ++
          [ecto_repos: [OuterBrain.Persistence.Repo]],
      jido_integration_v2_store_postgres:
        repo_runtime(Jido.Integration.V2.StorePostgres.Repo, urls.jido_integration) ++
          [ecto_repos: [Jido.Integration.V2.StorePostgres.Repo]],
      jido_integration_secrets_provider: [
        managed_providers: %{
          "vault" => [provider: JidoVaultProvider, vault_server: VaultKvV2]
        }
      ],
      synapse_core: [
        app_kit_backend_stack: Nshkr.Runtime.AppKitBackendStack,
        app_kit_backend_options: app_kit_backend_options
      ]
    ]
  end

  defp app_kit_backend_options(env) do
    [
      program_id: required(env, "NSHKR_SYNAPSE_PROGRAM_ID"),
      work_class_id: required(env, "NSHKR_SYNAPSE_WORK_CLASS_ID")
    ]
  end

  defp repo_runtime(repo, url) do
    [
      {repo,
       [
         url: url,
         pool_size: 4,
         show_sensitive_data_on_connection_error: false,
         log: false
       ]}
    ]
  end

  defp temporal_options(env) do
    [
      governed?: true,
      enabled?: true,
      substrate_available?: true,
      address: optional(env, "NSHKR_TEMPORAL_ADDRESS", "127.0.0.1:7233"),
      namespace: "default",
      task_queues: [@temporal_task_queue],
      instance_base: Mezzanine.WorkflowRuntime.Temporal
    ]
  end

  defp vault_options(env) do
    runtime_root = required(env, "NSHKR_RUNTIME_SECRET_DIR")

    [
      name: VaultKvV2,
      endpoint: optional(env, "NSHKR_VAULT_ENDPOINT", "http://127.0.0.1:18200"),
      mount: "kv",
      auth_module: VaultAppRoleAuth,
      auth_options: [
        mount: "approle",
        role_id_path: Path.join(runtime_root, "vault-role-id"),
        secret_id_path: Path.join(runtime_root, "vault-secret-id")
      ]
    ]
  end

  defp minio_options(env, vault_options) do
    credential_path = "object-store/minio"

    [
      name: MinioS3,
      endpoint: optional(env, "NSHKR_MINIO_ENDPOINT", "http://127.0.0.1:19000"),
      bucket: "artifacts",
      region: "us-east-1",
      credential_provider: VaultCredentialProvider,
      credential_options: [path: credential_path, vault_server: VaultKvV2],
      preflight_credential_options: [path: credential_path, vault_options: vault_options]
    ]
  end

  defp required(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> raise ArgumentError, "missing developer profile value: #{key}"
    end
  end

  defp optional(env, key, default) do
    case Map.get(env, key, default) do
      value when is_binary(value) and value != "" -> value
      _invalid -> raise ArgumentError, "invalid developer profile value: #{key}"
    end
  end
end
