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

# --- Transcript -------------------------------------------------------------
#
# SKELETON. Every TODO is a decision to make, not just code to write. Numbered
# L-x to match docs/decisions.md L-1.
#
# One run of this script is a forty-minute unattended install of software we did
# not write, and the only record of what it did is whatever scrolled past. The
# transcript is that record, written to a file so it survives the terminal.
#
# THE CONSTRAINT THAT DECIDES THE SHAPE: this cannot push anywhere. Loki is Phase
# 13.2 and this is Phase 0, so the transcript is a plain local file that a later
# agent ingests — never a push, never a network dependency. Same rule as the
# netplan snapshot in 1.3-6: a record must not depend on the thing it records.
#
# TODO L-1.1: one `exec` redirect, here, before any step runs — NOT a `tee` on
#             each call. Children inherit the file descriptors, so this captures
#             ca-install-all.sh, coredns-installer.sh, and the 2,700-line
#             vendored CloudStack installer with no change to any of them. That
#             last one is the whole point: it is the output you most want after a
#             failed install and the one you cannot get by teeing call sites.
#
#               exec > >(tee -a "${LOG_FILE}") 2>&1
#
# TODO L-1.2: strip ANSI on the FILE branch only. common.sh's log/warn/die emit
#             \033[1;32m, which lands in the file as literal escape bytes and
#             makes it grep-hostile. Do not fix this by removing colour, and do
#             NOT make log() conditional on [[ -t 1 ]] — after the exec above,
#             stdout is a pipe, so that test is false and colour would vanish
#             from the terminal too. Tee into a stripper instead, and use sed -u:
#             without unbuffered output the tail is lost on a crash.
#
# TODO L-1.3: wait for tee before exiting. Process substitution can outlive the
#             script, so a `die` at the end can truncate the log at exactly the
#             moment it matters. Capture the substitution PID from $! straight
#             after the exec and wait on it in an EXIT trap. This is the single
#             most common way a logging harness works until the day it is needed.
#             Prove it: make the last step die, and check the file has the
#             message.
#
# TODO L-1.4: the filename. A run identity that cannot overwrite the run before
#             it — re-running bootstrap must not destroy the log of the run that
#             failed. Decide the directory, the timestamp format (UTC), and the
#             mode. 0640 root:adm is the convention; see L-1.6 for why the mode
#             is a security control here rather than housekeeping.
#
# TODO L-1.5: per-line timestamps. Forty minutes of output without them cannot
#             be read, and the vendored installer emits none of its own. `ts` from
#             moreutils is the obvious tool and is NOT installed on this host —
#             so either add it to install_cli_tools or prefix with awk/strftime
#             and take no new dependency. Whichever, it goes on the file branch
#             ahead of the ANSI strip.
#
# TODO L-1.6: decide `set -x`, deliberately. BASH_XTRACEFD sends trace to a
#             dedicated fd, so it can go to the file and never to the terminal:
#
#               exec 9>>"${LOG_FILE}"; BASH_XTRACEFD=9; set -x
#
#             The cost is real. cloudstack-install.sh:1148 runs
#             `cloudstack-setup-databases cloud:cloud@localhost` — with -x that
#             credential is in a file, permanently. The CA scripts are safe (the
#             passphrase goes openssl rand > file and never through an echoed
#             variable), but the vendored installer is not ours and has not been
#             audited for this. If -x is on, L-1.4's mode is a control.
#
# TODO L-1.7: rotation. One file per run, forever, is a disk leak on a host that
#             already carries 22 GB of containerd data. logrotate drop-in, or a
#             retention sweep in this script. Decide which owns it.

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

# Run the CA installer: the offline root, the intermediate, and Vault's leaf —
# the only certificate this CA issues, since Vault's PKI engine takes over at
# 3.4 (3.4-1). Before CloudStack — it is seconds of local openssl work, so a bad
# path fails here rather than after a long install, which is also why issuance
# sits inside the CA installer rather than beside the service that reads it.
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

# Run the Vault installer: prepares ownership, starts the container behind the
# certificate ca/ issued, then initialises and unseals it. Last, and after
# CoreDNS: Vault is reached by name from the moment it exists, so the resolver
# has to answer first.
install_vault() {
  local installer="${SOURCE_SCRIPT}/docker/vault/vault-installer.sh"
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
  install_vault
}

main "$@"
