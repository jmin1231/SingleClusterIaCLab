#!/usr/bin/env bash
#
# coredns-installer.sh — render CoreDNS's generated config, start it, and point
# the host's resolver at it for lab.test.
#
# Usage: sudo ./coredns-installer.sh
#
# Called by bootstrap.sh, which owns the ordering. Runs after CloudStack: both
# addresses it needs come from cloudbr0, which does not exist before then.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

TMPL="${SOURCE_SCRIPT}/zones/lab.test.zone.tmpl"
ZONE="${SOURCE_SCRIPT}/zones/lab.test.zone"
COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/10-lab.conf"
# Phase 1's bootstrap resolver floor, retired here. See decisions.md 1.3-3.
BOOTSTRAP_DROPIN="/etc/systemd/resolved.conf.d/05-cloudstack-bootstrap.conf"

# Write the two generated files — .env and the rendered zone — from this host's
# addresses. Overwrites, so a re-run corrects stale values.
render_config() {
  local cloudbr0_ip gateway
  cloudbr0_ip="$(bridge_ip)"
  gateway="$(gateway_ip)"

  [[ -f "${TMPL}" ]] || die "Missing zone template: ${TMPL}"

  log "Rendering CoreDNS config for ${cloudbr0_ip} (upstream ${gateway})..."

  # Discovered values only; the image pin lives in docker-compose.yml.
  printf 'CLOUDBR0_IP=%s\nGATEWAY_IP=%s\n' "${cloudbr0_ip}" "${gateway}" >"${SOURCE_SCRIPT}/.env"

  # The allow-list stops envsubst eating $ORIGIN and $TTL, and the value must be
  # in the environment — envsubst cannot see a shell local.
  # shellcheck disable=SC2016  # the quotes are intentional: this is the allow-list
  CLOUDBR0_IP="${cloudbr0_ip}" envsubst '${CLOUDBR0_IP}' <"${TMPL}" >"${ZONE}"

  log "CoreDNS config rendered: $(basename "${ZONE}") and .env"
}

# Start the container. --remove-orphans so a renamed service does not leave an
# old container holding port 53.
start_coredns() {
  log "Starting CoreDNS..."
  docker compose -f "${COMPOSE}" up -d --remove-orphans
}

# Point systemd-resolved at CoreDNS for lab.test only. The ~ prefix makes it a
# routing domain — send this suffix here — rather than a search domain. Split
# this way, a CoreDNS restart costs lab names only; the host keeps resolving
# everything else through its existing upstream.
configure_resolver() {
  local bridge
  bridge="$(bridge_ip)"

  log "Pointing systemd-resolved at ${bridge} for lab.test..."

  # Deleted, not left to lose on sort order: `DNS=` accumulates across drop-ins.
  if [[ -f "${BOOTSTRAP_DROPIN}" ]]; then
    log "Retiring the bootstrap resolver floor ${BOOTSTRAP_DROPIN}..."
    rm -f "${BOOTSTRAP_DROPIN}" ||
      die "Failed to remove ${BOOTSTRAP_DROPIN}; it would keep answering alongside CoreDNS."
  fi

  mkdir -p "$(dirname "${RESOLVED_DROPIN}")"
  # [Resolve] is required. A drop-in does not inherit the section of the file it
  # extends: without the header, resolved logs "Assignment outside of section"
  # and ignores every key — the file looks correct and does nothing.
  printf '[Resolve]\nDNS=%s\nDomains=~lab.test\n' "${bridge}" >"${RESOLVED_DROPIN}"
  systemctl restart systemd-resolved || die "Failed to restart systemd-resolved."

  # resolved accepts a drop-in it ignored, so assert on what it concluded rather
  # than on the file. Retried: systemctl returns once the unit has started, but
  # resolvectl answers over D-Bus and that takes a moment longer.
  #
  # Captured to a variable rather than piped into grep. `resolvectl status |
  # grep -q` deadlocks the check under `set -o pipefail`: grep exits on the first
  # match, resolvectl is still writing, takes SIGPIPE, and the pipeline reports
  # 141 — so a successful match reads as a failure.
  local i status
  for ((i = 0; i < 10; i++)); do
    status="$(resolvectl status 2>/dev/null || true)"
    if grep -q "DNS Servers:.*${bridge}" <<<"${status}"; then
      log "systemd-resolved is routing lab.test to ${bridge}."
      return 0
    fi
    sleep 1
  done
  die "systemd-resolved did not pick up ${RESOLVED_DROPIN}; check 'journalctl -u systemd-resolved'."
}

main() {
  require_root
  render_config
  start_coredns
  configure_resolver
  log "CoreDNS ready. Check with: getent hosts gitea.lab.test"
}

main "$@"
