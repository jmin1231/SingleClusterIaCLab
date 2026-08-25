#!/usr/bin/env bash
#
# issue-leaf.sh — issue Vault's server certificate from the intermediate CA.
#
# Usage: sudo ./issue-leaf.sh
#
# Called by bootstrap.sh after ca-install-all.sh, which must have run first —
# this script consumes the intermediate and refuses to start without it. Safe to
# re-run: an existing leaf is left alone.
#
# One certificate, for vault.lab.test, and nothing else ever. Vault's PKI engine
# becomes the lab's issuing CA at 3.4, which lands before Gitea, MinIO and the
# reverse proxy — so the only certificate needed before Vault exists is Vault's
# own. This is the bootstrap step of a two-CA design, not a general issuer. See
# decisions.md 3.4-1; the mechanics its comments used to carry are in 3.4-3.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

# REPO_ROOT, not a "../" hop off PKI_DIR: PKI_DIR is already ca/. See 3.4-3.
PKI_DIR="$(cd -- "${SOURCE_SCRIPT}/.." && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_SCRIPT}/../.." && pwd)"
ROOT_DIR="${PKI_DIR}/root"
ROOT_CRT="${ROOT_DIR}/root-ca.crt"
INT_DIR="${PKI_DIR}/intermediate"
INT_CNF="${PKI_DIR}/intermediate-ca.cnf"
INT_CRT="${INT_DIR}/intermediate-ca.crt"
INT_KEY="${INT_DIR}/intermediate-ca.key.enc"
INT_PASS="/root/.intermediate-ca.pass"

# The DN every leaf must carry, less the CN. [ leaf_pol ] lists domainComponent
# and organizationName as `match`, so a CSR that differs is refused. See 2.4-2.
LEAF_DN_BASE="/DC=test/DC=lab/O=SingleClusterIaCLab"

# The CN names the holder; the array is every other name it answers for. Empty
# on purpose, and kept rather than deleted — sign_csr's union iterates it, and
# that union is what puts the CN in its own SAN. See 3.4-3.
LEAF_CN="vault.lab.test"
LEAF_ALT_NAMES=()

# Leaves live with the service that reads them, never under ca/ (2.4-5).
# Filenames are kubernetes.io/tls, so 3.4 replaces the writer and not the
# consumer's config. bundle.crt is leaf + intermediate — what a server sends —
# and is not ca-chain.crt, which is intermediate + root.
LEAF_DIR="${REPO_ROOT}/docker/vault/certs"
LEAF_KEY="${LEAF_DIR}/tls.key"
LEAF_CRT="${LEAF_DIR}/tls.crt"
LEAF_BUNDLE="${LEAF_DIR}/bundle.crt"
LEAF_CSR="${LEAF_DIR}/tls.csr" # transient; sign_csr deletes it

# Refuse to start unless the intermediate is present and its passphrase opens
# it. The set is [ intermediate_ca ]'s, less `serial` — rand_serial retires it.
require_intermediate_ca() {
  local missing=()
  for file in "${INT_CRT}" "${INT_KEY}" "${INT_PASS}" "${INT_DIR}/index.txt"; do
    [[ -e "${file}" ]] || missing+=("${file}")
  done
  [[ -d "${INT_DIR}/newcerts" ]] || missing+=("${INT_DIR}/newcerts")

  [[ ${#missing[@]} -eq 0 ]] ||
    die "No usable intermediate CA: missing ${missing[*]}. Run ca/ca-install-all.sh first."

  openssl pkey -in "${INT_KEY}" -passin file:"${INT_PASS}" -noout 2>/dev/null ||
    die "${INT_PASS} does not open ${INT_KEY} — the intermediate cannot sign. Restore the matching passphrase."
}

# Decide whether issuing is safe: create when nothing exists, stop when the set
# is complete AND still chains to the CA on disk, refuse anything between.
# Presence is not validity — a re-minted intermediate orphans a leaf that still
# exists (2.4-3), and this is the only place that is checked (3.4-2).
check_existing() {
  local present=() missing=() file

  for file in "${LEAF_KEY}" "${LEAF_CRT}" "${LEAF_BUNDLE}"; do
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
    die "Incomplete leaf: missing ${missing[*]}. Remove ${LEAF_DIR} and re-run; the CA is untouched."
  fi

  # Runs before require_intermediate_ca, so the CA cannot be assumed present.
  # Said separately: "cannot be checked" and "failed the check" differ.
  for file in "${ROOT_CRT}" "${INT_CRT}"; do
    [[ -f "${file}" ]] ||
      die "${LEAF_CRT} exists but ${file} does not, so its chain cannot be checked. Remove ${LEAF_DIR} and re-run."
  done

  openssl verify -CAfile "${ROOT_CRT}" -untrusted "${INT_CRT}" "${LEAF_CRT}" >/dev/null 2>&1 ||
    die "${LEAF_CRT} no longer chains to the CA in ${INT_DIR} — the intermediate was replaced. Remove ${LEAF_DIR} and re-run."

  log "Using the existing leaf ${LEAF_CRT}"
  exit 0
}

# Generate the leaf private key, unencrypted — Vault starts unattended, so a
# passphrase would make every boot a prompt. This reverses 2.3-5 deliberately;
# 3.4-3 records what protects the key instead.
create_key() {
  mkdir -p "${LEAF_DIR}"
  chmod 0755 "${LEAF_DIR}"

  openssl genpkey -algorithm RSA \
    -pkeyopt rsa_keygen_bits:4096 \
    -quiet \
    -out "${LEAF_KEY}"

  chmod 0400 "${LEAF_KEY}"

  log "Generated the leaf private key: ${LEAF_KEY}"
}

# Request a certificate for that key: a key and a subject, nothing else. Not
# ${INT_CNF} — its [ req ] would name the request after the CA — and not the
# SAN, which copy_extensions discards. Both traps are in 3.4-3.
create_csr() {
  openssl req -new \
    -key "${LEAF_KEY}" \
    -subj "${LEAF_DN_BASE}/CN=${LEAF_CN}" \
    -out "${LEAF_CSR}"

  log "Created the leaf CSR: ${LEAF_CSR}"
}

# Have the intermediate sign the CSR, issuing the leaf. CA_DIR and LEAF_SAN ride
# on the command because openssl expands $ENV:: at config load; both fail
# silently when wrong. The SAN is seeded with the CN so it cannot be omitted.
sign_csr() {
  local san="DNS:${LEAF_CN}"
  local name
  for name in "${LEAF_ALT_NAMES[@]}"; do
    san+=",DNS:${name}"
  done

  CA_DIR="${INT_DIR}" LEAF_SAN="${san}" openssl ca -batch \
    -config "${INT_CNF}" \
    -extensions leaf_ext \
    -passin file:"${INT_PASS}" \
    -in "${LEAF_CSR}" \
    -out "${LEAF_CRT}"

  chmod 0444 "${LEAF_CRT}"
  rm -f "${LEAF_CSR}" # success path only: a failed signing leaves it to inspect

  log "Signed the leaf certificate: ${LEAF_CRT}"
}

# Assemble what the server sends: leaf + intermediate, and never the root.
# Omitting the intermediate is the failure that works in a browser which cached
# it and fails in curl on a clean machine.
build_bundle() {
  # Removed before rewriting: the previous bundle is 0444, so overwriting in
  # place would rely on root being allowed to ignore that.
  rm -f "${LEAF_BUNDLE}"

  cat "${LEAF_CRT}" "${INT_CRT}" >"${LEAF_BUNDLE}"
  chmod 0444 "${LEAF_BUNDLE}"

  log "Built the serving bundle: ${LEAF_BUNDLE}"
}

# Run every step in order.
main() {
  require_root
  check_existing
  require_intermediate_ca
  create_key
  create_csr
  sign_csr
  build_bundle
}

main "$@"
