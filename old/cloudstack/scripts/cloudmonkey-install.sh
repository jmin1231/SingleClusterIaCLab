#!/usr/bin/env bash
#
# cloudmonkey-install.sh — install the CloudMonkey CLI (cmk), and mint the
# CloudStack API key and secret with it.
#
# Executed, it installs cmk and nothing else. Source it to call
# ensure_cloudstack_api_keys, which exports the credentials to the caller.
#
# Runs as root: cmk keeps its profile in $HOME/.cmk. See decisions.md 1.2-1.

set -euo pipefail

# Source the /lib/common.sh
SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

# Pinned cloudmonkey version
CMK_VERSION="${CMK_VERSION:-6.5.0}"

# Cloudstack creds
export CLOUDSTACK_ADMIN_USER="${CLOUDSTACK_ADMIN_USER:-admin}"
export CLOUDSTACK_ADMIN_PASS="${CLOUDSTACK_ADMIN_PASS:-password}"
export CLOUDSTACK_URL="${CLOUDSTACK_URL:-}"
export CLOUDSTACK_API_KEY="${CLOUDSTACK_API_KEY:-}"
export CLOUDSTACK_SECRET_KEY="${CLOUDSTACK_SECRET_KEY:-}"

install_cloudmonkey() {
  if command -v cmk >/dev/null 2>&1; then
    log "Cloudmonkey already installed"
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
  log "Downloading CloudMonkey ${CMK_VERSION} (${arch})..."
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN
  curl -fSL "${url}" -o "${tmp}" || die "Failed to download CloudMonkey"
  install -m 0755 "${tmp}" /usr/local/bin/cmk

  command -v cmk >/dev/null 2>&1 || die "CloudMonkey install failed"
  log "CloudMonkey installed successfully"
}

# Point cmk at this host and log it in by password. Shared setup for both key
# paths below; separate because password auth is how we bootstrap, and it is the
# only thing here that writes a credential to ~/.cmk/config.
cmk_configure() {
  command -v cmk >/dev/null 2>&1 || die "cmk not installed"
  command -v jq >/dev/null 2>&1 || die "jq not installed"

  CLOUDSTACK_URL="http://$(bridge_ip):8080/client/api"
  cmk set url "${CLOUDSTACK_URL}" >/dev/null || die "cmk set url failed"
  cmk set username "${CLOUDSTACK_ADMIN_USER}" >/dev/null || die "cmk set username failed"
  cmk set password "${CLOUDSTACK_ADMIN_PASS}" >/dev/null || die "cmk set password failed"
  cmk sync >/dev/null || die "cmk sync failed"
  export CLOUDSTACK_URL
}

admin_user_id() {
  local uid
  uid="$(cmk -o json list users username="${CLOUDSTACK_ADMIN_USER}" | jq -r '.user[0].id')"
  [[ -n "${uid}" && "${uid}" != "null" ]] ||
    die "Could not find CloudStack user '${CLOUDSTACK_ADMIN_USER}'."
  printf '%s' "${uid}"
}

# Read the keys CloudStack already holds. Returns 1 when the user has never
# registered any, which is a normal first-run state and not a failure.
capture_cloudstack_api_keys() {
  local keys
  keys="$(cmk -o json get userkeys id="$(admin_user_id)" 2>/dev/null)" || return 1

  CLOUDSTACK_API_KEY="$(jq -r '.userkeys.apikey // empty' <<<"${keys}")"
  CLOUDSTACK_SECRET_KEY="$(jq -r '.userkeys.secretkey // empty' <<<"${keys}")"
  [[ -n "${CLOUDSTACK_API_KEY}" && -n "${CLOUDSTACK_SECRET_KEY}" ]] || return 1

  export CLOUDSTACK_API_KEY CLOUDSTACK_SECRET_KEY
  log "Captured the existing CloudStack API key for '${CLOUDSTACK_ADMIN_USER}'."
}

# MINTS NEW KEYS AND INVALIDATES THE OLD ONES. Named for what it does, because
# the previous name said "generate" and the danger was invisible: registerUserKeys
# is not a read. Anything holding the previous key — a stored secret, a CI job, a
# cmk profile on another machine — starts failing with a 401 that says nothing
# about why. Call this only when capture has already returned empty, or when a
# rotation is what you actually want.
register_cloudstack_api_keys() {
  local keys
  warn "Registering NEW API keys for '${CLOUDSTACK_ADMIN_USER}' — any previously issued key stops working."
  keys="$(cmk -o json register userkeys id="$(admin_user_id)")" || die "cmk register userkeys failed."

  CLOUDSTACK_API_KEY="$(jq -r '.userkeys.apikey // empty' <<<"${keys}")"
  CLOUDSTACK_SECRET_KEY="$(jq -r '.userkeys.secretkey // empty' <<<"${keys}")"
  [[ -n "${CLOUDSTACK_API_KEY}" ]] || die "Failed to obtain API key from cmk."
  [[ -n "${CLOUDSTACK_SECRET_KEY}" ]] || die "Failed to obtain secret key from cmk."

  export CLOUDSTACK_API_KEY CLOUDSTACK_SECRET_KEY
  log "Registered new CloudStack API keys."
}

# Capture first, register only if there is nothing to capture (3.6). This is what
# makes the function safe to call twice: the old one called registerUserKeys
# unconditionally, so a second call silently rotated a live credential. On this
# host that mattered immediately — ~/.cmk/config carries no api key at all and
# authenticates by password, while CloudStack holds an 86-character key from an
# earlier run. The old code would have destroyed it.
ensure_cloudstack_api_keys() {
  cmk_configure
  capture_cloudstack_api_keys || register_cloudstack_api_keys
  log "CloudStack URL and API credentials exported."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_cloudmonkey
fi
