#!/usr/bin/env bash
#
# ca-install-all.sh — create the lab's certificate authority: the offline root,
# then the intermediate that signs everything the lab serves over TLS.
#
# Usage: sudo ./ca-install-all.sh
#
# The entry point bootstrap.sh calls; every other script here is called by it,
# and the order is a dependency, not a preference — the intermediate consumes
# the root. Safe to re-run: an existing CA is left alone.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../lib/common.sh"

require_root

# Resolve both children before running either. Step 1 generates a passphrase and
# a 4096-bit key, so a path that is wrong — renamed, moved, not executable — has
# to stop us here, while nothing has been written to disk yet.
ROOT_CA="${SOURCE_SCRIPT}/scripts/root-ca-create.sh"
INTERMEDIATE_CA="${SOURCE_SCRIPT}/scripts/intermediate-ca-create.sh"
for script in "${ROOT_CA}" "${INTERMEDIATE_CA}"; do
  [[ -x "${script}" ]] || die "Missing or not executable: ${script}"
done

# Run every step, in dependency order.
main() {
  log "Step 1/2: creating the offline root CA..."
  "${ROOT_CA}"

  log "Step 2/2: creating the intermediate CA..."
  "${INTERMEDIATE_CA}"

  log "CA ready; the intermediate is what issues leaf certificates."
}

main "$@"
