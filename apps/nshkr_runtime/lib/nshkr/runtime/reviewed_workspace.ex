defmodule Nshkr.Runtime.ReviewedWorkspace do
  @moduledoc false

  @spec verify(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error,
             :reviewed_file_verification_failed
             | :reviewed_workspace_contents_mismatch
             | {:reviewed_workspace_unavailable, term()}}
  def verify(workspace_root, relative_path, reviewed_content, reviewed_content_digest)
      when is_binary(workspace_root) and is_binary(relative_path) and
             is_binary(reviewed_content) and is_binary(reviewed_content_digest) do
    target = Path.join(workspace_root, relative_path)

    with true <- inside_workspace?(target, workspace_root),
         {:ok, entries} <- workspace_entries(workspace_root),
         :ok <- verify_entries(entries, relative_path),
         {:ok, body} <- File.read(target),
         true <- digest(body) == reviewed_content_digest,
         true <- body == reviewed_content do
      {:ok, body}
    else
      false -> {:error, :reviewed_file_verification_failed}
      {:error, :reviewed_workspace_contents_mismatch} = error -> error
      {:error, reason} -> {:error, {:reviewed_workspace_unavailable, reason}}
    end
  end

  def verify(_workspace_root, _relative_path, _reviewed_content, _reviewed_content_digest),
    do: {:error, :reviewed_file_verification_failed}

  defp workspace_entries(workspace_root), do: walk(workspace_root, "")

  defp walk(root, relative_root) do
    with {:ok, names} <- File.ls(Path.join(root, relative_root)) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, entries} ->
        relative_path =
          case relative_root do
            "" -> name
            parent -> Path.join(parent, name)
          end

        case File.lstat(Path.join(root, relative_path)) do
          {:ok, %{type: :directory}} ->
            case walk(root, relative_path) do
              {:ok, nested} ->
                {:cont, {:ok, entries ++ [{relative_path, :directory} | nested]}}

              {:error, _reason} = error ->
                {:halt, error}
            end

          {:ok, %{type: type}} ->
            {:cont, {:ok, entries ++ [{relative_path, type}]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp expected_entries(relative_path) do
    segments = String.split(relative_path, "/", trim: true)

    directories =
      segments
      |> Enum.drop(-1)
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.map(&{&1, :directory})

    directories ++ [{relative_path, :regular}]
  end

  defp verify_entries(entries, relative_path) do
    if entries == expected_entries(relative_path),
      do: :ok,
      else: {:error, :reviewed_workspace_contents_mismatch}
  end

  defp inside_workspace?(path, workspace_root) do
    expanded_root = Path.expand(workspace_root)
    expanded_path = Path.expand(path)
    expanded_path != expanded_root and String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end
end
