#!/usr/bin/env bash
#
# bootstrap.sh — bare Ubuntu 24.04 to a running lab, in one command. Prepares the
# host, installs CloudStack, then brings up the services in dependency order.
#
# Usage: sudo ./bootstrap.sh
#
# Imperative and root-only; everything after this point is declarative. Safe to
# re-run — every step is a no-op once its work is done.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/lib/common.sh"

# --- Steps ------------------------------------------------------------------

# Correct the system clock before any apt or TLS work, both of which report a
# skewed clock as something else entirely. Asserts that the clock is
# synchronised, not that any particular daemon is enabled — no NTP daemon is
# installed here because the CloudStack installer brings openntpd, which
# conflicts with chrony.
sync_clock() {
  log "Clock before sync: $(date)"

  timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP via timedatectl."
  systemctl restart systemd-timesyncd 2>/dev/null || true

  log "Waiting for the clock to synchronise..."
  for ((i = 0; i < 60; i++)); do
    if [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]]; then
      log "Clock synchronised: $(date)"
      return 0
    fi
    sleep 1
  done

  die "Clock did not synchronise within 60s — apt signature validation will fail."
}

# Verify the host can run KVM guests. Verify-only: neither failure is something
# a script can repair, so both messages name the likely cause rather than the
# symptom. Fatal, because every later phase boots VMs.
check_kvm() {
  log "Checking hardware virtualization..."

  grep -Eq '(vmx|svm)' /proc/cpuinfo ||
    die "CPU reports no vmx/svm flag — if this host is itself a VM, enable nested virtualization on the hypervisor."
  [[ -c /dev/kvm ]] ||
    die "/dev/kvm is missing — the kvm_intel/kvm_amd module did not load. Check 'lsmod | grep kvm' and 'dmesg | grep -i kvm'."

  log "KVM available: $(grep -Eom1 '(vmx|svm)' /proc/cpuinfo) flag present, /dev/kvm ready"
}

# Install the tooling later phases assume: curl and ca-certificates to fetch over
# TLS (Docker's repository key, immediately below), jq for JSON, envsubst for
# rendering ${VAR} templates, openssl for credentials and the Phase 2 CA.
# ca-certificates ships no binary, so its presence is asked of dpkg rather than
# the shell — everything else is tested by whether the command resolves.
install_cli_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v envsubst >/dev/null 2>&1 || missing+=(gettext-base)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)

  if ! dpkg -s ca-certificates >/dev/null 2>&1; then
    missing+=(ca-certificates)
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "CLI tools are installed"
    return
  fi
  log "Installing CLI tools: ${missing[*]}..."
  apt-get update
  apt-get install -y "${missing[@]}" ||
    die "Failed to install ${missing[*]}."
  log "CLI tools ready"
}

# Install Docker Engine and the Compose v2 plugin from Docker's own apt
# repository rather than the get.docker.com convenience script: the key and repo
# are pinned, every package is signed, and the result is auditable. Verifies the
# daemon responds, not merely that a binary exists.
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return
  fi

  log "Installing Docker..."

  local codename
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker

  docker info >/dev/null 2>&1 ||
    die "Docker installed but the daemon is not responding — check 'systemctl status docker'."
  docker compose version >/dev/null 2>&1 ||
    die "Docker installed but the compose plugin is missing."

  log "Docker ready: $(docker --version)"
}

# ---- Services --------------------------------------------------------------
#
# CoreDNS comes first among the services, so friendly names resolve for every
# installer below it. Vault, Gitea, MinIO and the proxy slot in after it from
# Phase 3.

# Hand off to the CloudStack all-in-one installer, which owns ROOT_PASSWORD, the
# executable guards on its four child scripts, and the step ordering — kept there
# rather than duplicated here.
#
# Load-bearing position: cloudbr0 does not exist until this returns, so every
# later step calling bridge_ip or gateway_ip depends on it. That ordering is why
# host preparation and service deployment share one script.
install_cloudstack() {
  local installer="${SOURCE_SCRIPT}/cloudstack/cloudstack-install-all.sh"
  [[ -x "${installer}" ]] || die "Missing or not executable: ${installer}"

  log "Running the CloudStack all-in-one installer (this takes a while)..."
  "${installer}"
  log "CloudStack installed; cloudbr0 is up."
}

main() {
  require_root
  sync_clock
  check_kvm
  install_cli_tools
  install_docker
  install_cloudstack
}

main "$@"
