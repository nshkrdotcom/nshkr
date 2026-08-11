defmodule Mix.Tasks.Nshkr.CompileMatrix.DepsGet do
  use Mix.Task

  @shortdoc "Fetch dependencies for every P02 matrix project through Blitz"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          force: :boolean,
          max_concurrency: :integer,
          result_dir: :string,
          store_dir: :string
        ],
        aliases: [j: :max_concurrency]
      )

    if positional != [] or invalid != [] do
      Mix.raise("invalid matrix deps.get arguments: #{inspect(positional ++ invalid)}")
    end

    summary = Nshkr.Build.CompileMatrix.fetch_dependencies(opts)

    Mix.shell().info("matrix deps.get: selected=#{summary.selected}, skipped=#{summary.skipped}")
  end
end
