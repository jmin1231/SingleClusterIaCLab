#!/usr/bin/env bash
#
# intermediate-ca-create.sh — create the CA that actually issues: an encrypted
# RSA-4096 key, a CSR, and a certificate signed by the offline root. Everything
# the lab serves over TLS is issued from this one, never from the root.
#
# Usage: sudo ./intermediate-ca-create.sh
#
# Called by bootstrap.sh after root-ca-create.sh, which must have run first —
# this script consumes the root and refuses to start without it. Safe to re-run:
# an existing intermediate is left alone.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

PKI_DIR="$(cd -- "${SOURCE_SCRIPT}/.." && pwd)"
ROOT_DIR="${PKI_DIR}/root"
INT_DIR="${PKI_DIR}/intermediate"
ROOT_CNF="${PKI_DIR}/root-ca.cnf"
INT_CNF="${PKI_DIR}/intermediate-ca.cnf"
ROOT_KEY="${ROOT_DIR}/root-ca.key.enc"
ROOT_CRT="${ROOT_DIR}/root-ca.crt"
ROOT_PASS="/root/.root-ca.pass"
INT_KEY="${INT_DIR}/intermediate-ca.key.enc"
INT_CRT="${INT_DIR}/intermediate-ca.crt"
INT_CSR="${INT_DIR}/intermediate-ca.csr"
INT_PASS="/root/.intermediate-ca.pass"
CHAIN="${INT_DIR}/ca-chain.crt"

# Decide whether creating an intermediate CA is safe: create when nothing
# exists, stop when it already does, refuse anything in between.
check_existing() {
  local present=() missing=()

  for file in "${INT_KEY}" "${INT_CRT}" "${INT_CSR}"; do
    if [[ -e "${file}" ]]; then
      present+=("${file}")
    else
      missing+=("${file}")
    fi
  done

  if [[ ${#present[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Incomplete intermediate CA: missing ${missing[*]}. Remove ${INT_DIR} and re-run; the root is untouched."
  fi

  # Present is not the same as usable. Minting a new root leaves the old
  # intermediate sitting here, and nothing about its three files says which root
  # signed it — so ask the root on disk instead of trusting the filenames.
  verify_chain_to_root
  ensure_chain

  log "Using the existing intermediate CA ${INT_CRT}"
  exit 0
}

# Rebuild ca-chain.crt if it is missing or does not match the two certificates
# it is made of. Unlike a key or a certificate, the chain is derived — both
# inputs are verified just above — so regenerating it loses nothing, and
# refusing over a file we can rewrite would strand Phase 2.5 with no chain.
ensure_chain() {
  if [[ -f "${CHAIN}" ]] && cmp -s <(cat "${INT_CRT}" "${ROOT_CRT}") "${CHAIN}"; then
    return 0
  fi

  warn "${CHAIN} is missing or stale; rebuilding it."
  build_chain
}

# Confirm the intermediate on disk was signed by the root on disk. Reads only
# the root certificate, so it needs no passphrase and leaves the key untouched.
verify_chain_to_root() {
  [[ -f "${ROOT_CRT}" ]] ||
    die "${INT_CRT} exists but ${ROOT_CRT} does not. Remove ${INT_DIR} and re-run."

  openssl verify -CAfile "${ROOT_CRT}" "${INT_CRT}" >/dev/null 2>&1 ||
    die "${INT_CRT} was not signed by the root now in ${ROOT_DIR} — the root was replaced. Remove ${INT_DIR} and re-run."
}

# Refuse to start unless the root CA is present and its passphrase opens it.
require_root_ca() {
  local missing=()
  for file in "${ROOT_CRT}" "${ROOT_KEY}" "${ROOT_PASS}" "${ROOT_DIR}/index.txt"; do
    [[ -e "${file}" ]] || missing+=("${file}")
  done

  [[ ${#missing[@]} -eq 0 ]] ||
    die "No usable root CA: missing ${missing[*]}. Run ca/scripts/root-ca-create.sh first; bootstrap.sh runs it before this one."

  openssl pkey -in "${ROOT_KEY}" -passin file:"${ROOT_PASS}" -noout 2>/dev/null ||
    die "${ROOT_PASS} does not open ${ROOT_KEY} — the root CA cannot sign. Restore the matching passphrase before issuing an intermediate."
}

# Write a random passphrase to /root, never readable by anyone but root.
create_passphrase() {
  (
    umask 077
    openssl rand -base64 32 >"${INT_PASS}"
  ) || die "Failed to write ${INT_PASS}"

  chmod 0400 "${INT_PASS}"

  log "Generated a new intermediate CA passphrase: ${INT_PASS}"
}

# Generate the private key, encrypted with that passphrase.
create_key() {
  mkdir -p "${INT_DIR}"
  chmod 700 "${INT_DIR}"

  openssl genpkey -algorithm RSA \
    -pkeyopt rsa_keygen_bits:4096 \
    -aes256 \
    -quiet \
    -pass file:"${INT_PASS}" \
    -out "${INT_KEY}"

  chmod 0400 "${INT_KEY}"

  log "Generated the intermediate CA private key: ${INT_KEY}"
}

# Initialise the intermediate's own CA database, for the leaves it issues.
init_ca_db() {
  touch "${INT_DIR}/index.txt"
  mkdir -p "${INT_DIR}/newcerts"

  log "Initialised the CA Database: ${INT_DIR}/index.txt"
}

# Request a certificate for that key: a CSR for the root to sign.
create_csr() {
  CA_DIR="${INT_DIR}" LEAF_SAN="" openssl req -new \
    -key "${INT_KEY}" \
    -passin file:"${INT_PASS}" \
    -config "${INT_CNF}" \
    -out "${INT_CSR}"

  log "Created the intermediate CSR: ${INT_CSR}"
}

# Have the root sign the CSR, issuing the intermediate certificate.
sign_csr() {
  CA_DIR="${ROOT_DIR}" openssl ca -batch \
    -config "${ROOT_CNF}" \
    -extensions intermediate_ca_ext \
    -passin file:"${ROOT_PASS}" \
    -in "${INT_CSR}" \
    -out "${INT_CRT}"

  chmod 0444 "${INT_CRT}"

  log "Signed the intermediate certificate: ${INT_CRT}"
}

# build the entire CA chain
build_chain() {
  # Removed before rewriting: a previous chain is left 0444, so writing over it
  # works only because root may ignore that. Deleting first makes a rebuild
  # depend on the logic rather than on who is running it.
  rm -f "${CHAIN}"

  cat "${INT_CRT}" "${ROOT_CRT}" >"${CHAIN}"

  chmod 0444 "${CHAIN}"

  log "Built the CA chain: ${CHAIN}"
}

# Run every step in order.
main() {
  require_root
  check_existing
  require_root_ca
  create_passphrase
  create_key
  init_ca_db
  create_csr
  sign_csr
  build_chain
}

main "$@"
