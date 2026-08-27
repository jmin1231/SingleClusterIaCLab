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

# journald retention. The number orders this file against other NUMBERED
# drop-ins only: *.conf.d/ sorts by filename across every search directory, so a
# vendor file starting with a letter outranks it from a lower-priority one. Two
# constants because masking that vendor file needs a second path here. See L-2.
JOURNALD_DIR="/etc/systemd/journald.conf.d"
JOURNALD_DROPIN="${JOURNALD_DIR}/10-lab.conf"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"

# 2.1-1's mitigation, named there and never built. Host preparation runs on every
# invocation, and from Phase 3 on the service layer is re-run far more often than
# the host changes.
#
# It skips the steps that MUTATE the host, not everything before the services.
# require_root and check_kvm stay: neither prepares anything — check_kvm only
# verifies, and its failures are fatal (0.3-3). start_transcript stays because it
# is the record of the run, and a skipped run still needs one.
#
# Validated rather than tested loosely, so SKIP_HOST_PREP=true fails instead of
# being silently ignored — which would look exactly like the flag not working.
SKIP_HOST_PREP="${SKIP_HOST_PREP:-0}"
[[ "${SKIP_HOST_PREP}" == "0" || "${SKIP_HOST_PREP}" == "1" ]] ||
  die "SKIP_HOST_PREP must be 0 or 1, got '${SKIP_HOST_PREP}'."

# --- Transcript -------------------------------------------------------------
#
# One run is forty minutes of unattended installation of software we did not
# write, and the only other record is terminal scrollback. It cannot push
# anywhere — Loki is Phase 13.2, this is Phase 0 — so it is a plain local file:
# a record must not depend on the thing it records (1.3-6). See L-1.

# Fixed at script start so the run identity cannot change mid-run. UTC and
# ISO-8601 basic form, so lexicographic order is chronological order.
LOG_DIR="/var/log/lab"
LOG_FILE="${LOG_DIR}/bootstrap-$(date -u +%Y%m%dT%H%M%SZ).log"

# --- Steps ------------------------------------------------------------------

# Open this run's transcript. Called after require_root rather than at file
# scope: the redirect would otherwise precede the root check, and a non-root run
# would die on "permission denied" instead of the readable message.
start_transcript() {
  # Mode set at creation, not corrected afterwards — this holds the output of a
  # privileged install and must never be briefly world-readable.
  install -d -m 0750 -o root -g adm "${LOG_DIR}" ||
    die "Cannot create ${LOG_DIR} — check 'df -h /var/log' and 'mount | grep /var'."
  install -m 0640 -o root -g adm /dev/null "${LOG_FILE}" ||
    die "Cannot create ${LOG_FILE} — check free space and mount options."

  # Keep the newest 20. Filenames sort chronologically, so sort is the ordering
  # rather than mtime, which a copy or a restore would rewrite.
  compgen -G "${LOG_DIR}/bootstrap-*.log" 2>/dev/null |
    sort -r | tail -n +21 | xargs -r rm -f || true

  # One redirect for the whole process — children inherit these descriptors, so
  # it captures the vendored CloudStack installer without touching it.
  #
  # fd 3 is the terminal branch, which is why colour survives there and not in
  # the file. NOT `tee >(...)`: nesting hides a process from $!, so
  # close_transcript could only wait for the outer one. printf '%(...)T' is a
  # builtin — no fork per line, and no dependency on moreutils' ts or gawk's
  # strftime, since a fresh Ubuntu defaults to mawk.
  exec 3>&1
  exec > >(
    export TZ=UTC
    while IFS= read -r line; do
      printf '%s\n' "${line}" >&3
      printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "${line}"
    done | sed -u 's/\x1B\[[0-9;]*[mK]//g' >>"${LOG_FILE}"
  ) 2>&1

  # Global: close_transcript reads it from a trap, after this function returns.
  TRANSCRIPT_PID=$!
  trap close_transcript EXIT

  log "Transcript: ${LOG_FILE}"
}

# Flush and close the transcript, preserving the exit status. The shell does not
# wait for its process substitutions, so without this a die can exit while the
# tail of the log is still in an undrained pipe.
close_transcript() {
  local rc=$? # first statement: $? is still the script's status

  # Closing fd 1 and 2 is what gives the writer EOF; without it the wait never
  # returns. Nothing may write to stdout or stderr below this line.
  exec 1>&- 2>&-
  wait "${TRANSCRIPT_PID}" 2>/dev/null || true

  # Explicit, so a line added above can never turn a failed run into exit 0.
  exit "${rc}"
}

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

# Give the journal a retention policy before anything noisy writes to it.
# After sync_clock, because MaxRetentionSec ages entries by their own
# timestamps; before install_cloudstack, whose output is the history it keeps.
#
# journald accepts a drop-in it ignored — a bad section header or a typo'd key
# reads as "running on defaults", indistinguishable from success. So the checks
# below assert what the daemon concluded, never the file that was written.
#
# ForwardToSyslog is deliberately left as Ubuntu ships it, so every entry is on
# disk twice (L-2). Revisit when the Docker log driver lands: container output
# starts being duplicated into /var/log/syslog too.
configure_journald() {
  local rendered restarted_at complaints

  # Above the early return: install -d re-asserts the mode on an existing
  # directory where mkdir -p would not, so a re-run corrects drift.
  install -d -m 0755 "${JOURNALD_DIR}"

  # `<<-` strips leading TABS only — that is what puts [Journal] at column 0.
  # Spaces would survive, and an indented section header is not a header.
  rendered="$(
    cat <<-'EOF'
			[Journal]
			# Storage=auto means "persistent if /var/log/journal exists", and no package
			# creates that directory — so on a fresh VM the default is a coin flip.
			Storage=persistent

			# SystemKeepFree guards what is NOT the journal: CloudStack primary and
			# secondary storage share this disk. MaxRetentionSec is aligned on purpose
			# with logrotate's `rotate 4, weekly` for /var/log/syslog — do not change
			# one without the other.
			SystemMaxUse=2G
			SystemKeepFree=20G
			MaxRetentionSec=1month
		EOF
  )"

  # Matching content alone is not enough to skip: a run that died after writing
  # would leave it matching, and the next run would return before checking
  # anything. Restarting journald pulls the log socket out from under every
  # service, so the skip has to be real.
  if [[ -f "${JOURNALD_DROPIN}" && "$(<"${JOURNALD_DROPIN}")" == "${rendered}" && -d /var/log/journal ]]; then
    log "journald retention already configured"
    return 0
  fi

  log "Configuring journald retention..."
  printf '%s\n' "${rendered}" >"${JOURNALD_DROPIN}"
  chmod 0644 "${JOURNALD_DROPIN}"

  # Before the restart, so the query below cannot match a complaint the previous
  # instance made about a previous version of this file.
  restarted_at="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl restart systemd-journald ||
    die "systemd-journald failed to restart — check 'systemctl status systemd-journald' and ${JOURNALD_DROPIN}."

  # Silence is success: systemd's parser names the offending FILE in every
  # complaint, so our own path is the pattern rather than error wording upstream
  # can reword. Captured, not piped into `grep -q`: -q exits on first match, the
  # producer takes SIGPIPE, and pipefail then reports the pipeline as failed —
  # so the test would read false on a match and never fire.
  complaints="$(journalctl -u systemd-journald --since "${restarted_at}" --no-pager 2>/dev/null || true)"
  if grep -qF "${JOURNALD_DROPIN}" <<<"${complaints}"; then
    die "journald rejected ${JOURNALD_DROPIN} — see: journalctl -u systemd-journald --since '${restarted_at}'"
  fi

  # What the parse check cannot see: a file that parses and still leaves storage
  # volatile, which looks like success until the next reboot throws it away.
  [[ -d /var/log/journal ]] ||
    die "journald did not create /var/log/journal — storage is still volatile, so this install will not survive a reboot."

  log "journald retention configured — $(journalctl --disk-usage)"
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

# Install Docker Engine and the Compose v2 plugin from Docker's own apt
# repository, then check the daemon actually responds.
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

# Point Docker's logs at journald, so container output and systemd unit output
# share one store, one query tool and one retention policy (L-2). Runs directly
# after install_docker and before any container exists: LogConfig is baked in at
# container creation, so anything started under the old driver keeps it until
# recreated.
#
# Wholesale ownership of daemon.json rather than a jq merge — Docker has no
# conf.d, and T-3 already assumes a fresh VM. That discards a stale
# insecure-registries entry naming a Gitea this repo has not built, at a
# hardcoded address 0.4-1 exists to prevent; Phase 4 adds it back derived from
# bridge_ip().
#
# tag "{{.Name}}" is set daemon-wide, so every container is queryable by its own
# name (journalctl -t vault) with no per-compose configuration. The default is
# the first 12 characters of the container ID, which changes on every recreate.
configure_docker() {
  local rendered stale

  rendered="$(
    cat <<-'EOF'
			{
			  "log-driver": "journald",
			  "log-opts": {
			    "tag": "{{.Name}}"
			  }
			}
		EOF
  )"

  if [[ -f "${DOCKER_DAEMON_JSON}" && "$(<"${DOCKER_DAEMON_JSON}")" == "${rendered}" ]]; then
    log "Docker logging already configured"
    return 0
  fi

  log "Pointing Docker's logs at journald..."
  install -d -m 0755 "${DOCKER_DAEMON_JSON%/*}"
  printf '%s\n' "${rendered}" >"${DOCKER_DAEMON_JSON}"
  chmod 0644 "${DOCKER_DAEMON_JSON}"

  # Not reloadable: log-driver is not in dockerd's SIGHUP set.
  systemctl restart docker ||
    die "Docker failed to restart after writing ${DOCKER_DAEMON_JSON} — malformed JSON is the usual cause. Check 'journalctl -u docker -n 30'."

  [[ "$(docker info --format '{{.LoggingDriver}}' 2>/dev/null)" == "journald" ]] ||
    die "Docker restarted but its logging driver is not journald — check ${DOCKER_DAEMON_JSON}."

  # A re-run on a live lab is exactly when this matters: those containers still
  # write json-file and will keep doing so until they are recreated.
  stale="$(docker ps -aq 2>/dev/null | wc -l)"
  ((stale == 0)) ||
    warn "${stale} container(s) predate this change and keep their original log driver; recreate with 'docker compose up -d --force-recreate'."

  log "Docker logging: journald, tagged by container name"
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
VAULT_CONFIGURE="${SOURCE_SCRIPT}/docker/vault/vault-configure.sh"
PROXY_INSTALLER="${SOURCE_SCRIPT}/docker/proxy/proxy-installer.sh"
for script in "${CA_INSTALLER}" "${CLOUDSTACK_INSTALLER}" "${COREDNS_INSTALLER}" \
  "${VAULT_INSTALLER}" "${VAULT_CONFIGURE}" "${PROXY_INSTALLER}"; do
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

# Run the CloudStack all-in-one installer, which also creates the cloudbr0 bridge.
install_cloudstack() {
  log "Running the CloudStack all-in-one installer (this takes a while)..."
  "${CLOUDSTACK_INSTALLER}"
  log "CloudStack installed; cloudbr0 is up."
}

# Run the CoreDNS installer: renders its config, starts the container, and points
# the host resolver at it. After CloudStack, whose bridge it binds to.
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

# Run the proxy installer: issue a certificate from Vault's PKI engine, render
# the vhost against the discovered bridge address, start nginx. Last, and after
# configure_vault, because the certificate comes from pki/issue/lab-server —
# which is 3.4-1's reordering of 2.5. Vault is NOT behind this proxy; it
# terminates its own TLS on :8200.
install_proxy() {
  "${PROXY_INSTALLER}"
}

# Run every step, in dependency order.
main() {
  require_root
  start_transcript
  check_kvm

  if [[ "${SKIP_HOST_PREP}" == "1" ]]; then
    warn "SKIP_HOST_PREP=1 — skipping clock, journald, CLI tools and Docker."
    # Asserted anyway, for the same reason check_kvm runs early: install_coredns
    # and install_vault both need Docker, and failing here names the cause where
    # failing there names a container.
    verify_docker
  else
    sync_clock
    configure_journald
    install_cli_tools
    install_docker
    configure_docker
  fi

  install_ca
  install_cloudstack
  install_coredns
  install_vault
  configure_vault
  install_proxy
}

main "$@"
