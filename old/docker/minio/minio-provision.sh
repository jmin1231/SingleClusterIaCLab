#!/usr/bin/env bash
#
# minio-provision.sh — buckets, policies and the two scoped service accounts
# (5.1). Runs after minio-installer.sh; MinIO must be up.
#
# Usage: sudo ./minio-provision.sh
#
# The split from minio-installer.sh is 5.1's blast-radius argument made
# structural: the installer handles the ROOT credential, this script mints the
# SCOPED keys and is the only thing that writes them to Vault for pipelines.
#
# Safe to re-run: buckets, policies and accounts are all ensured rather than
# created — an existing service account is not reminted, because 5.4 and every
# pipeline after it hold the key it already issued.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/vault.sh"

POLICY_DIR="${SOURCE_SCRIPT}/policies"

MINIO_NAME="minio.lab.test"
ROOT_PATH="secret/minio/root"
COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
STATE_BUCKET="lab-tfstate"
IMAGES_BUCKET="lab-images"

# mc runs INSIDE the minio container, not on the host (there is no mc there) and
# not in toolbox (that would make Phase 5 depend on the CI image). The deciding
# reason is trust: this container already has SSL_CERT_FILE=/certs/ca.crt from
# docker-compose.yml, so mc validates the lab chain with no --insecure. That
# validation is now the only certificate check left in Phase 5.
#
# Shaped after lib/vault.sh:vault_(), including the part that matters most:
# `-e MC_HOST_lab` carries NO VALUE, so the credential is passed through from the
# environment instead of appearing in argv, where ps shows it to every user on
# the host (2.3-5). Writing -e MC_HOST_lab="https://user:pass@..." would publish
# the root credential to the whole machine.
#
# All three alias variables are listed even though only `lab` exists today.
# Docker silently omits an -e whose variable is unset, so the scoped aliases
# minted later cost nothing here and save rewriting every call site.
#
# MC_CONFIG_DIR is not optional: `user:` is pinned, so there is no home directory
# and mc dies with "mkdir /.mc: permission denied" trying to write its config.
mc_() {
  docker compose -f "${COMPOSE}" exec -T \
    -e MC_CONFIG_DIR=/tmp/.mc \
    -e MC_HOST_lab -e MC_HOST_state -e MC_HOST_images \
    minio mc "$@"
}

# Defines the root alias entirely through the environment. No `mc alias set`, and
# so no config file to write, no home directory to need, and no credential
# persisted inside the container.
mc_alias() {
  local user pass

  user="$(vault_field "${ROOT_PATH}" username)"
  pass="$(vault_field "${ROOT_PATH}" password)"
  [[ -n "${user}" && -n "${pass}" ]] ||
    die "${ROOT_PATH} is missing or incomplete. Run docker/vault/scripts/vault-ensure-minio.sh."

  # No URL-encoding, and that is a Phase 3 decision paying off rather than luck:
  # new_password() is hex "because these values end up in PostgreSQL connection
  # strings, URL form bodies and environment variables, and base64's + and / are
  # meaningful in all three". This is one of those URLs.
  MC_HOST_lab="https://${user}:${pass}@${MINIO}:9000"
  export MC_HOST_lab

  # MC_HOST_ is lazy — nothing parses or contacts anything until a command uses
  # the alias. Without a probe here the first failure would surface inside
  # ensure_buckets and read as a bucket problem.
  #
  # `admin info` rather than `ls`: every later call in this script is an admin
  # call (policy create, service account add), so prove admin rights, not merely
  # that the S3 endpoint answers.
  mc_ admin info lab >/dev/null 2>&1 ||
    die "mc cannot use the root alias against ${MINIO}:9000. Two causes and this cannot tell them apart: the credential in ${ROOT_PATH} is wrong, or the served certificate does not validate against /certs/ca.crt inside the container."

  log "mc root alias works against ${MINIO}:9000"
}

# One bucket, created if absent and versioned either way.
#
# Two buckets rather than one bucket with state/ and images/ prefixes, because a
# bucket is the blast-radius boundary: a policy naming the wrong bucket grants
# NOTHING, while a prefix policy with a sloppy wildcard grants EVERYTHING. And
# ListBucket is an action on the bucket, not on objects, so scoping a prefix
# policy correctly is the part people get wrong. 5.1's done-when tests exactly
# that boundary.
#
# NOT set here, and both are creation-time-only in S3 — retrofitting them means
# making a new bucket and copying: object lock (`mc mb --with-lock`, WORM, needs
# versioning) and the default encryption mode. Skipped per 0.2-8: one host, one
# account, no KMS. Revisit object lock for the state bucket if this ever holds
# anything that matters.
ensure_bucket() {
  local bucket="$1"

  if mc_ ls "lab/${bucket}" >/dev/null 2>&1; then
    log "Bucket ${bucket} already present"
  else
    mc_ mb "lab/${bucket}" >/dev/null 2>&1 ||
      die "Could not create bucket ${bucket}. Root alias works, so this is MinIO refusing the name or the disk."
    log "Created bucket ${bucket}"
  fi

  # Unconditional rather than checked-then-set: PutBucketVersioning is
  # idempotent, and parsing mc's prose to decide would be more fragile than the
  # call it saves.
  mc_ version enable "lab/${bucket}" >/dev/null 2>&1 ||
    die "Could not enable versioning on ${bucket}."

  # Read back rather than trust the exit status. Versioning is the one setting
  # here with a downstream consumer that fails SILENTLY without it: Drill 5
  # restores a previous state object, and an unversioned bucket has no previous
  # object to restore — the gap surfaces a phase later as data loss rather than
  # as a failed exercise.
  #
  # Grepping the quoted JSON value, not the human output: mc's prose wording for
  # the un-versioned case is not pinned anywhere and "not enabled" would match a
  # looser pattern.
  mc_ --json version info "lab/${bucket}" 2>/dev/null | grep -q '"Enabled"' ||
    die "Versioning is not reported as Enabled on ${bucket} after enabling it."

  log "  versioning enabled on ${bucket}"
}

ensure_buckets() {
  local bucket
  for bucket in "${STATE_BUCKET}" "${IMAGES_BUCKET}"; do
    ensure_bucket "${bucket}"
  done
}

ensure_policies() {
  # TODO 5: envsubst each template in ${POLICY_DIR} with ONLY the bucket vars
  #         allow-listed, then `mc admin policy create`. Re-applying an existing
  #         policy must update it, not fail — that is what makes this re-runnable
  #         when a policy is edited in a diff and reapplied.
  die "TODO: ensure_policies is not implemented"
}

ensure_service_accounts() {
  # TODO 6: one service account per policy. Skip if it already exists — see the
  #         header on why reminting is not idempotent from the consumer's side.
  #
  # TODO 7: write ONLY these scoped keys to Vault, at their own paths. The root
  #         credential does not move (5.1). 5.4 is what teaches pipelines to
  #         read them.
  die "TODO: ensure_service_accounts is not implemented"
}

# ---------------------------------------------------------------- Stage 6 ----
verify() {
  # TODO 8: 5.1's done-when, asserted rather than eyeballed — the runner-smoke
  #         lesson: a test that only logs is a test that passes while broken.
  #
  #         a) the IMAGES account is DENIED listing the state bucket. Assert the
  #            failure; a script that runs the command and ignores the exit
  #            status proves nothing.
  #         b) the images account CAN write to its own bucket — otherwise (a)
  #            passes trivially when the credential is simply broken.
  #         c) versioning reports Enabled on both buckets.
  #
  # TODO 9: assert the endpoint presents MinIO's Vault-issued certificate and
  #         not the proxy's. One `openssl s_client -servername minio.lab.test`
  #         and an issuer check. This is the only thing that distinguishes the
  #         L4 design from the L7 one it was chosen over, so it is the assertion
  #         that must not be skipped.
  die "TODO: verify is not implemented"
}

main() {
  require_root
  vault_authenticate
  mc_alias
  ensure_buckets
  ensure_policies
  ensure_service_accounts
  verify
}

main "$@"
