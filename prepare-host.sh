#!/usr/bin/env bash
#
# prepare-host.sh — day-0 preparation for a bare Ubuntu 24.04 host: correct the
# clock, verify hardware virtualization, and install the tooling every later
# phase assumes. Imperative and run once by hand; everything after this point is
# declarative. Root-only, and safe to re-run.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- Helpers ----------------------------------------------------------------
log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

# Refuse to run as anyone but root, before doing any work.
require_root() {
  [[ ${EUID} -eq 0 ]] || die "prepare-host.sh must be run as root:  sudo ./prepare-host.sh"
}

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

# Install CLI tools the component rely on:
install_cli_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v envsubst >/dev/null 2>&1 || missing+=(gettext-base)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
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

# Install Docker
# install_docker() {
#     if command -v docker >/dev/null 2>&1; then
#       log "Docker is already installed: $(docker --version)"
#     else
#       if !
# }

main() {
  require_root
  sync_clock
  check_kvm
  install_cli_tools
}

main "$@"
