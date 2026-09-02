#!/usr/bin/env bash
#
# vault-ensure-gitea.sh — generate Gitea's credentials IN VAULT, before Gitea
# exists (4.1).
#
# Usage: sudo ./vault-ensure-gitea.sh
#
# The other direction from vault-ensure-cloudstack.sh, and 4.1 says to pick per
# credential: CloudStack mints its own key and we capture it; here Vault is the
# origin and the service is told what to use. Generating first is the cleaner
# half — nothing is ever typed into a form, and no default password exists to
# leak into a committed file, which is the mistake the reference lab makes.
#
# Safe to re-run: a password that already exists is never regenerated. Rotating
# it here would leave Gitea and its database authenticating with different
# secrets, which is 3.6's rotation trap with two moving parts instead of one.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="${SOURCE_SCRIPT}/.."
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/vault.sh"

DB_PATH="secret/gitea/postgres"
ADMIN_PATH="secret/gitea/admin"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-labadmin}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-labadmin@lab.test}"
GITEA_DB_NAME="gitea"
GITEA_DB_USER="gitea"

# Present is enough — unlike CloudStack, there is no far side to compare against
# yet. Gitea does not exist when this first runs; that is the point of running it
# first. vault_field is what expresses that: it returns empty rather than failing
# on a missing secret, which its own comment calls the first-run state every
# ensure script tests for.

ensure_db_secret() {
  if [[ -n "$(vault_field "${DB_PATH}" password)" ]]; then
    log "${DB_PATH} already present"
    return 0
  fi
  vault_ kv put "${DB_PATH}" \
    database="${GITEA_DB_NAME}" username="${GITEA_DB_USER}" password="$(new_password)" >/dev/null ||
    die "Could not write ${DB_PATH}."
  log "Generated ${DB_PATH}"
}

ensure_admin_secret() {
  if [[ -n "$(vault_field "${ADMIN_PATH}" password)" ]]; then
    log "${ADMIN_PATH} already present"
    return 0
  fi
  vault_ kv put "${ADMIN_PATH}" \
    username="${GITEA_ADMIN_USER}" email="${GITEA_ADMIN_EMAIL}" password="$(new_password)" >/dev/null ||
    die "Could not write ${ADMIN_PATH}."
  log "Generated ${ADMIN_PATH}"
}

main() {
  require_root
  vault_authenticate
  ensure_db_secret
  ensure_admin_secret
}

main "$@"
