#!/usr/bin/env bash
#
# vault-pki.sh
#
#

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_SCRIPT}/../../.." && pwd)"

# ---------------------- IMPORT -----------------------------------
# shellcheck source=../../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh" || {
    printf '\033[1;31m[x]\033[0m cannot source %s/lib/common.sh\n' "${REPO_ROOT}" >&2
    exit 1
}

# shellcheck source=vault-env.sh
source "${SOURCE_SCRIPT}/vault-env.sh" || {
    printf '\033[1;31m[x]\033[0m cannot source %s/vault-env.sh\n' "${SOURCE_SCRIPT}" >&2
    exit 1
}

# ------------------------ CONFIGURE PKI ------------------------------

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

configure_pki_root() {
    log "Configuring root PKI..."

    local response

    if ! response="$(curl -fsS --max-time 10 \
        --cacert "${CA_CRT}" \
        --resolve "${VAULT_HOST}:${VAULT_PORT}:${CLOUDBR0_IP}" \
        --header "X-Vault-Token: ${TOKEN}" \
        "${VAULT_API}/v1/pki/ca/pem")"; then
        die "Could not read the root CA from pki/."
    fi

    case "$response" in
        "")
            log "No root yet. Generating it..."
            create_pki_root
            ;;
        *"BEGIN CERTIFICATE"*)
            log "Root CA already exists at pki/."
            ;;
        *)
            die "Unexpected response from pki/ca/pem. Refusing to generate a root."
            ;;
    esac
}

create_pki_root() {
    log "Generating root CA..."

    local response

    if ! response="$(curl -fsS --max-time 10 \
        --cacert "${CA_CRT}" \
        --resolve "${VAULT_HOST}:${VAULT_PORT}:${CLOUDBR0_IP}" \
        --header "X-Vault-Token: ${TOKEN}" \
        --header "Content-Type: application/json" \
        --request POST \
        --data '{
            "common_name": "SingleClusterIaCLab Root CA",
            "ttl": "87600h",
            "key_type": "rsa",
            "key_bits": 4096,
            "issuer_name": "lab-root"
        }' \
        "${VAULT_API}/v1/pki/root/generate/internal")"; then
        die "Could not create the root CA."
    fi

    log "Root CA created: serial $(jq -r '.data.serial_number' <<<"$response")"
}

configure_pki_urls() {
    log "Configuring PKI URLs..."

    local body

    body="$(jq -n \
        --arg ca "${VAULT_API}/v1/pki/ca" \
        --arg crl "${VAULT_API}/v1/pki/crl" \
        '{issuing_certificates: [$ca], crl_distribution_points: [$crl]}')"

    curl -fsS -o /dev/null --max-time 10 \
        --cacert "${CA_CRT}" \
        --resolve "${VAULT_HOST}:${VAULT_PORT}:${CLOUDBR0_IP}" \
        --header "X-Vault-Token: ${TOKEN}" \
        --header "Content-Type: application/json" \
        --request POST \
        --data "$body" \
        "${VAULT_API}/v1/pki/config/urls" ||
        die "Could not configure PKI URLs"

    log "PKI issuing and CRL URLs configured"    
}

configure_pki_role() {
    log "Configuring lab-server PKI role..."

    # ttl equals max_ttl deliberately: the lab is short-lived, so nothing
    # should expire mid-run whether or not a caller passes a ttl. A
    # persistent deployment would keep the default well below the ceiling
    # and make a long-lived certificate a deliberate request.

    curl -fsS -o /dev/null --max-time 10 \
        --cacert "${CA_CRT}" \
        --resolve "${VAULT_HOST}:${VAULT_PORT}:${CLOUDBR0_IP}" \
        --header "X-Vault-Token: ${TOKEN}" \
        --header "Content-Type: application/json" \
        --request POST \
        --data '{
            "issuer_ref": "lab-root",
            "allowed_domains": ["lab.test"],
            "allow_subdomains": true,
            "allow_bare_domains": false,
            "allow_wildcard_certificates": false,
            "allow_localhost": false,
            "allow_ip_sans": false,
            "ttl": "720h",
            "max_ttl": "720h"
        }' \
        "${VAULT_API}/v1/pki/roles/lab-server" ||
        die "Could not configure lab-server PKI role."

    log "PKI role lab-server configured."
}

main () {
    TOKEN="$(jq -r '.root_token' "${INIT_FILE}")"
    [[ -n "${TOKEN}" && "${TOKEN}" != null ]] || \
        die "Token is missing"

    CLOUDBR0_IP="$(get_cloudbr0_ip)"

    configure_pki_mount
    configure_pki_root
    configure_pki_urls
    configure_pki_role
}

main "$@"