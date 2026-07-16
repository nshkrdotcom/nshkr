defmodule Nshkr.Runtime.ConfigProvider do
  @moduledoc "Release config provider for a pre-materialized NSHKR profile file."

  @behaviour Config.Provider

  @impl true
  def init(opts) when is_list(opts) do
    path = opts |> Keyword.fetch!(:path) |> resolve_path!() |> Path.expand()
    %{path: path}
  end

  @impl true
  def load(config, %{path: path}) do
    unless File.regular?(path), do: raise("NSHKR profile file is missing: #{path}")

    {document, binding} = Code.eval_file(path)

    unless binding == [] and is_map(document) and
             MapSet.new(Map.keys(document)) == MapSet.new([:production_profile, :runtime_config]) and
             (is_map(document.production_profile) or
                Keyword.keyword?(document.production_profile)) and
             Keyword.keyword?(document.runtime_config) do
      raise "NSHKR profile file must evaluate to the production_profile/runtime_config document"
    end

    runtime_config =
      Config.Reader.merge(
        document.runtime_config,
        nshkr_runtime: [production_profile: document.production_profile]
      )

    Config.Reader.merge(config, runtime_config)
  end

  defp resolve_path!({:system, variable}) when is_binary(variable),
    do: System.fetch_env!(variable)

  defp resolve_path!(path) when is_binary(path), do: path
end
