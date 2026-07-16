#!/bin/sh
set -eu

app_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
runtime_dir="$app_root/.runtime-secrets"
env_file="$runtime_dir/dev.env"
compose_file="$app_root/priv/dev/compose.yaml"

ensure_env_file() {
  if [ ! -f "$env_file" ]; then
    umask 077
    mkdir -p "$runtime_dir"
    {
      printf 'NSHKR_DEV_VAULT_ROOT_TOKEN=%s\n' "$(openssl rand -hex 32)"
      printf 'NSHKR_DEV_MINIO_ACCESS_KEY=%s\n' "nshkr$(openssl rand -hex 8)"
      printf 'NSHKR_DEV_MINIO_SECRET_KEY=%s\n' "$(openssl rand -hex 32)"
    } > "$env_file"
  fi
}

compose() {
  NSHKR_DEV_RUNTIME_DIR="$runtime_dir" \
    NSHKR_DEV_UID="$(id -u)" \
    NSHKR_DEV_GID="$(id -g)" \
    docker compose --env-file "$env_file" -f "$compose_file" "$@"
}

case "${1:-}" in
  up)
    ensure_env_file
    compose up -d vault minio
    compose run --rm minio-bootstrap >/dev/null
    compose run --rm vault-bootstrap >/dev/null
    ;;
  status)
    ensure_env_file
    compose ps
    ;;
  down)
    ensure_env_file
    compose down
    ;;
  *)
    printf '%s\n' 'usage: priv/dev/services.sh {up|status|down}' >&2
    exit 64
    ;;
esac
