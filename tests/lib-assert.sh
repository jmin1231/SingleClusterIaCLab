#!/usr/bin/env bash
#
# tests/lib-assert.sh
#   Asserts the behaviours of lib/lib.sh that are easy to get subtly wrong.
#
#   Runs as an ordinary user: LAB_LOG_DIR and LAB_TRACKER_FILE are overridable,
#   which is not a test-only hack - it is what lets a non-root dry run work.
#
#   Usage: tests/lib-assert.sh

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0
fail=0
ok() { printf '\033[1;32m  ok\033[0m   %s\n' "$*"; pass=$((pass + 1)); }
no() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; fail=$((fail + 1)); }

# --- the transcript ---------------------------------------------------------
#
# A subject script that logs, then dies. The die is the point: trap 4 exists
# because a die can exit before the writer has flushed.

cat > "${WORK}/subject.sh" <<'SUBJECT'
#!/usr/bin/env bash
set -euo pipefail
source "${REPO_ROOT}/lib/lib.sh"
main() {
    start_transcript
    log "line one"
    warn "line two"
    printf 'line three from a child\n'
    /bin/echo "line four from a real child process"
    die "line five, and this exits non-zero"
}
main "$@"
SUBJECT

printf 'transcript\n'

set +e
REPO_ROOT="${REPO_ROOT}" LAB_LOG_DIR="${WORK}/logs" \
    bash "${WORK}/subject.sh" >"${WORK}/terminal.txt" 2>&1
rc=$?
set -e

[[ $rc -eq 1 ]] && ok "die still exits 1 through the redirect" \
    || no "expected exit 1 from die, got ${rc}"

logfile="$(find "${WORK}/logs" -name 'bootstrap-*.log' -print -quit 2>/dev/null)"
if [[ -z "${logfile}" ]]; then
    no "no transcript written"
else
    ok "transcript created: $(basename "${logfile}")"

    # Trap 4: every line survives a die, including the die's own message and
    # output from a real child process.
    missing=()
    for want in "line one" "line two" "line three from a child" \
                "line four from a real child process" "line five"; do
        grep -qF -- "${want}" "${logfile}" || missing+=("${want}")
    done
    ((${#missing[@]} == 0)) && ok "all 5 lines present after die (no truncation)" \
        || no "truncated - missing: ${missing[*]}"

    # Trap 3: stripped in the file...
    if grep -qP '\x1b\[' "${logfile}"; then
        no "ANSI escapes reached the file"
    else
        ok "file is ANSI-free"
    fi

    # ...and NOT stripped on the terminal branch.
    if grep -qP '\x1b\[' "${WORK}/terminal.txt"; then
        ok "terminal keeps its colour"
    else
        no "colour was lost from the terminal (the [[ -t 1 ]] trap)"
    fi

    # Timestamps, from bash's printf rather than ts or gawk's strftime.
    if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' "${logfile}"; then
        ok "every line is timestamped ISO-8601 UTC"
    else
        no "timestamps missing or malformed"
    fi

    untimed="$(grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "${logfile}" || true)"
    [[ "${untimed}" == "0" ]] && ok "no untimestamped lines" \
        || no "${untimed} lines without a timestamp"
fi

# Trap 4, under volume - and this is the assertion that actually bites.
# Five lines is not enough to lose: the die's own message is written last and
# arrives either way, so a small transcript passes whether or not the EXIT trap
# waits. Removing the wait and running 200 lines gives 142/198/164 across three
# runs - a race on how much the writer has drained. With the wait it is 201
# every time. Asserting on an exact count is what makes this test falsifiable.
cat > "${WORK}/bulk.sh" <<'BULK'
#!/usr/bin/env bash
set -euo pipefail
source "${REPO_ROOT}/lib/lib.sh"
main() {
    start_transcript
    for i in $(seq 1 200); do printf 'bulk %s\n' "$i"; done
    die "bulk done"
}
main
BULK

set +e
REPO_ROOT="${REPO_ROOT}" LAB_LOG_DIR="${WORK}/bulklogs" \
    bash "${WORK}/bulk.sh" >/dev/null 2>&1
set -e

bulklog="$(find "${WORK}/bulklogs" -name 'bootstrap-*.log' -print -quit)"
bulkcount="$(grep -c '^.* bulk [0-9]' "${bulklog}" || true)"
[[ "${bulkcount}" -eq 200 ]] \
    && ok "all 200 bulk lines survived the die (the wait is load-bearing)" \
    || no "lost $((200 - bulkcount)) of 200 bulk lines - the EXIT trap is not draining the writer"

# --- retention --------------------------------------------------------------

printf 'retention\n'

rm -rf "${WORK}/sweep"; mkdir -p "${WORK}/sweep"
for i in $(seq -w 1 25); do
    : > "${WORK}/sweep/bootstrap-202610${i}T000000Z.log"
done

( source "${REPO_ROOT}/lib/lib.sh"
  LAB_LOG_DIR="${WORK}/sweep"; LAB_LOG_KEEP=20
  sweep_transcripts )

count="$(find "${WORK}/sweep" -name 'bootstrap-*.log' | wc -l)"
[[ "${count}" -eq 20 ]] && ok "retention kept 20 of 25" || no "retention kept ${count}, expected 20"

# Sorted by NAME, so the newest timestamps survive regardless of mtime.
if [[ -f "${WORK}/sweep/bootstrap-20261025T000000Z.log" \
   && ! -f "${WORK}/sweep/bootstrap-20261001T000000Z.log" ]]; then
    ok "retention kept the newest by name, dropped the oldest"
else
    no "retention dropped the wrong files"
fi

# --- the tracker ------------------------------------------------------------
#
# The bug being guarded against: the vendored installer tests for a non-empty
# value, so `key=no` reads as done.

printf 'tracker\n'

export LAB_TRACKER_FILE="${WORK}/tracker.conf"
# shellcheck source=../lib/lib.sh
source "${REPO_ROOT}/lib/lib.sh"

tracker_set demo_step no
if tracker_is_done demo_step; then
    no "key=no read as DONE - this is the vendored installer's bug"
else
    ok "key=no reads as not-done"
fi

tracker_set demo_step yes
tracker_is_done demo_step && ok "key=yes reads as done" || no "key=yes did not read as done"

tracker_forget demo_step
if tracker_is_done demo_step; then
    no "a forgotten key still reads as done"
else
    ok "a deleted line reads as not-done"
fi

tracker_set demo_step yes
tracker_set demo_step yes
dupes="$(grep -c '^demo_step=' "${LAB_TRACKER_FILE}")"
[[ "${dupes}" -eq 1 ]] && ok "re-setting a key does not duplicate the line" \
    || no "${dupes} lines for one key"

tracker_is_done never_set_at_all \
    && no "an unknown key read as done" \
    || ok "an unknown key reads as not-done"

# --- result -----------------------------------------------------------------

printf '\n'
if ((fail)); then
    printf '\033[1;31m[x]\033[0m lib: %d passed, %d FAILED\n' "${pass}" "${fail}" >&2
    exit 1
fi
printf '\033[1;32m[+]\033[0m lib: %d assertions passed\n' "${pass}"
