#!/usr/bin/env bash
#
# root-ca-create.sh — create the lab's offline root CA: a random passphrase, an
# encrypted RSA-4096 key, and a self-signed 20-year certificate that will sign
# exactly one thing, the intermediate of Phase 2.4.
#
# Usage: sudo ./root-ca-create.sh
#
# Called by bootstrap.sh, which owns the ordering. Safe to re-run: an existing CA
# is left alone, because a second root invalidates every certificate issued under
# the first. The passphrase lives in /root, outside the repository, so a copy of
# the working tree carries an encrypted key and no way to open it.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../lib/common.sh"

CA_DIR="${SOURCE_SCRIPT}/root"
KEY="${CA_DIR}/root-ca.key.enc"
CRT="${CA_DIR}/root-ca.crt"
CNF="${SOURCE_SCRIPT}/root-ca.cnf"
PASS_FILE="/root/.root-ca.pass"
DAYS=7300 # 20 years: the root outlives the lab, so it never expires mid-phase

# Decide whether creating a CA is safe: create when nothing exists, stop when
# all of it exists and the passphrase opens the key, refuse anything between.
check_existing() {
  local present=() missing=()

  for file in "${PASS_FILE}" "${KEY}" "${CRT}"; do
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
    die "Incomplete root CA: missing ${missing[*]} while ${present[*]} exists. A previous run failed part-way, this host was rebuilt, or a backup restored one without the other — the key and its passphrase live in different places by design. Restore the missing file, or move ${CA_DIR} aside and re-run to mint a new root, which invalidates every certificate ever issued under the old one."
  fi

  openssl pkey -in "${KEY}" -passin file:"${PASS_FILE}" -noout 2>/dev/null ||
    die "${PASS_FILE} does not open ${KEY} — they are from different generations of the CA. Restore the passphrase that matches this key, or move ${CA_DIR} aside and re-run to mint a new root, which invalidates every certificate ever issued under the old one."

  log "Using the existing root CA ${CRT}"
  exit 0
}

# Write a random passphrase to /root, never readable by anyone but root.
create_passphrase() {
  (
    umask 077
    openssl rand -base64 32 >"${PASS_FILE}"
  ) || die "Failed to write ${PASS_FILE}."

  chmod 0400 "${PASS_FILE}"

  log "Generated a new root CA passphrase: ${PASS_FILE}"
}

# Generate the private key, encrypted with that passphrase.
create_key() {
  mkdir -p "${CA_DIR}"
  chmod 700 "${CA_DIR}"

  openssl genpkey -algorithm RSA \
    -pkeyopt rsa_keygen_bits:4096 \
    -aes256 \
    -quiet \
    -pass file:"${PASS_FILE}" \
    -out "${KEY}"

  chmod 0400 "${KEY}"

  log "Generated the root CA private key: ${KEY}"
}

# Issue the self-signed root certificate from that key.
self_sign() {
  openssl req -x509 -new \
    -key "${KEY}" \
    -passin file:"${PASS_FILE}" \
    -config "${CNF}" \
    -days "${DAYS}" \
    -out "${CRT}"

  chmod 0444 "${CRT}"

  log "Self-signed the root certificate: ${CRT}"
}

# Assert the issued certificate really is a CA, then print it for the operator.
verify_root() {
  local text
  text="$(openssl x509 -in "${CRT}" -noout -text)"

  grep -q "CA:TRUE" <<<"${text}" ||
    die "${CRT} is not a CA certificate — check basicConstraints in the [ root_ca_ext ] section of ${CNF}."
  grep -q "Certificate Sign" <<<"${text}" ||
    die "${CRT} cannot sign certificates — check keyUsage in the [ root_ca_ext ] section of ${CNF}."

  log "Root CA ready:"
  openssl x509 -in "${CRT}" -noout -subject -dates -fingerprint -sha256
}

# Run every step in order.
main() {
  require_root
  check_existing
  create_passphrase
  create_key
  self_sign
  verify_root
}

main "$@"
