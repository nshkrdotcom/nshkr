defmodule Nshkr.Runtime.GovernedCodexEffectTest do
  use ExUnit.Case, async: true

  alias Nshkr.Runtime.GovernedCodexEffect

  @uuid "11111111-1111-4111-8111-111111111111"

  test "publishes only the governed Codex session capability" do
    assert GovernedCodexEffect.capability_id() == "codex.session.turn"
  end

  test "uses only the single-use database-time grant checkpoint at dispatch" do
    source =
      __DIR__
      |> Path.join("../../../lib/nshkr/runtime/governed_codex_effect.ex")
      |> Path.expand()
      |> File.read!()

    assert source =~ "ToolEffectAuthority.decide_grant"
    assert source =~ "grant_control_receipt_ref"
    refute source =~ "ToolEffectAuthority.verify_grant"
  end

  test "rejects caller-supplied credentials before durable admission" do
    assert {:error, {:unknown_governed_codex_field, :api_key}} =
             attrs()
             |> Map.put(:api_key, "caller-secret")
             |> GovernedCodexEffect.execute()
  end

  test "rejects undeclared fields before durable admission" do
    assert {:error, {:unknown_governed_codex_field, :provider_options}} =
             attrs()
             |> Map.put(:provider_options, %{unsafe: true})
             |> GovernedCodexEffect.execute()

    assert {:error, {:unknown_governed_codex_field, :account_ref}} =
             attrs()
             |> Map.put(:account_ref, "provider-account://caller-selected")
             |> GovernedCodexEffect.execute()
  end

  test "requires exact durable owner identities" do
    assert {:error, :invalid_governed_codex_owner_identity} =
             attrs()
             |> Map.put(:review_unit_id, "review-unit://unbound")
             |> GovernedCodexEffect.execute()
  end

  test "rejects broad and traversal-capable workspaces before dispatch" do
    assert {:error, :invalid_governed_codex_workspace} =
             attrs()
             |> Map.put(:workspace_root, "/home/home")
             |> GovernedCodexEffect.execute()

    workspace = temporary_workspace!()

    assert {:error, :invalid_governed_codex_relative_path} =
             attrs(workspace)
             |> Map.put(:relative_path, "../escape.txt")
             |> GovernedCodexEffect.execute()
  end

  test "rejects a reviewed path that traverses a workspace symlink" do
    workspace = temporary_workspace!()
    outside = temporary_workspace!()
    File.ln_s!(outside, Path.join(workspace, "linked"))

    assert {:error, :unsafe_governed_codex_workspace_target} =
             attrs(workspace)
             |> Map.put(:relative_path, "linked/reviewed.txt")
             |> GovernedCodexEffect.execute()
  end

  test "requires all reviewed operation fields" do
    assert {:error, {:missing_governed_codex_fields, missing}} =
             attrs()
             |> Map.delete(:reviewed_content)
             |> GovernedCodexEffect.execute()

    assert :reviewed_content in missing
  end

  defp attrs(workspace_root \\ nil) do
    %{
      tenant_ref: "tenant://nshkr/test",
      run_ref: "run://mezzanine/test",
      turn_ref: "turn://synapse/test",
      subject_id: @uuid,
      run_id: @uuid,
      review_unit_id: @uuid,
      workspace_ref: "workspace://nshkr/test",
      workspace_root: workspace_root || temporary_workspace!(),
      relative_path: "reviewed.txt",
      reviewed_content: "reviewed bytes"
    }
  end

  defp temporary_workspace! do
    path =
      Path.join(
        System.tmp_dir!(),
        "nshkr-governed-codex-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
