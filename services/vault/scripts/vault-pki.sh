#!/usr/bin/env bash
#
# vault-pki.sh
#
#

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_SCRIPT}/../../.." && pwd)"
source "${REPO_ROOT}/lib/common.sh"
source "${SOURCE_SCRIPT}/vault-env.sh"

configure_pki_mount() {
    log "Configuring pki mount..."

    local response
    local mount_type

    if ! response="$(curl -fsS --max-time 10 \
        --cacert "${CA_CRT}" \
        --resolve "${VAULT_HOST}:${VAULT_PORT}:${CLOUDBR0_IP}" \
        --header "X-Vault-Token: ${TOKEN}" \
        "${VAULT_API}/v1/sys/mounts")"; then
        die "Could not list Vault mounts."
    fi

    mount_type="$(printf '%s' "$response" |
        jq -r '.data["pki/"].type // "missing"')" ||
        die "Could not parse Vault mounts."
    
    case "$mount_type" in
        pki)
            log "PKI is already mounted at pki/."
            ;;
        missing)
            log "No mount exists at pki/. Creating it..."
            create_pki_mount
            ;;
        *)
            die "Expected a pki engine at pki/, found ${mount_type}. Refusing to configure it."
            ;;
    esac
}

create_pki_mount() {
    curl -fsS --max-time 10 \
        --cacert "${CA_CRT}" \
        --resolve "${VAULT_HOST}:${VAULT_PORT}:${CLOUDBR0_IP}" \
        --header "X-Vault-Token: ${TOKEN}" \
        --header "Content-Type: application/json" \
        --request POST \
        --data '{
            "type": "pki",
            "config": {
                "max_lease_ttl": "87600h"
            }
        }' \
        "${VAULT_API}/v1/sys/mounts/pki" ||
        die "Could not create the pki mount at pki/."

    log "PKI engine mounted at pki/."
}

main () {
    TOKEN="$(jq -r '.root_token' "${INIT_FILE}")"
    [[ -n "${TOKEN}" && "${TOKEN}" != null ]] || \
        die "Token is missing"

    CLOUDBR0_IP="$(get_cloudbr0_ip)"

    configure_pki_mount
}

main "$@"