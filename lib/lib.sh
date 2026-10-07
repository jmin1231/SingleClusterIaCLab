#!/usr/bin/env bash
#
# lib/lib.sh
#   Shared helpers for bootstrap.sh and every installer under docker/ and
#   cloudstack/.
#
#   SOURCED, NEVER EXECUTED. It deliberately does not set shell options:
#   `set -euo pipefail` belongs to the calling script. A library that silently
#   changes its caller's error handling is a library that makes failures appear
#   in the wrong file.
#
#   Grows in three passes, per the build plan:
#     0.2  output, guards, apt, host facts   <- this pass
#     0.3  the install transcript
#     0.4  the step tracker
#

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '\033[1;31m[x]\033[0m %s is a library - source it, do not run it\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 1
fi

# Guard against being sourced twice. Re-sourcing is harmless for functions but
# would reset any state the later passes keep, so make it explicit and cheap.
if [[ -n "${LAB_LIB_SOURCED:-}" ]]; then
    return 0
fi
LAB_LIB_SOURCED=1

# The repository root, derived from this file rather than from the caller's
# directory, so every consumer resolves the same paths no matter where it sits.
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_STATE_DIR="${LAB_ROOT}/state"

# ------------------------------- Output -------------------------------------
#
# Colour goes to the terminal; the transcript added at 0.3 strips it on the way
# to the file. Note what is NOT done here: log() is not made conditional on
# `[[ -t 1 ]]`. After 0.3's redirect, stdout is a pipe even when a terminal is
# attached, so that test would be false and colour would vanish from the
# terminal as well as the file.

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

# die's message should name the LIKELY CAUSE, not the symptom. "cloudbr0 has no
# address - has cloudstack-install-all.sh run?" costs one line to write and
# saves the next reader the search. A message that only restates the failed
# command is a message that explains nothing the exit status did not.
die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

# ------------------------------- Guards -------------------------------------

verify_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Must be run as root - try again with sudo"
    fi
}

# A verify is not an install: it cannot fix anything, so it fails fast and
# says what must be changed and where. Nested virtualization is set on the
# HYPERVISOR and cannot be enabled from inside the guest - get it wrong and
# the VM is rebuilt, which is why this runs before anything is installed.
verify_kvm() {
    if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        die "CPU reports no vmx/svm flag. If this host is itself a VM, nested virtualization is off - set it on the hypervisor; it cannot be fixed from in here."
    fi

    if [[ ! -e /dev/kvm ]]; then
        die "/dev/kvm is missing though the CPU supports virtualization. Check the kvm module loaded: lsmod | grep kvm"
    fi

    log "KVM available: $(grep -oEm1 'vmx|svm' /proc/cpuinfo) flag present, /dev/kvm ready"
}

# The user who invoked sudo, which is what you want for `chown` and for group
# membership - $USER is `root` under sudo and tells you nothing. SUDO_USER is
# unset in a real root shell (someone logged in as root, or a systemd unit),
# which is a case to handle rather than assume away: return 1 and let the
# caller decide whether that is fatal.
invoking_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "${SUDO_USER}"
        return 0
    fi
    return 1
}

# --------------------------------- apt --------------------------------------
#
# apt WAITS for the dpkg lock rather than racing it. Unattended upgrades run on
# a fresh Ubuntu and hold the lock for minutes; without this the failure is
# "Could not get lock /var/lib/dpkg/lock-frontend", which reads like a bug in
# our script and is in fact a timing problem that fixes itself if asked to
# wait.

APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-300}"

apt_get() {
    DEBIAN_FRONTEND=noninteractive \
        apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" "$@"
}

# ------------------------------ Host facts ----------------------------------
#
# Discovered, never declared. An address that differs per host is asked for at
# run time; an interface name written into a constant is a per-host fact
# wearing a constant's clothing.

# The source address the kernel would use to reach the internet. This is the
# robust question: it works before CloudStack has built the bridge AND after,
# because it asks about routing rather than about an interface that may not
# exist yet. Parsed by scanning for the `src` keyword rather than by field
# position, because `ip route get` inserts `via` only when the target is off-link.
#
# No jq: this is needed in Phase 1 before `install_cli_tools` has run.
host_ip() {
    local addr
    addr="$(
        ip route get 1.1.1.1 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
    )"

    [[ -n "${addr}" ]] || die "Could not determine this host's outbound source address. Is there a default route? Check: ip route show default"

    printf '%s\n' "${addr}"
}

# The default gateway. Asked via `route get` rather than `route show default`
# because the latter can return several lines - a link-scope route, or one per
# metric - and taking the first is a guess that is wrong on exactly the hosts
# where it matters.
gateway_ip() {
    local addr
    addr="$(
        ip route get 1.1.1.1 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}'
    )"

    [[ -n "${addr}" ]] || die "Could not determine the default gateway. If the internet is reachable on-link there is no 'via' to find, which this lab does not expect."

    printf '%s\n' "${addr}"
}

# The address CloudStack's bridge ended up with. Every published container port
# binds to this rather than to 0.0.0.0, so a service is reachable on the lab
# network without also being an open listener on everything else.
#
# Deliberately separate from host_ip(): after the installer runs these are the
# same address, but asking the bridge directly is how we VERIFY that the
# installer did what Phase 1.7 expects, rather than assuming it.
bridge_ip() {
    local bridge="${1:-cloudbr0}"
    local addr

    addr="$(
        ip -4 -o addr show dev "${bridge}" scope global 2>/dev/null |
            awk '{split($4, a, "/"); print a[1]; exit}'
    )"

    [[ -n "${addr}" ]] || die "Interface ${bridge} has no global IPv4 address. It is created by cloudstack/cloudstack-install-all.sh - has that run?"

    printf '%s\n' "${addr}"
}

# ------------------------------ Conventions ---------------------------------
#
# Two shell traps this repo has paid for, recorded where they will be read:
#
#   CAPTURE, DO NOT PIPE, INTO `grep -q`. grep exits on its first match, the
#   producer takes SIGPIPE, and under `pipefail` the pipeline reports 141 - so
#   a SUCCESSFUL match is read as a failure. It is a race on output length, so
#   it passes on a quiet host and fails on a busy one. Write:
#       out="$(some_command)"; if grep -q pattern <<<"${out}"; then
#
#   AN ERROR HANDLER AFTER A FAILING COMMAND IN A `set -e` SCRIPT IS
#   DECORATION. The shell has already exited. Use `if ! cmd; then` or `|| die`,
#   and note that a RETURN trap does not fire on `die` - it needs RETURN EXIT.
