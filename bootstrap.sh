#!/usr/bin/env bash

set -euo pipefail

# Must run as root user
ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "bootstrap.sh must be run as root; re-run with sudo" >&2
        exit 1
    fi
}

# Install python3 if missing
ensure_python3() {
    if command -v python3 >/dev/null 2>&1; then
        echo "Check python3 version"
    fi
}


main() {
    ensure_root
}

main "$@"