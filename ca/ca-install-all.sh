#!/usr/bin/env bash
#
# ca-install-all.sh — create the lab's certificate authority and issue the one
# certificate it exists to produce: the offline root, the intermediate beneath
# it, and Vault's leaf.
#
# Usage: sudo ./ca-install-all.sh
#
set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../lib/common.sh"

require_root

# Resolve all three children before running any of them. Step 1 generates a
# passphrase and a 4096-bit key, so a path that is wrong — renamed, moved, not
# executable — has to stop us here, while nothing has been written to disk yet.
# Every entry below belongs in the loop: one left out is one that fails at its
# own step, after the steps before it have already written keys.
#
# LEAF, not LEAF_CA. A leaf is `CA:FALSE` and the root's pathlen:0 on the
# intermediate is what guarantees it — naming it a CA here would contradict the
# one constraint this chain is built on.
ROOT_CA="${SOURCE_SCRIPT}/scripts/root-ca-create.sh"
INTERMEDIATE_CA="${SOURCE_SCRIPT}/scripts/intermediate-ca-create.sh"
LEAF="${SOURCE_SCRIPT}/scripts/issue-leaf.sh"
for script in "${ROOT_CA}" "${INTERMEDIATE_CA}" "${LEAF}"; do
  [[ -x "${script}" ]] || die "Missing or not executable: ${script}"
done

# Run every step, in dependency order.
main() {
  log "Step 1/3: creating the offline root CA..."
  "${ROOT_CA}"

  log "Step 2/3: creating the intermediate CA..."
  "${INTERMEDIATE_CA}"

  log "Step 3/3: issuing Vault's certificate..."
  "${LEAF}"

  log "CA ready. Vault holds the only leaf this intermediate issues; everything else is issued by Vault's PKI engine from 3.4."
}

main "$@"
