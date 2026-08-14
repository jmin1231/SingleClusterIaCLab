#!/usr/bin/env bash
#
# preflight-bridge-netfilter.sh — fail fast if the KVM host has bridge netfilter
# enabled, which breaks CloudStack VPC networking.
#
# With bridge netfilter on, iptables sees bridged frames and CloudStack's VPC
# port forwards drop them SILENTLY — no error, no log entry, packets simply
# vanish. That invisibility is why this is a standalone check rather than a line
# inside the installer: it needs running again before anything that depends on
# VPC networking, such as a terraform apply of the tiers.
#
# Set CHECK_BRIDGE_NETFILTER=false to skip, for runs that do not use local KVM
# bridges. Any other unrecognised value is an error, not a silent skip.

set -euo pipefail

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

CHECK_BRIDGE_NETFILTER="${CHECK_BRIDGE_NETFILTER:-true}"
case "${CHECK_BRIDGE_NETFILTER}" in
true) ;;
false)
  log "CHECK_BRIDGE_NETFILTER=false — skipping the bridge netfilter check."
  exit 0
  ;;
*) die "CHECK_BRIDGE_NETFILTER must be 'true' or 'false', got '${CHECK_BRIDGE_NETFILTER}'." ;;
esac

log "Checking if the KVM host has bridge netfilter enabled"

# No br_netfilter module means no bridge netfilter, which is the state we want.
# An absent directory is therefore a pass, not a failure.
[[ -d /proc/sys/net/bridge ]] || exit 0

enabled=""
for path in \
  /proc/sys/net/bridge/bridge-nf-call-iptables \
  /proc/sys/net/bridge/bridge-nf-call-ip6tables \
  /proc/sys/net/bridge/bridge-nf-call-arptables; do
  [[ -f "$path" ]] || continue
  if [[ "$(cat "$path")" == "1" ]]; then
    name="${path#/proc/sys/}"
    if [[ -n "$enabled" ]]; then
      enabled="$enabled $name"
    else
      enabled="$name"
    fi
  fi
done

if [[ -n "$enabled" ]]; then
  die "KVM bridge netfilter is enabled ($enabled). Disable these host sysctls before relying on VPC networking, or set CHECK_BRIDGE_NETFILTER=false for runs that do not use local KVM bridges."
fi

log "Bridge netfilter is disabled."
