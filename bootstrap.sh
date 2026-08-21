#!/usr/bin/env bash
#
# bootstrap.sh — bare Ubuntu 24.04 to a running lab, in one command.
# Prepares the host, installs CloudStack, then installs the services.
#
# Usage: sudo ./bootstrap.sh
#
# Safe to re-run: every step is a no-op once its work is done.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/lib/common.sh"

# --- Steps ------------------------------------------------------------------

# Enable NTP and wait up to 60s for the clock to synchronise. Runs first because
# a skewed clock breaks apt and TLS.
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

# Check the host can run KVM guests. Verify-only, and fatal: later phases boot VMs.
check_kvm() {
  log "Checking hardware virtualization..."

  grep -Eq '(vmx|svm)' /proc/cpuinfo ||
    die "CPU reports no vmx/svm flag — if this host is itself a VM, enable nested virtualization on the hypervisor."
  [[ -c /dev/kvm ]] ||
    die "/dev/kvm is missing — the kvm_intel/kvm_amd module did not load. Check 'lsmod | grep kvm' and 'dmesg | grep -i kvm'."

  log "KVM available: $(grep -Eom1 '(vmx|svm)' /proc/cpuinfo) flag present, /dev/kvm ready"
}

# Install the CLI tools later steps use: curl, jq, envsubst, openssl and
# ca-certificates. Installs only what is missing.
install_cli_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v envsubst >/dev/null 2>&1 || missing+=(gettext-base)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)

  # ca-certificates ships no binary, so ask dpkg instead of the shell.
  if ! dpkg -s ca-certificates >/dev/null 2>&1; then
    missing+=(ca-certificates)
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "CLI tools are installed"
    return
  fi
  log "Installing CLI tools: ${missing[*]}..."
  apt_get update
  apt_get install -y "${missing[@]}" ||
    die "Failed to install ${missing[*]}. If this reports a dpkg lock, another package manager held it for longer than ${APT_LOCK_TIMEOUT}s — wait for unattended-upgrades to finish and re-run."
  log "CLI tools ready"
}

# Install Docker Engine and the Compose v2 plugin from Docker's own apt
# repository, then check the daemon actually responds.
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

  apt_get update
  apt_get install -y \
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

# Run the CA installer: the offline root, then the intermediate that signs
# everything the lab serves over TLS. Before CloudStack — it is seconds of local
# openssl work, so a bad path fails here rather than after a long install.
install_ca() {
  local installer="${SOURCE_SCRIPT}/ca/ca-install-all.sh"
  [[ -x "${installer}" ]] || die "Missing or not executable: ${installer}"
  "${installer}"
}

# Run the CloudStack all-in-one installer, which also creates the cloudbr0 bridge.
install_cloudstack() {
  local installer="${SOURCE_SCRIPT}/cloudstack/cloudstack-install-all.sh"
  [[ -x "${installer}" ]] || die "Missing or not executable: ${installer}"

  log "Running the CloudStack all-in-one installer (this takes a while)..."
  "${installer}"
  log "CloudStack installed; cloudbr0 is up."
}

# Run the CoreDNS installer: renders its config, starts the container, and points
# the host resolver at it. After CloudStack, whose bridge it binds to.
install_coredns() {
  local installer="${SOURCE_SCRIPT}/docker/coredns/coredns-installer.sh"
  [[ -x "${installer}" ]] || die "Missing or not executable: ${installer}"
  "${installer}"
}

# Run every step, in dependency order.
main() {
  require_root
  sync_clock
  check_kvm
  install_cli_tools
  install_docker
  install_ca
  install_cloudstack
  install_coredns
}

main "$@"
