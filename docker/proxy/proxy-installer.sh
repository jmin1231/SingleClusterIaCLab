#!/usr/bin/env bash
#
# proxy-installer.sh — the lab's edge terminator: issue a certificate from
# Vault's PKI engine, render the vhost, start nginx (2.5).
#
# Usage: sudo ./proxy-installer.sh
#
# Runs after Vault is configured, because the certificate comes from
# pki/issue/lab-server. That is 3.4-1's reordering: the proxy used to be Phase
# 2.5 with a certificate from issue-leaf.sh, which now issues exactly one leaf.
#
# Safe to re-run: the certificate is reissued only when it is missing, unreadable
# or close to expiry. Renewal on a timer is 3.5; this is the manual half.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
CONF_TMPL="${SOURCE_SCRIPT}/conf/default.conf.tmpl"
CONF="${SOURCE_SCRIPT}/conf/default.conf"
CERT_DIR="${SOURCE_SCRIPT}/certs"
CRT="${CERT_DIR}/cloudstack.crt"
KEY="${CERT_DIR}/cloudstack.key"

VAULT_COMPOSE="${SOURCE_SCRIPT}/../vault/docker-compose.yml"
VAULT_INIT="${SOURCE_SCRIPT}/../vault/secrets/vault-init.json"
PKI_ROLE="lab-server"
PROXY_CN="cloudstack.lab.test"

# Reissue when fewer than this many seconds remain. 7 days against the role's
# 30-day ceiling: enough slack that a re-run inside the window is a no-op, and
# enough margin that a lab left alone for a week still comes back working.
RENEW_BEFORE=$((7 * 24 * 3600))

vault_() {
  docker compose -f "${VAULT_COMPOSE}" exec -T -e VAULT_TOKEN vault vault "$@"
}

authenticate() {
  [[ -r "${VAULT_INIT}" ]] ||
    die "Cannot read ${VAULT_INIT}. Vault must be installed and configured before the proxy — bootstrap.sh runs both first."
  VAULT_TOKEN="$(jq -r '.root_token // empty' "${VAULT_INIT}")"
  [[ -n "${VAULT_TOKEN}" ]] || die "${VAULT_INIT} holds no root_token."
  export VAULT_TOKEN
}

# Present is not the same as usable: a certificate can exist and be expired, or
# be for the wrong name. Checked rather than assumed, so a re-run repairs.
cert_usable() {
  [[ -s "${CRT}" && -s "${KEY}" ]] || return 1
  openssl x509 -in "${CRT}" -noout -checkend "${RENEW_BEFORE}" >/dev/null 2>&1 || return 1
  openssl x509 -in "${CRT}" -noout -checkhost "${PROXY_CN}" >/dev/null 2>&1
}

issue_cert() {
  if cert_usable; then
    log "Certificate for ${PROXY_CN} is current; not reissuing"
    return 0
  fi

  local json
  json="$(vault_ write -format=json "pki/issue/${PKI_ROLE}" common_name="${PROXY_CN}" 2>/dev/null)" ||
    die "Vault would not issue for ${PROXY_CN}. Is the ${PKI_ROLE} role present? Run vault-configure.sh."

  install -d -m 0755 "${CERT_DIR}"
  # Key first and restrictive: it must never exist world-readable, not even
  # briefly. nginx's master process reads it as root before dropping privileges.
  (
    umask 077
    jq -r '.data.private_key' <<<"${json}" >"${KEY}"
  )
  chmod 0400 "${KEY}"

  # Leaf + issuing CA, in that order: a client that trusts only the root must be
  # able to build the path from what the server sends.
  jq -r '.data.certificate, .data.ca_chain[]' <<<"${json}" >"${CRT}"
  chmod 0444 "${CRT}"

  log "Issued ${PROXY_CN}, valid until $(openssl x509 -in "${CRT}" -noout -enddate | cut -d= -f2)"
}

render_conf() {
  local bridge
  bridge="$(bridge_ip)"
  # The allow-list keeps envsubst away from nginx's own $host, $scheme and
  # $remote_addr, and the value must be in the environment — envsubst cannot see
  # a shell local. Same pattern as coredns-installer.sh:41.
  # shellcheck disable=SC2016  # the quotes are intentional: this is the allow-list
  CLOUDBR0_IP="${bridge}" envsubst '${CLOUDBR0_IP}' <"${CONF_TMPL}" >"${CONF}"
  log "Rendered vhost: ${PROXY_CN} -> ${bridge}:8080"
}

start_proxy() {
  docker compose -f "${COMPOSE}" up -d --remove-orphans

  # nginx exits on a bad config rather than serving a broken one, so a running
  # container is the assertion. Ask it directly rather than trusting `up`.
  docker compose -f "${COMPOSE}" exec -T proxy nginx -t >/dev/null 2>&1 ||
    die "nginx rejected its configuration. See: docker logs proxy"

  # Issuing is not enough — the server has to be told. nginx reads its config
  # once at start, and `compose up -d` leaves a running container alone when the
  # compose spec has not changed, so a re-rendered vhost or a reissued
  # certificate sits on disk unused. This is exactly the incident 3.5 names: the
  # certificate renewed and the site served the old one. Reload is idempotent and
  # only reached once `nginx -t` has passed, so a bad config cannot take the
  # proxy down.
  docker compose -f "${COMPOSE}" exec -T proxy nginx -s reload >/dev/null 2>&1 ||
    die "nginx would not reload. See: docker logs proxy"

  log "Proxy up. Verify: curl --cacert ca/root/root-ca.crt https://${PROXY_CN}/client/"
}

main() {
  require_root
  authenticate
  issue_cert
  render_conf
  start_proxy
}

main "$@"
