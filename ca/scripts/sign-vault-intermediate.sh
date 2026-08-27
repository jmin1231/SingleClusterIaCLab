#!/usr/bin/env bash
#
# sign-vault-intermediate.sh — the offline root signs a CSR from Vault's PKI
# engine, producing the certificate that makes Vault an issuing CA (3.4).
#
set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

# stdout is the certificate, so log() would write into it. Disabled rather than
# redirected: a stray call then fails at the call site instead of silently
# embedding escape codes in the PEM. warn and die are already on stderr.
log() { die "log() writes to stdout, which is the certificate here. Use warn()."; }

CA_ROOT_DIR="${SOURCE_SCRIPT}/../root"
ROOT_CNF="${SOURCE_SCRIPT}/../root-ca.cnf"
ROOT_PASS="/root/.root-ca.pass"

# Named so the link to root-ca.cnf is greppable from both ends: rename a section
# there and openssl fails with "unable to find 'section'", not a wrong policy.
SIGN_POLICY="vault_intermediate_pol"
SIGN_EXTENSIONS="intermediate_ca_ext"

# Set by read_csr. openssl ca needs real paths, so a filter still touches disk.
WORKSPACE=""
CSR_FILE=""
CRT_FILE=""

# --- Steps ------------------------------------------------------------------

# stdin is a pipe and can be read once, so capture it before anything needs it.
read_csr() {
  # The only precondition worth asserting by hand: openssl is never reached, so
  # nothing else reports it. Measured — the `cat` below waits forever for an EOF
  # that is not coming, printing nothing.
  [[ ! -t 0 ]] ||
    die "No CSR on stdin. Usage:  vault write -field=csr pki/intermediate/generate/internal ... | sudo ${0##*/} > cert.pem"

  WORKSPACE="$(mktemp -d)" || die "Could not create a temporary workspace."
  # Removed on every exit, including failure: the CSR came from stdin and the
  # caller can regenerate it, and openssl's errors are already on stderr.
  trap 'rm -rf "${WORKSPACE}"' EXIT
  CSR_FILE="${WORKSPACE}/vault-int.csr"
  CRT_FILE="${WORKSPACE}/vault-int.crt"

  cat >"${CSR_FILE}"
  [[ -s "${CSR_FILE}" ]] || die "Empty CSR on stdin — the producing command wrote nothing."
}

# The one operation that needs the offline root's passphrase.
sign_csr() {
  # -notext: without it openssl prepends a human-readable dump before the PEM,
  # 5579 bytes instead of 1545, corrupting a stdout that is the certificate.
  # -passin file: keeps the passphrase out of argv, where ps shows it (2.3-5).
  # -extensions with copy_extensions = none is what actually constrains Vault:
  # the CSR's requests are discarded and the root stamps CA:true, pathlen:0.
  CA_DIR="${CA_ROOT_DIR}" openssl ca -batch -notext \
    -config "${ROOT_CNF}" \
    -policy "${SIGN_POLICY}" \
    -extensions "${SIGN_EXTENSIONS}" \
    -passin file:"${ROOT_PASS}" \
    -in "${CSR_FILE}" \
    -out "${CRT_FILE}" ||
    die "openssl ca refused to sign — its errors are above."

  # Measured: openssl ca exits 0 when it REFUSES a CSR whose self-signature does
  # not verify — no certificate, no index.txt row, exit 0. A policy failure exits
  # 1; a signature failure does not. Output existing is the only proof of signing.
  [[ -s "${CRT_FILE}" ]] ||
    die "openssl ca wrote no certificate but reported success — which is what it does when the CSR's self-signature fails to verify. Its errors are above."

  warn "Signed: $(openssl x509 -in "${CRT_FILE}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
}

# The only write to stdout, and last, so nothing reaches the caller unless
# sign_csr proved a certificate exists.
emit_certificate() {
  cat "${CRT_FILE}"
}

main() {
  require_root
  read_csr
  sign_csr
  emit_certificate
}

main "$@"
