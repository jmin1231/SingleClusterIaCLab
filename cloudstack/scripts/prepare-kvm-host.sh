#!/usr/bin/env bash

# prepare-kvm-host.sh — set the root password and open root + password SSH, so
# CloudStack can add this machine as its KVM host. It adds hosts over SSH even
# when the host is itself, which is why an all-in-one install needs this.
#
# Not run directly — called by cloudstack-install-all.sh, which owns
# ROOT_PASSWORD and the ordering. Run standalone it inherits neither root nor
# DEBIAN_FRONTEND and will fail partway through.
#
# LAB ONLY. Root login with a password is a real hole; it is opened deliberately
# and closed again in Phase 1.6:
#
#   sudo rm /etc/ssh/sshd_config.d/01-cloudstack.conf && sudo systemctl restart ssh

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

ROOT_PASSWORD="${ROOT_PASSWORD:-password}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-cloudstack.conf"

# Ensure openssh-server
if ! dpkg -s openssh-server >/dev/null 2>&1; then
  log "OpenSSH is not installed; installing openssh-server..."
  apt-get update || die "apt-get update failed."
  # --force-confnew: take the package's canonical sshd_config.
  apt-get install -y -o Dpkg::Options::=--force-confnew openssh-server ||
    die "Failed to install openssh-server."
fi

# Set the root password
log "Setting root password..."
printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd || die "Failed to set root password."

# Enable SSH login via a drop-in
log "Enabling root + password SSH login"
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config ||
  die "sshd_config has no Include for sshd_config.d/ - the drop-in would be ignored."
cat >"${SSHD_DROPIN}" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
chmod 644 "${SSHD_DROPIN}"

# Restart SSH server
log "Restarting SSH..."
systemctl restart ssh || die "Failed to restart ssh."

# Assert on what sshd concluded, not on the file we wrote. sshd -T prints the
# effective config after every drop-in is merged, and it uses the FIRST value it
# obtains for each keyword — so a lower-numbered drop-in silently outranks ours.
# Nothing above this point can detect that.
effective="$(sshd -T 2>/dev/null)" || die "sshd -T failed; the config is invalid."
for directive in "permitrootlogin yes" "passwordauthentication yes"; do
  grep -qi "^${directive}$" <<<"${effective}" ||
    die "sshd reports '${directive%% *}' is not '${directive##* }'. Check that sshd_config Includes sshd_config.d/, and that no drop-in sorting before ${SSHD_DROPIN##*/} overrides it."
done

log "Host prepared: root + password SSH enabled"
