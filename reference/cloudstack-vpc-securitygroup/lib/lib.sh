#!/usr/bin/env bash
#
# lib.sh - shared helpers (logging, tracker, netplan backup) sourced by bootstrap.sh.

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${LIB_DIR}/.." && pwd)"
STATE_DIR="${STATE_DIR:-${REPO_ROOT}/state}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/bootstrap.log}"
TRACKER_FILE="${TRACKER_FILE:-${STATE_DIR}/tracker.conf}"
NETPLAN_SRC="${NETPLAN_SRC:-/etc/netplan}"
NETPLAN_BACKUP_DIR="${NETPLAN_BACKUP_DIR:-/var/backups/cloudstack-lab/netplan.orig}"

# ---- logging ------
log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; _logfile "[+] $*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; _logfile "[!] $*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; _logfile "[x] $*"; exit 1; }


# ---- root guard -----
verify_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "run as root: sudo $0 ${CMD:-}"
    fi
}

# ---- tracking -----

_logfile() {
    mkdir -p "${STATE_DIR}"
    printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG_FILE"
}

track_get() {
    grep "^$1=" "$TRACKER_FILE" 2>/dev/null | cut -d= -f2- || true
}

track_set() {
    local key="$1" value="$2"
    mkdir -p "$STATE_DIR"
    if grep -q "^${key}=" "$TRACKER_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$TRACKER_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$TRACKER_FILE"
    fi
}

is_done() {
    [[ -n "$(track_get "$1")" ]];
}

# ---- tool wrappers  -----
cmk() { command cmk "$@"; }
mc()  { command mc "$@"; }

# ---- dependency install (fresh-VM friendly; needs root) -----

# Ensure a command exists, installing its apt package if missing.
# The update is best-effort so an unrelated broken apt source cannot abort the run;
# a genuinely missing package still fails at the install step.
ensure_apt_pkg() {
    local cmd="$1" pkg="$2"
    command -v "${cmd}" >/dev/null 2>&1 && return 0
    log "Installing ${pkg} (provides ${cmd})"
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}"
}

# Configure the HashiCorp apt repo (provides terraform + packer). Always (re)installs
# the current signing key and our source line, so a stale/rotated key self-heals.
ensure_hashicorp_repo() {
    log "Configuring the HashiCorp apt repository"
    DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/hashicorp.gpg
    chmod a+r /etc/apt/keyrings/hashicorp.gpg
    # shellcheck disable=SC2154,SC1091  # VERSION_CODENAME comes from sourcing os-release
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "${VERSION_CODENAME}") main" \
        >/etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq || true
}


# ---- backup netplan -----
backup_netplan() {
    if is_done netplan_backed_up; then
        log "netplan already backed up ($(track_get netplan_backed_up)); skipping"
        return 0
    fi
    
    mkdir -p "${NETPLAN_BACKUP_DIR}"
    cp -a "${NETPLAN_SRC}"/. "${NETPLAN_BACKUP_DIR}"/
    track_set netplan_backed_up "${NETPLAN_BACKUP_DIR}"
    log "backed up ${NETPLAN_SRC} -> ${NETPLAN_BACKUP_DIR}"
}

# ---- restore netplan -----
# Restore the original netplan from the backup dir (not the tracker, which teardown
# deletes first); a reboot (by cmd_down) applies it.
restore_netplan() {
    if [[ ! -d "${NETPLAN_BACKUP_DIR}" ]]; then
        warn "no netplan backup at ${NETPLAN_BACKUP_DIR}; leaving networking untouched"
        return 0
    fi
    log "Restoring netplan from ${NETPLAN_BACKUP_DIR}"
    rm -f "${NETPLAN_SRC}"/*.yaml
    cp -a "${NETPLAN_BACKUP_DIR}/." "${NETPLAN_SRC}"/
    netplan generate || true
}

# ---- bridge ip -----
bridge_ip() {
    local ip_addr
    ip_addr="$(ip -4 -o addr show dev cloudbr0 scope global 2>/dev/null \
        | awk '{split($4, a, "/"); print a[1]; exit}')"
    [[ -n "${ip_addr}" ]] || die "could not get cloudbr0 ip"
    printf '%s\n' "${ip_addr}"
}