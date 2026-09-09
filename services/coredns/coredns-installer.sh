#!/usr/bin/env bash
#
# coredns-installer.sh
#   Installs the CoreDNS docker container
#


set -euo pipefail

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_FILE="${SOURCE_SCRIPT}/docker-compose.yml"
RESOLVED_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN="${RESOLVED_DIR}/lab-dns.conf"
ZONE_TEMPLATE="${SOURCE_SCRIPT}/zones/lab.test.zone.tmpl"
ZONE_FILE="${SOURCE_SCRIPT}/zones/lab.test.zone"
ENV_FILE="${SOURCE_SCRIPT}/.env"

get_cloudbr0_ip() {
    local ip_addr

    ip_addr="$(
        ip -4 -o addr show dev cloudbr0 scope global 2>/dev/null |
        awk '{split($4, a, "/"); print a[1]; exit}'
    )"

    [[ -n "$ip_addr" ]] || die "Unable to determine cloudbr0 ip address. cloudbr0 is created by cloudstack-install-all.sh - has it run?"

    printf '%s\n' "$ip_addr"
}

render_config() {
    local cloudbr0_ip
    local zone_serial

    cloudbr0_ip="$(get_cloudbr0_ip)"
    zone_serial="$(date -u +%s)"

    cat > "$ENV_FILE" << EOF
CLOUDBR0_IP=${cloudbr0_ip}
EOF

    CLOUDBR0_IP="$cloudbr0_ip" \
    ZONE_SERIAL="$zone_serial" \
    envsubst '${CLOUDBR0_IP} ${ZONE_SERIAL}' \
        < "$ZONE_TEMPLATE" \
        > "$ZONE_FILE"

    log "Environment file rendered: ${ENV_FILE}"
    log "CoreDNS zone rendered: ${ZONE_FILE}"
}

configure_resolved() {
    local cloudbr0_ip

    cloudbr0_ip="$(get_cloudbr0_ip)"

    log "Configuring systemd-resolved for lab.test"

    install -d -m 0755 "${RESOLVED_DIR}"

    cat > "${RESOLVED_DROPIN}" <<EOF
[Resolve]
DNS=${cloudbr0_ip}
Domains=~lab.test
EOF

    chmod 644 "${RESOLVED_DROPIN}"

    systemctl restart systemd-resolved ||
        die "Failed to restart systemd-resolved"

    log "lab.test DNS routing configured"

}

start_coredns() {
    log "Starting CoreDNS"
    docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
}

main() {
    render_config
    start_coredns
    configure_resolved
    log "CoreDNS ready"
}

main "$@"