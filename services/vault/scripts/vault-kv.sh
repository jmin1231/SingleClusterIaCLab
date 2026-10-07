#!/usr/bin/env bash
#
# vault-kv.sh
#   Mounts the KV v2 store the later phases write their credentials into.
#
#   Runs on its own against a Vault that is already up and unsealed.
#

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_SCRIPT}/../../.." && pwd)"

# ---------------------- IMPORT -----------------------------------
# shellcheck source=../../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

# shellcheck source=vault-env.sh
source "${SOURCE_SCRIPT}/vault-env.sh"

# ------------------------ CONFIGURE KV ---------------------------

configure_kv_mount() {
    log "Configuring kv mount..."

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
        jq -r '.data["secret/"].type // "missing"')" ||
        die "Could not parse Vault mounts."

    case "$mount_type" in
        kv)
            printf '%s' "$response" |
                jq -e '.data["secret/"].options.version == "2"' >/dev/null ||
                die "Expected kv v2 at secret/. Refusing to use it."

            log "KV v2 is already mounted at secret/."
            ;;
        missing)
            log "No mount exists at secret/. Creating it..."
            create_kv_mount
            ;;
        *)
            die "Expected a kv engine at secret/, found ${mount_type}. Refusing to configure it."
            ;;
    esac
}

create_kv_mount() {
    curl -fsS -o /dev/null --max-time 10 \
        --cacert "${CA_CRT}" \
        --resolve "${VAULT_HOST}:${VAULT_PORT}:${CLOUDBR0_IP}" \
        --header "X-Vault-Token: ${TOKEN}" \
        --header "Content-Type: application/json" \
        --request POST \
        --data '{
            "type": "kv",
            "options": {
                "version": "2"
            }
        }' \
        "${VAULT_API}/v1/sys/mounts/secret" ||
        die "Could not create the kv mount at secret/."

    log "KV v2 engine mounted at secret/."
}

main () {
    # The credentials file is root-owned and mode 0400, so say that plainly
    # rather than failing on a permission error three lines down.
    verify_root

    TOKEN="$(jq -r '.root_token' "${INIT_FILE}")"
    [[ -n "${TOKEN}" && "${TOKEN}" != null ]] || \
        die "Token is missing"

    CLOUDBR0_IP="$(get_cloudbr0_ip)"

    configure_kv_mount
}

main "$@"
