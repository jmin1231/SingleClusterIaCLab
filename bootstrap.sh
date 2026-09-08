#!/usr/bin/env bash
#
# bootstrap.sh - Installs all of the required dependencies and services
#                to enable infrastructure provisioning through CI
#

set -euo pipefail

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES=(curl jq gettext-base openssl gnupg ca-certificates)

verify_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Must be run as root - sudo ./bootstrap.sh"
    fi
}

verify_kvm() {
    if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        die "CPU reports no vmx/svm flag. If this host is itself a VM, enable nested virtualization on the hypervisor - it cannot be set from inside the guest."
    fi

    if [[ ! -e /dev/kvm ]]; then
        die "/dev/kvm is missing though the CPU supports virtualization - the kvm_intel/kvm_amd module did not load. Check 'lsmod | grep kvm' and 'dmesg | grep -i kvm'."
    fi

    log "KVM available: $(grep -oEm1 'vmx|svm' /proc/cpuinfo) flag present, /dev/kvm ready"
}

wait_for_time_sync() {
    if [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]]; then
        log "Clock is already synchronized"
        return 0
    fi

    timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP via timedatectl"

    log "Waiting for the clock to synchronize..."

    local i
    for ((i = 0; i < 60; i++)); do
        if [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]]; then
            log "Clock synchronized"
            return 0
        fi
        sleep 1
    done

    die "Clock failed to synchronize after 60 seconds"
}

install_cli_tools() {
    if dpkg -s "${PACKAGES[@]}" >/dev/null 2>&1; then
        log "CLI tools already installed"
        return 0
    fi

    log "Installing CLI tools: ${PACKAGES[*]}..."
    apt-get -o DPkg::lock::Timeout=300 update
    apt-get -o DPkg::lock::Timeout=300 install -y "${PACKAGES[@]}"

    log "CLI tools ready"
}

main() {
    verify_root
    verify_kvm
    wait_for_time_sync
    install_cli_tools
}

main "$@"
