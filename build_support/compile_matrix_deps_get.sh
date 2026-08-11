#!/usr/bin/env bash

set -u

result_dir=$1
mkdir -p "$result_dir"

log_tmp="$result_dir/deps_get.log.tmp"
meta_tmp="$result_dir/deps_get.meta.tmp"

started=$(date +%s%N)
mix deps.get >"$log_tmp" 2>&1
exit_code=$?
finished=$(date +%s%N)
elapsed_ms=$(((finished - started) / 1000000))

mv "$log_tmp" "$result_dir/deps_get.log"

{
  printf 'exit=%s\n' "$exit_code"
  printf 'milliseconds=%s\n' "$elapsed_ms"
} >"$meta_tmp"

mv "$meta_tmp" "$result_dir/deps_get.meta"

exit 0
