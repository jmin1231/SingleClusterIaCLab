#!/usr/bin/env bash
#
# prepare-kvm-host.sh - set the root password and enable root + password SSH for
# CloudStack's KVM host-add.


set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SOURCE_DIR}/../../lib/lib.sh"

ROOT_PASSWORD_FILE="${STATE_DIR}/root_password"
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-cloudstack.conf"

# Pick the root password: use the caller's, else a prior run's, else generate + persist one.
resolve_root_password() {
    if [[ -n "${ROOT_PASSWORD:-}" ]]; then
        return 0
    elif [[ -f "${ROOT_PASSWORD_FILE}" ]]; then
        ROOT_PASSWORD="$(cat "${ROOT_PASSWORD_FILE}")"
    else
        mkdir -p "${STATE_DIR}"
        ROOT_PASSWORD="$(openssl rand -hex 16)"
        (umask 077; printf '%s' "${ROOT_PASSWORD}" > "${ROOT_PASSWORD_FILE}")
        log "generated a root password -> ${ROOT_PASSWORD_FILE} (0600)"
    fi
}

# Install the OpenSSH server if it is not already present.
ensure_ssh_server() {
    if ! command -v sshd >/dev/null; then
        log "installing openssh-server"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    fi
}

# Set the host's root account password (non-interactively).
set_root_password() {
    log "Setting root password"
    printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
}

# Write the drop-in that turns on root + password login, then restart sshd.
ensure_sshd_dropin() {
    log "Ensuring sshd drop-in"
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        warn "sshd_config has no Include for sshd_config.d; adding it"
        printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
    fi
    log "enabling root + password SSH (${SSHD_DROPIN})"
    cat > "${SSHD_DROPIN}" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
    chmod 644 "${SSHD_DROPIN}"

    systemctl restart ssh
}

# Confirm the effective sshd config actually enables both (no other drop-in wins).
verify_dropin() {
    log "Verifying sshd config"
    local eff
    eff="$(sshd -T 2>/dev/null | grep -Ei '^(permitrootlogin|passwordauthentication) ')"
    grep -qi 'permitrootlogin yes' <<<"${eff}" ||
        die "PermitRootLogin is not 'yes' — another drop-in overrides it"
    grep -qi 'passwordauthentication yes' <<<"${eff}" ||
        die "PasswordAuthentication is not 'yes' — another drop-in overrides it"

    log "KVM host prepared: root + password SSH enabled"
}


# Orchestrate the steps in order (must run as root).
main() {
    verify_root
    resolve_root_password
    ensure_ssh_server
    set_root_password
    ensure_sshd_dropin
    verify_dropin
}

main "$@"
