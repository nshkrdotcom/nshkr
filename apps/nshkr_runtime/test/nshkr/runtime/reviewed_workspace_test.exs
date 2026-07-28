defmodule Nshkr.Runtime.ReviewedWorkspaceTest do
  use ExUnit.Case, async: true

  alias Nshkr.Runtime.ReviewedWorkspace

  @content "reviewed bytes"
  @digest "sha256:" <> (:crypto.hash(:sha256, @content) |> Base.encode16(case: :lower))

  test "accepts only the exact reviewed regular file" do
    workspace = temporary_workspace!()
    File.write!(Path.join(workspace, "reviewed.txt"), @content)

    assert {:ok, @content} =
             ReviewedWorkspace.verify(workspace, "reviewed.txt", @content, @digest)
  end

  test "accepts only the exact parent directories for a nested reviewed file" do
    workspace = temporary_workspace!()
    File.mkdir_p!(Path.join(workspace, "reviewed/nested"))
    File.write!(Path.join(workspace, "reviewed/nested/result.txt"), @content)

    assert {:ok, @content} =
             ReviewedWorkspace.verify(
               workspace,
               "reviewed/nested/result.txt",
               @content,
               @digest
             )
  end

  test "rejects any additional workspace effect" do
    workspace = temporary_workspace!()
    File.write!(Path.join(workspace, "reviewed.txt"), @content)
    File.write!(Path.join(workspace, "extra.txt"), "not reviewed")

    assert {:error, :reviewed_workspace_contents_mismatch} =
             ReviewedWorkspace.verify(workspace, "reviewed.txt", @content, @digest)
  end

  test "rejects a symlink at the reviewed target" do
    workspace = temporary_workspace!()
    outside = temporary_workspace!()
    outside_file = Path.join(outside, "outside.txt")
    File.write!(outside_file, @content)
    File.ln_s!(outside_file, Path.join(workspace, "reviewed.txt"))

    assert {:error, :reviewed_workspace_contents_mismatch} =
             ReviewedWorkspace.verify(workspace, "reviewed.txt", @content, @digest)
  end

  test "rejects digest or byte drift" do
    workspace = temporary_workspace!()
    File.write!(Path.join(workspace, "reviewed.txt"), @content <> "\n")

    assert {:error, :reviewed_file_verification_failed} =
             ReviewedWorkspace.verify(workspace, "reviewed.txt", @content, @digest)
  end

  defp temporary_workspace! do
    path =
      Path.join(
        System.tmp_dir!(),
        "nshkr-reviewed-workspace-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
