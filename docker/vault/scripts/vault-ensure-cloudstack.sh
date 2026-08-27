#!/usr/bin/env bash
#
# vault-ensure-cloudstack.sh — CloudStack's three identities, all held in Vault.
#
# Usage: sudo ./vault-ensure-cloudstack.sh
#
#   admin         break-glass. Enabled, off its shipped default, used by nothing.
#   admin-api     admin's API key, for this lab's own scripts.
#   svc-terraform automation's own account, so Terraform never authenticates as
#                 admin (7.1's consumer, created now).
#
# The split mirrors the AWS root/admin discipline: the identity you cannot afford
# to lose is not the identity you work as. CloudStack's admin is not structurally
# special the way AWS root is — it can be disabled, re-roled, deleted — so the
# discipline transfers but the reasoning does not.
#
# Every step is `ensure` (3.6): create if absent, leave alone if present, NEVER
# rotate silently. Rotation is unsafe as a default because some consumers read a
# credential once at initialisation and never again, so regenerating
# desynchronises two systems in a way that surfaces much later as an unexplained
# 401.
#
# One script rather than three because the three share cmk setup, the admin
# password lookup, and a mandatory ordering that nothing enforced while they were
# separate. Runs as root: cmk resolves its profile from $HOME and offers no
# per-invocation override, so every caller must agree on one profile (1.2-1).

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Captured before the sources below, because sourcing another of this repo's
# scripts CLOBBERS SOURCE_SCRIPT: cloudmonkey-install.sh sets it from its own
# BASH_SOURCE[0], so every path defined after that would resolve under
# cloudstack/scripts/. The symptom is a die naming a path that never existed.
VAULT_DIR="${SOURCE_SCRIPT}/.."

# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/vault.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../cloudstack/scripts/cloudmonkey-install.sh"

# KV v2, so the CLI path is secret/cloudstack/admin and the API path — the one a
# policy must name — is secret/data/cloudstack/admin (3.2).
ADMIN_PATH="secret/cloudstack/admin"
API_PATH="secret/cloudstack/admin-api"
SVC_PATH="secret/cloudstack/svc-terraform"

ADMIN_USER="admin"
SVC_USER="svc-terraform"

# Root Admin for now, narrowed at 7.1. Scoping before the consumer exists means
# guessing which APIs Terraform calls, and being wrong surfaces part-way through
# an apply. Named here per 0.2-8 rather than left looking unconsidered. What the
# separate account buys today is not privilege separation — both are Root Admin —
# but that automation is never configured with admin's key in the first place.
SVC_ROLE="Root Admin"

# Set only by ensure_admin_password, cleaned up unconditionally. The trap is at
# file scope rather than inside the function because a RETURN trap set inside a
# function is global in bash and fires again on the next function's return.
COOKIE_JAR=""
trap '[[ -n "${COOKIE_JAR}" ]] && rm -f "${COOKIE_JAR}"' EXIT

# --- admin-api ---------------------------------------------------------------

stored_key() { vault_field "${API_PATH}" api_key; }

# What CloudStack holds right now. Read-only: getUserKeys, never registerUserKeys.
live_key() {
  cmk -o json get userkeys id="$(admin_user_id)" 2>/dev/null | jq -r '.userkeys.apikey // empty'
}

# Four states, and only one is "do nothing". The last is the one 3.6 spends a
# paragraph on: admin is recreated whenever CloudStack's database is redeployed,
# invalidating the stored key while Vault goes on serving it. A non-rotating
# script must not fix that by rotating — it cannot tell a rebuild from a key
# someone else still uses. So it refuses, and names the reseed path.
ensure_api_key() {
  local stored live
  stored="$(stored_key)"
  live="$(live_key)"

  if [[ -z "${stored}" ]]; then
    log "${API_PATH} is absent; seeding from CloudStack"
    ensure_cloudstack_api_keys

    # The URL travels with the credential deliberately: a consumer needs both,
    # and the address is discovered from the bridge. Leaving it out would mean
    # every consumer rediscovering it, or hardcoding it.
    vault_ kv put "${API_PATH}" \
      url="${CLOUDSTACK_URL}" \
      api_key="${CLOUDSTACK_API_KEY}" \
      secret_key="${CLOUDSTACK_SECRET_KEY}" >/dev/null ||
      die "Could not write ${API_PATH} to Vault."
  elif [[ "${stored}" == "${live}" ]]; then
    log "${API_PATH} already matches CloudStack; leaving it alone"
    return 0
  else
    die "${API_PATH} holds a key CloudStack no longer accepts — its database was probably redeployed. Vault will keep serving the stale key and every consumer will fail with a 401 that does not say why. To reseed deliberately:  vault kv delete ${API_PATH}  then re-run."
  fi

  # Prove the round trip rather than the write.
  local back
  back="$(stored_key)"
  [[ -n "${back}" && "${back}" == "$(live_key)" ]] ||
    die "Read-back from ${API_PATH} does not match CloudStack's current key."
  log "Seeded and verified ${API_PATH}"
}

# --- svc-terraform -----------------------------------------------------------

# listall=true is not optional. `list users` defaults to the CALLER's account
# even for Root Admin, and this user lives in its own account — without it the
# lookup returns nothing for a user that plainly exists.
svc_user_id() {
  cmk -o json list users username="${SVC_USER}" listall=true 2>/dev/null | jq -r '.user[0].id // empty'
}

# Capture before minting, as cloudmonkey-install.sh does: on a retry after a
# partial failure, capture is what stops a second registration invalidating keys
# the first attempt already handed out.
svc_keys() {
  local uid="$1" keys
  keys="$(cmk -o json get userkeys id="${uid}" 2>/dev/null)" || keys=""
  SVC_API_KEY="$(jq -r '.userkeys.apikey // empty' <<<"${keys}" 2>/dev/null)"
  SVC_SECRET_KEY="$(jq -r '.userkeys.secretkey // empty' <<<"${keys}" 2>/dev/null)"

  if [[ -z "${SVC_API_KEY}" ]]; then
    warn "Registering API keys for '${SVC_USER}' — it has none yet."
    keys="$(cmk -o json register userkeys id="${uid}")" || die "register userkeys failed for ${SVC_USER}."
    SVC_API_KEY="$(jq -r '.userkeys.apikey // empty' <<<"${keys}")"
    SVC_SECRET_KEY="$(jq -r '.userkeys.secretkey // empty' <<<"${keys}")"
  fi
  [[ -n "${SVC_API_KEY}" && -n "${SVC_SECRET_KEY}" ]] || die "Could not obtain API keys for ${SVC_USER}."
}

# createAccount, not createUser. The ROLE lives on the account, and so does
# resource ownership and event-log attribution — a user created inside the admin
# account is a second key to the same identity, not a separate one.
ensure_svc_account() {
  if [[ -n "$(vault_field "${SVC_PATH}" api_key)" ]]; then
    log "${SVC_PATH} already present; ${SVC_USER} has its own credentials"
    return 0
  fi

  local roleid uid pass
  roleid="$(cmk -o json list roles name="${SVC_ROLE}" 2>/dev/null | jq -r '.role[0].id // empty')"
  [[ -n "${roleid}" ]] || die "No CloudStack role named '${SVC_ROLE}'."

  uid="$(svc_user_id)"
  if [[ -z "${uid}" ]]; then
    pass="$(new_password)"
    # Vault first: a password that exists only in this shell is one a failed
    # write loses for good.
    vault_ kv put "${SVC_PATH}" username="${SVC_USER}" password="${pass}" >/dev/null ||
      die "Could not write ${SVC_PATH}; CloudStack is unchanged."

    cmk create account username="${SVC_USER}" password="${pass}" \
      firstname=terraform lastname=service email="${SVC_USER}@lab.test" \
      accounttype=1 roleid="${roleid}" >/dev/null ||
      die "createAccount failed. ${SVC_PATH} holds a password for an account that does not exist. Recover with:  vault kv delete ${SVC_PATH}  then re-run."
    log "Created CloudStack account '${SVC_USER}' with role ${SVC_ROLE}"

    uid="$(svc_user_id)"
    [[ -n "${uid}" ]] || die "createAccount reported success but ${SVC_USER} does not exist."
  else
    log "CloudStack account '${SVC_USER}' already exists; capturing its keys"
  fi

  svc_keys "${uid}"

  vault_ kv patch "${SVC_PATH}" \
    url="${CLOUDSTACK_URL}" api_key="${SVC_API_KEY}" secret_key="${SVC_SECRET_KEY}" >/dev/null ||
    die "Could not write ${SVC_USER}'s API keys to ${SVC_PATH}."

  log "Stored ${SVC_USER} credentials at ${SVC_PATH}"
}

# --- admin password ----------------------------------------------------------

# Log in and print the session key, or nothing. Credentials go in the request
# BODY via --data @-, never in argv where ps shows them (2.3-5) — the same reason
# vault-unseal.sh uses the API rather than the CLI.
cs_login() {
  printf 'command=login&username=%s&password=%s&domain=/&response=json' "${ADMIN_USER}" "$1" |
    curl -s -c "${COOKIE_JAR}" --data @- "${CLOUDSTACK_URL}" |
    jq -r '.loginresponse.sessionkey // empty'
}

# A break-glass account at its factory default is not break-glass. That is the
# whole content of this step. admin stays ENABLED — it is the account for the day
# a service account is broken (14.5).
#
# Runs LAST: everything above authenticates cmk with this password, and cmk
# caches it in a profile written at cmk_configure time.
ensure_admin_password() {
  if [[ -n "$(vault_field "${ADMIN_PATH}" password)" ]]; then
    log "${ADMIN_PATH} already present; admin is off its default"
    return 0
  fi

  COOKIE_JAR="$(mktemp)" || die "Could not create a cookie jar."

  local session uid new
  session="$(cs_login "${CLOUDSTACK_ADMIN_PASS}")"
  [[ -n "${session}" ]] ||
    die "Could not log in as ${ADMIN_USER} with the expected current password. If it was changed by hand, re-run with CLOUDSTACK_ADMIN_PASS=<current>."

  uid="$(admin_user_id)"
  new="$(new_password)"

  # Vault FIRST, then CloudStack. The other order loses the password entirely if
  # the write fails — it would exist only in this shell, and the UI would be
  # locked. This order's failure is recoverable: Vault holds a password
  # CloudStack has not accepted yet, and the fix is a delete and a re-run.
  vault_ kv put "${ADMIN_PATH}" username="${ADMIN_USER}" password="${new}" >/dev/null ||
    die "Could not write ${ADMIN_PATH}; CloudStack is unchanged."

  printf 'command=updateUser&id=%s&password=%s&currentpassword=%s&response=json&sessionkey=%s' \
    "${uid}" "${new}" "${CLOUDSTACK_ADMIN_PASS}" "${session}" |
    curl -s -b "${COOKIE_JAR}" --data @- "${CLOUDSTACK_URL}" |
    jq -e '.updateuserresponse.user.username' >/dev/null 2>&1 ||
    die "updateUser failed. ${ADMIN_PATH} now holds a password CloudStack has not accepted. Recover with:  vault kv delete ${ADMIN_PATH}  then re-run."

  # Prove it, rather than trusting a 200.
  [[ -n "$(cs_login "${new}")" ]] ||
    die "CloudStack accepted updateUser but the new password does not log in. Recover with:  vault kv delete ${ADMIN_PATH}  then re-run."

  log "CloudStack admin password moved off the default and stored at ${ADMIN_PATH}"
}

main() {
  require_root
  vault_authenticate

  # Prefer Vault's copy, falling back to the shipped default so a fresh host
  # works before ensure_admin_password has ever run.
  CLOUDSTACK_ADMIN_PASS="$(vault_field "${ADMIN_PATH}" password)"
  [[ -n "${CLOUDSTACK_ADMIN_PASS}" ]] || CLOUDSTACK_ADMIN_PASS="password"
  export CLOUDSTACK_ADMIN_PASS

  cmk_configure

  ensure_api_key
  ensure_svc_account
  ensure_admin_password
}

main "$@"
