#!/usr/bin/env bash

# bootstrap.sh - Install core services for the host
#
#   sudo ./bootstrap.sh
#

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Absolute, so `sudo /path/to/bootstrap.sh` from anywhere still builds the venv
# beside the script rather than in whatever directory you happened to be in.
VENV="${SOURCE_SCRIPT}/.venv"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

require_root() {
  # ${0##*/} strips the leading path — same result as basename, without
  # spawning a process. $0 is what the user actually typed, so the hint below
  # is always runnable exactly as printed.
  [[ ${EUID} -eq 0 ]] || die "${0##*/} must be run as root:  sudo ${0}"
}

sync_clock() {
  log "Syncing clock for apt"

  timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP"
  systemctl restart systemd-timesyncd 2>/dev/null || true

  log "Waiting for the clock to synchronise..."
  local count
  for ((count=0; count < 60; count++)); do
    if [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]]; then
      log "Clock synced"
      return 0
    fi
    sleep 1
  done

  die "Clock did not sync"
}

install_deps() {
  log "Installing Dependencies..."
  apt-get update
  apt-get install -y python3-venv ca-certificates curl
}

# Named for what it does. It never activates anything: `source .../activate`
# only edits PATH in the current shell, and this script's shell exits a few lines
# later. Callers use "${VENV}/bin/python" by path instead.
create_venv() {
  if [[ -x "${VENV}/bin/python" ]]; then
    log "venv already present at ${VENV}"
  else
    log "Creating venv at ${VENV}..."
    python3 -m venv "${VENV}"
  fi

  log "Installing the lab package..."
  "${VENV}/bin/pip" install --quiet -e "${SOURCE_SCRIPT}"

  if [[ -n "${SUDO_USER:-}" ]]; then
    # "user:" — a trailing colon means the user's own login group, whatever it
    # is called. Spelling the group as the username assumes Ubuntu's default
    # useradd behaviour, and chown exits non-zero on any host where that is
    # not true, killing the script after the venv is already built.
    chown -R "${SUDO_USER}:" "${VENV}"
  else
    warn "SUDO_USER is unset, so this is a real root shell — ${VENV} stays root-owned."
  fi
}

install_docker() {
  # `docker compose`, not `docker`: Ubuntu's own docker.io package provides the
  # daemon but not the compose plugin, so a host carrying it would pass a
  # `command -v docker` check here and then fail at the first compose file.
  if docker compose version >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return 0
  fi

  log "Installing docker..."

  # No sudo anywhere below: require_root already guaranteed EUID 0, and calling
  # sudo from a root shell only adds a dependency on sudo being installed.
  #
  # install -d rather than mkdir -p, because it sets the mode in the same call.
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  # apt drops to the _apt user before verifying signatures, so the key has to be
  # world-readable or verification fails on permissions.
  chmod a+r /etc/apt/keyrings/docker.asc

  # The armoured key is referenced directly with signed-by, so there is no
  # gpg --dearmor step — and trust is scoped to this one repository rather than
  # granted to everything apt fetches.
  # shellcheck disable=SC1091  # /etc/os-release is a host file, not in the repo
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc]" \
    "https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

add_docker_group() {
  if [[ -z "${SUDO_USER:-}" ]]; then
    warn "SUDO_USER is unset, so there is no account to add to the docker group."
    return 0
  fi

  if id -nG "${SUDO_USER}" | tr ' ' '\n' | grep -qx docker; then
    log "${SUDO_USER} is already in the docker group"
    return 0
  fi

  usermod -aG docker "${SUDO_USER}"
  log "Added ${SUDO_USER} to the docker group - log out and back in to use it"
}

main() {
  require_root
  sync_clock
  install_deps
  create_venv
  install_docker
  add_docker_group
}

main "$@"
