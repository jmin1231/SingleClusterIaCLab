#!/usr/bin/env bash

# prepare-kvm-host.sh

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

ROOT_PASSWORD="${ROOT_PASSWORD:-password}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-cloudstack.conf"
