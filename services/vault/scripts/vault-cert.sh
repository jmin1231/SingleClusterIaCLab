#!/usr/bin/env bash

# vault-cert.sh
# 

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_SCRIPT}/../../.." && pwd)"

# ---------------------- IMPORT -----------------------------------
# shellcheck source=../../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

# shellcheck source=vault-env.sh
source "${SOURCE_SCRIPT}/vault-env.sh"

cert_needs_replacing() {

    [[ -s "${TLS_CRT}" ]] || die "${TLS_CRT} does not exist"
    

}

main() {
    cert_needs_replacing
}

main "$@"