#!/usr/bin/env bash
#
# vault-pki.sh
#
#

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_SCRIPT}/../../.." && pwd)"
source "${REPO_ROOT}/lib/common.sh"
source "${SOURCE_SCRIPT}/vault-env.sh"

