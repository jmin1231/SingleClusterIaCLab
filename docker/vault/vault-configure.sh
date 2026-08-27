#!/usr/bin/env bash
#
# vault-configure.sh — everything that must happen to a RUNNING Vault: the audit
# device, KV v2, and the PKI engine (3.2, 3.3, 3.4).
#
# Usage: sudo ./vault-configure.sh
#
set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
INIT_FILE="${SOURCE_SCRIPT}/secrets/vault-init.json"
ROOT_CRT="${SOURCE_SCRIPT}/../../ca/root/root-ca.crt"
SIGNER="${SOURCE_SCRIPT}/../../ca/scripts/sign-vault-intermediate.sh"

KV_PATH="secret"
PKI_PATH="pki"
AUDIT_PATH="file"
AUDIT_FILE="/vault/logs/audit.log"

# The subject the offline root will sign. Distinct from the openssl
# intermediate's "lab.test Issuing CA" — they are siblings under one root, and
# two CAs sharing a name are indistinguishable in every log and error message.
INT_CN="lab.test Vault Issuing CA"
INT_O="SingleClusterIaCLab"

# Ten years, matching root-ca.cnf's default_days. The mount's max_lease_ttl caps
# what it will issue, and the default is 32 days — which would silently truncate
# the intermediate at import.
PKI_MAX_TTL="87600h"

# The role is 0.2-8's "server-side enforcement of what may be issued" — the thing
# that replaces issue-leaf.sh's profile table. A caller asks for a name and a TTL;
# the role decides whether it may have them.
PKI_ROLE="lab-server"
PKI_ROLE_TTL="720h"
PKI_ROLE_MAX_TTL="720h"

# Vault serves both of these itself, so unlike most AIA fields they are reachable
# from inside the lab. Without them a client holding only a leaf cannot fetch the
# issuer, and revocation cannot be checked at all — which is what set-signed warns
# about when a mount has no AIA configured.
PKI_ISSUING_URL="https://vault.lab.test:8200/v1/pki/ca"
PKI_CRL_URL="https://vault.lab.test:8200/v1/pki/crl"

# --- Helpers ------------------------------------------------------------------

# -e VAULT_TOKEN with no value passes it through from the environment; writing
# -e VAULT_TOKEN=$TOKEN would put the token in argv, where ps shows it (2.3-5).
vault_() {
  docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault vault "$@"
}

mounted() {
  vault_ secrets list -format=json 2>/dev/null | jq -e --arg p "$1/" 'has($p)' >/dev/null
}

# --- Steps --------------------------------------------------------------------

# The root token is the only credential that exists at this point, which is the
# honest reason to use it and not a good one — 3.2's lesson is that a lab using
# only the root token has installed a very expensive text file. Every consumer
# after this gets a scoped token or an AppRole.
authenticate() {
  [[ -r "${INIT_FILE}" ]] ||
    die "Cannot read ${INIT_FILE}. Run vault-installer.sh first; bootstrap.sh runs it before this."

  VAULT_TOKEN="$(jq -r '.root_token // empty' "${INIT_FILE}")"
  [[ -n "${VAULT_TOKEN}" ]] || die "${INIT_FILE} holds no root_token."
  export VAULT_TOKEN

  vault_ status >/dev/null 2>&1 ||
    die "Vault is not answering, or is sealed. Run vault-unseal.sh."
}

# First, before anything worth reading is stored (3.3). Vault stops serving
# requests if it cannot write this file, so vault-installer.sh owns the
# directory's ownership — the image ships /vault/logs to its own uid.
ensure_audit() {
  if vault_ audit list -format=json 2>/dev/null | jq -e --arg p "${AUDIT_PATH}/" 'has($p)' >/dev/null; then
    log "Audit device already enabled"
    return 0
  fi
  vault_ audit enable -path="${AUDIT_PATH}" file file_path="${AUDIT_FILE}" ||
    die "Could not enable the audit device. If ${AUDIT_FILE} is not writable by the container, Vault will stop serving requests."
  log "Audit device enabled at ${AUDIT_FILE}"
}

ensure_kv() {
  if mounted "${KV_PATH}"; then
    log "KV v2 already mounted at ${KV_PATH}/"
    return 0
  fi
  vault_ secrets enable -path="${KV_PATH}" -version=2 kv
  log "KV v2 mounted at ${KV_PATH}/"
}

# The guard sign-vault-intermediate.sh asks its caller for: not "does the mount
# exist" but "is it a working CA under OUR root". A mount can exist with no
# issuer, and an issuer can exist that chains somewhere else — both would pass a
# weaker check and both leave the lab unable to issue a trusted certificate.
pki_provisioned() {
  local pem
  pem="$(vault_ read -field=certificate "${PKI_PATH}/cert/ca" 2>/dev/null)" || return 1
  [[ -n "${pem}" ]] || return 1
  openssl verify -CAfile "${ROOT_CRT}" <(printf '%s\n' "${pem}") >/dev/null 2>&1
}

ensure_pki() {
  mounted "${PKI_PATH}" ||
    vault_ secrets enable -path="${PKI_PATH}" -max-lease-ttl="${PKI_MAX_TTL}" pki

  if pki_provisioned; then
    log "PKI already provisioned; its issuer chains to the offline root"
    return 0
  fi

  [[ -x "${SIGNER}" ]] || die "Missing or not executable: ${SIGNER}"

  # Generate, sign, import — one pipeline, with the root key touched only in the
  # middle stage. The CSR never reaches disk here; the signer writes it to its
  # own workspace because openssl needs a path.
  #
  # append_root because set-signed stores whatever chain it is given, and a Vault
  # that can serve a complete chain means clients need only the root, not the
  # intermediate out of band.
  log "Provisioning the PKI engine: generate CSR, sign with the offline root, import"
  vault_ write -field=csr "${PKI_PATH}/intermediate/generate/internal" \
    common_name="${INT_CN}" organization="${INT_O}" \
    key_type=rsa key_bits=4096 |
    "${SIGNER}" |
    {
      cat
      cat "${ROOT_CRT}"
    } |
    vault_ write "${PKI_PATH}/intermediate/set-signed" certificate=- >/dev/null

  # Assert the outcome, not the exit codes: this is the one check that proves the
  # whole pipeline did what it claimed.
  pki_provisioned ||
    die "set-signed reported success but ${PKI_PATH}/cert/ca does not chain to ${ROOT_CRT}."

  log "PKI provisioned: $(vault_ read -field=certificate "${PKI_PATH}/cert/ca" 2>/dev/null |
    openssl x509 -noout -subject | sed 's/^subject=//')"
}

# No existence guard, unlike the mounts above: `vault write` overwrites, so this
# is already idempotent. `vault secrets enable` is not — it exits 2 with "path is
# already in use" — which is why those steps test first and these do not.
ensure_pki_urls() {
  vault_ write "${PKI_PATH}/config/urls" \
    issuing_certificates="${PKI_ISSUING_URL}" \
    crl_distribution_points="${PKI_CRL_URL}" >/dev/null
  log "PKI AIA URLs set"
}

# What this CA will and will not issue. Compare the openssl intermediate, whose
# equivalent rules live in ca/intermediate-ca.cnf and are enforced only because
# issue-leaf.sh chooses to pass them: here the rules are server-side, so a caller
# cannot ask for a name outside lab.test or a lifetime beyond the ceiling.
#
# 720h (30 days) against the openssl CA's 397 days. Deliberately NOT shorter:
# 3.4's lesson is that a CA as a service *can* issue short certificates, but the
# renewal that makes them safe is 3.5's job and does not exist yet. A 72h ceiling
# would mean the proxy's certificate expiring every three days until then — a
# self-imposed deadline, not a lesson. Shorten it at 3.5, once a timer is
# renewing and reloading without anyone watching.
#
# 2048-bit leaves, not the 4096 used for the CAs: a leaf is not a CA, 2048 is what
# public issuers actually hand out, and a short lifetime is the control that
# matters more than key size here.
ensure_pki_role() {
  vault_ write "${PKI_PATH}/roles/${PKI_ROLE}" \
    allowed_domains="lab.test" \
    allow_subdomains=true \
    allow_bare_domains=false \
    allow_localhost=false \
    allow_ip_sans=false \
    organization="${INT_O}" \
    key_type="rsa" key_bits=2048 \
    server_flag=true client_flag=false \
    key_usage="DigitalSignature,KeyEncipherment" \
    ext_key_usage="ServerAuth" \
    ttl="${PKI_ROLE_TTL}" max_ttl="${PKI_ROLE_MAX_TTL}" >/dev/null
  log "PKI role ${PKI_ROLE}: *.lab.test, ttl ${PKI_ROLE_TTL}, max ${PKI_ROLE_MAX_TTL}"
}

main() {
  require_root
  authenticate
  ensure_audit
  ensure_kv
  ensure_pki
  ensure_pki_urls
  ensure_pki_role
}

main "$@"
