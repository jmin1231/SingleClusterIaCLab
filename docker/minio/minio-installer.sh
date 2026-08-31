#!/usr/bin/env bash
#
# minio-installer.sh — issue MinIO's certificate from Vault, render its
# environment, and start it (5.1).
#
# Usage: sudo ./minio-installer.sh
#
# Runs after vault-ensure-minio.sh, which puts the root credential in Vault
# before this script reads it back. Ordering, not preference: 5.1 keeps the root
# keys off disk except where MinIO itself needs them.
#
# Safe to re-run: the certificate is reissued only when missing, unreadable or
# near expiry — the same test proxy-installer.sh uses.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/vault.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
CERT_DIR="${SOURCE_SCRIPT}/certs"
DATA_DIR="${SOURCE_SCRIPT}/data"
# MinIO mandates these two names and will not read anything else. Notably NOT
# the tls.crt/tls.key this repo uses elsewhere: that convention comes from
# kubernetes.io/tls, and MinIO predates caring about it. Get them wrong and MinIO
# does not fail — it silently generates its own self-signed pair.
CERT_FILE="${CERT_DIR}/public.crt"
KEY_FILE="${CERT_DIR}/private.key"
ENV_FILE="${SOURCE_SCRIPT}/.env"

PKI_ROLE="lab-server"
MINIO_NAME="minio.lab.test"
ROOT_PATH="secret/minio/root"

# NOT the image's own uid, for the reason 3.1-1 settles: Ubuntu allocates
# 100-999 at package-install time, so a number in that range means a different
# daemon on every host and can be claimed by a package installed LATER, after the
# chown has already succeeded and still looks correct.
#
# 65101 rather than Vault's 65100 — "the pattern, not the number" (3.1-1), so
# neither service can read the other's key material. Must match `user:` in
# docker-compose.yml; those are the only two places it may appear.
MINIO_UID=65101
MINIO_GID=65101

# --- Step 1 · Preflight -------------------------------------------------------

# Host-level inputs only, and deliberately BEFORE vault_authenticate in main():
# that function reaches Vault through `docker compose exec`, so on a host whose
# daemon is down it dies with "Vault is not answering, or is sealed" and sends
# you to vault-unseal.sh to fix a Docker problem. Checking here is what makes the
# message name the cause rather than the symptom (0.3-7).
#
# Nothing here creates, chowns or writes. A preflight with side effects cannot be
# re-run to ask a question, and every step after this one is expensive to unwind:
# issue_cert spends a Vault issuance, and `compose up` creates a missing bind
# mount source as ROOT, which is a failure to repair rather than prevent
# (vault-installer.sh:start_vault).
preflight() {
  command -v docker >/dev/null 2>&1 ||
    die "docker is not installed. bootstrap.sh installs it; see its docker step."
  docker info >/dev/null 2>&1 ||
    die "Cannot reach the Docker daemon. Is it running, and are you root?"

  [[ -f "${COMPOSE}" ]] || die "No compose file at ${COMPOSE}"

  # The uid must belong to nobody at all. If a real account owns it, the chown in
  # issue_cert hands that account read access to MinIO's private key — and the
  # chown SUCCEEDS, so nothing warns and the file still looks correctly owned.
  local claimed
  if claimed="$(getent passwd "${MINIO_UID}")"; then
    die "uid ${MINIO_UID} is already ${claimed%%:*}. Pick another reserved-range uid; see 3.1-1."
  fi
  if claimed="$(getent group "${MINIO_GID}")"; then
    die "gid ${MINIO_GID} is already ${claimed%%:*}. Pick another reserved-range gid; see 3.1-1."
  fi
}

# Named for what it requires, the way vault-installer.sh has require_leaf rather
# than a second preflight. Separate because it is the one input that needs
# vault_authenticate to have run first.
#
# Without it render_env writes empty values and compose's ${VAR:?} guards refuse
# — correctly, but with a message about a compose variable, which does not tell
# you which script to run.
require_root_secret() {
  [[ -n "$(vault_field "${ROOT_PATH}" password)" ]] ||
    die "${ROOT_PATH} is missing. Run docker/vault/scripts/vault-ensure-minio.sh first."
}

# One name, so no parameter and no issue_certs() wrapper — proxy-installer.sh
# takes a CN because it loops over five vhosts; this has exactly one, and it is
# already a constant.
issue_cert() {
  local json

  if cert_usable "${CERT_FILE}" "${KEY_FILE}" "${MINIO_NAME}"; then
    log "Certificate for ${MINIO_NAME} is current; not reissuing"
    return 0
  fi

  # Directory before the issuance, not after: a permissions problem here should
  # not cost a certificate that has already been minted.
  install -d -m 0755 "${CERT_DIR}"

  json="$(vault_ write -format=json "pki/issue/${PKI_ROLE}" common_name="${MINIO_NAME}" 2>/dev/null)" ||
    die "Vault would not issue for ${MINIO_NAME}. Is the ${PKI_ROLE} role present? Run docker/vault/scripts/vault-configure.sh."

  # Key first and restrictive: it must never exist world-readable, not even
  # briefly, so the umask is what protects the window before the chmod lands.
  (
    umask 077
    jq -r '.data.private_key' <<<"${json}" >"${KEY_FILE}"
  )
  # 3.1-1's second half: the key is written LOCKED, and the consumer's installer
  # is what opens it — to exactly one uid, never to a group. preflight has
  # already proved no account on this host is MINIO_UID.
  chown "${MINIO_UID}:${MINIO_GID}" "${KEY_FILE}"
  chmod 0400 "${KEY_FILE}"

  # Leaf + issuing CA, in that order: a client trusting only the root must be
  # able to build the path from what the server sends.
  #
  # Not chowned, deliberately: 0444 is public, so ownership grants nothing that
  # the mode has not already given away. Only the key needs an owner.
  jq -r '.data.certificate, .data.ca_chain[]' <<<"${json}" >"${CERT_FILE}"
  chmod 0444 "${CERT_FILE}"

  log "Issued ${MINIO_NAME}, valid until $(openssl x509 -in "${CERT_FILE}" -noout -enddate | cut -d= -f2)"
}

# Vault is the origin; MinIO is told what to use. Both fields travel the same
# path deliberately — hardcoding the username here would give it two sources of
# truth, and minio-provision.sh reads it back out of Vault to build its mc alias.
render_env() {
  local minio_user minio_pass

  minio_user="$(vault_field "${ROOT_PATH}" username)"
  minio_pass="$(vault_field "${ROOT_PATH}" password)"

  # require_root_secret already vouched for the password. The username is the
  # one nothing else checks, and the one that FAILS OPEN: unset, MinIO starts as
  # its built-in minioadmin while Vault records something else, and nothing errors.
  [[ -n "${minio_user}" && -n "${minio_pass}" ]] ||
    die "${ROOT_PATH} is missing or incomplete. Run docker/vault/scripts/vault-ensure-minio.sh."

  # umask inside the subshell, so the file is never world-readable in the window
  # between creation and the chmod below. 0600 matches docker/gitea/.env.
  (
    umask 077
    printf 'CLOUDBR0_IP=%s\nMINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' \
      "$(bridge_ip)" "${minio_user}" "${minio_pass}" >"${ENV_FILE}"
  )
  chmod 0600 "${ENV_FILE}"

  log "Rendered ${ENV_FILE} from Vault"
}

# Ownership BEFORE the container. Docker creates a missing bind-mount source as
# root, so a `compose up` first is a failure to repair rather than prevent —
# vault-installer.sh:start_vault learned this the same way.
start_minio() {
  mkdir -p "${DATA_DIR}"
  chown "${MINIO_UID}:${MINIO_GID}" "${DATA_DIR}"
  chmod 0700 "${DATA_DIR}"

  # --remove-orphans: a renamed service otherwise keeps 9000, and the bind error
  # reads as though something else is installed.
  log "Starting MinIO..."
  docker compose -f "${COMPOSE}" up -d --remove-orphans

  wait_for_minio
  verify_cert
}

# Deliberately --insecure, and deliberately separate from verify_cert. This asks
# ONE question: is the process listening? Validating the certificate here too
# would collapse two failures with two different fixes into one timeout message
# saying "did not become ready", which is exactly the symptom-not-cause trap
# 0.3-7 is about.
wait_for_minio() {
  local i
  log "Waiting for MinIO on ${MINIO_NAME}:9000..."
  for ((i = 0; i < 60; i++)); do
    if curl -fsS --insecure "https://${MINIO_NAME}:9000/minio/health/live" >/dev/null 2>&1; then
      log "MinIO is answering."
      return 0
    fi
    sleep 1
  done
  die "MinIO did not become ready in 60s. See: docker logs minio"
}


main() {
  require_root
  preflight
  vault_authenticate
  require_root_secret
  issue_cert
  render_env
  start_minio
}

main "$@"
