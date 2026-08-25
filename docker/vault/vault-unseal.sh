#!/usr/bin/env bash
#
# vault-unseal.sh — unseal Vault using the key stored at init time.
#
# Usage: sudo ./vault-unseal.sh
#
# Separate from vault-installer.sh because seal is not stop (3.1-4):
# `restart: unless-stopped` brings Vault back sealed, so unsealing must work
# after a reboot and in a drill without re-running an installer that would also
# try to initialise.
#
# Safe to re-run — unsealing an unsealed Vault is a no-op. Self-contained by
# design: it duplicates the installer's readiness poll because being runnable
# with nothing else present is the point.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
CERT_DIR="${SOURCE_SCRIPT}/certs"
LEAF_CA="${CERT_DIR}/ca.crt"
INIT_FILE="${SOURCE_SCRIPT}/secrets/vault-init.json"

# Usable, not present — this runs standalone, months later, against a file that
# could have been edited or truncated. The message carries both meanings because
# it runs before Vault is asked anything and cannot yet tell them apart.
require_init_file() {
  [[ -e "${INIT_FILE}" ]] ||
    die "${INIT_FILE} is missing. Run vault-installer.sh — or, if Vault is already initialised, this held its only key."

  jq -e '.unseal_keys_b64[0]' "${INIT_FILE}" >/dev/null 2>&1 ||
    die "${INIT_FILE} has no unseal key. Restore it; do NOT re-initialise — that abandons this Vault's data."
}

# Runs at boot too, so Docker may not have started the container yet. 120s
# rather than the installer's 60: an install has already proved Docker is up and
# this has not. Duplicated deliberately — do not factor into lib/common.sh.
wait_for_vault() {
  local bridge code i state

  bridge="$(bridge_ip)"

  log "Waiting for Vault to answer on ${bridge}:8200..."

  for ((i = 0; i < 120; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      --cacert "${LEAF_CA}" \
      --resolve "vault.lab.test:8200:${bridge}" \
      "https://vault.lab.test:8200/v1/sys/health")" || true

    # Any status means it is listening; 000 means no connection was made.
    [[ "${code}" == "000" ]] || return 0
    sleep 1
  done

  # "Not running" and "running but silent" are different problems with different
  # fixes, and at boot the first is the likely one. Ask before dumping a log that
  # may not exist.
  state="$(docker inspect -f '{{.State.Status}}' vault 2>/dev/null)" || state="absent"
  if [[ "${state}" != "running" ]]; then
    die "The vault container is ${state}. Start it:  docker compose -f ${COMPOSE} up -d"
  fi

  warn "Last lines from the container:"
  docker logs vault --tail 20 2>&1 | sed 's/^/    /' >&2 || true
  die "Vault is running but did not answer on ${bridge}:8200 in 120s. See the log above."
}

# A second probe rather than reusing wait_for_vault's: that proved Vault
# answers, this needs to know what it answered.
unseal_vault() {
  local bridge response threshold i

  bridge="$(bridge_ip)"

  response="$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "${LEAF_CA}" \
    --resolve "vault.lab.test:8200:${bridge}" \
    "https://vault.lab.test:8200/v1/sys/health")" || true

  case "${response}" in
  501)
    die "Vault is not initialised, so there is nothing to unseal. Run vault-installer.sh."
    ;;
  200 | 429 | 473)
    log "Vault is already unsealed."
    return 0
    ;;
  503) ;;
  *)
    # Not silently treated as sealed: an unexpected code means an assumption
    # here is wrong, and unsealing on a guess is the wrong way to find out.
    die "Vault answered HTTP ${response}, which this script does not know how to read."
    ;;
  esac

  # One call per share, up to the threshold recorded at init. With 1/1 the loop
  # runs once; written as a loop so that raising the threshold does not turn this
  # into a script that unseals nothing and reports success.
  threshold="$(jq -r '.unseal_threshold' "${INIT_FILE}")"
  log "Unsealing Vault (${threshold} share(s))..."

  for ((i = 0; i < threshold; i++)); do
    # `-` reads the key from stdin: never in argv, where ps shows it to every
    # user (2.3-5), and never in a file. -T keeps Compose from taking the pipe.
    # Output discarded — L-1 puts this stdout in /var/log permanently.
    jq -r ".unseal_keys_b64[${i}]" "${INIT_FILE}" |
      docker compose -f "${COMPOSE}" exec -T vault vault operator unseal - >/dev/null ||
      die "Unseal failed on share $((i + 1)) of ${threshold}."
  done
}

# `operator unseal` exits 0 when it accepted a share without meeting the
# threshold, so a clean loop and a sealed Vault are compatible. seal-status
# rather than health: it answers 200 with the state in the body, so a failure
# can say how many shares were accepted.
verify_unsealed() {
  local bridge body

  bridge="$(bridge_ip)"

  body="$(curl -s \
    --cacert "${LEAF_CA}" \
    --resolve "vault.lab.test:8200:${bridge}" \
    "https://vault.lab.test:8200/v1/sys/seal-status")" ||
    die "Could not reach Vault on ${bridge}:8200 to confirm it unsealed."

  # jq -e exits non-zero for null exactly as for false, so an unparseable body
  # would otherwise read as "unsealed, all good".
  jq -e 'has("sealed")' <<<"${body}" >/dev/null 2>&1 ||
    die "Vault did not return a seal status. Check that the container is running."

  if jq -e '.sealed == false' <<<"${body}" >/dev/null 2>&1; then
    log "Vault is unsealed."
    return 0
  fi

  die "Vault is still sealed: $(jq -r '.progress' <<<"${body}") of $(jq -r '.t' <<<"${body}") shares accepted."
}

# Run every step in order.
main() {
  require_root
  require_init_file
  wait_for_vault
  unseal_vault
  verify_unsealed
}

main "$@"
