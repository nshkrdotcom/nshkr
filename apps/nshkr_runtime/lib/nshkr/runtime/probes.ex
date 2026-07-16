defmodule Nshkr.Runtime.Probes do
  @moduledoc "Reachability probes for concrete NSHKR production dependencies."

  @spec postgres(keyword(), module()) :: :ok | {:error, term()}
  def postgres(opts, repo) when is_list(opts) and is_atom(repo) do
    migrator_opts = Keyword.take(opts, [:pool_size, :timeout])

    case Ecto.Migrator.with_repo(
           repo,
           fn started_repo -> Ecto.Adapters.SQL.query(started_repo, "SELECT 1", []) end,
           migrator_opts
         ) do
      {:ok, {:ok, %{rows: [[1]]}}, _apps} -> :ok
      {:ok, {:error, reason}, _apps} -> {:error, {:postgres_query_failed, safe_reason(reason)}}
      {:error, reason} -> {:error, {:postgres_start_failed, safe_reason(reason)}}
      other -> {:error, {:invalid_postgres_probe, safe_reason(other)}}
    end
  rescue
    error -> {:error, {:postgres_probe_exception, error.__struct__}}
  end

  @spec owner_store(keyword(), module(), module(), atom(), list()) :: :ok | {:error, term()}
  def owner_store(repo_opts, repo, module, function, args)
      when is_list(repo_opts) and is_atom(repo) and is_atom(module) and is_atom(function) and
             is_list(args) do
    case Ecto.Migrator.with_repo(
           repo,
           fn _started_repo ->
             Nshkr.Runtime.DurableOwner.probe(
               owner_module: module,
               health_function: function,
               health_args: args
             )
           end,
           Keyword.take(repo_opts, [:pool_size, :timeout])
         ) do
      {:ok, :ok, _apps} -> :ok
      {:ok, {:error, reason}, _apps} -> {:error, reason}
      {:error, reason} -> {:error, {:owner_store_start_failed, safe_reason(reason)}}
      _other -> {:error, :invalid_owner_store_probe}
    end
  rescue
    error -> {:error, {:owner_store_probe_exception, error.__struct__}}
  end

  @spec outer_brain(keyword()) :: :ok | {:error, term()}
  def outer_brain(_service_opts) do
    OuterBrain.Persistence.Store.preflight(
      profile: :durable_redacted,
      repo_mode: :temporary,
      repo_options: []
    )
  end

  @spec jido_owner(keyword()) :: :ok | {:error, term()}
  def jido_owner(service_opts) when is_list(service_opts) do
    service_opts
    |> Keyword.delete(:name)
    |> Keyword.put(:repo_mode, :standalone)
    |> Jido.Integration.V2.StorePostgres.DurableRuntime.preflight()
  end

  defp safe_reason(%{__struct__: module}), do: module
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({left, _right}) when is_atom(left), do: left
  defp safe_reason(_reason), do: :redacted
end
