#!/usr/bin/env bash
#
# vault-installer.sh — bring Vault up behind its own TLS at vault.lab.test:8200,
# initialise it, and unseal it.
#
# Usage: sudo ./vault-installer.sh
#
# Called by bootstrap.sh after coredns-installer.sh. Vault is reached by name
# from the moment it exists, so the resolver has to answer first. The certificate
# it serves came from ca/scripts/issue-leaf.sh — the only leaf this lab's openssl
# CA ever issues, because Vault becomes the issuing CA at 3.4 (3.4-1).
#
# ---------------------------------------------------------------------------
# PARTIAL. Steps 1 and 2 are written; 3 to 5 are not. A remaining TODO is a
# decision still to make, not merely code still to write, and each is numbered
# by the step it belongs to. Settled ones have been removed rather than marked —
# the reasoning lives in docs/decisions.md, which is where it is looked for.
#
# THE PARADOX THIS STEP MANAGES, which is the whole of 3.1:
#
#     the thing that will hold every secret has to come up before there is
#     anywhere safe to put its own credentials.
#
# Vault's storage is encrypted with a key Vault does not keep. `operator init`
# mints that key and a root token, prints them once, and never again. Both have
# to land somewhere, and that somewhere cannot be Vault. Every TODO in step 3
# falls out of that one sentence.
#
# THE SECOND IDEA, and the one that costs an evening if it stays abstract: seal
# and unseal are not start and stop. A restarted Vault is running, listening and
# useless — it answers every request with 503 sealed. Anything that restarts this
# container without unsealing it has broken the lab in a way that first presents
# as a network problem.
#
# WHAT MAKES THIS UNLIKE CoreDNS, the only other service so far: CoreDNS is
# stateless. Delete the container, re-run the installer, and you are exactly
# where you started. Vault holds state that cannot be regenerated. `operator
# init` against initialised storage is refused — but against EMPTY storage it
# succeeds, mints a new barrier key, and orphans every secret written under the
# old one. The guards below exist for that asymmetry, not for tidiness.
# ---------------------------------------------------------------------------

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
CERT_DIR="${SOURCE_SCRIPT}/certs"
DATA_DIR="${SOURCE_SCRIPT}/data"
# Plural, and not a preference: .gitignore's global secrets/ rule and
# .yamllint's docker/**/secrets/ match this name and nothing else. The unseal
# key lands here, so a name one character off is 2.3-6 with the worst possible
# file in it.
SECRETS_DIR="${SOURCE_SCRIPT}/secrets"

# The UID Vault runs as, and it is deliberately NOT the image's own (100:1000).
#
# Ubuntu reserves 0-99 for static system accounts and 100-999 for dynamic
# allocation at package-install time. A fresh 24.04 has that whole dynamic range
# empty — the highest assigned uid in the base image is 42 — so uid 100 is
# claimed by whichever package bootstrap.sh happens to install first, in an
# order apt does not guarantee. That makes "who else can read tls.key" a
# different answer on every host, and it can change AFTER the chown: a package
# installed later takes uid 100 and inherits read access to Vault's key, with
# nothing to warn you.
#
# 65100 is above the human range and below nobody(65534), outside every
# allocator's reach, so no account maps to it and no process can be it except
# the one we tell to be it. Vault does not need its image UID: every path it
# writes is a bind mount we own. This is the arbitrary-UID pattern 3.1-1 cites
# from OpenShift, applied deliberately rather than inherited.
#
# Must match user: in docker-compose.yml. Nothing discovers this at run time —
# see 3.1-1 for why pinning is the point.
VAULT_UID=65100
VAULT_GID=65100

LEAF_KEY="${CERT_DIR}/tls.key"
LEAF_CA="${CERT_DIR}/ca.crt" # the root; what VAULT_CACERT points at
LEAF_BUNDLE="${CERT_DIR}/bundle.crt"

# --- Step 1 · Preflight and generated config ---------------------------------

# Refuse to start without the certificate Vault serves. Presence is enough here:
# issue-leaf.sh writes all four files together and its own check_existing already
# refuses a partial or orphaned set, so re-verifying the chain would be asking a
# question whose answer cannot have changed. Reports every missing file at once,
# so one run names everything to fix.
require_leaf() {
  local missing=() file

  for file in "${LEAF_KEY}" "${LEAF_BUNDLE}" "${LEAF_CA}"; do
    [[ -e "${file}" ]] || missing+=("${file}")
  done

  [[ ${#missing[@]} -eq 0 ]] ||
    die "No usable certificate: missing ${missing[*]}. Run ca/ca-install-all.sh first; bootstrap.sh runs it before this one."
}

# Write .env from this host's bridge address. Discovered values only — the image
# pin and everything else live in docker-compose.yml (3.1-3), and vault.hcl is
# committed because nothing in it varies per host (3.1-2). Overwrites, so a
# re-run corrects a stale address rather than skipping.
render_config() {
  local cloudbr0_ip
  cloudbr0_ip="$(bridge_ip)"

  printf 'CLOUDBR0_IP=%s\n' "${cloudbr0_ip}" >"${SOURCE_SCRIPT}/.env"

  log "Vault will publish on ${cloudbr0_ip}:8200; wrote .env"
}

# --- Step 2 · The container ---------------------------------------------------

# Prepare everything the container will touch, then start it. Ownership first:
# Docker creates a missing bind-mount source as root, so a compose up before this
# would be a failure to repair rather than one to prevent.
start_vault() {
  # 0400 with owner and group both VAULT_UID/GID. With 65100 chosen precisely
  # because no account maps to it, owner-versus-group stops being the interesting
  # question — neither number means anything on this host. What matters is that
  # nothing but the container can be 65100, so the narrowest mode is also free.
  #
  # The certificates stay 0444 as issue-leaf.sh wrote them: they are public, and
  # ca.crt is copied into trust stores everywhere at 2.6.
  chown "${VAULT_UID}:${VAULT_GID}" "${LEAF_KEY}"
  chmod 0400 "${LEAF_KEY}"

  # Vault's own state, so Vault owns it; 0700 because nothing else has business
  # there and the group bits would grant that to no one anyway.
  mkdir -p "${DATA_DIR}"
  chown "${VAULT_UID}:${VAULT_GID}" "${DATA_DIR}"
  chmod 0700 "${DATA_DIR}"

  # Root only, and created before step 3 needs it. mkdir alone leaves this at the
  # umask — typically 0755 — and the next thing written here is the one
  # credential in the lab that cannot be regenerated.
  mkdir -p "${SECRETS_DIR}"
  chown root:root "${SECRETS_DIR}"
  chmod 0700 "${SECRETS_DIR}"

  # --remove-orphans: a renamed service otherwise leaves an old container holding
  # 8200, and the bind error that follows reads like something else is installed.
  log "Starting Vault..."
  docker compose -f "${COMPOSE}" up -d --remove-orphans

  wait_for_vault
}

# Poll until Vault answers at all. `docker compose up -d` returns when the
# process starts, not when the listener is up, so without this "started" is a
# claim start_vault cannot back.
#
# Any HTTP status counts as ready, including 501 (not initialised) and 503
# (sealed) — those are exactly the states init and unseal need to find. So the
# predicate is "did a response arrive", not "was it 200", and --fail is
# deliberately absent because it would turn the two useful codes into errors.
#
# --resolve, not the bare address: the certificate's only SAN is
# DNS:vault.lab.test, so connecting by IP fails verification. This gives
# name-based verification over an IP-based connection. The IP is the bridge and
# not loopback because 3.1-2 pinned the publish address there — Docker binds
# only cloudbr0, so 127.0.0.1:8200 is not listening at all.
#
# --cacert on purpose. This probes Vault, nothing else; verify_vault is the check
# that must succeed WITHOUT it, because that is what proves 2.6.
wait_for_vault() {
  local bridge code i
  bridge="$(bridge_ip)"

  log "Waiting for Vault to answer on ${bridge}:8200..."

  for ((i = 0; i < 60; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      --cacert "${LEAF_CA}" \
      --resolve "vault.lab.test:8200:${bridge}" \
      "https://vault.lab.test:8200/v1/sys/health")" || true

    # 000 is curl's placeholder when no connection was made at all.
    if [[ "${code}" != "000" ]]; then
      log "Vault is answering (HTTP ${code})."
      return 0
    fi
    sleep 1
  done

  # The answer is almost always in the container's own log, and the likeliest
  # cause right now is Vault unable to read tls.key — it dies loading its
  # listener. Printing the log here saves the round trip a "check the logs"
  # message would cost.
  warn "Last lines from the container:"
  docker logs vault --tail 20 2>&1 | sed 's/^/    /' >&2 || true
  die "Vault did not answer on ${bridge}:8200 within 60s. See the log above."
}

# --- Step 3 · Initialisation, which happens exactly once ----------------------

# TODO 3.1: refuse to initialise twice — but be clear what you are guarding
#           against, because it is not the obvious thing. Vault itself refuses
#           `operator init` against initialised storage. The danger is an init
#           against storage that is EMPTY because something removed it: that
#           succeeds, mints a new barrier key, and every secret written under the
#           old one becomes unreadable. Ask Vault (`vault status`), not the
#           filesystem — the filesystem is exactly what lied to you.
#
# TODO 3.2: key shares and threshold. The reference uses -key-shares=1
#           -key-threshold=1 and writes the single key beside the root token. 3.1
#           asks for honesty about that: it is the DEGENERATE case of Shamir —
#           one share, one holder, the same person holding the root token. A
#           reasonable lab choice, and not "protected by threshold cryptography".
#           Splitting shares means nothing until the holders are different
#           people.
#
# TODO 3.3: where the unseal key and root token land, and in what format.
#           `operator init -format=json` is parseable; the human format is not.
#           Whatever you choose: mode 0400, and decided BEFORE the first run.
#           This is the one output in the whole lab that no amount of re-running
#           will regenerate.
#
# TODO 3.4: the root token is not a credential to keep using — it bypasses every
#           policy. 3.2 creates real policies, and 14.5 is a break-glass drill
#           built on revoking this one. Write down now where it lives and what
#           would have to be true before you reach for it again.
#
# TODO 3.5: what this step PRINTS. `operator init` writes the only copy of both
#           secrets to stdout — which, once L-1's transcript exists, means into a
#           file under /var/log, permanently. Decide how that is prevented before
#           the transcript lands. The two features are individually reasonable
#           and jointly a disclosure, which is the kind of thing that is obvious
#           only in the order you happen to build them.
init_vault() {

  die "TODO 3.1: init_vault() not implemented"
}

# --- Step 4 · Unseal -----------------------------------------------------------

# TODO 4.1: unsealing an unsealed Vault is a no-op, so this can run on every
#           bootstrap — which is what keeps bootstrap.sh's "safe to re-run"
#           promise true for this service. Read the state rather than assuming
#           it: `vault status` exits 2 when sealed, a documented exit code and
#           not an error, so `set -e` will need handling.
# TODO 4.3: how the unseal key reaches the CLI. Not on argv, where ps shows it to
#           every user on the host — 2.3-5 rejected exactly that for the CA
#           passphrase and the reasoning transfers unchanged.
unseal_vault() {
  die "TODO 4.1: unseal_vault() not implemented"
}

# --- Step 5 · Prove it ----------------------------------------------------------

# TODO 5.1: assert on what Vault reports, not on what the container is doing.
#           `docker ps` says the same thing for a sealed Vault, an unreachable
#           Vault and a working one. 3.1's done-when is `vault status` over HTTPS
#           reporting sealed=false.
#
# TODO 5.2: reach it BY NAME, over TLS, with no -k and no --cacert. Both halves
#           matter: the name proves CoreDNS and api_addr agree, and the absence
#           of --cacert proves 2.6 put the root in the host store. Needing
#           --cacert here means 2.6 is unfinished — better discovered now than in
#           Phase 4 when CI hits it.
#
# TODO 5.3: this is also build-order 2.4's acceptance check, arriving late and
#           unchanged. Same command, same name, same port; only the thing
#           answering has moved from a placeholder to Vault.
verify_vault() {
  die "TODO 5.1: verify_vault() not implemented"
}

# Run every step, in dependency order.
main() {
  require_root
  require_leaf
  render_config
  start_vault
  init_vault
  unseal_vault
  verify_vault
}

main "$@"
