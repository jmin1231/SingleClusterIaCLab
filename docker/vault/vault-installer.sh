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
# SKELETON. Every TODO is a decision to make, not just code to write. Grep for
# TODO to see what is left; they are numbered by the step they belong to.
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

# TODO 0.1: the remaining paths — rendered config, storage directory, and
#           wherever init material lands. Declare them together the way the CA
#           scripts do, so "what does this write" reads in one place.
#
#           Two names are already chosen for you by files that exist. .yamllint
#           ignores docker/**/data/ and docker/**/secrets/, and .gitignore has a
#           global secrets/ rule. Using those means no new rules; using anything
#           else means adding some, and 2.3-6 is the entry about what happens
#           when a rule and the thing it protects drift apart.
#
# TODO 0.2: .gitignore. docker/vault/certs/ is covered. The storage directory and
#           the init material are not. Add them BEFORE the first run. An unseal
#           key in git history is not fixed by deleting the file — it is fixed by
#           rebuilding the Vault.
#
# TODO 0.3: this script writes into a directory the CA already created as root
#           (mkdir -p made docker/vault/ root-owned when the leaf was issued).
#           Decide who owns what here: the compose file and config are committed
#           and want to be user-editable; certs/ and the storage directory do
#           not. Getting this wrong is not a security problem, it is an hour of
#           sudo-to-edit friction.

# --- Step 1 · The configuration ---------------------------------------------

# TODO 1.1: the listener. Vault serves TLS itself — nothing terminates in front
#           of it (3.4-1). tls_cert_file must be the BUNDLE, not tls.crt: leaf
#           plus intermediate, the same rule nginx follows. Point it at the bare
#           leaf and a browser that has met your intermediate before will work
#           while curl on a clean machine fails. That asymmetry is the hardest
#           version of this bug to believe while you are looking at it.
#
# TODO 1.2: tls_client_ca_file is NOT what you want, despite the name. It
#           verifies certificates CLIENTS present — mutual TLS, a different
#           feature. Serving a chain needs only the cert and the key.
#
# TODO 1.3: the bind address. 0.4-1 says services publish on 0.0.0.0; 3.4-1's
#           accepted cost 3 defers the exception to right here. With nothing in
#           front of it, Vault on 0.0.0.0:8200 answers on every interface on this
#           host — eight of them, four Docker bridges and cloud0 among them.
#           Decide whether Vault is the one service that pins the bridge address.
#           0.4-1 records the reference being inconsistent in exactly this
#           direction, so either answer reverses somebody.
#
# TODO 1.4: api_addr = https://vault.lab.test:8200, and this is the most
#           consequential line in the file. Vault hands this address out — in
#           redirects, in cluster responses, to every client deriving a URL from
#           it. Set it to the container's own view and everything works locally
#           and fails for everyone else, quietly. 3.1 calls it the address that
#           propagates furthest in the lab: CI variables, a cluster-vars
#           ConfigMap, the ClusterSecretStore. A NAME here is what stops the
#           bridge address being baked into thirteen phases of configuration.
#
# TODO 1.5: storage. `file` or integrated `raft`. Raft is HashiCorp's
#           recommendation and brings cluster machinery for the one node this lab
#           has; file is simpler and can never become a cluster. Whichever you
#           choose, write down what a backup of it means — 15.1 backs up
#           everything stateful and this is the first thing in that category.
#
# TODO 1.6: mlock. Vault asks the kernel to pin its memory so secrets cannot be
#           swapped to disk; in a container that needs cap_add IPC_LOCK. The
#           alternative, disable_mlock = true, is one line and means plaintext
#           secrets can reach swap. Decide it deliberately — this is a security
#           property, not a startup warning to silence.
#
# TODO 1.7: ui = true, or not. Costs nothing and adds one more surface on
#           whatever address 1.3 settled.
render_config() {
  die "TODO 1.1: render_config() not implemented"
}

# --- Step 2 · The container ---------------------------------------------------

# TODO 2.1: the image, pinned, in docker-compose.yml the way CoreDNS pins its
#           tag. Note HashiCorp relicensed Vault to BUSL at 1.15 — free for a lab
#           and OpenBao is the Apache-2.0 fork if that matters. Either way pin
#           it: "latest" makes a rebuild a different lab.
#
# TODO 2.2: the bind-mount ownership trap, which 3.1 names because it catches
#           everyone. The container does not run as root. A root-owned storage
#           directory makes `operator init` fail with a permission error that
#           never says "ownership". Fix it before the container starts, and
#           record which UID and why — MinIO has the same problem with a
#           different number, and 5.1 will thank you.
#
# TODO 2.3: mount certs READ-ONLY. Vault has no reason to write there, and the
#           key it would overwrite is the one file here that cannot be replaced
#           without also redistributing trust.
#
# TODO 2.4: CONTAINER_TAG, per L-2, so this service is queryable by a stable name
#           once the daemon's log driver moves to journald. Add it now even
#           though that switch has not happened — L-2 says per compose file as
#           each is written, and retrofitting means finding them all again.
#
# TODO 2.5: the restart policy, and it is a trap. CoreDNS uses unless-stopped and
#           is self-healing because it is stateless. The same policy on Vault
#           brings it back SEALED — running, listening, and refusing everything.
#           Either accept that and make unsealing part of the recovery you
#           practise, or decline to restart automatically and find out
#           immediately. 15.x's drills depend on which you pick.
start_vault() {
  die "TODO 2.1: start_vault() not implemented"
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
#
# TODO 4.2: the container is up before Vault is listening — docker compose
#           returns when the process STARTS. Poll for readiness rather than
#           sleeping, bound the loop, and make the failure message name the fix.
#           Same shape as coredns-installer.sh's resolvectl retry, same reason.
#
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
  render_config
  start_vault
  init_vault
  unseal_vault
  verify_vault
}

main "$@"
