#!/usr/bin/env bash
#
# vault-ensure-cloudstack-admin.sh — move CloudStack's admin login off its
# shipped default and into Vault (3.6 pattern, applied to a break-glass account).
#
# Usage: sudo ./vault-ensure-cloudstack-admin.sh
#
# admin stays ENABLED and becomes break-glass: strong password in Vault, used by
# no automation, present for the day a service account is broken (14.5). That is
# the operational half of the AWS root-account discipline — the identity you
# cannot afford to lose is not the identity you work as. CloudStack's admin is
# not structurally special the way AWS root is (it can be disabled, re-roled,
# deleted), so the discipline transfers but the reasoning does not.
#
# A break-glass account at its factory default is not break-glass. That is the
# whole content of this script.
#
# Safe to re-run: a password already in Vault is never regenerated. This is a
# single deliberate move off a known default, not rotation (3.6).

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="${SOURCE_SCRIPT}/.."
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/vault.sh"

ADMIN_PATH="secret/cloudstack/admin"
ADMIN_USER="admin"

# What the password is BEFORE this runs. CloudStack ships 'password'; override if
# it has already been changed by hand.
CURRENT_PASS="${CLOUDSTACK_ADMIN_PASS:-password}"

COOKIE_JAR=""
API=""

# Log in and print the session key, or nothing. Credentials go in the request
# BODY via --data @-, never in argv where ps shows them (2.3-5) — the same reason
# vault-unseal.sh uses the API rather than the CLI.
cs_login() {
  local pass="$1"
  printf 'command=login&username=%s&password=%s&domain=/&response=json' "${ADMIN_USER}" "${pass}" |
    curl -s -c "${COOKIE_JAR}" --data @- "${API}" |
    jq -r '.loginresponse.sessionkey // empty'
}

main() {
  require_root
  vault_authenticate

  if [[ -n "$(vault_ kv get -field=password "${ADMIN_PATH}" 2>/dev/null || true)" ]]; then
    log "${ADMIN_PATH} already present; admin is off its default"
    return 0
  fi

  local session
  session="$(cs_login "${CURRENT_PASS}")"
  [[ -n "${session}" ]] ||
    die "Could not log in as ${ADMIN_USER} with the expected current password. If it was already changed by hand, re-run with CLOUDSTACK_ADMIN_PASS=<current>."

  local uid new
  uid="$(cmk -o json list users username="${ADMIN_USER}" | jq -r '.user[0].id')"
  [[ -n "${uid}" && "${uid}" != "null" ]] || die "Could not resolve the ${ADMIN_USER} user id."
  new="$(new_password)"

  # Vault FIRST, then CloudStack. The other order loses the password entirely if
  # the write fails — it would exist only in this shell, and the UI would be
  # locked (the API key still works, but that is a recovery path, not a plan).
  # This order's failure is recoverable: Vault holds a password CloudStack has
  # not accepted yet, and the fix is a delete and a re-run.
  vault_ kv put "${ADMIN_PATH}" username="${ADMIN_USER}" password="${new}" >/dev/null ||
    die "Could not write ${ADMIN_PATH}; CloudStack is unchanged."

  printf 'command=updateUser&id=%s&password=%s&currentpassword=%s&response=json&sessionkey=%s' \
    "${uid}" "${new}" "${CURRENT_PASS}" "${session}" |
    curl -s -b "${COOKIE_JAR}" --data @- "${API}" |
    jq -e '.updateuserresponse.user.username' >/dev/null 2>&1 ||
    die "updateUser failed. ${ADMIN_PATH} now holds a password CloudStack has not accepted. Recover with:  vault kv delete ${ADMIN_PATH}  then re-run."

  # Prove it, rather than trusting a 200: log in with the new password.
  [[ -n "$(cs_login "${new}")" ]] ||
    die "CloudStack accepted updateUser but the new password does not log in. Recover with:  vault kv delete ${ADMIN_PATH}  then re-run."

  log "CloudStack admin password moved off the default and stored at ${ADMIN_PATH}"
}

main "$@"
