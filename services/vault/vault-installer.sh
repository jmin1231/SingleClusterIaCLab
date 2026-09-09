#!/usr/bin/env bash
#
#   vault-installer.sh
#       Install vault container
#

set -euo pipefail

log() { printf '\033[1;36m[+]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SOURCE_SCRIPT}/docker-compose.yml"
CERT_DIR="${SOURCE_SCRIPT}/certs"
DATA_DIR="${SOURCE_SCRIPT}/data"
LOGS_DIR="${SOURCE_SCRIPT}/logs"

VAULT_UID=65100
VAULT_GID=65100

generate_cert() {
    if [[ -f "${CERT_DIR}/tls.crt" && -f "${CERT_DIR}/tls.key" ]]; then
        log "Certificate already present"
        return 0
    fi

    log "No certificate yet - generating a self-signed certificate"

    openssl req \
        -x509 \
        -newkey rsa:2048 \
        -noenc \
        -days 3650 \
        -subj "/O=SingleClusterIaCLab/CN=vault.lab.test" \
        -addext "subjectAltName=DNS:vault.lab.test,DNS:localhost,IP:127.0.0.1" \
        -keyout "${CERT_DIR}/tls.key" \
        -out "${CERT_DIR}/tls.crt" 2>/dev/null

    cp "${CERT_DIR}/tls.crt" "${CERT_DIR}/bundle.crt"
    cp "${CERT_DIR}/tls.crt" "${CERT_DIR}/ca.crt"

    chown "${VAULT_UID}:${VAULT_GID}" \
        "${CERT_DIR}/tls.crt" \
        "${CERT_DIR}/bundle.crt" \
        "${CERT_DIR}/ca.crt" \
        "${CERT_DIR}/tls.key"

    chmod 0644 \
        "${CERT_DIR}/tls.crt" \
        "${CERT_DIR}/bundle.crt" \
        "${CERT_DIR}/ca.crt"

    chmod 0600 "${CERT_DIR}/tls.key"

    log "Vault TLS certificate generated"
}

create_bind_mounts() {
    log "Creating bind mounts..."

    install -d -o "${VAULT_UID}" -g "${VAULT_GID}" -m 0700 "${DATA_DIR}"
    install -d -o "${VAULT_UID}" -g "${VAULT_GID}" -m 0700 "${LOGS_DIR}"
    install -d -o "${VAULT_UID}" -g "${VAULT_GID}" -m 0700 "${CERT_DIR}"
}

main() {
    create_bind_mounts
    generate_cert
}

main "$@"