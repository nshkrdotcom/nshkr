defmodule DependencySources do
  @moduledoc false

  @source_keys [:path, :github, :hex]

  def deps(repo_root \\ Path.dirname(__DIR__), opts \\ []) do
    repo_root
    |> config!()
    |> deps_config()
    |> Enum.map(fn {app, config} ->
      dep(app, repo_root, Keyword.merge(config[:opts] || [], opts))
    end)
  end

  def dep(app, repo_root \\ Path.dirname(__DIR__), extra_opts \\ []) do
    repo_root = Path.expand(repo_root)
    config = config!(repo_root)
    dep_config = Map.fetch!(deps_config(config), app) |> Map.new()
    override = local_override(repo_root, app)
    source = selected_source!(dep_config, override, publish_mode?(), repo_root)
    dep_tuple(app, dep_config, override, source, repo_root, extra_opts)
  end

  defp config!(repo_root) do
    path = Path.join(repo_root, "build_support/dependency_sources.config.exs")
    {config, _binding} = Code.eval_file(path)

    unless is_map(config) or Keyword.keyword?(config) do
      raise ArgumentError, "dependency source config must evaluate to a map or keyword list"
    end

    config
  end

  defp deps_config(config), do: Map.new(config[:deps] || config["deps"] || config)

  defp local_override(repo_root, app) do
    path = Path.join(repo_root, ".dependency_sources.local.exs")

    if File.regular?(path) do
      {overrides, _binding} = Code.eval_file(path)
      overrides = Map.new(overrides[:deps] || overrides["deps"] || %{})
      Map.new(overrides[app] || overrides[Atom.to_string(app)] || %{})
    else
      %{}
    end
  end

  defp selected_source!(config, override, publish?, repo_root) do
    order =
      cond do
        override[:source] -> [override[:source]]
        publish? -> config[:publish_order] || [:hex]
        true -> config[:default_order] || [:path, :github, :hex]
      end

    Enum.find(order, fn
      :path -> path_available?(override[:path] || config[:path], repo_root)
      source when source in @source_keys -> configured?(config, override, source)
      other -> raise ArgumentError, "unsupported dependency source #{inspect(other)}"
    end) || raise ArgumentError, "no configured dependency source is available"
  end

  defp path_available?(path, repo_root) when is_binary(path),
    do: File.exists?(Path.expand(path, repo_root))

  defp path_available?(paths, repo_root) when is_list(paths),
    do: Enum.any?(paths, &path_available?(&1, repo_root))

  defp path_available?(_, _), do: false

  defp configured?(config, override, source),
    do: not is_nil(override[source] || config[source])

  defp dep_tuple(app, config, override, :hex, _repo_root, extra_opts) do
    requirement = override[:hex] || config[:hex]
    {app, requirement, merged_opts(config, extra_opts)}
  end

  defp dep_tuple(app, config, override, :path, repo_root, extra_opts) do
    path = override[:path] || config[:path]

    path =
      if is_list(path),
        do: Enum.find(path, &File.exists?(Path.expand(&1, repo_root))),
        else: path

    {app, Keyword.merge([path: Path.expand(path, repo_root)], merged_opts(config, extra_opts))}
  end

  defp dep_tuple(app, config, override, :github, _repo_root, extra_opts) do
    github = Map.merge(Map.new(config[:github] || %{}), Map.new(override[:github] || %{}))
    repo = Map.fetch!(github, :repo)

    source_opts =
      github
      |> Map.take([:branch, :ref, :tag, :subdir])
      |> Enum.sort()

    {app,
     Keyword.merge([github: repo], Keyword.merge(source_opts, merged_opts(config, extra_opts)))}
  end

  defp merged_opts(config, extra_opts),
    do: Keyword.merge(config[:opts] || [], extra_opts)

  defp publish_mode? do
    System.argv()
    |> Enum.join(" ")
    |> String.contains?("hex.")
  end
end
