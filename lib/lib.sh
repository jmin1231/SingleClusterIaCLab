#!/usr/bin/env bash
#
# lib/lib.sh
#   Shared helpers for bootstrap.sh and every installer under docker/ and
#   cloudstack/.
#
#   SOURCED, NEVER EXECUTED. It deliberately does not set shell options:
#   `set -euo pipefail` belongs to the calling script. A library that silently
#   changes its caller's error handling is a library that makes failures appear
#   in the wrong file.
#
#   Contents, per the build plan:
#     0.2  output, guards, apt, host facts
#     0.3  the install transcript, the step tracker
#
#   Verified by tests/lib-assert.sh.
#

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '\033[1;31m[x]\033[0m %s is a library - source it, do not run it\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 1
fi

# Guard against being sourced twice. Re-sourcing is harmless for functions but
# would reset any state the later passes keep, so make it explicit and cheap.
if [[ -n "${LAB_LIB_SOURCED:-}" ]]; then
    return 0
fi
LAB_LIB_SOURCED=1

# The repository root, derived from this file rather than from the caller's
# directory, so every consumer resolves the same paths no matter where it sits.
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_STATE_DIR="${LAB_ROOT}/state"

# ------------------------------- Output -------------------------------------
#
# Colour goes to the terminal; the transcript added at 0.3 strips it on the way
# to the file. Note what is NOT done here: log() is not made conditional on
# `[[ -t 1 ]]`. After 0.3's redirect, stdout is a pipe even when a terminal is
# attached, so that test would be false and colour would vanish from the
# terminal as well as the file.

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

# die's message should name the LIKELY CAUSE, not the symptom. "cloudbr0 has no
# address - has cloudstack-install-all.sh run?" costs one line to write and
# saves the next reader the search. A message that only restates the failed
# command is a message that explains nothing the exit status did not.
die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

# ------------------------------- Guards -------------------------------------

verify_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Must be run as root - try again with sudo"
    fi
}

# A verify is not an install: it cannot fix anything, so it fails fast and
# says what must be changed and where. Nested virtualization is set on the
# HYPERVISOR and cannot be enabled from inside the guest - get it wrong and
# the VM is rebuilt, which is why this runs before anything is installed.
verify_kvm() {
    if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        die "CPU reports no vmx/svm flag. If this host is itself a VM, nested virtualization is off - set it on the hypervisor; it cannot be fixed from in here."
    fi

    if [[ ! -e /dev/kvm ]]; then
        die "/dev/kvm is missing though the CPU supports virtualization. Check the kvm module loaded: lsmod | grep kvm"
    fi

    log "KVM available: $(grep -oEm1 'vmx|svm' /proc/cpuinfo) flag present, /dev/kvm ready"
}

# The user who invoked sudo, which is what you want for `chown` and for group
# membership - $USER is `root` under sudo and tells you nothing. SUDO_USER is
# unset in a real root shell (someone logged in as root, or a systemd unit),
# which is a case to handle rather than assume away: return 1 and let the
# caller decide whether that is fatal.
invoking_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "${SUDO_USER}"
        return 0
    fi
    return 1
}

# --------------------------------- apt --------------------------------------
#
# apt WAITS for the dpkg lock rather than racing it. Unattended upgrades run on
# a fresh Ubuntu and hold the lock for minutes; without this the failure is
# "Could not get lock /var/lib/dpkg/lock-frontend", which reads like a bug in
# our script and is in fact a timing problem that fixes itself if asked to
# wait.

APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-300}"

apt_get() {
    DEBIAN_FRONTEND=noninteractive \
        apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" "$@"
}

# ------------------------------ Host facts ----------------------------------
#
# Discovered, never declared. An address that differs per host is asked for at
# run time; an interface name written into a constant is a per-host fact
# wearing a constant's clothing.

# The source address the kernel would use to reach the internet. This is the
# robust question: it works before CloudStack has built the bridge AND after,
# because it asks about routing rather than about an interface that may not
# exist yet. Parsed by scanning for the `src` keyword rather than by field
# position, because `ip route get` inserts `via` only when the target is off-link.
#
# No jq: this is needed in Phase 1 before `install_cli_tools` has run.
host_ip() {
    local addr
    addr="$(
        ip route get 1.1.1.1 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
    )"

    [[ -n "${addr}" ]] || die "Could not determine this host's outbound source address. Is there a default route? Check: ip route show default"

    printf '%s\n' "${addr}"
}

# The default gateway. Asked via `route get` rather than `route show default`
# because the latter can return several lines - a link-scope route, or one per
# metric - and taking the first is a guess that is wrong on exactly the hosts
# where it matters.
gateway_ip() {
    local addr
    addr="$(
        ip route get 1.1.1.1 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}'
    )"

    [[ -n "${addr}" ]] || die "Could not determine the default gateway. If the internet is reachable on-link there is no 'via' to find, which this lab does not expect."

    printf '%s\n' "${addr}"
}

# The address CloudStack's bridge ended up with. Every published container port
# binds to this rather than to 0.0.0.0, so a service is reachable on the lab
# network without also being an open listener on everything else.
#
# Deliberately separate from host_ip(): after the installer runs these are the
# same address, but asking the bridge directly is how we VERIFY that the
# installer did what Phase 1.7 expects, rather than assuming it.
bridge_ip() {
    local bridge="${1:-cloudbr0}"
    local addr

    addr="$(
        ip -4 -o addr show dev "${bridge}" scope global 2>/dev/null |
            awk '{split($4, a, "/"); print a[1]; exit}'
    )"

    [[ -n "${addr}" ]] || die "Interface ${bridge} has no global IPv4 address. It is created by cloudstack/cloudstack-install-all.sh - has that run?"

    printf '%s\n' "${addr}"
}

# ---------------------------- The transcript --------------------------------
#
# One file per run, under LAB_LOG_DIR, capturing everything this script and its
# CHILDREN print - which is the point: children inherit file descriptors, so a
# single redirect here captures the 2,704-line vendored CloudStack installer for
# free. Per-call-site teeing would capture only the scripts we wrote, which are
# the ones least likely to surprise us.
#
# Four traps, all previously paid for:
#
#   1. start_transcript is called from main() AFTER verify_root - never at file
#      scope. At file scope a non-root invocation dies on "cannot create
#      /var/log/lab: Permission denied" instead of the readable message.
#   2. The terminal is saved on fd 3 and 4 before the redirect, so the EXIT trap
#      can put output back and so tee has somewhere to write.
#   3. ANSI is stripped on the FILE branch only. Making log() conditional on
#      [[ -t 1 ]] looks equivalent and is wrong: after the redirect stdout is a
#      pipe, so the test is false and colour disappears from the terminal too.
#   4. The EXIT trap WAITS for the writer. A die() can otherwise exit before the
#      last lines are flushed, truncating the log exactly when it matters. One
#      process substitution containing a whole pipeline is what makes this work -
#      $! is the subshell running the pipeline, and it does not exit until every
#      member has drained. `tee >(...)` would leave $! pointing at tee while the
#      inner stripper was still writing, reintroducing the truncation.
#
# Timestamps come from bash's own printf. NOT `ts` (moreutils, not installed) and
# NOT awk's strftime (a gawk extension - awk on a dev box is often gawk, but a
# fresh Ubuntu is mawk, so that choice fails only on the machine it was written
# to serve).
#
# `set -x` is deliberately NOT used. cloudstack-install.sh runs
# `cloudstack-setup-databases cloud:cloud@localhost --deploy-as=root:`, and trace
# would put that credential in a file permanently.

LAB_LOG_DIR="${LAB_LOG_DIR:-/var/log/lab}"
LAB_LOG_KEEP="${LAB_LOG_KEEP:-20}"
LAB_LOG_FILE=""
LAB_LOG_WRITER=""

utc_stamp() { TZ=UTC printf '%(%Y%m%dT%H%M%SZ)T\n' -1; }

start_transcript() {
    # Idempotent: a sub-installer sourced into an already-redirected run must not
    # start a second writer.
    if [[ -n "${LAB_LOG_WRITER}" ]]; then
        return 0
    fi

    install -d -m 0750 "${LAB_LOG_DIR}" ||
        die "Cannot create ${LAB_LOG_DIR}. start_transcript must run after verify_root."

    # Named so the files sort chronologically: retention then orders by NAME, and
    # a copy or a restore cannot reshuffle it the way rewritten mtimes would.
    LAB_LOG_FILE="${LAB_LOG_DIR}/bootstrap-$(utc_stamp).log"
    : >"${LAB_LOG_FILE}" || die "Cannot write ${LAB_LOG_FILE}"
    chmod 0640 "${LAB_LOG_FILE}"

    # Save the real terminal before anything is redirected (trap 2).
    exec 3>&1 4>&2

    exec > >(
        TZ=UTC
        # tee: raw to the terminal on fd 3, raw onward down the pipe.
        # sed -u: unbuffered, or the file lags a crashed run by a whole block.
        # printf: a builtin, so no fork per line across a 2,700-line install.
        tee /dev/fd/3 |
            sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' |
            while IFS= read -r line; do
                printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "${line}"
            done >>"${LAB_LOG_FILE}"
    ) 2>&1

    LAB_LOG_WRITER=$!

    # EXIT, not RETURN: a RETURN trap does not fire on die().
    trap finish_transcript EXIT

    log "Transcript: ${LAB_LOG_FILE}"
}

finish_transcript() {
    local code=$?

    [[ -n "${LAB_LOG_WRITER}" ]] || return "${code}"

    # Put output back on the terminal first, so anything printed from here on is
    # not swallowed by a pipe nobody is reading any more.
    exec 1>&3 2>&4

    # Trap 4: let the writer drain before the shell exits.
    wait "${LAB_LOG_WRITER}" 2>/dev/null || true
    LAB_LOG_WRITER=""

    sweep_transcripts

    return "${code}"
}

# Keep the newest LAB_LOG_KEEP, swept by the script that writes them so nothing
# external has to be configured. Sorted by name - see start_transcript.
sweep_transcripts() {
    local -a logs=()
    local f

    for f in "${LAB_LOG_DIR}"/bootstrap-*.log; do
        [[ -f "$f" ]] || continue
        logs+=("$f")
    done

    ((${#logs[@]} > LAB_LOG_KEEP)) || return 0

    mapfile -t logs < <(printf '%s\n' "${logs[@]}" | sort -r)

    local i
    for ((i = LAB_LOG_KEEP; i < ${#logs[@]}; i++)); do
        rm -f -- "${logs[i]}"
    done
}

# ------------------------------ The tracker ---------------------------------
#
# Which steps are already done, so a re-run is a no-op and a failed run resumes.
#
# THE BUG THIS DOES NOT REPEAT: the vendored installer decides what to skip with
#
#     is_step_tracked() { [[ -n "${tracker_values[$key]:-}" ]]; }
#
# which tests for a NON-EMPTY VALUE, not for `yes`. So `db_deployed=no` reads as
# *done* and the step is skipped. Two full installer runs were lost to editing
# `yes` into `no` and watching nothing happen. tracker_is_done compares against
# `yes` and nothing else.
#
# Read straight from the file rather than caching in an associative array: each
# installer is its own process, so a cache loaded at start goes stale the moment
# a sibling writes. The file is a few dozen lines; the read is free.

LAB_TRACKER_FILE="${LAB_TRACKER_FILE:-${LAB_STATE_DIR}/tracker.conf}"

_tracker_init() {
    install -d -m 0755 "$(dirname -- "${LAB_TRACKER_FILE}")"

    [[ -f "${LAB_TRACKER_FILE}" ]] && return 0

    cat >"${LAB_TRACKER_FILE}" <<'EOF'
# Step tracker. One key=value per line; `yes` means done and nothing else does.
# To genuinely re-run a step, DELETE ITS LINE (or blank the value) - setting it
# to `no` is what the vendored installer mis-reads as done.
EOF
}

# Keys are our own identifiers ([A-Za-z0-9_]), so they are safe in a pattern.
# Last occurrence wins, so an appended re-set is authoritative.
tracker_get() {
    local key="$1"

    [[ -f "${LAB_TRACKER_FILE}" ]] || return 0

    awk -F= -v k="${key}" \
        '$1 == k { v = substr($0, index($0, "=") + 1) } END { print v }' \
        "${LAB_TRACKER_FILE}"
}

tracker_set() {
    local key="$1"
    local value="$2"
    local tmp

    _tracker_init

    # Rewrite through a temp file and rename, so an interrupted write cannot
    # leave a half-truncated tracker - which would read as "nothing is done"
    # and re-run steps that had succeeded.
    tmp="$(mktemp "${LAB_TRACKER_FILE}.XXXXXX")" ||
        die "Cannot create a temporary tracker file beside ${LAB_TRACKER_FILE}"

    grep -v "^${key}=" "${LAB_TRACKER_FILE}" >"${tmp}" || true
    printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"

    chmod 0644 "${tmp}"
    mv "${tmp}" "${LAB_TRACKER_FILE}"
}

tracker_is_done() {
    [[ "$(tracker_get "$1")" == "yes" ]]
}

tracker_done() { tracker_set "$1" yes; }

# The documented way to force a step to re-run.
tracker_forget() {
    local key="$1"
    local tmp

    [[ -f "${LAB_TRACKER_FILE}" ]] || return 0

    tmp="$(mktemp "${LAB_TRACKER_FILE}.XXXXXX")" ||
        die "Cannot create a temporary tracker file beside ${LAB_TRACKER_FILE}"

    grep -v "^${key}=" "${LAB_TRACKER_FILE}" >"${tmp}" || true
    chmod 0644 "${tmp}"
    mv "${tmp}" "${LAB_TRACKER_FILE}"
}

# ------------------------------ Conventions ---------------------------------
#
# Two shell traps this repo has paid for, recorded where they will be read:
#
#   CAPTURE, DO NOT PIPE, INTO `grep -q`. grep exits on its first match, the
#   producer takes SIGPIPE, and under `pipefail` the pipeline reports 141 - so
#   a SUCCESSFUL match is read as a failure. It is a race on output length, so
#   it passes on a quiet host and fails on a busy one. Write:
#       out="$(some_command)"; if grep -q pattern <<<"${out}"; then
#
#   AN ERROR HANDLER AFTER A FAILING COMMAND IN A `set -e` SCRIPT IS
#   DECORATION. The shell has already exited. Use `if ! cmd; then` or `|| die`,
#   and note that a RETURN trap does not fire on `die` - it needs RETURN EXIT.
