#!/usr/bin/env bash
#
# vault-ensure-cloudstack.sh — put CloudStack's API credentials in Vault, once,
# and leave them alone afterwards (3.6).
#
# Usage: sudo ./vault-ensure-cloudstack.sh
#
# The first `ensure`-shaped script, and the pattern every later secret follows:
# create if absent, leave alone if present, NEVER rotate silently. Rotation is
# not a safe default because some consumers read a credential once at
# initialisation and never again — regenerating desynchronises two systems in a
# way that surfaces much later as a 401 that says nothing about the cause.
#
# Runs as root: cmk resolves its profile from $HOME and offers no per-invocation
# override, so every caller must agree on one profile (1.2-1).

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Held separately, because sourcing another of this repo's scripts CLOBBERS
# SOURCE_SCRIPT: cloudmonkey-install.sh sets it from its own BASH_SOURCE[0], so
# every path defined after that source would resolve under cloudstack/scripts/.
# The symptom is a die naming a path that does not exist and never should have.
VAULT_DIR="${SOURCE_SCRIPT}/.."

# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/vault.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../cloudstack/scripts/cloudmonkey-install.sh"

# KV v2, so the CLI path is secret/cloudstack/admin-api and the API path — the
# one a policy must name — is secret/data/cloudstack/admin-api (3.2).
SECRET_PATH="secret/cloudstack/admin-api"

# What Vault holds, or empty. Not an error when absent — that is the first run.
stored_key() {
  vault_ kv get -field=api_key "${SECRET_PATH}" 2>/dev/null || true
}

# What CloudStack holds right now. Read-only: getUserKeys, never registerUserKeys.
live_key() {
  cmk -o json get userkeys id="$(admin_user_id)" 2>/dev/null | jq -r '.userkeys.apikey // empty'
}

seed() {
  ensure_cloudstack_api_keys

  # The URL travels with the credential deliberately. A consumer needs both, and
  # the address is discovered from the bridge — leaving it out would mean every
  # consumer rediscovering it, or worse, hardcoding it.
  vault_ kv put "${SECRET_PATH}" \
    url="${CLOUDSTACK_URL}" \
    api_key="${CLOUDSTACK_API_KEY}" \
    secret_key="${CLOUDSTACK_SECRET_KEY}" >/dev/null ||
    die "Could not write ${SECRET_PATH} to Vault."

  log "Seeded ${SECRET_PATH}"
}

# Four states, and only one of them is "do nothing". The fourth is the one 3.6
# spends a paragraph on: CloudStack's admin account is recreated whenever its
# database is redeployed, which invalidates the stored key while Vault goes on
# serving it happily. A non-rotating script must not fix that by rotating — it
# has no way to know whether the mismatch is a rebuild or a key someone else is
# still using. So it refuses, and names the reseed path.
main() {
  require_root
  vault_authenticate
  cmk_configure

  local stored live
  stored="$(stored_key)"
  live="$(live_key)"

  if [[ -z "${stored}" ]]; then
    log "${SECRET_PATH} is absent; seeding from CloudStack"
    seed
  elif [[ "${stored}" == "${live}" ]]; then
    log "${SECRET_PATH} already present and matches CloudStack; leaving it alone"
  else
    die "${SECRET_PATH} holds a key CloudStack no longer accepts — its database was probably redeployed. Vault will keep serving the stale key and every consumer will fail with a 401 that does not say why. To reseed deliberately:  vault kv delete ${SECRET_PATH}  then re-run this script."
  fi

  # Prove the round trip rather than the write: read back out of Vault and check
  # it is the key CloudStack actually holds.
  local back
  back="$(stored_key)"
  [[ -n "${back}" && "${back}" == "$(live_key)" ]] ||
    die "Read-back from ${SECRET_PATH} does not match CloudStack's current key."
  log "Verified: ${SECRET_PATH} matches the key CloudStack holds"
}

main "$@"
