defmodule Mix.Tasks.Nshkr.CompileMatrix do
  use Mix.Task

  @shortdoc "Generate the P02 compile matrix through Blitz"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          force: :boolean,
          max_concurrency: :integer,
          output_dir: :string,
          result_dir: :string,
          store_dir: :string
        ],
        aliases: [j: :max_concurrency]
      )

    if positional != [] or invalid != [] do
      Mix.raise("invalid compile-matrix arguments: #{inspect(positional ++ invalid)}")
    end

    result = Nshkr.Build.CompileMatrix.run(opts)
    summary = result.summary

    Mix.shell().info(
      "compile matrix: #{length(result.rows)} projects, selected=#{summary.selected}, skipped=#{summary.skipped}, output=#{result.output_dir}"
    )
  end
end
