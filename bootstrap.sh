#!/usr/bin/env bash
#
# bootstrap.sh — bare Ubuntu 24.04 to a running lab, in one command.
# Prepares the host, installs CloudStack, then installs the services.
#
# Usage: sudo ./bootstrap.sh
#        sudo SKIP_HOST_PREP=1 ./bootstrap.sh   # host already prepared
#
# Safe to re-run: every step is a no-op once its work is done.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/lib/common.sh"

# 2.1-1's mitigation, named there and never built. Host preparation runs on every
# invocation, and from Phase 3 on the service layer is re-run far more often than
# the host changes.
#
# It skips the steps that MUTATE the host, not everything before the services.
# require_root and check_kvm stay: neither prepares anything — check_kvm only
# verifies, and its failures are fatal (0.3-3).
#
# Validated rather than tested loosely, so SKIP_HOST_PREP=true fails instead of
# being silently ignored — which would look exactly like the flag not working.
SKIP_HOST_PREP="${SKIP_HOST_PREP:-0}"
[[ "${SKIP_HOST_PREP}" == "0" || "${SKIP_HOST_PREP}" == "1" ]] ||
  die "SKIP_HOST_PREP must be 0 or 1, got '${SKIP_HOST_PREP}'."

# --- Steps ------------------------------------------------------------------

# Enable NTP and wait up to 60s for the clock to synchronise. Runs first because
# a skewed clock breaks apt and TLS.
sync_clock() {
  log "Clock before sync: $(date)"

  timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP via timedatectl."
  systemctl restart systemd-timesyncd 2>/dev/null || true

  log "Waiting for the clock to synchronise..."
  local i
  for ((i = 0; i < 60; i++)); do
    if [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]]; then
      log "Clock synchronised: $(date)"
      return 0
    fi
    sleep 1
  done

  die "Clock did not synchronise within 60s — apt signature validation will fail."
}

# Verify-only, and fatal: later phases boot VMs.
check_kvm() {
  log "Checking hardware virtualization..."

  grep -Eq '(vmx|svm)' /proc/cpuinfo ||
    die "CPU reports no vmx/svm flag — if this host is itself a VM, enable nested virtualization on the hypervisor."
  [[ -c /dev/kvm ]] ||
    die "/dev/kvm is missing — the kvm_intel/kvm_amd module did not load. Check 'lsmod | grep kvm' and 'dmesg | grep -i kvm'."

  log "KVM available: $(grep -Eom1 '(vmx|svm)' /proc/cpuinfo) flag present, /dev/kvm ready"
}

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

# Assert Docker is usable, not merely present. Called on BOTH paths of
# install_docker: `command -v docker` proves a binary exists on PATH and nothing
# else, and `apt install docker.io` leaves exactly the state it cannot see — a
# daemon that may be dead and no compose plugin at all. Returning early on the
# binary alone would mean a half-installed Docker never converges, which is the
# line at the top of this file claiming more than it delivers.
verify_docker() {
  docker info >/dev/null 2>&1 ||
    die "Docker is installed but the daemon is not responding — check 'systemctl status docker'."
  docker compose version >/dev/null 2>&1 ||
    die "Docker is installed but the compose plugin is missing — install docker-compose-plugin."

  log "Docker ready: $(docker --version)"
}

# From Docker's own apt repository, not Ubuntu's.
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    verify_docker
    return
  fi

  log "Installing Docker..."

  local codename
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc ||
    die "Could not fetch Docker's signing key — check egress to download.docker.com."
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
    docker-compose-plugin ||
    die "Failed to install Docker packages — check 'apt-get update' output above for the docker.sources repository."

  systemctl enable --now docker
  verify_docker
}

# ---- Services --------------------------------------------------------------

# Resolve every installer before running any of them, as ca-install-all.sh and
# cloudstack-install-all.sh already do. This replaces a guard that was repeated
# in each wrapper — 0.2-5's revisit trigger, which fired at the fifth copy — and
# it is strictly better than factoring that guard into a helper: a per-call check
# fails at the point of use, so a missing vault-configure.sh would surface only
# after CloudStack had installed and the CA existed. This stops while the host is
# still untouched.
CA_INSTALLER="${SOURCE_SCRIPT}/ca/ca-install-all.sh"
CLOUDSTACK_INSTALLER="${SOURCE_SCRIPT}/cloudstack/cloudstack-install-all.sh"
COREDNS_INSTALLER="${SOURCE_SCRIPT}/docker/coredns/coredns-installer.sh"
VAULT_INSTALLER="${SOURCE_SCRIPT}/docker/vault/vault-installer.sh"
VAULT_CONFIGURE="${SOURCE_SCRIPT}/docker/vault/scripts/vault-configure.sh"
VAULT_ENSURE_CS="${SOURCE_SCRIPT}/docker/vault/scripts/vault-ensure-cloudstack.sh"
VAULT_ENSURE_GITEA="${SOURCE_SCRIPT}/docker/vault/scripts/vault-ensure-gitea.sh"
GITEA_INSTALLER="${SOURCE_SCRIPT}/docker/gitea/gitea-installer.sh"
VAULT_ENSURE_GITEA_TOKEN="${SOURCE_SCRIPT}/docker/vault/scripts/vault-ensure-gitea-token.sh"
GITEA_REPO_SETUP="${SOURCE_SCRIPT}/docker/gitea/gitea-repo-setup.sh"
TOOLBOX_INSTALLER="${SOURCE_SCRIPT}/docker/toolbox/toolbox-installer.sh"
PROXY_INSTALLER="${SOURCE_SCRIPT}/docker/proxy/proxy-installer.sh"
for script in "${CA_INSTALLER}" "${CLOUDSTACK_INSTALLER}" "${COREDNS_INSTALLER}" \
  "${VAULT_INSTALLER}" "${VAULT_CONFIGURE}" "${VAULT_ENSURE_CS}" \
  "${VAULT_ENSURE_GITEA}" "${GITEA_INSTALLER}" \
  "${VAULT_ENSURE_GITEA_TOKEN}" "${GITEA_REPO_SETUP}" \
  "${TOOLBOX_INSTALLER}" "${PROXY_INSTALLER}"; do
  [[ -x "${script}" ]] || die "Missing or not executable: ${script}"
done

# The wrappers below stay one-liners rather than collapsing into main(): each
# carries the reason it runs where it does, and main() reads as a dependency
# order rather than a list of paths.

# Run the CA installer: the offline root, the intermediate, and Vault's leaf —
# the only certificate this CA issues, since Vault's PKI engine takes over at
# 3.4 (3.4-1). Before CloudStack — it is seconds of local openssl work, so a bad
# path fails here rather than after a long install, which is also why issuance
# sits inside the CA installer rather than beside the service that reads it.
install_ca() {
  "${CA_INSTALLER}"
}

# The all-in-one installer also creates the cloudbr0 bridge.
install_cloudstack() {
  log "Running the CloudStack all-in-one installer (this takes a while)..."
  "${CLOUDSTACK_INSTALLER}"
  log "CloudStack installed; cloudbr0 is up."
}

# After CloudStack, whose bridge it binds to.
install_coredns() {
  "${COREDNS_INSTALLER}"
}

# Run the Vault installer: prepares ownership, starts the container behind the
# certificate ca/ issued, then initialises and unseals it. Last, and after
# CoreDNS: Vault is reached by name from the moment it exists, so the resolver
# has to answer first.
install_vault() {
  "${VAULT_INSTALLER}"
}

# Configure the running Vault: audit device, KV v2, and the PKI engine (3.2-3.4).
# Separate from install_vault because of an ordering it cannot escape — the PKI
# engine emits a CSR the offline root signs, so Vault must already be up and
# unsealed. That is the reference lab's server-phase / secrets-phase split, one
# phase earlier. Safe to re-run: it tests each outcome rather than re-issuing
# each command.
configure_vault() {
  "${VAULT_CONFIGURE}"
}

# Seed CloudStack's API credentials into Vault (3.6). After configure_vault
# because it needs the KV mount, and after install_cloudstack because it reads
# the keys from a running management server. Never rotates: it captures what
# CloudStack already holds, and refuses if Vault's copy has gone stale.
# CloudStack's three secrets: admin's API key (captured), a separate identity for
# automation, and admin's UI password (generated). One script because the order
# between them is forced — cmk authenticates by password on a fresh host, so the
# rotation must come last (1.2-2).
ensure_cloudstack_secret() {
  "${VAULT_ENSURE_CS}"
}

# Generate Gitea's database and admin passwords IN Vault, before Gitea exists —
# 4.1's other direction, where Vault is the origin rather than the capturer.
ensure_gitea_secret() {
  "${VAULT_ENSURE_GITEA}"
}

# Gitea and its database, reading those credentials back out of Vault.
install_gitea() {
  "${GITEA_INSTALLER}"
}

# A Gitea API token, minted once and kept in Vault. After install_gitea, because
# it needs the API answering — the other half of 4.1's split, where the service
# mints a credential that cannot be read back.
ensure_gitea_token() {
  "${VAULT_ENSURE_GITEA_TOKEN}"
}

# Push this repository to Gitea and close the gate: direct pushes to main are
# refused, with a status check named before any check exists (4.2).
setup_gitea_repo() {
  "${GITEA_REPO_SETUP}"
}

# Build the CI toolbox image every pipeline job runs in (4.3). Placed by phase
# order, not by dependency: it builds from docker/toolbox/ and needs nothing but
# Docker, so it could run any time after install_docker. It is also the slowest
# step here after CloudStack — roughly a gigabyte of pinned tools — so it is not
# a candidate for running early to fail fast. 4.4 is what consumes it: the
# runner's label names the tag this builds, and the image stays on this host
# rather than going to a registry, because the toolbox is the image every job
# runs in and so cannot be built by a job.
install_toolbox() {
  "${TOOLBOX_INSTALLER}"
}

# Run the proxy installer: issue a certificate from Vault's PKI engine, render
# the vhost against the discovered bridge address, start nginx. Last, and after
# configure_vault, because the certificate comes from pki/issue/lab-server —
# which is 3.4-1's reordering of 2.5. Vault is NOT behind this proxy; it
# terminates its own TLS on :8200.
install_proxy() {
  "${PROXY_INSTALLER}"
}

main() {
  require_root
  check_kvm

  if [[ "${SKIP_HOST_PREP}" == "1" ]]; then
    warn "SKIP_HOST_PREP=1 — skipping clock, CLI tools and Docker."
    # Asserted anyway, for the same reason check_kvm runs early: install_coredns
    # and install_vault both need Docker, and failing here names the cause where
    # failing there names a container.
    verify_docker
  else
    sync_clock
    install_cli_tools
    install_docker
  fi

  install_ca
  install_cloudstack
  install_coredns
  install_vault
  configure_vault
  ensure_cloudstack_secret
  ensure_gitea_secret
  install_gitea
  ensure_gitea_token
  setup_gitea_repo
  install_toolbox
  install_proxy
}

main "$@"
