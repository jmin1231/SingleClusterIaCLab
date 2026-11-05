#!/usr/bin/env bash
#
# cloudstack-install-all.sh - orchestrate the full provision: netplan backup, host
# prep, cmk, CloudStack install, and offerings.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_DIR}/.." && pwd)"
# shellcheck source=../lib/lib.sh
source "${REPO_ROOT}/lib/lib.sh"

SCRIPTS="${SOURCE_DIR}/scripts"
CS_INSTALLER="${SCRIPTS}/cloudstack-install.sh"

# Offering names Terraform references when building the VPC + tiers.
CLOUDSTACK_ZONE="${CLOUDSTACK_ZONE:-Zone1}"
VPC_OFFERING_NAME="${VPC_OFFERING_NAME:-iac-vpc-offering}"
NETWORK_OFFERING_NAME="${NETWORK_OFFERING_NAME:-iac-tier-offering}"

# Disable KVM bridge netfilter (live + persisted); CloudStack VPC port-forwards
# are silently dropped while it is on.
disable_bridge_netfilter() {
    log "Disabling KVM bridge netfilter"
    modprobe br_netfilter 2>/dev/null || true
    cat >/etc/sysctl.d/99-disable-bridge-netfilter.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF
    local s
    for s in net.bridge.bridge-nf-call-iptables \
             net.bridge.bridge-nf-call-ip6tables \
             net.bridge.bridge-nf-call-arptables; do
        sysctl -w "${s}=0" >/dev/null 2>&1 || true
    done
}

# Fail fast if bridge netfilter is still on after we tried to disable it.
check_bridge_netfilter() {
    local s v
    for s in net.bridge.bridge-nf-call-iptables \
             net.bridge.bridge-nf-call-ip6tables \
             net.bridge.bridge-nf-call-arptables; do
        v="$(sysctl -n "${s}" 2>/dev/null || echo 0)"
        [[ "${v}" == "0" ]] || die "${s} is not disabled (value: ${v})"
    done
    log "Bridge netfilter is disabled"
}

# Run the vendored installer unattended, reusing the root password that
# prepare-kvm-host.sh generated and persisted. Guarded so re-runs skip it.
install_cloudstack() {
    if is_done cloudstack_installed; then
        log "CloudStack already installed; skipping"
        return 0
    fi
    local root_pw
    root_pw="${ROOT_PASSWORD:-$(cat "${STATE_DIR}/root_password" 2>/dev/null)}"
    [[ -n "${root_pw}" ]] || die "no root password found; did prepare-kvm-host run?"
    CLOUDSTACK_UNATTENDED=1 ROOT_PASSWORD="${root_pw}" BRIDGE=cloudbr0 \
        CS_STATE_DIR="${STATE_DIR}" \
        "${CS_INSTALLER}"
    track_set cloudstack_installed yes
}

# Create the ConfigDrive VPC + tier network offerings Terraform needs (idempotent).
# Admin password auth: still the default here, since cloudmonkey rotates it later.
ensure_offerings() {
    if is_done offerings_ensured; then
        log "Offerings already ensured; skipping"
        return 0
    fi
    local admin_pw
    admin_pw="$(cat "${STATE_DIR}/cloudstack_admin_password" 2>/dev/null || echo password)"
    CLOUDSTACK_API_URL="http://$(bridge_ip):8080/client/api" \
        CS_USERNAME=admin CS_PASSWORD="${admin_pw}" \
        CLOUDSTACK_ZONE="${CLOUDSTACK_ZONE}" \
        VPC_OFFERING_NAME="${VPC_OFFERING_NAME}" \
        NETWORK_OFFERING_NAME="${NETWORK_OFFERING_NAME}" \
        "${SCRIPTS}/ensure-offerings.sh"
    track_set offerings_ensured yes
}

main() {
    verify_root
    backup_netplan
    disable_bridge_netfilter
    "${SCRIPTS}/prepare-kvm-host.sh"
    "${SCRIPTS}/cloudmonkey-install.sh"
    install_cloudstack
    ensure_offerings
    check_bridge_netfilter
    log "Provision complete"
}

main "$@"
