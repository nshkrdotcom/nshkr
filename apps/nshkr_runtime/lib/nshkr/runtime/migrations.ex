defmodule Nshkr.Runtime.Migrations do
  @moduledoc "Owner-ordered migration-head verification without running migrations."

  @spec verify(map()) :: :ok | {:error, term()}
  def verify(%{repo: repo, migration_path: path}) do
    with true <- Code.ensure_loaded?(Ecto.Migrator),
         true <- Code.ensure_loaded?(repo),
         true <- File.dir?(path),
         {:ok, statuses} <- migration_statuses(repo, path),
         [] <- Enum.filter(statuses, &match?({:down, _, _}, &1)) do
      :ok
    else
      false -> {:error, :migration_dependency_or_path_missing}
      [_ | _] = pending -> {:error, {:pending_migrations, Enum.map(pending, &elem(&1, 1))}}
      {:error, _reason} = error -> error
      other -> {:error, {:migration_verification_failed, safe_reason(other)}}
    end
  end

  defp migration_statuses(repo, path) do
    Ecto.Migrator.with_repo(repo, fn started_repo ->
      Ecto.Migrator.migrations(started_repo, path)
    end)
    |> case do
      {:ok, statuses, _apps} -> {:ok, statuses}
      {:error, reason} -> {:error, {:repository_unavailable, safe_reason(reason)}}
    end
  rescue
    error -> {:error, {:migration_exception, error.__struct__}}
  end

  defp safe_reason(%{__struct__: module}), do: module
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({left, _right}) when is_atom(left), do: left
  defp safe_reason(_reason), do: :redacted
end
