defmodule Nshkr.Runtime.ContractsTest do
  use ExUnit.Case, async: true

  alias Nshkr.Runtime.Contracts.{CapabilityDescriptor, ProductionProfile}

  defp migration_owners do
    Map.new(ProductionProfile.database_owners(), fn owner ->
      {owner,
       %{
         "repository" => "/home/home/p/g/n/#{owner}",
         "migration_path" => "priv/repo/migrations"
       }}
    end)
  end

  defp profile_attrs do
    %{
      contract_version: 1,
      profile_ref: "profile://nshkr/production-monolith/v1",
      mode: "production_monolith",
      postgres: %{
        "provider" => "postgresql",
        "cluster_ref" => "postgres://nshkr/primary",
        "databases" => Map.new(ProductionProfile.database_owners(), &{&1, "nshkr_#{&1}"})
      },
      temporal: %{
        "provider" => "temporal",
        "namespace" => "nshkr-production",
        "task_queues" => %{
          "mezzanine_agent_run" => "nshkr.mezzanine.agent-run.v1",
          "outer_brain_semantic" => "nshkr.outer-brain.semantic.v1",
          "chassis_reconcile" => "nshkr.chassis.reconcile.v1",
          "extravaganza_issue_pr" => "nshkr.extravaganza.issue-pr.v1"
        }
      },
      object_store: %{
        "provider" => "minio_s3",
        "endpoint_ref" => "endpoint://nshkr/minio",
        "bucket_ref" => "bucket://nshkr/artifacts",
        "tenant_prefix" => "tenants/{tenant_ref}/",
        "encryption" => "server_side"
      },
      secret_store: %{
        "provider" => "hashicorp_vault_kv_v2",
        "endpoint_ref" => "endpoint://nshkr/vault",
        "mount_ref" => "vault-mount://nshkr/kv-v2",
        "auth_role_ref" => "vault-role://nshkr/runtime",
        "lease_required" => true
      },
      semantic_index: %{
        "provider" => "postgresql_pgvector",
        "rebuildable" => true,
        "source_of_truth" => false
      },
      migration_owners: migration_owners()
    }
  end

  test "freezes the production substrate and migration-owner topology" do
    assert {:ok, profile} = ProductionProfile.new(profile_attrs())
    assert profile.temporal["namespace"] == "nshkr-production"
    assert map_size(profile.postgres["databases"]) == 6
  end

  test "rejects forbidden providers and secret-bearing profile data" do
    assert {:error, :invalid_production_profile} =
             profile_attrs()
             |> put_in([:object_store, "provider"], "memory")
             |> ProductionProfile.new()

    assert {:error, :invalid_production_profile} =
             profile_attrs()
             |> put_in([:secret_store, "token"], "sentinel-secret")
             |> ProductionProfile.new()

    assert {:error, :invalid_production_profile} =
             profile_attrs() |> Map.put(:token, "sentinel-secret") |> ProductionProfile.new()
  end

  test "capability is executable only when the exact mode is ready and healthy" do
    attrs = %{
      contract_version: 1,
      capability_ref: "capability://nshkr/gemini-local",
      capability_id: "model.gemini.managed-account.local-effect",
      producer_revision: String.duplicate("a", 40),
      adapter_revision: String.duplicate("b", 40),
      runtime_revision: String.duplicate("c", 40),
      contract_revisions: %{"citadel.scoped-grant.v1" => String.duplicate("d", 64)},
      mode: "managed_account_local_effect",
      required_components: ["jido_integration", "inference", "gemini_ex"],
      optional_features: [],
      readiness: "ready",
      health: "healthy",
      release_ref: "release://nshkr/0.1.0",
      evidence_refs: ["evidence://nshkr/gemini-local"]
    }

    assert {:ok, descriptor} = CapabilityDescriptor.new(attrs)
    assert CapabilityDescriptor.executable?(descriptor)

    absent =
      attrs
      |> Map.merge(%{readiness: "absent", health: "unknown", absence_reason: "not_composed"})

    assert {:ok, absent_descriptor} = CapabilityDescriptor.new(absent)
    refute CapabilityDescriptor.executable?(absent_descriptor)
  end

  test "local and runtime-admitted modes cannot be relabeled" do
    attrs = %{
      contract_version: 1,
      capability_ref: "capability://nshkr/gemini-local",
      capability_id: "model.gemini.managed-account.local-effect",
      producer_revision: "p",
      adapter_revision: "a",
      runtime_revision: "r",
      contract_revisions: %{},
      mode: "generic_execution",
      required_components: ["gemini_ex"],
      optional_features: [],
      readiness: "absent",
      health: "unknown",
      absence_reason: "not_composed",
      release_ref: "release://nshkr/0.1.0",
      evidence_refs: []
    }

    assert {:error, :invalid_capability_descriptor} = CapabilityDescriptor.new(attrs)
  end
end
