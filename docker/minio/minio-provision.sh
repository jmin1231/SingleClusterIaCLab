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

# TODO 1: bucket names, read from the single definition chosen in
#         vault-ensure-minio.sh TODO 1 rather than redeclared here.

mc_alias() {
  # TODO 2: point `mc` at https://minio.lab.test using the ROOT credential from
  #         Vault. Note mc runs on the host, so it resolves through CoreDNS and
  #         crosses the SNI router — which makes this the first real proof the
  #         Stage 1 passthrough works end to end.
  #
  # TODO 3: decide how mc trusts the lab CA. It reads ~/.mc/certs/CAs/, NOT the
  #         system bundle. Same class of trap as NODE_EXTRA_CA_CERTS in 4.6:
  #         the system store is already correct and this tool ignores it.
  die "TODO: mc_alias is not implemented"
}

ensure_buckets() {
  # TODO 4: create both buckets if absent, and turn versioning ON for both.
  #         Drill 5 restores a previous state object from versioning — without
  #         this, that drill has nothing to restore and the gap surfaces a phase
  #         later as data loss rather than as a failed exercise.
  die "TODO: ensure_buckets is not implemented"
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
