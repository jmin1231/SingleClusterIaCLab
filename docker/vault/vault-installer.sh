#!/usr/bin/env bash
#
# vault-installer.sh — bring Vault up behind its own TLS at vault.lab.test:8200,
# initialise it, and unseal it.
#
# Usage: sudo ./vault-installer.sh
#
# Called by bootstrap.sh after coredns-installer.sh: Vault is reached by name
# from the moment it exists. Its certificate is the only leaf this lab's openssl
# CA ever issues (3.4-1).
#
# Complete, except that step 5 verifies by hand rather than automatically — see
# verify_vault. Reasoning for the decisions here is in docs/decisions.md 3.1-x.
#
# Two things to hold on to: operator init mints the storage key once and never
# again, and it cannot live in Vault. And seal is not stop — a restarted Vault
# is running, listening, and answers everything 503.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
CERT_DIR="${SOURCE_SCRIPT}/certs"
DATA_DIR="${SOURCE_SCRIPT}/data"
# Plural: .gitignore and .yamllint both match this name and nothing else.
SECRETS_DIR="${SOURCE_SCRIPT}/secrets"
# Write-once material, kept apart from anything rotatable (3.1-3).
INIT_FILE="${SECRETS_DIR}/vault-init.json"

# NOT the image's 100:1000 — Ubuntu allocates uid 100-999 per package install,
# so on the host it means a different daemon on every machine. 65100 belongs to
# nobody. Must match user: in docker-compose.yml. See 3.1-1.
VAULT_UID=65100
VAULT_GID=65100

LEAF_KEY="${CERT_DIR}/tls.key"
LEAF_CA="${CERT_DIR}/ca.crt" # the root; what VAULT_CACERT points at
LEAF_BUNDLE="${CERT_DIR}/bundle.crt"

# --- Step 1 · Preflight and generated config ---------------------------------

# Presence is enough: issue-leaf.sh writes these together and its own
# check_existing already refuses a partial set. Reports all misses at once.
require_leaf() {
  local missing=() file

  for file in "${LEAF_KEY}" "${LEAF_BUNDLE}" "${LEAF_CA}"; do
    [[ -e "${file}" ]] || missing+=("${file}")
  done

  [[ ${#missing[@]} -eq 0 ]] ||
    die "No usable certificate: missing ${missing[*]}. Run ca/ca-install-all.sh first."
}

# Discovered values only; everything fixed lives in docker-compose.yml and the
# committed vault.hcl (3.1-2). Overwrites, so a re-run corrects a stale address.
render_config() {
  local cloudbr0_ip
  cloudbr0_ip="$(bridge_ip)"

  printf 'CLOUDBR0_IP=%s\n' "${cloudbr0_ip}" >"${SOURCE_SCRIPT}/.env"

  log "Vault will publish on ${cloudbr0_ip}:8200; wrote .env"
}

# --- Step 2 · The container ---------------------------------------------------

# Ownership before the container: Docker creates a missing bind-mount source as
# root, so a compose up first is a failure to repair rather than prevent.
start_vault() {
  # 0400: nothing but the container can be 65100, so the narrowest mode is free.
  # Certificates stay 0444 as issue-leaf.sh wrote them — they are public.
  chown "${VAULT_UID}:${VAULT_GID}" "${LEAF_KEY}"
  chmod 0400 "${LEAF_KEY}"

  # Vault's own state, so Vault owns it.
  mkdir -p "${DATA_DIR}"
  chown "${VAULT_UID}:${VAULT_GID}" "${DATA_DIR}"
  chmod 0700 "${DATA_DIR}"

  # Root only, and created before step 3 writes the one unrepeatable credential
  # here. mkdir alone would leave it at the umask.
  mkdir -p "${SECRETS_DIR}"
  chown root:root "${SECRETS_DIR}"
  chmod 0700 "${SECRETS_DIR}"

  # --remove-orphans: a renamed service otherwise holds 8200, and the bind error
  # reads like something else is installed.
  log "Starting Vault..."
  docker compose -f "${COMPOSE}" up -d --remove-orphans

  wait_for_vault
}

# `compose up -d` returns when the process starts, not when it listens.
#
# Any status counts — 501 uninitialised and 503 sealed are what init and unseal
# need to find, hence no --fail. --resolve because the cert's only SAN is a name;
# the bridge rather than loopback because 3.1-2 pinned the publish there.
wait_for_vault() {
  local bridge code i
  bridge="$(bridge_ip)"

  log "Waiting for Vault to answer on ${bridge}:8200..."

  for ((i = 0; i < 60; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      --cacert "${LEAF_CA}" \
      --resolve "vault.lab.test:8200:${bridge}" \
      "https://vault.lab.test:8200/v1/sys/health")" || true

    # 000 is curl's placeholder when no connection was made at all.
    if [[ "${code}" != "000" ]]; then
      log "Vault is answering (HTTP ${code})."
      return 0
    fi
    sleep 1
  done

  # The answer is almost always in the container's own log, and the likeliest
  # cause right now is Vault unable to read tls.key — it dies loading its
  # listener. Printing the log here saves the round trip a "check the logs"
  # message would cost.
  warn "Last lines from the container:"
  docker logs vault --tail 20 2>&1 | sed 's/^/    /' >&2 || true
  die "Vault did not answer on ${bridge}:8200 within 60s. See the log above."
}

# --- Step 3 · Initialisation, which happens exactly once ----------------------

# Four states, from cross-checking Vault against disk: an emptied storage
# directory makes Vault report "uninitialised" exactly as a fresh one does.
init_vault() {
  local bridge response

  bridge="$(bridge_ip)"

  # 501 is "not initialised"; anything else means it is. Tested negatively
  # because a re-run after a working install answers 200.
  response="$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "${LEAF_CA}" \
    --resolve "vault.lab.test:8200:${bridge}" \
    "https://vault.lab.test:8200/v1/sys/health")" || true

  # Storage was destroyed under a Vault that existed. Re-minting is made a thing
  # you choose rather than one that happens.
  if [[ "${response}" == "501" && -e "${INIT_FILE}" ]]; then
    die "${DATA_DIR} was emptied but ${INIT_FILE} remains — that Vault's data is gone. To mint a new one:  sudo rm -f ${INIT_FILE}"
  fi

  # Works now; comes back sealed with nothing to open it. No repair exists.
  if [[ "${response}" != "501" && ! -e "${INIT_FILE}" ]]; then
    die "Vault is initialised but ${INIT_FILE} is gone — it cannot survive a restart. To start over:  docker compose -f ${COMPOSE} down && sudo rm -rf ${DATA_DIR}"
  fi

  # return, not exit: it is initialised but SEALED, and unseal_vault must run.
  if [[ "${response}" != "501" ]]; then
    log "Vault is already initialised; leaving it alone."
    return 0
  fi

  log "Initialising Vault. This happens once and cannot be repeated."

  # -T or Compose allocates a TTY and the JSON arrives with control bytes jq
  # rejects and cat hides. 1/1 is the degenerate case of Shamir, not threshold
  # cryptography. umask because `>` creates the file before the command writes.
  (
    umask 077
    docker compose -f "${COMPOSE}" exec -T vault \
      vault operator init -key-shares=1 -key-threshold=1 -format=json \
      >"${INIT_FILE}"
  ) || die "operator init failed."

  chmod 0400 "${INIT_FILE}"

  # Cannot be repeated: once init returned Vault was initialised, and a
  # truncated redirect means the unseal key exists nowhere.
  jq -e '.unseal_keys_b64[0] and .root_token' "${INIT_FILE}" >/dev/null 2>&1 ||
    die "${INIT_FILE} lacks the unseal key or root token, and Vault is initialised — the only path is a fresh init."

  # The path, never the contents: L-1 puts this stdout in /var/log permanently.
  log "Vault initialised. Unseal key and root token: ${INIT_FILE} (the only copy)."
}

# --- Step 4 · Unseal -----------------------------------------------------------

# Delegated to vault-unseal.sh (3.1-4): the same command has to work after a
# reboot and in a drill, not only during an install.
unseal_vault() {
  local unsealer="${SOURCE_SCRIPT}/vault-unseal.sh"
  [[ -x "${unsealer}" ]] || die "Missing or not executable: ${unsealer}"
  "${unsealer}"
}

# --- Step 5 · Prove it ----------------------------------------------------------

# By hand for now. Unlike every other probe here it takes NO --resolve and NO
# --cacert, and both absences are the test: the name must come from CoreDNS, and
# the root must already be in the host trust store (Phase 2.6).
#
# Read the failure — curl exit 6 is resolution, 7 the connection, 60 trust, and
# 0 still leaves "is it sealed", which a valid connection answers 503 to.
# Automate when 2.6 lands and the first command is expected to pass.
verify_vault() {
  log "Vault is up. Verify by hand:"
  log "  curl https://vault.lab.test:8200/v1/sys/seal-status"
  log "    -> expects sealed:false with no -k and no --cacert. Exit 60 means the"
  log "       root is not yet in the host trust store, which is Phase 2.6."
  log "  curl --cacert ${LEAF_CA} https://vault.lab.test:8200/v1/sys/seal-status"
  log "    -> the same check until 2.6 exists; failing this one is a real fault."
}

# Run every step, in dependency order.
main() {
  require_root
  require_leaf
  render_config
  start_vault
  init_vault
  unseal_vault
  verify_vault
}

main "$@"
