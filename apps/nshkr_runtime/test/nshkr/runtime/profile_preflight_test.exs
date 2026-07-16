defmodule Nshkr.Runtime.ProfilePreflightTest do
  use ExUnit.Case, async: false

  alias Nshkr.Runtime.{
    CapabilityTruth,
    ConfigProvider,
    DeveloperLocalProfile,
    DurableOwner,
    Preflight,
    Profile,
    Service
  }

  alias Nshkr.Runtime.CapabilityTruth.ReleaseManifestSource

  defmodule TestService do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def probe(_opts), do: :ok
    def health, do: {:ok, %{durable: true}}
    def init(opts), do: {:ok, opts}
  end

  defmodule TestMigrationVerifier do
    def verify(_migration), do: :ok
  end

  defmodule LeakyProbe do
    def start_link(_opts), do: :ignore
    def probe(_opts), do: raise("password=sentinel-secret")
  end

  defmodule CapabilitySource do
    @behaviour Nshkr.Runtime.CapabilityTruth.Source

    @impl true
    def list(opts), do: {:ok, Keyword.fetch!(opts, :descriptors)}
  end

  setup do
    previous = Application.get_env(:nshkr_runtime, :migration_verifier)
    Application.put_env(:nshkr_runtime, :migration_verifier, TestMigrationVerifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nshkr_runtime, :migration_verifier, previous),
        else: Application.delete_env(:nshkr_runtime, :migration_verifier)
    end)
  end

  test "orders durable children and passes a complete fail-closed preflight" do
    profile = profile_attrs() |> Profile.new!()

    assert :ok = Preflight.verify!(profile)

    ordered_ids =
      profile
      |> Profile.child_specs()
      |> Enum.map(& &1.id)

    assert ordered_ids == ~w(postgres secret object owner temporal outbox capability)
  end

  test "rejects a forbidden production selector before any child starts" do
    attrs =
      update_in(profile_attrs(), [:services], fn services ->
        Enum.map(services, fn
          %{id: "owner"} = service -> %{service | options: [backend: :memory]}
          service -> service
        end)
      end)

    assert_raise RuntimeError, ~r/forbidden_production_selection/, fn ->
      attrs |> Profile.new!() |> Preflight.verify!()
    end
  end

  test "forbidden-selector failures do not echo the rejected value" do
    attrs =
      update_in(profile_attrs(), [:services], fn services ->
        Enum.map(services, fn
          %{id: "owner"} = service ->
            %{service | options: [endpoint: "https://service.test/?token=sentinel-secret"]}

          service ->
            service
        end)
      end)

    exception =
      assert_raise RuntimeError, ~r/forbidden_production_selection/, fn ->
        attrs |> Profile.new!() |> Preflight.verify!()
      end

    refute Exception.message(exception) =~ "sentinel-secret"
  end

  test "rejects raw secret-bearing service options without echoing material" do
    attrs =
      update_in(profile_attrs(), [:services], fn services ->
        Enum.map(services, fn
          %{id: "owner"} = service -> %{service | options: [token: "sentinel-secret"]}
          service -> service
        end)
      end)

    exception =
      assert_raise RuntimeError, ~r/forbidden_production_selection/, fn ->
        attrs |> Profile.new!() |> Preflight.verify!()
      end

    refute Exception.message(exception) =~ "sentinel-secret"
  end

  test "capability truth refuses activation outside the phase allowlist" do
    descriptor = capability_descriptor("ready", "healthy", nil)

    assert {:error, {:unadmitted_capabilities, ["model.gemini"]}} =
             CapabilityTruth.probe(
               source: CapabilitySource,
               source_options: [descriptors: [descriptor]],
               allowed_active: []
             )

    assert :ok =
             CapabilityTruth.probe(
               source: CapabilitySource,
               source_options: [descriptors: [descriptor]],
               allowed_active: ["model.gemini"]
             )
  end

  test "capability truth accepts a durable absent descriptor without advertising it" do
    descriptor = capability_descriptor("absent", "unknown", "not_composed")

    assert {:ok, server} =
             CapabilityTruth.start_link(
               name: nil,
               source: CapabilitySource,
               source_options: [descriptors: [descriptor]],
               refresh_interval_ms: 0,
               allowed_active: []
             )

    assert [%{capability_id: "model.gemini", readiness: "absent"}] =
             CapabilityTruth.list(server)
  end

  test "release capability truth is pinned to the shipped artifact digest" do
    path = temporary_path("capabilities.json")
    bytes = Jason.encode!(%{schema: "nshkr.release-capabilities.v1", capabilities: []})
    File.write!(path, bytes)

    digest = bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    assert {:ok, []} = ReleaseManifestSource.list(path: path, sha256: digest)

    assert {:error, :capability_manifest_digest_mismatch} =
             ReleaseManifestSource.list(path: path, sha256: String.duplicate("0", 64))
  end

  test "release config provider accepts only the production profile document shape" do
    path = temporary_path("profile.exs")

    File.write!(
      path,
      inspect(%{
        production_profile: %{profile_ref: "profile://nshkr/test/v1"},
        runtime_config: [citadel_governance: [repo: TestService]]
      })
    )

    state = ConfigProvider.init(path: path)
    loaded = ConfigProvider.load([logger: [level: :warning]], state)

    assert get_in(loaded, [:nshkr_runtime, :production_profile, :profile_ref]) ==
             "profile://nshkr/test/v1"

    assert get_in(loaded, [:citadel_governance, :repo]) == TestService

    File.write!(path, inspect(%{production_profile: %{}, runtime_config: [], extra: true}))

    assert_raise RuntimeError, ~r/production_profile\/runtime_config document/, fn ->
      ConfigProvider.load([], state)
    end
  end

  test "developer profile receives deployment environment only at the config boundary" do
    env = %{
      "NSHKR_MEZZANINE_DATABASE_URL" => "ecto://localhost/mezzanine",
      "NSHKR_CITADEL_DATABASE_URL" => "ecto://localhost/citadel",
      "NSHKR_OUTER_BRAIN_DATABASE_URL" => "ecto://localhost/outer_brain",
      "NSHKR_JIDO_DATABASE_URL" => "ecto://localhost/jido",
      "NSHKR_RUNTIME_SECRET_DIR" => "/run/nshkr/secrets",
      "NSHKR_TEMPORAL_ADDRESS" => "temporal.internal:7233",
      "NSHKR_VAULT_ENDPOINT" => "https://vault.internal",
      "NSHKR_MINIO_ENDPOINT" => "https://minio.internal"
    }

    document = DeveloperLocalProfile.document(env)

    assert get_in(document.runtime_config, [
             :jido_integration_v2_store_postgres,
             Jido.Integration.V2.StorePostgres.Repo,
             :url
           ]) == "ecto://localhost/jido"

    assert %{options: temporal_options} =
             Enum.find(document.production_profile.services, &(&1.id == "temporal-workers"))

    assert temporal_options[:temporal][:address] == "temporal.internal:7233"

    assert_raise ArgumentError, ~r/NSHKR_JIDO_DATABASE_URL/, fn ->
      env |> Map.delete("NSHKR_JIDO_DATABASE_URL") |> DeveloperLocalProfile.document()
    end
  end

  test "durable owner monitor fails closed on an invalid health contract" do
    assert :ok =
             DurableOwner.probe(
               owner_module: TestService,
               health_function: :health,
               health_args: []
             )

    assert {:error, :invalid_owner_health_configuration} =
             DurableOwner.probe(
               owner_module: TestService,
               health_function: :missing,
               health_args: []
             )
  end

  test "probe failures never surface exception messages" do
    service =
      Service.new!(%{
        id: "redacted-probe",
        role: :owner_store,
        module: LeakyProbe,
        options: [],
        probe: {LeakyProbe, :probe, []}
      })

    assert {:error, {:probe_exception, RuntimeError}} = Service.probe(service)
    refute inspect(Service.probe(service)) =~ "sentinel-secret"
  end

  defp profile_attrs do
    %{
      topology: topology_attrs(),
      services: [
        service("capability", :capability_truth),
        service("outbox", :outbox_dispatcher),
        service("temporal", :temporal),
        service("owner", :owner_store),
        service("object", :object_store),
        service("secret", :secret_store),
        service("postgres", :postgres_repo)
      ],
      migration_plan:
        Enum.map(~w(mezzanine citadel outer_brain jido_integration), fn owner ->
          %{
            owner: owner,
            repo: TestService,
            otp_app: :nshkr_runtime,
            migration_path: "priv/repo/migrations/#{owner}"
          }
        end)
    }
  end

  defp service(id, role) do
    %{id: id, role: role, module: TestService, options: [], probe: {TestService, :probe, []}}
  end

  defp topology_attrs do
    owners = Nshkr.Runtime.Contracts.ProductionProfile.database_owners()

    %{
      contract_version: 1,
      profile_ref: "profile://nshkr/developer-local/v1",
      mode: "developer_local",
      postgres: %{
        "provider" => "postgresql",
        "cluster_ref" => "postgres://nshkr/local",
        "databases" => Map.new(owners, &{&1, "nshkr_#{&1}"})
      },
      temporal: %{
        "provider" => "temporal",
        "namespace" => "nshkr-local",
        "task_queues" => %{
          "mezzanine_agent_run" => "nshkr.mezzanine.agent-run.v1",
          "outer_brain_semantic" => "nshkr.outer-brain.semantic.v1",
          "chassis_reconcile" => "nshkr.chassis.reconcile.v1",
          "extravaganza_issue_pr" => "nshkr.extravaganza.issue-pr.v1"
        }
      },
      object_store: %{
        "provider" => "minio_s3",
        "endpoint_ref" => "endpoint://minio/local",
        "bucket_ref" => "bucket://nshkr/artifacts",
        "tenant_prefix" => "tenants/{tenant_ref}/",
        "encryption" => "server_side"
      },
      secret_store: %{
        "provider" => "hashicorp_vault_kv_v2",
        "endpoint_ref" => "endpoint://vault/local",
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

  defp capability_descriptor(readiness, health, absence_reason) do
    %{
      contract_version: 1,
      capability_ref: "capability://nshkr/model.gemini",
      capability_id: "model.gemini",
      producer_revision: "producer",
      adapter_revision: "adapter",
      runtime_revision: "runtime",
      contract_revisions: %{},
      mode: "managed_account_local_effect",
      required_components: ["jido_integration", "gemini_ex"],
      optional_features: [],
      readiness: readiness,
      health: health,
      absence_reason: absence_reason,
      release_ref: "release://nshkr/0.1.0",
      evidence_refs: []
    }
  end

  defp temporary_path(filename) do
    path =
      Path.join(
        System.tmp_dir!(),
        "nshkr-#{System.unique_integer([:positive, :monotonic])}-#{filename}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end
end
