#!/usr/bin/env bash
#
# gitea-repo-setup.sh — put this repository in Gitea and close the gate (4.2).
#
# Usage: sudo ./gitea-repo-setup.sh
#
# Gitea becomes the lab's source of truth. `origin` stays whatever it was —
# GitHub, here — as an off-host copy: this lab is torn down and rebuilt by
# design (T-4), and a repository that lives only inside it does not survive that.
#
# The token goes in an HTTP header supplied through the ENVIRONMENT, never in the
# remote URL and never in argv. A credential in the URL lands in .git/config and
# survives every clone; `git -c http.extraHeader=...` puts it on a command line
# where ps shows it (2.3-5). GIT_CONFIG_COUNT does neither.
#
# git runs as the repository's owner, not as root. This script needs root only to
# read vault-init.json — running git as root leaves root-owned files under .git/
# and the next ordinary push fails with "cannot lock ref: Permission denied".
#
# Only COMMITTED history is pushed. Obvious until the twenty minutes spent
# debugging why a fix visible in the editor had no effect.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SOURCE_SCRIPT}/../.."
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/vault.sh"

GITEA_URL="https://gitea.lab.test"
API="${GITEA_URL}/api/v1"
TOKEN_PATH="secret/gitea/api-token"
ADMIN_PATH="secret/gitea/admin"
REPO_NAME="SingleClusterIaCLab"
REMOTE_NAME="gitea"
BRANCH="main"
REPO_OWNER=""

api() {
  curl -s -H "Authorization: token ${GITEA_TOKEN}" "$@"
}

ensure_repo() {
  if api "${API}/repos/${GITEA_USER}/${REPO_NAME}" | jq -e '.id' >/dev/null 2>&1; then
    log "Repository ${GITEA_USER}/${REPO_NAME} already exists"
    return 0
  fi
  printf '{"name":"%s","private":true,"auto_init":false}' "${REPO_NAME}" |
    api -X POST -H 'Content-Type: application/json' --data @- "${API}/user/repos" |
    jq -e '.id' >/dev/null 2>&1 ||
    die "Could not create ${REPO_NAME} in Gitea."
  log "Created ${GITEA_USER}/${REPO_NAME} (private)"
}

# The remote carries no credential — see the header. Reset rather than added, so
# a URL that once held one is corrected rather than left.
# Every git call goes through here, as the owner, so nothing under .git/ ends up
# root-owned.
as_owner_git() {
  sudo -u "${REPO_OWNER}" git -C "${REPO_ROOT}" "$@"
}

ensure_remote() {
  local url="${GITEA_URL}/${GITEA_USER}/${REPO_NAME}.git"
  if as_owner_git remote get-url "${REMOTE_NAME}" >/dev/null 2>&1; then
    as_owner_git remote set-url "${REMOTE_NAME}" "${url}"
  else
    as_owner_git remote add "${REMOTE_NAME}" "${url}"
  fi
  log "Remote '${REMOTE_NAME}' -> ${url}"
}

push_committed() {
  local dirty
  dirty="$(as_owner_git status --porcelain | wc -l)"
  ((dirty == 0)) || warn "${dirty} uncommitted change(s) will NOT be pushed."

  # GIT_CONFIG_* passes the header through the environment. --preserve-env is
  # what carries it across sudo; without it sudo resets the environment and the
  # push authenticates as nobody.
  sudo -u "${REPO_OWNER}" \
    --preserve-env=GIT_CONFIG_COUNT,GIT_CONFIG_KEY_0,GIT_CONFIG_VALUE_0 \
    env GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: token ${GITEA_TOKEN}" \
    git -C "${REPO_ROOT}" push "${REMOTE_NAME}" "${BRANCH}" >/dev/null 2>&1 ||
    die "Push to ${REMOTE_NAME}/${BRANCH} failed."

  log "Pushed committed history to ${REMOTE_NAME}/${BRANCH}"
}

# Required status checks are named BEFORE any check exists, which is the point of
# 4.2: the gate closes now and opens later, rather than being added once there is
# something to gate and never quite tested.
protect_branch() {
  if api "${API}/repos/${GITEA_USER}/${REPO_NAME}/branch_protections" |
    jq -e --arg b "${BRANCH}" 'any(.[]; .branch_name == $b)' >/dev/null 2>&1; then
    log "Branch protection on ${BRANCH} already present"
    return 0
  fi
  printf '{"branch_name":"%s","enable_push":false,"enable_status_check":true,"status_check_contexts":["lint"]}' "${BRANCH}" |
    api -X POST -H 'Content-Type: application/json' --data @- \
      "${API}/repos/${GITEA_USER}/${REPO_NAME}/branch_protections" |
    jq -e '.branch_name' >/dev/null 2>&1 ||
    die "Could not enable branch protection on ${BRANCH}."
  log "Branch protection on ${BRANCH}: direct push disabled, status check 'lint' required"
}

main() {
  require_root
  vault_authenticate

  GITEA_USER="$(vault_field "${ADMIN_PATH}" username)"
  GITEA_TOKEN="$(vault_field "${TOKEN_PATH}" token)"
  [[ -n "${GITEA_USER}" && -n "${GITEA_TOKEN}" ]] ||
    die "Need ${ADMIN_PATH} and ${TOKEN_PATH}. Run the vault-ensure-gitea* scripts."

  REPO_OWNER="$(stat -c %U "${REPO_ROOT}")"
  [[ -n "${REPO_OWNER}" ]] || die "Could not determine the owner of ${REPO_ROOT}."

  ensure_repo
  ensure_remote
  push_committed
  protect_branch
}

main "$@"
