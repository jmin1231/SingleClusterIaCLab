#!/usr/bin/env bash
#
# cloudstack-install-all.sh
#   Install apache cloudstack
#

set -euo pipefail

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CHECK_BRIDGE_NETFILTER="${CHECK_BRIDGE_NETFILTER:-true}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-cloudstack.conf"
ROOT_PASSWORD="$(openssl rand -hex 24)"
export ROOT_PASSWORD

# -------------------- Prepare Bridge Netfilter ----------------------------

disable_bridge_netfilter() {
    local setting

    modprobe br_netfilter

    cat > /etc/sysctl.d/99-disable-bridge-netfilter.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF

    log Preparing bridge netfilter...

    for setting in \
        net.bridge.bridge-nf-call-iptables \
        net.bridge.bridge-nf-call-ip6tables \
        net.bridge.bridge-nf-call-arptables; do

        sysctl -w "${setting}=0" >/dev/null
    done

    log "Bridge netfilter disabled"
}

check_bridge_netfilter() {
    if [[ "${CHECK_BRIDGE_NETFILTER}" != "true" ]]; then
        log "Skipping local KVM bridge netfilter check"
        return 0
    fi

    local setting
    local value

    for setting in \
        net.bridge.bridge-nf-call-iptables \
        net.bridge.bridge-nf-call-ip6tables \
        net.bridge.bridge-nf-call-arptables; do

        value="$(sysctl -n "$setting" 2>/dev/null)"

        if [[ "$value" != "0" ]]; then
            die "$setting is not disabled (value: ${value})"
        fi
    done

    log "Local KVM bridge netfilter is disabled"
}

# ------------------------- Prepare Host ---------------------------

prepare_host() {
    log "Preparing host..."

    cat > "${SSHD_DROPIN}" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

    printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd || die "Failed to set root password"

    chmod 644 "${SSHD_DROPIN}"

    systemctl restart ssh || die "Failed to restart SSH"

    log "SSH configured"
}

# ------------------------- Install Cloudmonkey ---------------------------
install_cmk() {
    log "Installing cloudmonkey..."
    if command -v cmk >/dev/null 2>&1; then
        log "Cloudmonkey already installed"
        return 0
    fi
    local tempfile
    tempfile="$(mktemp)"
    if ! curl -fSL https://github.com/apache/cloudstack-cloudmonkey/releases/download/6.5.0/cmk.linux.x86-64 \
        -o "${tempfile}"; then
        rm -f "${tempfile}"
        die "Failed to download cloudmonkey"
    fi
    install -m 0755 "${tempfile}" /usr/local/bin/cmk
    rm -f "${tempfile}"
    log "Cloudmonkey installed"
}

main() {
    disable_bridge_netfilter
    check_bridge_netfilter
    prepare_host
    install_cmk
}

main "$@"
