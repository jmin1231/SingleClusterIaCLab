#!/usr/bin/env bash
#
# lib/common.sh
#   Shared helpers for bootstrap.sh and the service installers.
#
#   Sourced, never executed. Deliberately does not set shell options -
#   `set -euo pipefail` belongs to the calling script, not to a library that
#   would be silently changing its caller's behaviour.
#

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '\033[1;31m[x]\033[0m %s is a library - source it, do not run it\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 1
fi

# ------------------------------ Output ------------------------------------

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

# ------------------------------ Guards ------------------------------------

verify_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Must be run as root - try again with sudo"
    fi
}

# ------------------------------ Host facts --------------------------------

# The address CloudStack's bridge ended up with. Every service binds its
# published ports to this rather than to all interfaces.
get_cloudbr0_ip() {
    local ip_addr

    ip_addr="$(
        ip -4 -o addr show dev cloudbr0 scope global 2>/dev/null |
        awk '{split($4, a, "/"); print a[1]; exit}'
    )"

    [[ -n "$ip_addr" ]] || die "Unable to determine cloudbr0 ip address. cloudbr0 is created by cloudstack-install-all.sh - has it run?"

    printf '%s\n' "$ip_addr"
}
