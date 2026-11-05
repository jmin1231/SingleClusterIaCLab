#!/usr/bin/env bash
#
# verify-all.sh - automated checks that the security groups allow exactly the
# intended paths between the web/app/db tiers and drop everything else
# (mode: verify = assert/exit non-zero; demo = human-readable proof).

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_DIR}/.." && pwd)"
# shellcheck source=../lib/lib.sh
source "${REPO_ROOT}/lib/lib.sh"

TF_DIR="${REPO_ROOT}/terraform/tf_files"
SSH_KEY="${STATE_DIR}/lab_ssh_key"
WEB_PORT=80        # sg_web: open to everyone
APP_PORT=8080      # sg_app: from sg_web members only
DB_PORT=5432       # sg_db: from sg_app members only
UNLISTED_PORT=9090 # listening on every VM, allowed by no security group

MODE="${1:-verify}"
FAILED=0
declare -A RESULT MGMT TIER

# Pull the mgmt and tier IPs Terraform recorded for each VM.
load_ips() {
    local vms vm
    vms="$(terraform -chdir="${TF_DIR}" output -json vms)"
    for vm in web app db; do
        MGMT[${vm}]="$(jq -r --arg vm "${vm}" '.[$vm].mgmt_ip // empty' <<<"${vms}")"
        TIER[${vm}]="$(jq -r --arg vm "${vm}" '.[$vm].tier_ip // empty' <<<"${vms}")"
        [[ -n "${MGMT[${vm}]}" && -n "${TIER[${vm}]}" ]] || die "could not read ${vm} IPs from terraform output"
    done
}

ssh_run() {
    local host="$1"; shift
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR "ubuntu@${host}" "$@"
}

# ---- probes: return 0 when the connection succeeds ----

# From VM $1 to VM $2's tier IP on port $3: crosses the VPC router.
vm_to_vm() {
    local code
    code="$(ssh_run "${MGMT[$1]}" "curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://${TIER[$2]}:$3" 2>/dev/null)" || return 1
    [[ "${code}" == "200" ]]
}

# From this host to VM $1's mgmt IP on port $2.
host_to_vm() {
    curl -s --max-time 5 -o /dev/null "http://${MGMT[$1]}:$2"
}

# web -> db with db's security groups switched off: the network itself lets it
# through, so the block seen with them on comes from the security group.
db_open_without_sg() {
    local rc=0
    DB_SG_OFF=1
    ssh_run "${MGMT[db]}" "sudo nft flush ruleset" || rc=1
    [[ "${rc}" -eq 0 ]] && { vm_to_vm web db "${DB_PORT}" || rc=1; }
    restore_db_sg
    return "${rc}"
}

restore_db_sg() {
    [[ "${DB_SG_OFF:-0}" -eq 1 ]] || return 0
    ssh_run "${MGMT[db]}" "sudo systemctl restart nftables" || warn "could not restore db security groups"
    DB_SG_OFF=0
}

expect_open()    { "$@"; }
expect_blocked() { ! "$@"; }

# A test service on each VM's own port plus one on the unlisted port, as transient
# systemd units so they survive the SSH session.
start_listeners() {
    local vm port
    for vm in web app db; do
        case "${vm}" in web) port="${WEB_PORT}" ;; app) port="${APP_PORT}" ;; db) port="${DB_PORT}" ;; esac
        ssh_run "${MGMT[${vm}]}" "sudo systemctl stop sg-demo-own sg-demo-unlisted 2>/dev/null || true; \
            sudo systemd-run --quiet --unit=sg-demo-own python3 -m http.server ${port}; \
            sudo systemd-run --quiet --unit=sg-demo-unlisted python3 -m http.server ${UNLISTED_PORT}; \
            sleep 1" || true
    done
}

stop_listeners() {
    local vm
    restore_db_sg
    for vm in web app db; do
        ssh_run "${MGMT[${vm}]}" "sudo systemctl stop sg-demo-own sg-demo-unlisted 2>/dev/null || true" || true
    done
}

check() {
    local key="$1" desc="$2"; shift 2
    local mark
    if "$@"; then RESULT[${key}]=pass; mark="✓"; else RESULT[${key}]=fail; mark="✗"; FAILED=1; fi
    printf '  [%s] %s\n' "${mark}" "${desc}"
}

mark() { [[ "${RESULT[$1]:-fail}" == pass ]] && printf '✓' || printf '✗'; }

all_pass() {
    local key
    for key in "$@"; do [[ "${RESULT[${key}]:-fail}" == pass ]] || return 1; done
}

main() {
    command -v terraform >/dev/null 2>&1 || die "terraform not found (run bootstrap deps)"
    load_ips

    log "Verifying security groups across the web, app and db tiers"
    start_listeners
    trap stop_listeners EXIT

    check pub "sg_web:   anyone reaches web on port ${WEB_PORT}"             expect_open    host_to_vm web "${WEB_PORT}"
    check wa  "sg_app:   web reaches app on port ${APP_PORT}"                expect_open    vm_to_vm web app "${APP_PORT}"
    check ad  "sg_db:    app reaches db on port ${DB_PORT}"                  expect_open    vm_to_vm app db "${DB_PORT}"
    check wd  "sg_db:    web cannot skip the app tier to reach db"          expect_blocked vm_to_vm web db "${DB_PORT}"
    check da  "sg_app:   db is not in sg_web, so it cannot reach app"       expect_blocked vm_to_vm db app "${APP_PORT}"
    check ha  "sg_app:   app is not reachable from outside the VPC"         expect_blocked host_to_vm app "${APP_PORT}"
    check ul  "default:  a listening port no group allows is dropped"       expect_blocked vm_to_vm web app "${UNLISTED_PORT}"
    check net "network:  with db's groups off, web reaches db (SG did it)"  expect_open    db_open_without_sg

    stop_listeners
    trap - EXIT

    if [[ "${MODE}" == "demo" ]]; then
        local open blocked
        all_pass pub wa ad && open="✓" || open="✗"
        all_pass wd da ha ul && blocked="✓" || blocked="✗"
        printf '\n  allowed paths: OPEN %s · everything else: BLOCKED %s · enforced by the security group %s\n' \
            "${open}" "${blocked}" "$(mark net)"
    fi

    [[ "${FAILED}" -eq 0 ]] || die "verification failed"
    log "All checks passed"
}

main "$@"
