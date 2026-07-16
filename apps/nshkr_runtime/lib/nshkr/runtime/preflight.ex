defmodule Nshkr.Runtime.Preflight do
  @moduledoc "Fail-closed release validation performed before any product endpoint starts."

  alias Nshkr.Runtime.Profile
  alias Nshkr.Runtime.Service

  @forbidden_fragments ~w(fake fixture memory mickey_mouse noop no_op static_success incomplete req.test)
  @secret_keys ~w(api_key authorization bearer client_secret credential credentials password secret session_token token)

  @spec verify!(Profile.t()) :: :ok
  def verify!(%Profile{} = profile) do
    with :ok <- reject_forbidden(profile),
         :ok <- verify_modules(profile.services),
         :ok <- verify_migrations(profile.migration_plan),
         :ok <- probe_services(profile.services) do
      :ok
    else
      {:error, reason} -> raise "NSHKR preflight failed: #{inspect(reason)}"
    end
  end

  @spec reject_forbidden(term()) :: :ok | {:error, term()}
  def reject_forbidden(term) do
    case forbidden_path(term, []) do
      nil -> :ok
      path -> {:error, {:forbidden_production_selection, Enum.reverse(path)}}
    end
  end

  defp verify_modules(services) do
    Enum.reduce_while(services, :ok, fn service, :ok ->
      child_available? =
        Code.ensure_loaded?(service.module) and
          (function_exported?(service.module, :child_spec, 1) or
             function_exported?(service.module, :start_link, 1))

      probe_available? =
        case service.probe do
          {module, function, args} ->
            Code.ensure_loaded?(module) and function_exported?(module, function, length(args) + 1)
        end

      if child_available? and probe_available? do
        {:cont, :ok}
      else
        {:halt, {:error, {:unavailable_service_module, service.id}}}
      end
    end)
  end

  defp verify_migrations(plan) do
    Enum.reduce_while(plan, :ok, fn migration, :ok ->
      verifier =
        Application.get_env(:nshkr_runtime, :migration_verifier, Nshkr.Runtime.Migrations)

      case verifier.verify(migration) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:migration_not_current, migration.owner, reason}}}
      end
    end)
  end

  defp probe_services(services) do
    Enum.reduce_while(services, :ok, fn service, :ok ->
      case Service.probe(service) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:service_unreachable, service.id, reason}}}
      end
    end)
  end

  defp forbidden_path(%Profile{} = profile, path) do
    forbidden_path(
      %{
        topology: profile.topology,
        services: profile.services,
        migration_plan: profile.migration_plan
      },
      path
    )
  end

  defp forbidden_path(struct, path) when is_struct(struct),
    do: forbidden_path(Map.from_struct(struct), path)

  defp forbidden_path(map, path) when is_map(map) do
    Enum.find_value(map, fn {key, value} ->
      next_path = [safe_path_key(key) | path]

      if secret_key?(key) and value not in [nil, "", []],
        do: [:secret_value | next_path],
        else: forbidden_path(key, next_path) || forbidden_path(value, next_path)
    end)
  end

  defp forbidden_path(list, path) when is_list(list) do
    if Keyword.keyword?(list) do
      forbidden_path(Map.new(list), path)
    else
      list
      |> Enum.with_index()
      |> Enum.find_value(fn {value, index} -> forbidden_path(value, [index | path]) end)
    end
  end

  defp forbidden_path({left, right}, path),
    do: forbidden_path(left, path) || forbidden_path(right, path)

  defp forbidden_path(value, path) when is_atom(value) or is_binary(value) do
    normalized = value |> to_string() |> String.downcase()

    if Enum.any?(@forbidden_fragments, &String.contains?(normalized, &1)) or
         sensitive_uri?(value),
       do: [:forbidden_value | path],
       else: nil
  end

  defp forbidden_path(_value, _path), do: nil

  defp secret_key?(key) when is_atom(key) or is_binary(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in @secret_keys))
  end

  defp secret_key?(_key), do: false

  defp sensitive_uri?(value) when is_binary(value) do
    uri = URI.parse(value)

    present?(uri.userinfo) or
      (is_binary(uri.query) and
         uri.query
         |> URI.query_decoder()
         |> Enum.any?(fn {key, _value} -> secret_key?(key) end))
  rescue
    _error -> false
  end

  defp sensitive_uri?(_value), do: false

  defp present?(value), do: is_binary(value) and value != ""
  defp safe_path_key(key) when is_atom(key) or is_binary(key) or is_integer(key), do: key
  defp safe_path_key(_key), do: :redacted_key
end
