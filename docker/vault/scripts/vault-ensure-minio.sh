#!/usr/bin/env bash
#
# vault-ensure-minio.sh — generate MinIO's ROOT credential in Vault, before
# MinIO exists (5.1).
#
# Usage: sudo ./vault-ensure-minio.sh
#
# Same direction as vault-ensure-gitea.sh: Vault is the origin and the service
# is told what to use. 5.1 is explicit that the root keys never leave the host —
# they live here and in MinIO's runtime environment, and nowhere else. The
# SCOPED service-account keys are the ones written out for pipelines to read,
# and those are minted by minio-provision.sh after MinIO is up, not here.
#
# Safe to re-run: an existing credential is never regenerated. Rotating the root
# key here would leave MinIO authenticating against a value it has already
# baked into its running process — 3.6's rotation trap.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/vault.sh"

ROOT_PATH="secret/minio/root"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-labadmin}"

# The root credential and nothing else — not the bucket names, not the scoped
# service-account keys. 5.1's blast-radius argument is the whole reason those are
# separate, and this path is where that separation would quietly erode.
ensure_root_secret() {
  if [[ -n "$(vault_field "${ROOT_PATH}" password)" ]]; then
    log "${ROOT_PATH} already present"
    return 0
  fi

  vault_ kv put "${ROOT_PATH}" \
    username="${MINIO_ROOT_USER}" password="$(new_password)" >/dev/null ||
    die "Could not write ${ROOT_PATH}"
  log "Generated ${ROOT_PATH}"
}

main() {
  require_root
  vault_authenticate
  ensure_root_secret
}

main "$@"
