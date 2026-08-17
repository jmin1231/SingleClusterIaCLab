#!/usr/bin/env bash
#
# common.sh — helpers shared by every script in this repo.
#
# SOURCE this file, never execute it — hence not +x. Definitions only, so
# sourcing twice is harmless. Sets no shell options: `set -euo pipefail` belongs
# in the calling script where it can be seen.
#
# log goes to stdout (a script's output), warn and die to stderr (diagnostics).
# die calls exit, which is what makes it work inside a function — and which will
# close your terminal if you source this interactively and call it.
#
# Value-returning functions below print to stdout and must never log there, or
# the log line lands in the caller's variable.

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

# Refuse to run as anyone but root, before doing any work. $0 is the calling
# script as the user invoked it, so the hint is always runnable as printed.
require_root() {
  [[ ${EUID} -eq 0 ]] || die "${0##*/} must be run as root:  sudo ${0}"
}

# Print a bridge's IPv4 address. Usage: ip="$(bridge_ip)" or bridge_ip br0
#
# The single producer of this value: it differs per host, so it is discovered at
# run time rather than written down, and every consumer reads it from here.
bridge_ip() {
  local bridge="${1:-cloudbr0}" ip
  ip="$(ip -4 addr show "${bridge}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)"
  [[ -n "${ip}" ]] || die "${bridge} has no IPv4 address; is it up?"
  printf '%s' "${ip}"
}
