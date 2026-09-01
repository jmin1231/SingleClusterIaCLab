#!/usr/bin/env bash
#
# cloudstack-install-all.sh — one-shot CloudStack all-in-one install for Ubuntu
# 24.04. Lays a bootstrap resolver floor, prepares the KVM host, installs cmk,
# runs the vendored installer unattended, then disables bridge netfilter and
# verifies it.
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

# Matches the vendored installer's own DNS default. See decisions.md 1.3-2.
BOOTSTRAP_DNS="${BOOTSTRAP_DNS:-8.8.8.8}"
# Sorts below CoreDNS's 10-lab.conf, which retires it. See decisions.md 1.3-3.
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/05-cloudstack-bootstrap.conf"

# The installer's own default, 4.22, is broken upstream. See decisions.md 1.3-4.
CS_REPO_VERSION="${CS_REPO_VERSION:-4.21}"
CS_REPO_URL="${CS_REPO_URL:-https://download.cloudstack.org/ubuntu}"
CS_KEYRING="/etc/apt/keyrings/cloudstack.gpg"
CS_LIST="/etc/apt/sources.list.d/cloudstack.list"

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

# Give systemd-resolved a global resolver for the window in which the installer
# rebuilds host networking and no link yet supplies DNS. Removed by
# coredns-installer.sh in Phase 2.2. See decisions.md 1.3-2.
install_resolver_floor() {
  if ! systemctl is-active --quiet systemd-resolved; then
    warn "systemd-resolved is not active; skipping the bootstrap resolver floor. If the installer fails to resolve download.cloudstack.org immediately after configuring cloudbr0, this is the reason."
    return 0
  fi

  mkdir -p "$(dirname "${RESOLVED_DROPIN}")"
  cat >"${RESOLVED_DROPIN}" <<EOF
# Written by cloudstack-install-all.sh; removed by coredns-installer.sh in Phase 2.2.
[Resolve]
DNS=${BOOTSTRAP_DNS}
EOF
  chmod 644 "${RESOLVED_DROPIN}"

  systemctl restart systemd-resolved ||
    die "Failed to restart systemd-resolved after writing ${RESOLVED_DROPIN}."

  # Assert on resolution, not on the file: ask for the name the installer will fetch.
  resolvectl query download.cloudstack.org >/dev/null 2>&1 ||
    die "Wrote ${RESOLVED_DROPIN} but download.cloudstack.org still does not resolve. The host has no working DNS or no route out; the installer would fail at the signing-key fetch. Check 'resolvectl status' and that ${BOOTSTRAP_DNS} is reachable."

  log "Resolver floor in place: global DNS=${BOOTSTRAP_DNS}"
}

# Write the CloudStack apt repository before the installer looks for it. Seeding the
# list file is how the installer's silent-mode path lets us pin the version without
# patching the vendored file. See decisions.md 1.3-4.
seed_cloudstack_repo() {
  local codename tmp policy
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
  tmp="$(mktemp)"
  # RETURN covers the success path, EXIT the `die` paths. See decisions.md 1.3-4.
  # shellcheck disable=SC2064  # expand tmp now: it is what we want removed
  trap "rm -f '${tmp}'" RETURN EXIT

  log "Fetching the CloudStack signing key..."
  curl -fsS "${CS_REPO_URL%/ubuntu}/release.asc" | gpg --dearmor >"${tmp}" ||
    die "Could not fetch or dearmour the CloudStack signing key from ${CS_REPO_URL%/ubuntu}/release.asc. Check DNS and outbound HTTPS."
  [[ -s "${tmp}" ]] ||
    die "The CloudStack signing key dearmoured to an empty file; refusing to install it."

  install -D -m 0644 "${tmp}" "${CS_KEYRING}"
  printf 'deb [signed-by=%s] %s %s %s\n' \
    "${CS_KEYRING}" "${CS_REPO_URL}" "${codename}" "${CS_REPO_VERSION}" >"${CS_LIST}"
  log "Seeded ${CS_LIST} -> ${codename} ${CS_REPO_VERSION}"

  # Prove the repo yields an installable package before the installer runs on it.
  apt_get update >/dev/null ||
    die "apt-get update failed against ${CS_LIST}. If it reports a size or hash mismatch, component ${CS_REPO_VERSION} is broken upstream — try another with CS_REPO_VERSION=4.xx, and check https://download.cloudstack.org/ubuntu/dists/${codename}/Release for what is published."
  # Captured, not piped: `| grep -q` under pipefail reports 141 on a match.
  # Match a digit because an unavailable package prints `Candidate: (none)`.
  policy="$(apt-cache policy cloudstack-management 2>/dev/null || true)"
  grep -qE 'Candidate: [0-9]' <<<"${policy}" ||
    die "The repository updated but cloudstack-management has no installation candidate; ${CS_REPO_VERSION} may not publish for ${codename}."

  log "CloudStack repo ready: $(awk '/Candidate:/{print $2}' <<<"${policy}")"
}

log "Step 1/6: installing the bootstrap resolver floor..."
install_resolver_floor

log "Step 2/6: seeding the CloudStack apt repository..."
seed_cloudstack_repo

log "Step 3/6: preparing KVM host..."
"${PREPARE}"

log "Step 4/6: install cloudmonkey..."
"${CLOUDMONKEY}"

log "Step 5/6: install cloudstack..."
"${CS_INSTALLER}"

log "Step 6/6: disable KVM bridge netfilter..."
cat >/etc/sysctl.d/99-cloudstack-bridge.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF
sysctl -p /etc/sysctl.d/99-cloudstack-bridge.conf >/dev/null 2>&1 || true
"${PREFLIGHT}"

log "All done. Cloudstack all-in-one setup complete."
