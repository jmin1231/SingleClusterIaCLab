#!/usr/bin/env bash
#
# vault-ensure-gitea-token.sh — a Gitea API token, minted once and kept in Vault
# (4.1's create-and-capture direction, 4.2's consumer).
#
# Usage: sudo ./vault-ensure-gitea-token.sh
#
# The third direction. CloudStack's key can be CAPTURED because getUserKeys reads
# it back; Gitea's admin password is GENERATED in Vault because Vault is its
# origin. A Gitea token is neither: the service mints it and **will not show it
# again**, so the only moment it can be stored is the moment it is created.
#
# That makes the usual ensure check impossible — there is nothing on the far side
# to compare against. What is checkable is whether the token still WORKS, so that
# is the guard: present and authenticating means leave it alone.
#
# 4.1 notes the reference lab mints bootstrap-<epoch> on every run and the tokens
# accumulate, and says to decide whether to prune. Decided: one token with a
# fixed name, and a stale one is DELETED before a replacement is minted. A token
# list that grows without bound is a credential inventory nobody audits.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../../lib/vault.sh"

TOKEN_PATH="secret/gitea/api-token"
ADMIN_PATH="secret/gitea/admin"
TOKEN_NAME="lab-bootstrap"
GITEA_URL="https://gitea.lab.test"

# Enough to create a repository and set branch protection on it, and no more.
# 4.1 says to scope the token to the job; the CI token at 4.5 gets its own,
# narrower still.
TOKEN_SCOPES='["write:repository","write:user"]'

# Basic auth, because Gitea will not let a token mint a token.
gitea_admin() {
  curl -s -u "${GITEA_USER}:${GITEA_PASS}" "$@"
}

token_works() {
  [[ -n "$1" ]] || return 1
  [[ "$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: token $1" "${GITEA_URL}/api/v1/user")" == "200" ]]
}

main() {
  require_root
  vault_authenticate

  GITEA_USER="$(vault_field "${ADMIN_PATH}" username)"
  GITEA_PASS="$(vault_field "${ADMIN_PATH}" password)"
  [[ -n "${GITEA_USER}" && -n "${GITEA_PASS}" ]] ||
    die "${ADMIN_PATH} is missing. Run docker/vault/scripts/vault-ensure-gitea.sh."

  if token_works "$(vault_field "${TOKEN_PATH}" token)"; then
    log "${TOKEN_PATH} already present and authenticating"
    return 0
  fi

  # Either there is no token, or the stored one no longer works. Both mean the
  # named token on Gitea's side is dead weight — remove it, or the create below
  # fails on a duplicate name and leaves the account with a token nobody holds.
  if gitea_admin "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens" |
    jq -e --arg n "${TOKEN_NAME}" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
    warn "Deleting the stale '${TOKEN_NAME}' token before minting a replacement."
    gitea_admin -X DELETE -o /dev/null \
      "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens/${TOKEN_NAME}"
  fi

  local created token
  created="$(printf '{"name":"%s","scopes":%s}' "${TOKEN_NAME}" "${TOKEN_SCOPES}" |
    gitea_admin -X POST -H 'Content-Type: application/json' --data @- \
      "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens")"
  token="$(jq -r '.sha1 // empty' <<<"${created}")"
  [[ -n "${token}" ]] ||
    die "Gitea did not return a token: $(jq -r '.message // .' <<<"${created}" | head -1)"

  # Stored immediately. This value is unreadable from Gitea from here on — a
  # failed write does not lose access (the admin password still works) but it
  # does orphan a live credential, so the delete-before-create above is what
  # keeps that from accumulating.
  vault_ kv put "${TOKEN_PATH}" name="${TOKEN_NAME}" token="${token}" >/dev/null ||
    die "Minted a Gitea token but could not store it at ${TOKEN_PATH}. Delete it in Gitea's UI under Settings > Applications, then re-run."

  token_works "${token}" || die "The new token does not authenticate."
  log "Minted and stored ${TOKEN_PATH} (scopes: ${TOKEN_SCOPES})"
}

main "$@"
