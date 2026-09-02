#!/usr/bin/env bash
#
# gitea-installer.sh - Gitea, its database, and the CI runner.
#
# Usage: sudo ./gitea-installer.sh
#
# Generates Gitea's credentials in Vault before Gitea exists, then starts it with
# them. Vault is the origin of these passwords, not a place they are copied to -
# nobody ever chooses them, and they are never read back out of Gitea.
#
# The API token is NOT minted here. It needs Gitea's HTTP API, which is reachable
# only through the proxy, and the proxy starts after this. See gitea-repo-setup.sh.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
VAULT_COMPOSE="${SOURCE_SCRIPT}/../vault/docker-compose.yml"
VAULT_INIT="${SOURCE_SCRIPT}/../vault/secrets/vault-init.json"
ENV_FILE="${SOURCE_SCRIPT}/.env"
DATA_DIR="${SOURCE_SCRIPT}/data"
RUNNER_DIR="${SOURCE_SCRIPT}/runner"

DB_PATH="secret/gitea/postgres"
ADMIN_PATH="secret/gitea/admin"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-labadmin}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-labadmin@lab.test}"

# The rootless image runs as uid 1000 inside; bind mounts must match or Gitea
# cannot write its own data directory. Ownership is the host's job.
GITEA_UID=1000

[[ ${EUID} -eq 0 ]] || {
  echo "gitea-installer.sh must be run as root:  sudo $0" >&2
  exit 1
}

# --- talk to Vault ----------------------------------------------------------
#
# -e VAULT_TOKEN with no value passes it through from the environment. Writing
# -e VAULT_TOKEN=$TOKEN would put the token in argv, where ps shows it to every
# user on the host.

[[ -r "${VAULT_INIT}" ]] || {
  echo "Cannot read ${VAULT_INIT}. Run docker/vault/vault-installer.sh first." >&2
  exit 1
}
VAULT_TOKEN="$(jq -r '.root_token // empty' "${VAULT_INIT}")"
[[ -n "${VAULT_TOKEN}" ]] || {
  echo "${VAULT_INIT} holds no root_token." >&2
  exit 1
}
export VAULT_TOKEN

docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault vault status >/dev/null 2>&1 || {
  echo "Vault is not answering, or is sealed. Run docker/vault/scripts/vault-unseal.sh." >&2
  exit 1
}

# --- credentials, generated in Vault before Gitea exists --------------------
#
# Guarded because writing again would generate a NEW password while the database
# still holds the old one. `kv get` returns empty rather than failing when the
# path is absent, which is the first-run state.
#
# hex, not base64: these end up in a PostgreSQL connection string and a URL form
# body, and base64's + and / are meaningful in both.

if [[ -n "$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=password "${DB_PATH}" 2>/dev/null)" ]]; then
  echo "[+] ${DB_PATH} already present"
else
  docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
    vault kv put "${DB_PATH}" database=gitea username=gitea \
    password="$(openssl rand -hex 24)" >/dev/null
  echo "[+] Generated ${DB_PATH}"
fi

if [[ -n "$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=password "${ADMIN_PATH}" 2>/dev/null)" ]]; then
  echo "[+] ${ADMIN_PATH} already present"
else
  docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
    vault kv put "${ADMIN_PATH}" username="${GITEA_ADMIN_USER}" \
    email="${GITEA_ADMIN_EMAIL}" password="$(openssl rand -hex 24)" >/dev/null
  echo "[+] Generated ${ADMIN_PATH}"
fi

# --- render .env ------------------------------------------------------------
#
# .env, not exported variables: compose reads it, and it keeps the credentials
# out of the process table of everything this script runs.

db_name="$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=database "${DB_PATH}" 2>/dev/null)"
db_user="$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=username "${DB_PATH}" 2>/dev/null)"
db_pass="$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=password "${DB_PATH}" 2>/dev/null)"
[[ -n "${db_name}" && -n "${db_user}" && -n "${db_pass}" ]] || {
  echo "${DB_PATH} is missing or incomplete." >&2
  exit 1
}

# The host address, discovered rather than written down: it differs per host.
bridge="$(ip -4 addr show cloudbr0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
[[ -n "${bridge}" ]] || {
  echo "cloudbr0 has no IPv4 address; is it up?" >&2
  exit 1
}

# The GID that owns the docker socket, for the runner's group_add. Read from the
# socket, not from `getent group docker` - what grants access is the group that
# OWNS the socket, not one that happens to carry that name. Ubuntu allocates it
# descending from 999, so it differs per host.
docker_gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null)"
[[ -n "${docker_gid}" ]] || {
  echo "/var/run/docker.sock not found. Is Docker running?" >&2
  exit 1
}

(
  umask 077
  printf 'CLOUDBR0_IP=%s\nDOCKER_GID=%s\nGITEA_DB_NAME=%s\nGITEA_DB_USER=%s\nGITEA_DB_PASSWORD=%s\n' \
    "${bridge}" "${docker_gid}" "${db_name}" "${db_user}" "${db_pass}" >"${ENV_FILE}"
)
chmod 0600 "${ENV_FILE}"
echo "[+] Rendered ${ENV_FILE} from Vault"

# --- start Gitea ------------------------------------------------------------

# Ownership before the container: Docker creates a missing bind-mount source as
# root, and repairing afterwards is a race.
install -d -m 0750 "${DATA_DIR}/gitea" "${DATA_DIR}/postgres"
chown -R "${GITEA_UID}:${GITEA_UID}" "${DATA_DIR}/gitea"

# Named services, not the whole file: dind and runner cannot start until a
# registration token exists, and that cannot be minted until Gitea is up.
docker compose -f "${COMPOSE}" up -d --remove-orphans db gitea

for ((i = 0; i < 60; i++)); do
  docker compose -f "${COMPOSE}" exec -T gitea gitea --version >/dev/null 2>&1 && break
  sleep 2
done
docker compose -f "${COMPOSE}" exec -T gitea gitea --version >/dev/null 2>&1 || {
  echo "Gitea did not become ready in 120s. See: docker logs gitea" >&2
  exit 1
}
echo "[+] Gitea is up, reachable only via the proxy at https://gitea.lab.test"

# --- the admin user ---------------------------------------------------------
#
# Create-if-missing, not ensure-matches: Gitea errors on a duplicate, and the
# password is never read back, so there is nothing to compare against.

admin_user="$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=username "${ADMIN_PATH}" 2>/dev/null)"
admin_pass="$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=password "${ADMIN_PATH}" 2>/dev/null)"
admin_email="$(docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault kv get -field=email "${ADMIN_PATH}" 2>/dev/null)"

if docker compose -f "${COMPOSE}" exec -T gitea gitea admin user list 2>/dev/null |
  awk 'NR>1 {print $2}' | grep -qx "${admin_user}"; then
  echo "[+] Gitea admin '${admin_user}' already exists"
else
  docker compose -f "${COMPOSE}" exec -T gitea \
    gitea admin user create --admin --username "${admin_user}" --password "${admin_pass}" \
    --email "${admin_email}" --must-change-password=false >/dev/null || {
    echo "Could not create the Gitea admin user." >&2
    exit 1
  }
  echo "[+] Created Gitea admin '${admin_user}' with the password from Vault"
fi

# --- the runner and the daemon its jobs build on ----------------------------
#
# The registration token is minted here and passed in the environment for one
# command - never written to .env. It is single-use: the runner exchanges it at
# registration for runner/data/.runner, which is the durable credential. That is
# why a re-run skips minting entirely rather than registering twice.

install -d -m 0750 "${RUNNER_DIR}/data"

if [[ -f "${RUNNER_DIR}/data/.runner" ]]; then
  docker compose -f "${COMPOSE}" up -d dind runner
  echo "[+] Runner already registered; started it and dind."
else
  runner_token="$(docker compose -f "${COMPOSE}" exec -T gitea \
    gitea actions generate-runner-token 2>/dev/null | tr -d '\r\n[:space:]')"
  [[ -n "${runner_token}" ]] || {
    echo "Could not mint a runner token. Check GITEA__actions__ENABLED and: docker logs gitea" >&2
    exit 1
  }
  RUNNER_TOKEN="${runner_token}" docker compose -f "${COMPOSE}" up -d dind runner
  echo "[+] Runner registered against http://gitea:3000, jobs build on dind."
fi
