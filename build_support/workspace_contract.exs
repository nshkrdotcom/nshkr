defmodule Nshkr.Build.WorkspaceContract do
  @moduledoc false

  @package_paths ["apps/nshkr_runtime"]
  @active_project_globs [".", "apps/*"]

  def package_paths, do: @package_paths
  def active_project_globs, do: @active_project_globs
end
