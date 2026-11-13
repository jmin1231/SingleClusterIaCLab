#!/usr/bin/env bash

set -euo pipefail

PYTHON_PKG=python3.12
PYTHON=python3
QUIET=0

log() { printf '[+] %s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "bootstrap.sh must be run as root; re-run with sudo"
    fi
}

check_python_version() {
    "${PYTHON}" -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null
}

ensure_python() {
    if check_python_version; then
        [[ "${QUIET}" -eq 1 ]] || log "Python >= 3.12 found"
        return
    fi

    log "python >= 3.12 not found. Installing ${PYTHON_PKG}"

    apt-get -qq -o APT::Update::Error-Mode=any update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o DPkg::Lock::Timeout=120 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "${PYTHON_PKG}"

    if ! check_python_version; then
        die "${PYTHON} is older than 3.12 (or missing); refusing to continue"
    fi
}

main() {
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        QUIET=1
    fi
    ensure_root
    ensure_python
    exec "${PYTHON}" -B -m src "$@"
}

main "$@"
