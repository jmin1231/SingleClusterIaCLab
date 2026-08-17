#!/usr/bin/env bash
#
# cloudmonkey-install.sh — install the CloudMonkey CLI (cmk), and mint the
# CloudStack API key and secret with it.
#
# Executed, it installs cmk and nothing else. Source it to call
# generate_cloudstack_api_keys, which exports the credentials to the caller.
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

generate_cloudstack_api_keys() {
  command -v cmk >/dev/null 2>&1 || die "cmk not installed"
  command -v jq >/dev/null 2>&1 || die "jq not installed"

  local ip uid keys url
  ip="$(bridge_ip)"

  url="http://${ip}:8080/client/api"
  cmk set url "${url}" >/dev/null || die "cmk set url failed"
  cmk set username "${CLOUDSTACK_ADMIN_USER}" >/dev/null || die "cmk set username failed"
  cmk set password "${CLOUDSTACK_ADMIN_PASS}" >/dev/null || die "cmk set password failed"
  cmk sync >/dev/null || die "cmk sync failed"

  uid="$(cmk -o json list users username="${CLOUDSTACK_ADMIN_USER}" | jq -r '.user[0].id')"
  [[ -n "${uid}" && "${uid}" != "null" ]] || die "Could not find CloudStack user '${CLOUDSTACK_ADMIN_USER}'."

  log "Registering API keys for user '${CLOUDSTACK_ADMIN_USER}'..."
  keys="$(cmk -o json register userkeys id="${uid}")"
  CLOUDSTACK_API_KEY="$(jq -r '.userkeys.apikey' <<<"${keys}")"
  CLOUDSTACK_SECRET_KEY="$(jq -r '.userkeys.secretkey' <<<"${keys}")"
  [[ -n "${CLOUDSTACK_API_KEY}" && "${CLOUDSTACK_API_KEY}" != "null" ]] ||
    die "Failed to obtain API key from cmk."
  [[ -n "${CLOUDSTACK_SECRET_KEY}" && "${CLOUDSTACK_SECRET_KEY}" != "null" ]] ||
    die "Failed to obtain secret key from cmk."
  CLOUDSTACK_URL="${url}"
  export CLOUDSTACK_URL CLOUDSTACK_API_KEY CLOUDSTACK_SECRET_KEY
  log "CloudStack URL/API key/secret generated and exported."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_cloudmonkey
fi
