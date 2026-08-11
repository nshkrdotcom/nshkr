#!/usr/bin/env bash

set -u

result_dir=$1
mkdir -p "$result_dir"

probe_tmp="$result_dir/project_probe.log.tmp"
strict_tmp="$result_dir/strict.log.tmp"
strict_retry_tmp="$result_dir/strict.retry.log.tmp"
plain_tmp="$result_dir/plain.log.tmp"
meta_tmp="$result_dir/meta.tmp"

elixir -e 'Mix.start(); Mix.Project.in_project(:p02_probe, ".", fn _ -> IO.puts("P02_PROJECT=#{Mix.Project.config()[:app]}") end)' >"$probe_tmp" 2>&1
probe_exit=$?

strict_started=$(date +%s%N)
mix compile --warnings-as-errors >"$strict_tmp" 2>&1
strict_exit=$?
strict_finished=$(date +%s%N)
strict_ms=$(((strict_finished - strict_started) / 1000000))

plain_exit=-1
plain_ms=0
: >"$plain_tmp"
: >"$strict_retry_tmp"

if [ "$strict_exit" -ne 0 ]; then
  plain_started=$(date +%s%N)
  mix compile >"$plain_tmp" 2>&1
  plain_exit=$?
  plain_finished=$(date +%s%N)
  plain_ms=$(((plain_finished - plain_started) / 1000000))

  if [ "$plain_exit" -eq 0 ] && grep -Eq 'File\.Error|not owner|permission denied' "$strict_tmp"; then
    strict_retry_started=$(date +%s%N)
    mix compile --force --warnings-as-errors >"$strict_retry_tmp" 2>&1
    strict_exit=$?
    strict_retry_finished=$(date +%s%N)
    strict_ms=$((strict_ms + (strict_retry_finished - strict_retry_started) / 1000000))

    mv "$strict_tmp" "$result_dir/strict.initial.log"
    mv "$strict_retry_tmp" "$strict_tmp"
  fi
fi

rm -f "$strict_retry_tmp"

mv "$probe_tmp" "$result_dir/project_probe.log"
mv "$strict_tmp" "$result_dir/strict.log"
mv "$plain_tmp" "$result_dir/plain.log"

{
  printf 'probe_exit=%s\n' "$probe_exit"
  printf 'strict_exit=%s\n' "$strict_exit"
  printf 'strict_ms=%s\n' "$strict_ms"
  printf 'plain_exit=%s\n' "$plain_exit"
  printf 'plain_ms=%s\n' "$plain_ms"
} >"$meta_tmp"

mv "$meta_tmp" "$result_dir/meta"

# The wrapper reports capture success to Blitz. The nested Mix exit codes are
# preserved in metadata and become the matrix status.
exit 0
