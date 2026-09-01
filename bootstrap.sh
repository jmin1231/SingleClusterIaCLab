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

install_deps() {
  log "Installing Dependencies..."
  apt-get update
  apt-get install -y python3-venv
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
    chown -R "${SUDO_USER}:${SUDO_USER}" "${VENV}"
  else
    warn "SUDO_USER is unset, so this is a real root shell — ${VENV} stays root-owned."
  fi
}

main() {
  require_root
  install_deps
  create_venv
}

main "$@"
