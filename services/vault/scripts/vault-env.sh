#!/usr/bin/env bash
#
# services/vault/scripts/vault-env.sh
#   Paths and constants for the Vault service.
#
#   Sourced by ../vault-installer.sh and by its siblings in this directory.
#
#   The service root is THIS file's parent, not the caller's directory, so
#   every consumer resolves the same paths no matter where it sits.
#

# Every name here is consumed by the scripts that source this file, so a
# standalone check finds no use for any of them.
# shellcheck disable=SC2034

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '\033[1;31m[x]\033[0m %s is a library - source it, do not run it\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 1
fi

VAULT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

COMPOSE_FILE="${VAULT_DIR}/docker-compose.yml"
CONFIG_DIR="${VAULT_DIR}/config"
CERT_DIR="${VAULT_DIR}/certs"
DATA_DIR="${VAULT_DIR}/data"
LOGS_DIR="${VAULT_DIR}/logs"
ENV_FILE="${VAULT_DIR}/.env"

# Served to clients (bundle.crt); verified against (ca.crt). Two jobs.
CA_CRT="${CERT_DIR}/ca.crt"
BUNDLE_CRT="${CERT_DIR}/bundle.crt"
TLS_CRT="${CERT_DIR}/tls.crt"
TLS_KEY="${CERT_DIR}/tls.key"

# The name on the certificate, so every caller agrees with what is served.
# --resolve is built at call time: it needs CLOUDBR0_IP, discovered in main.
VAULT_HOST="vault.lab.test"
VAULT_PORT=8200
VAULT_API="https://${VAULT_HOST}:${VAULT_PORT}"

# Unseal key and root token. Written once by the installer, mode 0400.
INIT_FILE="${VAULT_DIR}/vault-init.json"

# Pinned high so no Ubuntu package can claim it and read Vault's data.
VAULT_UID=65100
VAULT_GID=65100
