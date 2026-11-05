#!/usr/bin/env bash
#
# cloudmonkey-install.sh - install the CloudMonkey CLI (cmk) and read/mint the
# CloudStack admin API key + secret.

set -euo pipefail

# Private var (not SOURCE_DIR) so sourcing this file never clobbers a caller's SOURCE_DIR.
CMK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${CMK_DIR}/../../lib/lib.sh"

CMK_VERSION="${CMK_VERSION:-6.5.0}"
ADMIN_PASS_FILE="${STATE_DIR}/cloudstack_admin_password"
ROTATE_ADMIN_PASS=0

export CLOUDSTACK_ADMIN_USER="${CLOUDSTACK_ADMIN_USER:-admin}"
export CLOUDSTACK_ADMIN_PASS="${CLOUDSTACK_ADMIN_PASS:-}"
export CLOUDSTACK_URL="${CLOUDSTACK_URL:-}"
export CLOUDSTACK_API_KEY="${CLOUDSTACK_API_KEY:-}"
export CLOUDSTACK_SECRET_KEY="${CLOUDSTACK_SECRET_KEY:-}"

# Install the pinned cmk binary for this architecture (skip if already present).
install_cloudmonkey() {
    if command -v cmk >/dev/null 2>&1; then
        log "CloudMonkey is already installed"
        return 0
    fi

    local arch
    case "$(uname -m)" in
        x86_64 | amd64) arch="x86-64" ;;
        aarch64 | arm64) arch="arm64" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac

    local tmp url
    url="https://github.com/apache/cloudstack-cloudmonkey/releases/download/${CMK_VERSION}/cmk.linux.${arch}"
    log "Downloading CloudMonkey ${CMK_VERSION} (${arch})"
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp}'" RETURN
    curl -fSL "${url}" -o "${tmp}" || die "Failed to download CloudMonkey"
    install -m 0755 "${tmp}" /usr/local/bin/cmk
    command -v cmk >/dev/null 2>&1 || die "CloudMonkey install failed"
    log "CloudMonkey installed"
}

# Generate + persist the admin password; flag first-run so we rotate from default.
resolve_admin_password() {
    if [[ -n "${CLOUDSTACK_ADMIN_PASS_OVERRIDE:-}" ]]; then
        CLOUDSTACK_ADMIN_PASS="${CLOUDSTACK_ADMIN_PASS_OVERRIDE}"
    elif [[ -f "${ADMIN_PASS_FILE}" ]]; then
        CLOUDSTACK_ADMIN_PASS="$(cat "${ADMIN_PASS_FILE}")"
    else
        mkdir -p "${STATE_DIR}"
        CLOUDSTACK_ADMIN_PASS="$(openssl rand -hex 16)"
        (umask 077; printf '%s' "${CLOUDSTACK_ADMIN_PASS}" > "${ADMIN_PASS_FILE}")
        ROTATE_ADMIN_PASS=1
        log "Generated CloudStack admin password -> ${ADMIN_PASS_FILE} (0600)"
    fi
}

# Point cmk at this host and log in; on first run, rotate the admin password
# off CloudStack's default to the generated one.
cmk_configure() {
    command -v cmk >/dev/null 2>&1 || die "cmk not installed"
    command -v jq  >/dev/null 2>&1 || die "jq not installed"

    CLOUDSTACK_URL="http://$(bridge_ip):8080/client/api"
    cmk set url "${CLOUDSTACK_URL}" >/dev/null || die "cmk set url failed"
    cmk set username "${CLOUDSTACK_ADMIN_USER}" >/dev/null || die "cmk set username failed"

    if ((ROTATE_ADMIN_PASS)); then
        cmk set password "password" >/dev/null
        cmk sync >/dev/null || die "cmk sync failed (default admin password)"
        cmk update user id="$(admin_user_id)" password="${CLOUDSTACK_ADMIN_PASS}" >/dev/null ||
            die "failed to rotate admin password"
        log "Rotated CloudStack admin password off the default"
    fi

    cmk set password "${CLOUDSTACK_ADMIN_PASS}" >/dev/null || die "cmk set password failed"
    cmk sync >/dev/null || die "cmk sync failed"
    export CLOUDSTACK_URL
}

# The admin user's id (needed to read/register its keys).
admin_user_id() {
    local uid
    uid="$(cmk -o json list users username="${CLOUDSTACK_ADMIN_USER}" | jq -r '.user[0].id')"
    [[ -n "${uid}" && "${uid}" != "null" ]] || die "Could not find user '${CLOUDSTACK_ADMIN_USER}'."
    printf '%s' "${uid}"
}

# Read the keys CloudStack already holds; return 1 if none (normal first run).
capture_cloudstack_api_keys() {
    local keys
    keys="$(cmk -o json get userkeys id="$(admin_user_id)" 2>/dev/null)" || return 1
    CLOUDSTACK_API_KEY="$(jq -r '.userkeys.apikey // empty' <<<"${keys}")"
    CLOUDSTACK_SECRET_KEY="$(jq -r '.userkeys.secretkey // empty' <<<"${keys}")"
    [[ -n "${CLOUDSTACK_API_KEY}" && -n "${CLOUDSTACK_SECRET_KEY}" ]] || return 1
    export CLOUDSTACK_API_KEY CLOUDSTACK_SECRET_KEY
    log "Captured existing CloudStack API key for '${CLOUDSTACK_ADMIN_USER}'."
}

# Mint NEW keys (invalidates any old ones) — only when capture found none.
register_cloudstack_api_keys() {
    local keys
    warn "Registering NEW API keys for '${CLOUDSTACK_ADMIN_USER}' — any previously issued key stops working."
    keys="$(cmk -o json register userkeys id="$(admin_user_id)")" || die "cmk register userkeys failed."
    CLOUDSTACK_API_KEY="$(jq -r '.userkeys.apikey // empty' <<<"${keys}")"
    CLOUDSTACK_SECRET_KEY="$(jq -r '.userkeys.secretkey // empty' <<<"${keys}")"
    [[ -n "${CLOUDSTACK_API_KEY}" ]] || die "Failed to obtain API key."
    [[ -n "${CLOUDSTACK_SECRET_KEY}" ]] || die "Failed to obtain secret key."
    export CLOUDSTACK_API_KEY CLOUDSTACK_SECRET_KEY
    log "Registered new CloudStack API keys."
}

# Resolve the password, configure cmk, then capture-or-register the keys.
ensure_cloudstack_api_keys() {
    resolve_admin_password
    cmk_configure
    capture_cloudstack_api_keys || register_cloudstack_api_keys
    log "CloudStack URL and API credentials exported."
}

# Executed directly: install cmk only. Sourced: expose the functions, run nothing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_cloudmonkey
fi
