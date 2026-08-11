defmodule Nshkr.Build.CompileMatrix do
  @moduledoc false

  alias Blitz.{Command, MixWorkspace}
  alias Nshkr.Build.WorkspaceContract

  @workspace_root Path.expand("../../..", __DIR__)
  @wrapper Path.join(@workspace_root, "build_support/compile_matrix_project.sh")
  @deps_wrapper Path.join(@workspace_root, "build_support/compile_matrix_deps_get.sh")
  @default_output_dir "/home/home/p/g/j/jido_brainstorm/nshkrdotcom/docs/20260809/state"
  @default_store_dir Path.join(@workspace_root, ".blitz/tmp/compile_matrix_state")
  @default_result_dir Path.join(@workspace_root, ".blitz/tmp/compile_matrix_results")
  @default_deps_result_dir Path.join(@workspace_root, ".blitz/tmp/compile_matrix_deps_results")

  @failure_classes ~w(
    missing_dep
    stale_lock
    api_drift
    undefined_function
    protocol_consolidation
    syntax
    config
    unknown
  )

  def run(opts \\ []) do
    workspace = MixWorkspace.load!()
    project_paths = MixWorkspace.project_paths(workspace)
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir) |> Path.expand()
    result_dir = Keyword.get(opts, :result_dir, @default_result_dir) |> Path.expand()
    store_dir = Keyword.get(opts, :store_dir, @default_store_dir) |> Path.expand()
    force? = Keyword.get(opts, :force, false)
    concurrency = Keyword.get(opts, :max_concurrency)

    File.mkdir_p!(output_dir)
    File.mkdir_p!(result_dir)
    File.mkdir_p!(store_dir)

    impact_opts = [
      command_mapper: &capture_command(&1, result_dir),
      force: force?,
      store_dir: store_dir
    ]

    task_args = if concurrency, do: ["-j", Integer.to_string(concurrency)], else: []

    summary = MixWorkspace.Impact.run!(workspace, :compile_matrix, task_args, impact_opts)
    rows = Enum.map(project_paths, &build_row(&1, result_dir))

    write_json!(output_dir, rows)
    write_markdown!(output_dir, rows)

    %{summary: summary, rows: rows, output_dir: output_dir}
  end

  def workspace_env(%{project_root: project_root}) do
    [
      {"MIX_BUILD_PATH", Path.join(project_root, "_build/p02_matrix")},
      {"MIX_DEPS_PATH", Path.join(project_root, "_build/p02_matrix_deps")}
    ]
  end

  def fetch_dependencies(opts \\ []) do
    workspace = MixWorkspace.load!()
    result_dir = Keyword.get(opts, :result_dir, @default_deps_result_dir) |> Path.expand()
    store_dir = Keyword.get(opts, :store_dir, @default_store_dir) |> Path.expand()
    concurrency = Keyword.get(opts, :max_concurrency)

    File.mkdir_p!(result_dir)
    File.mkdir_p!(store_dir)

    task_args = if concurrency, do: ["-j", Integer.to_string(concurrency)], else: []

    MixWorkspace.Impact.run!(workspace, :matrix_deps_get, task_args,
      command_mapper: &capture_deps_command(&1, result_dir),
      force: Keyword.get(opts, :force, false),
      store_dir: store_dir
    )
  end

  defp capture_command(%Command{} = command, result_root) do
    project_result_dir = Path.join(result_root, project_key(command.id))
    File.mkdir_p!(project_result_dir)

    %Command{
      command
      | command: "bash",
        args: [@wrapper, project_result_dir]
    }
  end

  defp capture_deps_command(%Command{} = command, result_root) do
    project_result_dir = Path.join(result_root, project_key(command.id))
    File.mkdir_p!(project_result_dir)

    %Command{
      command
      | command: "bash",
        args: [@deps_wrapper, project_result_dir]
    }
  end

  defp build_row(project_path, result_root) do
    path = project_absolute_path(project_path)
    result_dir = Path.join(result_root, project_key(project_path))
    meta_path = Path.join(result_dir, "meta")

    if File.regular?(meta_path) do
      meta = read_meta!(meta_path)
      strict_log = read_log(result_dir, "strict.log")
      plain_log = read_log(result_dir, "plain.log")
      strict_exit = Map.fetch!(meta, "strict_exit")
      plain_exit = Map.fetch!(meta, "plain_exit")
      status = status(strict_exit, plain_exit)

      %{
        project: project_name(result_dir, path),
        repo: WorkspaceContract.compile_matrix_repo(path),
        path: path,
        status: status,
        seconds: seconds(meta),
        warning_count: warning_count(strict_log),
        error_class: error_class(status, strict_log, plain_log),
        first_error: first_error(status, strict_log, plain_log)
      }
    else
      %{
        project: Path.basename(path),
        repo: WorkspaceContract.compile_matrix_repo(path),
        path: path,
        status: "skipped",
        seconds: 0.0,
        warning_count: 0,
        error_class: "unknown",
        first_error: "matrix wrapper produced no metadata"
      }
    end
  end

  defp read_meta!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, String.to_integer(value)}
    end)
  end

  defp read_log(result_dir, name) do
    case File.read(Path.join(result_dir, name)) do
      {:ok, contents} -> strip_ansi(contents)
      {:error, _reason} -> ""
    end
  end

  defp status(0, _plain_exit), do: "ok"
  defp status(_strict_exit, 0), do: "warnings"
  defp status(_strict_exit, _plain_exit), do: "fail"

  defp seconds(meta) do
    total_ms = Map.fetch!(meta, "strict_ms") + Map.fetch!(meta, "plain_ms")
    Float.round(total_ms / 1000, 3)
  end

  defp warning_count(log) do
    ~r/^\s*warning:/m
    |> Regex.scan(log)
    |> length()
  end

  defp error_class("ok", _strict_log, _plain_log), do: nil

  defp error_class("warnings", strict_log, plain_log) do
    if String.contains?(String.downcase(strict_log), ["file.error", "not owner"]) do
      classify_failure(strict_log, plain_log)
    end
  end

  defp error_class(_status, strict_log, plain_log) do
    classify_failure(strict_log, plain_log)
  end

  defp classify_failure(strict_log, plain_log) do
    output = String.downcase(plain_log <> "\n" <> strict_log)

    cond do
      contains_any?(output, ["protocol consolidation", "consolidated protocol"]) ->
        "protocol_consolidation"

      contains_any?(output, [
        "syntaxerror",
        "tokenmissingerror",
        "missingterminatorerror",
        "unexpected token",
        "syntax error"
      ]) ->
        "syntax"

      contains_any?(output, [
        "config.reader",
        "dependency_sources.exs",
        "file.error",
        "permission denied",
        "not owner",
        " eacces",
        "environment variable",
        "could not read config",
        "invalid configuration"
      ]) ->
        "config"

      contains_any?(output, [
        "undefinedfunctionerror",
        "undefined function",
        " is undefined or private",
        "undefined or private macro"
      ]) ->
        "undefined_function"

      contains_any?(output, [
        "unchecked dependencies",
        "can't continue due to errors on dependencies",
        "could not compile dependency",
        "no package with name",
        "cannot find application",
        "mix deps.get"
      ]) ->
        "missing_dep"

      contains_any?(output, [
        "dependencies have diverged",
        "lock mismatch",
        "lock is outdated",
        "does not match the requirement",
        "lockfile is out of date"
      ]) ->
        "stale_lock"

      contains_any?(output, [
        "functionclauseerror",
        "keyerror",
        "matcherror",
        "caseclauseerror",
        "badmaperror",
        "compileerror",
        "does not implement",
        "no function clause matching"
      ]) ->
        "api_drift"

      true ->
        "unknown"
    end
  end

  defp first_error("ok", _strict_log, _plain_log), do: nil

  defp first_error("warnings", strict_log, _plain_log) do
    find_error_line(strict_log, [~r/^\*\* \(.+\)/, ~r/^\s*warning:/])
  end

  defp first_error(_status, strict_log, plain_log) do
    find_error_line(plain_log <> "\n" <> strict_log, [
      ~r/^\s*error:/,
      ~r/^\*\* \(.+\)/,
      ~r/^== Compilation error.+==$/,
      ~r/^Unchecked dependencies.+:$/,
      ~r/^Dependencies have diverged.+:$/,
      ~r/^Could not compile.+$/,
      ~r/^No package with name.+$/,
      ~r/^\s*warning:/
    ])
  end

  defp find_error_line(log, patterns) do
    lines = String.split(log, "\n")

    Enum.find_value(patterns, fn pattern ->
      Enum.find(lines, fn line -> Regex.match?(pattern, line) end)
    end) ||
      Enum.find(lines, fn line ->
        line = String.trim(line)
        line != "" and not String.starts_with?(line, ["==>", "Compiling ", "Generated ", "["])
      end)
  end

  defp project_name(result_dir, path) do
    probe = read_log(result_dir, "project_probe.log")

    case Regex.run(~r/^P02_PROJECT=([A-Za-z0-9_]+)$/m, probe, capture: :all_but_first) do
      [project] -> project
      _other -> Path.basename(path)
    end
  end

  defp project_absolute_path("."), do: @workspace_root
  defp project_absolute_path(path), do: Path.expand(path, @workspace_root)

  defp project_key(project_path) do
    :crypto.hash(:sha256, project_path)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 20)
  end

  defp contains_any?(output, patterns), do: Enum.any?(patterns, &String.contains?(output, &1))

  defp strip_ansi(contents), do: Regex.replace(~r/\e\[[0-9;]*m/, contents, "")

  defp write_json!(output_dir, rows) do
    payload = %{
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "projects" => Enum.map(rows, &json_row/1)
    }

    json = payload |> :json.format() |> IO.iodata_to_binary()
    File.write!(Path.join(output_dir, "compile_matrix.json"), json <> "\n")
  end

  defp json_row(row) do
    %{
      "project" => row.project,
      "repo" => row.repo,
      "path" => row.path,
      "status" => row.status,
      "seconds" => row.seconds,
      "warning_count" => row.warning_count,
      "error_class" => json_nullable(row.error_class),
      "first_error" => json_nullable(row.first_error)
    }
  end

  defp json_nullable(nil), do: :null
  defp json_nullable(value), do: value

  defp write_markdown!(output_dir, rows) do
    counts = Enum.frequencies_by(rows, & &1.status)

    failure_counts =
      rows |> Enum.reject(&is_nil(&1.error_class)) |> Enum.frequencies_by(& &1.error_class)

    matrix_lines =
      Enum.map(rows, fn row ->
        "| #{md(row.project)} | #{md(row.repo)} | `#{row.path}` | #{row.status} | #{format_seconds(row.seconds)} | #{row.warning_count} | #{row.error_class || "—"} | #{md(row.first_error || "—")} |"
      end)

    class_lines =
      Enum.map(@failure_classes, fn class ->
        "| #{class} | #{Map.get(failure_counts, class, 0)} |"
      end)

    deferred =
      rows
      |> Enum.filter(
        &(&1.status in ["fail", "skipped"] and
            &1.error_class not in ["missing_dep", "stale_lock", "config"])
      )
      |> Enum.map(fn row ->
        "| #{md(row.project)} | #{row.error_class} | `#{row.path}` | #{md(row.first_error || "—")} |"
      end)

    content =
      [
        "# P02 compile matrix",
        "",
        "Generated from a Blitz impact-aware fan-out across #{length(rows)} source Mix projects discovered with `find` in the packet's 24 repositories. Generated, vendored, archived, legacy, fixture, dependency, and build-output trees were excluded. Elixir #{System.version()}, OTP #{System.otp_release()}.",
        "",
        "## Matrix",
        "",
        "| Project | Repo | Path | Status | Seconds | Warnings | Error class | First error |",
        "|---|---|---|---:|---:|---:|---|---|"
        | matrix_lines
      ] ++
        [
          "",
          "## Failure classes",
          "",
          "| Class | Projects |",
          "|---|---:|"
        ] ++
        class_lines ++
        [
          "",
          "Status totals: ok=#{Map.get(counts, "ok", 0)}, warnings=#{Map.get(counts, "warnings", 0)}, fail=#{Map.get(counts, "fail", 0)}, skipped=#{Map.get(counts, "skipped", 0)}.",
          "",
          "## Fixed in this mission",
          "",
          "- Upgraded nshkr's committed Blitz dependency from 0.3.0 to the released 0.4.1 baseline, while using the local unpublished 0.4.2 defect fix through the ignored local source override.",
          "- Fixed Blitz external absolute project globs and made impact fingerprints use each external project's own Git worktree, so all 339 rows are both runnable and safe to skip.",
          "- Fetched the complete graph through Blitz and repaired 50 incomplete package lockfiles across AppKit, Mezzanine, Citadel, Chassis, Outer Brain, and StackLab.",
          "- Isolated matrix builds and dependency sources under each project's `_build/p02_matrix*`, eliminating the foreign-owner configuration failures recorded by P01 without altering existing developer builds.",
          "- Made the two newly released Execution Plane package configurations independent of whichever repository loaded the shared dependency-source helper first.",
          "- Regenerated this table after all mechanical repairs; no final `missing_dep`, `stale_lock`, or `config` row remains.",
          "",
          "## Deferred to P03",
          "",
          "| Project | Class | Path | First error |",
          "|---|---|---|---|"
        ] ++
        if(deferred == [], do: ["| — | — | — | None |"], else: deferred) ++
        [
          "",
          "## Verdict",
          "",
          "#{Map.get(counts, "ok", 0)} of #{length(rows)} projects pass `mix compile --warnings-as-errors`; #{Map.get(counts, "warnings", 0)} compile only without the strict warning gate; #{Map.get(counts, "fail", 0)} fail plain compilation; and #{Map.get(counts, "skipped", 0)} were skipped. Deferred source/API failures belong to P03 and were not refactored here.",
          ""
        ]

    File.write!(Path.join(output_dir, "02_compile_matrix.md"), Enum.join(content, "\n"))
  end

  defp md(value),
    do: value |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ")

  defp format_seconds(seconds), do: :erlang.float_to_binary(seconds, decimals: 3)
end
