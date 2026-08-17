#!/usr/bin/env bash
#
# cloudstack-install-all.sh — one-shot CloudStack all-in-one install for Ubuntu
# 24.04. Prepares the KVM host, installs cmk, runs the vendored installer
# unattended, then disables bridge netfilter and verifies it.
#
# Usage: sudo ./cloudstack-install-all.sh
#
# The entry point a human runs; every other script here is called by it and
# shares this script's ROOT_PASSWORD. Safe to re-run — each step is a no-op once
# its work is done.
#
# LAB ONLY. This rewrites host networking and opens root + password SSH, which
# Phase 1.6 closes again.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../lib/common.sh"

export ROOT_PASSWORD="${ROOT_PASSWORD:-password}"
export CLOUDSTACK_UNATTENDED=1

require_root

# Resolve every child before running any of them. Step 1 sets the root password
# and opens SSH, so a path that is wrong — renamed, moved, not executable — has
# to stop us here, while the host is still untouched.
PREPARE="${SOURCE_SCRIPT}/scripts/prepare-kvm-host.sh"
CLOUDMONKEY="${SOURCE_SCRIPT}/scripts/cloudmonkey-install.sh"
CS_INSTALLER="${SOURCE_SCRIPT}/scripts/cloudstack-install.sh"
PREFLIGHT="${SOURCE_SCRIPT}/scripts/preflight-bridge-netfilter.sh"
for script in "${PREPARE}" "${CLOUDMONKEY}" "${CS_INSTALLER}" "${PREFLIGHT}"; do
  [[ -x "${script}" ]] || die "Missing or not executable: ${script}"
done

log "Step 1/4: preparing KVM host..."
"${PREPARE}"

log "Step 2/4: install cloudmonkey..."
"${CLOUDMONKEY}"

log "Step 3/4: install cloudstack..."
"${CS_INSTALLER}"

log "Step 4/4: disable KVM bridge netfilter..."
cat >/etc/sysctl.d/99-cloudstack-bridge.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF
sysctl -p /etc/sysctl.d/99-cloudstack-bridge.conf >/dev/null 2>&1 || true
"${PREFLIGHT}"

log "All done. Cloudstack all-in-one setup complete."
