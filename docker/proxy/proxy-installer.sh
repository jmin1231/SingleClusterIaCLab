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
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/vault.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
CONF_TMPL="${SOURCE_SCRIPT}/conf/default.conf.tmpl"
CONF="${SOURCE_SCRIPT}/conf/default.conf"
CERT_DIR="${SOURCE_SCRIPT}/certs"

PKI_ROLE="lab-server"
# Every name this proxy serves. One certificate each, one server block each.
PROXY_NAMES=(cloudstack.lab.test gitea.lab.test)

issue_cert() {
  local cn="$1" crt="${CERT_DIR}/$1.crt" key="${CERT_DIR}/$1.key" json
  if cert_usable "${crt}" "${key}" "${cn}"; then
    log "Certificate for ${cn} is current; not reissuing"
    return 0
  fi

  json="$(vault_ write -format=json "pki/issue/${PKI_ROLE}" common_name="${cn}" 2>/dev/null)" ||
    die "Vault would not issue for ${cn}. Is the ${PKI_ROLE} role present? Run docker/vault/scripts/vault-configure.sh."

  install -d -m 0755 "${CERT_DIR}"
  # Key first and restrictive: it must never exist world-readable, not even
  # briefly. nginx's master reads it as root before dropping privileges.
  (
    umask 077
    jq -r '.data.private_key' <<<"${json}" >"${key}"
  )
  chmod 0400 "${key}"

  # Leaf + issuing CA, in that order: a client trusting only the root must be
  # able to build the path from what the server sends.
  jq -r '.data.certificate, .data.ca_chain[]' <<<"${json}" >"${crt}"
  chmod 0444 "${crt}"

  log "Issued ${cn}, valid until $(openssl x509 -in "${crt}" -noout -enddate | cut -d= -f2)"
}

issue_certs() {
  local cn
  for cn in "${PROXY_NAMES[@]}"; do issue_cert "${cn}"; done
}

render_conf() {
  local bridge
  bridge="$(bridge_ip)"
  # The allow-list keeps envsubst away from nginx's own $host, $scheme and
  # $remote_addr, and the value must be in the environment — envsubst cannot see
  # a shell local. Same pattern as coredns-installer.sh:41.
  # shellcheck disable=SC2016  # the quotes are intentional: this is the allow-list
  CLOUDBR0_IP="${bridge}" envsubst '${CLOUDBR0_IP}' <"${CONF_TMPL}" >"${CONF}"
  log "Rendered vhosts for ${#PROXY_NAMES[@]} names against ${bridge}"
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

  log "Proxy up for: ${PROXY_NAMES[*]}"
}

main() {
  require_root
  vault_authenticate
  issue_certs
  render_conf
  start_proxy
}

main "$@"
