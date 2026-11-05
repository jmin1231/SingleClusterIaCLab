#!/usr/bin/env bash
#
# register-cloudstack-template.sh - register the MinIO-hosted QCOW2 as a
# CloudStack template and wait for it to download into secondary storage.

set -euo pipefail

CLOUDSTACK_API_URL="${CLOUDSTACK_API_URL:-http://127.0.0.1:8080/client/api}"
CLOUDSTACK_API_KEY="${CLOUDSTACK_API_KEY:-}"
CLOUDSTACK_SECRET_KEY="${CLOUDSTACK_SECRET_KEY:-}"
TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-24.04}"
TEMPLATE_URL="${TEMPLATE_URL:-}"
TEMPLATE_FORMAT="${TEMPLATE_FORMAT:-QCOW2}"
TEMPLATE_HYPERVISOR="${TEMPLATE_HYPERVISOR:-KVM}"
OS_TYPE_NAME="${OS_TYPE_NAME:-Ubuntu 24.04 LTS}"
CLOUDSTACK_ZONE="${CLOUDSTACK_ZONE:-Zone1}"
CMK_TIMEOUT_SECONDS="${CMK_TIMEOUT_SECONDS:-120}"
TEMPLATE_READY_TIMEOUT="${TEMPLATE_READY_TIMEOUT:-1800}"

log() { printf '[template] %s\n' "$*"; }
die() { printf '[template] ERROR: %s\n' "$*" >&2; exit 1; }

# Run a cmk command, returning its JSON on stdout (stderr kept separate so a stray warning never corrupts the JSON).
cmk_json() {
    local err output rc
    err="$(mktemp)"
    output="$(timeout "${CMK_TIMEOUT_SECONDS}" cmk -o json "$@" 2>"${err}")" || {
        rc=$?
        cat "${err}" >&2
        rm -f "${err}"
        [[ "${rc}" -eq 124 ]] && die "cmk $* timed out after ${CMK_TIMEOUT_SECONDS}s"
        return 1
    }
    rm -f "${err}"
    [[ -n "${output}" ]] || { printf '{}\n'; return 0; }
    printf '%s\n' "${output}" | jq -e . >/dev/null || die "cmk $* returned non-JSON output"
    printf '%s\n' "${output}"
}

# Fail fast if a required tool or input is missing.
preflight() {
    command -v cmk >/dev/null 2>&1 || die "cmk not installed"
    command -v jq  >/dev/null 2>&1 || die "jq not installed"
    [[ -n "${TEMPLATE_URL}" ]] || die "TEMPLATE_URL is required"
    [[ -n "${CLOUDSTACK_API_KEY}" && -n "${CLOUDSTACK_SECRET_KEY}" ]] \
        || die "CLOUDSTACK_API_KEY and CLOUDSTACK_SECRET_KEY are required"
}

# Point cmk at this host using the API key/secret this run was handed.
configure_cmk() {
    cmk set url "${CLOUDSTACK_API_URL}" >/dev/null
    cmk set apikey "${CLOUDSTACK_API_KEY}" >/dev/null
    cmk set secretkey "${CLOUDSTACK_SECRET_KEY}" >/dev/null
    cmk set output json >/dev/null
    timeout "${CMK_TIMEOUT_SECONDS}" cmk sync >/dev/null
}

# Resolve the zone id into the ZONE_ID global.
resolve_zone_id() {
    ZONE_ID="$(cmk_json list zones \
        | jq -r --arg ref "${CLOUDSTACK_ZONE}" \
            '.zone[]? | select(.id == $ref or .name == $ref) | .id' \
        | head -n 1)"
    [[ -n "${ZONE_ID}" ]] || die "could not resolve zone ${CLOUDSTACK_ZONE}"
}

# Resolve the OS type id: exact name first, then any Ubuntu 64-bit, then a generic Linux.
resolve_ostype_id() {
    local types id
    types="$(cmk_json list ostypes)"
    for match in \
        ".ostype[]? | select(.description == \"${OS_TYPE_NAME}\") | .id" \
        '.ostype[]? | select(.description | test("Ubuntu.*64-bit"; "i")) | .id' \
        '.ostype[]? | select(.description | test("Ubuntu"; "i")) | .id' \
        '.ostype[]? | select(.description | test("Other.*Linux.*64-bit"; "i")) | .id'; do
        id="$(printf '%s\n' "${types}" | jq -r "${match}" | head -n 1)"
        [[ -n "${id}" && "${id}" != "null" ]] && { printf '%s' "${id}"; return 0; }
    done
    return 1
}

# The id of an already-registered template with this name in this zone, if any.
find_template_id() {
    cmk_json list templates templatefilter=self zoneid="${ZONE_ID}" \
        | jq -r --arg name "${TEMPLATE_NAME}" \
            '.template[]? | select(.name == $name) | .id' \
        | head -n 1
}

# Poll until the template finishes downloading into secondary storage.
wait_for_template_ready() {
    local template_id="$1" start ready status
    start="$(date +%s)"
    while :; do
        local response
        response="$(cmk_json list templates templatefilter=self zoneid="${ZONE_ID}" id="${template_id}")"
        ready="$(printf '%s\n' "${response}" | jq -r '.template[0].isready // false')"
        [[ "${ready}" == "true" ]] && { log "Template is ready"; return 0; }
        status="$(printf '%s\n' "${response}" | jq -r '.template[0].status // "pending"')"
        [[ "$(( $(date +%s) - start ))" -ge "${TEMPLATE_READY_TIMEOUT}" ]] \
            && die "template not ready within ${TEMPLATE_READY_TIMEOUT}s (last status: ${status})"
        log "Waiting for template download (${status})"
        sleep 10
    done
}

# Register the template if it does not already exist, then wait until it is ready.
ensure_template() {
    local existing ostype_id response template_id

    existing="$(find_template_id)"
    if [[ -n "${existing}" ]]; then
        log "Template ${TEMPLATE_NAME} already registered (${existing}); ensuring it is ready"
        wait_for_template_ready "${existing}"
        return 0
    fi

    ostype_id="$(resolve_ostype_id)" || die "could not resolve an OS type for '${OS_TYPE_NAME}'"

    log "Registering template ${TEMPLATE_NAME} from ${TEMPLATE_URL}"
    response="$(cmk_json register template \
        name="${TEMPLATE_NAME}" \
        displaytext="${TEMPLATE_NAME}" \
        url="${TEMPLATE_URL}" \
        format="${TEMPLATE_FORMAT}" \
        hypervisor="${TEMPLATE_HYPERVISOR}" \
        ostypeid="${ostype_id}" \
        zoneid="${ZONE_ID}" \
        ispublic=true \
        passwordenabled=false \
        requireshvm=true)"
    template_id="$(printf '%s\n' "${response}" | jq -r '.template[0].id // empty')"
    [[ -n "${template_id}" ]] || die "registerTemplate returned no template id"

    wait_for_template_ready "${template_id}"
    log "Template ${TEMPLATE_NAME} registered (${template_id})"
}

main() {
    preflight
    configure_cmk
    resolve_zone_id
    ensure_template
}

main "$@"
