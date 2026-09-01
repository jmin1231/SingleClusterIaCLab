#!/usr/bin/env bash
#
# vault.sh — talking to the lab's Vault. SOURCE this, never execute it — hence
# not +x. Requires lib/common.sh to have been sourced first, for die().
#
# Separate from common.sh because not every script talks to Vault: ca/scripts/
# and cloudstack/scripts/ never do, and a helper they cannot use does not belong
# in the file they all source.
#
# Factored out at the sixth caller. Four of the six had drifted apart —
# gitea-installer.sh and proxy-installer.sh had no `vault status` check, so a
# sealed Vault produced empty reads and an error naming the wrong script. That
# is 0.2-5's second trigger, the one about guard logic needing to change in more
# than one place at once, rather than the count.

# Located from THIS file, not from the caller. The six callers sit at four
# different depths and each carried its own relative path to the same compose
# file; one moved directory would have broken them one at a time. Overridable so
# a test can point at something else.
_VAULT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VAULT_COMPOSE="${VAULT_COMPOSE:-${_VAULT_LIB_DIR}/../docker/vault/docker-compose.yml}"
VAULT_INIT="${VAULT_INIT:-${_VAULT_LIB_DIR}/../docker/vault/secrets/vault-init.json}"

# Run a vault command inside the container.
#
# -e VAULT_TOKEN with NO value passes it through from the environment; writing
# -e VAULT_TOKEN=$TOKEN would put the token in argv, where ps shows it to every
# user on the host (2.3-5).
vault_() {
  docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault vault "$@"
}

# Export VAULT_TOKEN from the init file, and prove Vault will answer.
#
# The status check is the part that had gone missing in two callers. Without it
# every later `kv get` returns empty and the caller blames a missing secret —
# sending you to seed something that is already there, when the real answer is
# to unseal.
vault_authenticate() {
  [[ -r "${VAULT_INIT}" ]] ||
    die "Cannot read ${VAULT_INIT}. Run docker/vault/vault-installer.sh first; bootstrap.sh runs it before this."

  VAULT_TOKEN="$(jq -r '.root_token // empty' "${VAULT_INIT}")"
  [[ -n "${VAULT_TOKEN}" ]] || die "${VAULT_INIT} holds no root_token."
  export VAULT_TOKEN

  vault_ status >/dev/null 2>&1 ||
    die "Vault is not answering, or is sealed. Run docker/vault/scripts/vault-unseal.sh."
}

# Print one field of a KV v2 secret, or nothing. Absence is not an error: it is
# the first-run state every ensure script tests for.
vault_field() {
  vault_ kv get -field="$2" "$1" 2>/dev/null || true
}

# Reissue when fewer than this many seconds remain. 7 days against the PKI role's
# 30-day ceiling: enough slack that a re-run inside the window is a no-op, and
# enough margin that a lab left alone for a week still comes back working.
CERT_RENEW_BEFORE="${CERT_RENEW_BEFORE:-$((7 * 24 * 3600))}"

# Is this certificate one we can keep using? Present is NOT usable: it can exist
# and be expired, or be for the wrong name. Checked rather than assumed, so a
# re-run repairs rather than trusting whatever is on disk.
#
# Paths are explicit rather than derived from the CN, because the two callers
# disagree on filenames — proxy-installer.sh names them after the vhost, and
# MinIO mandates public.crt/private.key.
#
# Like new_password() below, not strictly a Vault operation. It lives here
# because both callers exist to decide whether to call pki/issue, and it is
# guard logic — which is 0.2-5's second factoring trigger, the one about logic
# that must change in more than one place at once rather than about the count.
# Move it to common.sh if a caller appears that never talks to Vault.
cert_usable() {
  local crt="$1" key="$2" cn="$3" window="${4:-${CERT_RENEW_BEFORE}}"

  [[ -s "${crt}" && -s "${key}" ]] || return 1
  openssl x509 -in "${crt}" -noout -checkend "${window}" >/dev/null 2>&1 || return 1
  openssl x509 -in "${crt}" -noout -checkhost "${cn}" >/dev/null 2>&1
}

# A password to put IN Vault. Not strictly a Vault operation, but every caller is
# a vault-ensure-* script and the encoding choice below is driven by how
# Vault-stored values get consumed — move it to common.sh if that stops being
# true.
#
# hex, not base64: these values end up in PostgreSQL connection strings, URL
# form bodies and environment variables, and base64's + and / are meaningful in
# all three. The default 24 bytes is 48 hex characters, 192 bits — far past
# anything that matters here, and short enough to paste.
new_password() {
  openssl rand -hex "${1:-24}"
}
