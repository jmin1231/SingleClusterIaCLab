#!/usr/bin/env bash
#
# vault-ensure-cloudstack-svc.sh — a CloudStack identity for automation, so
# Terraform never authenticates as admin (7.1's consumer, created now).
#
# Usage: sudo ./vault-ensure-cloudstack-svc.sh
#
# createAccount, not createUser. The ROLE lives on the account, not the user, and
# so does resource ownership and event-log attribution — a user created inside
# the admin account is a second key to the same identity, not a separate one.
#
# Root Admin for now, narrowed at 7.1. Scoping the role before the consumer
# exists means guessing which APIs Terraform calls, and being wrong surfaces as a
# permission failure part-way through an apply. Named here per 0.2-8 rather than
# left looking like nobody considered least privilege.
#
# What this buys today is not privilege separation — admin and this account are
# both Root Admin. It is that automation never gets configured with admin's key
# in the first place, because that is the thing nobody goes back and changes.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/vault.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../cloudstack/scripts/cloudmonkey-install.sh"

SVC_PATH="secret/cloudstack/svc-terraform"
ADMIN_PATH="secret/cloudstack/admin"
SVC_USER="svc-terraform"
SVC_ROLE="Root Admin"

# listall=true is not optional. `list users` defaults to the CALLER's account
# even for Root Admin, and this user lives in its own account — so without it the
# lookup returns nothing for a user that plainly exists, and the script concludes
# createAccount lied.
svc_user_id() {
  cmk -o json list users username="${SVC_USER}" listall=true 2>/dev/null | jq -r '.user[0].id // empty'
}

# Reuses cloudmonkey-install.sh's discipline: read the keys the account already
# has before minting new ones. On a first run there are none and register is
# correct; on a retry after a partial failure, capture is what stops a second
# registration invalidating keys the first attempt may already have handed out.
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

main() {
  require_root
  vault_authenticate

  if [[ -n "$(vault_field "${SVC_PATH}" api_key)" ]]; then
    log "${SVC_PATH} already present; ${SVC_USER} has its own credentials"
    return 0
  fi

  # cmk authenticates as admin to do the creating. Vault's password, falling
  # back to the shipped default on a host where the rotation has not run.
  CLOUDSTACK_ADMIN_PASS="$(vault_field "${ADMIN_PATH}" password)"
  [[ -n "${CLOUDSTACK_ADMIN_PASS}" ]] || CLOUDSTACK_ADMIN_PASS="password"
  export CLOUDSTACK_ADMIN_PASS
  cmk_configure

  local roleid uid pass
  roleid="$(cmk -o json list roles name="${SVC_ROLE}" 2>/dev/null | jq -r '.role[0].id // empty')"
  [[ -n "${roleid}" ]] || die "No CloudStack role named '${SVC_ROLE}'."

  uid="$(svc_user_id)"
  if [[ -z "${uid}" ]]; then
    pass="$(new_password)"
    # Vault first, as with the admin rotation: a password that exists only in
    # this shell is one a failed write loses for good.
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

main "$@"
