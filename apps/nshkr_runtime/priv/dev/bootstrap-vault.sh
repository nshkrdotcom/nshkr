#!/bin/sh
set -eu

vault secrets enable -path=kv kv-v2 >/dev/null 2>&1 || true
vault auth enable approle >/dev/null 2>&1 || true

vault policy write nshkr-runtime - >/dev/null <<'POLICY'
path "kv/data/*" {
  capabilities = ["read"]
}
POLICY

vault kv put kv/object-store/minio \
  access_key_id="$MINIO_ACCESS_KEY" \
  secret_access_key="$MINIO_SECRET_KEY" >/dev/null

vault write auth/approle/role/nshkr-runtime \
  token_policies=nshkr-runtime \
  token_ttl=10m \
  token_max_ttl=30m \
  secret_id_ttl=24h >/dev/null

umask 077
vault read -field=role_id auth/approle/role/nshkr-runtime/role-id > /out/vault-role-id
vault write -field=secret_id -f auth/approle/role/nshkr-runtime/secret-id > /out/vault-secret-id
