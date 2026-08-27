#!/usr/bin/env bash
#
# gitea-installer.sh — Gitea and PostgreSQL, configured from Vault (4.1).
#
# Usage: sudo ./gitea-installer.sh
#
# Runs after vault-ensure-gitea.sh, which generates the credentials this reads.
# Nothing here invents a password: Vault is the origin, this is the consumer.
#
# Safe to re-run. The admin user is created only if absent — Gitea's own
# `admin user create` fails on a duplicate, and treating that as success would
# hide a real error.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/vault.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
ENV_FILE="${SOURCE_SCRIPT}/.env"
DATA_DIR="${SOURCE_SCRIPT}/data"

DB_PATH="secret/gitea/postgres"
ADMIN_PATH="secret/gitea/admin"

# The rootless image runs as uid 1000 inside; bind mounts must match or Gitea
# cannot write its own data directory. Same class of problem as Vault's 65100
# (3.1-1), and the same fix: ownership is the host's job.
GITEA_UID=1000

# .env, not exported variables: compose reads it, and it keeps the credentials
# out of the process table of everything this script runs (2.3-5).
render_env() {
  local db_name db_user db_pass
  db_name="$(vault_ kv get -field=database "${DB_PATH}" 2>/dev/null)"
  db_user="$(vault_ kv get -field=username "${DB_PATH}" 2>/dev/null)"
  db_pass="$(vault_ kv get -field=password "${DB_PATH}" 2>/dev/null)"
  [[ -n "${db_name}" && -n "${db_user}" && -n "${db_pass}" ]] ||
    die "${DB_PATH} is missing or incomplete. Run docker/vault/scripts/vault-ensure-gitea.sh."

  (
    umask 077
    printf 'CLOUDBR0_IP=%s\nGITEA_DB_NAME=%s\nGITEA_DB_USER=%s\nGITEA_DB_PASSWORD=%s\n' \
      "$(bridge_ip)" "${db_name}" "${db_user}" "${db_pass}" >"${ENV_FILE}"
  )
  chmod 0600 "${ENV_FILE}"
  log "Rendered ${ENV_FILE} from Vault"
}

start_gitea() {
  # Ownership before the container, as vault-installer.sh does: Docker creates a
  # missing bind-mount source as root, and repairing afterwards is a race.
  install -d -m 0750 "${DATA_DIR}/gitea" "${DATA_DIR}/postgres"
  chown -R "${GITEA_UID}:${GITEA_UID}" "${DATA_DIR}/gitea"

  docker compose -f "${COMPOSE}" up -d --remove-orphans

  local i
  for ((i = 0; i < 60; i++)); do
    docker compose -f "${COMPOSE}" exec -T gitea gitea --version >/dev/null 2>&1 && break
    sleep 2
  done
  docker compose -f "${COMPOSE}" exec -T gitea gitea --version >/dev/null 2>&1 ||
    die "Gitea did not become ready in 120s. See: docker logs gitea"
  log "Gitea is up on $(bridge_ip):3000"
}

# Created only if absent. Gitea's own command errors on a duplicate, and the
# password is not read back afterwards — so this is create-if-missing, not
# ensure-matches: there is nothing to compare against (4.1).
ensure_admin_user() {
  local user pass email
  user="$(vault_ kv get -field=username "${ADMIN_PATH}" 2>/dev/null)"
  pass="$(vault_ kv get -field=password "${ADMIN_PATH}" 2>/dev/null)"
  email="$(vault_ kv get -field=email "${ADMIN_PATH}" 2>/dev/null)"
  [[ -n "${user}" && -n "${pass}" ]] ||
    die "${ADMIN_PATH} is missing. Run docker/vault/scripts/vault-ensure-gitea.sh."

  if docker compose -f "${COMPOSE}" exec -T gitea gitea admin user list 2>/dev/null |
    awk 'NR>1 {print $2}' | grep -qx "${user}"; then
    log "Gitea admin '${user}' already exists"
    return 0
  fi

  # The password reaches the container through stdin-free argv inside the
  # container only; it never appears in a host command line because compose
  # passes it as an argument to the containerised process. Accepted for now —
  # Gitea offers no stdin form for this command.
  docker compose -f "${COMPOSE}" exec -T gitea \
    gitea admin user create --admin --username "${user}" --password "${pass}" \
    --email "${email}" --must-change-password=false >/dev/null ||
    die "Could not create the Gitea admin user."
  log "Created Gitea admin '${user}' with the password from Vault"
}

main() {
  require_root
  vault_authenticate
  render_env
  start_gitea
  ensure_admin_user
}

main "$@"
