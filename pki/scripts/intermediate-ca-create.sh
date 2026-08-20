#!/usr/bin/env bash

# intermediate-ca-create.sh

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
INT_KEY="${INT_DIR}/intermediate-ca.key.enc"
INT_CRT="${INT_DIR}/intermediate-ca.crt"
INT_CSR="${INT_DIR}/intermediate-ca.csr"
CHAIN="${INT_DIR}/ca-chain.crt"

# Decide whether creating a intermediate CA is safe
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

  log "Using the existing intermediate CA ${INT_CRT}"
  exit 0
}

main() {
  require_root
  check_existing
}

main "$@"
