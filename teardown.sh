#!/usr/bin/env bash

# teardown.sh - Remove the containers this lab started.
#
#   ./teardown.sh           # ask first
#   ./teardown.sh --yes     # do not ask
#
# SKELETON — the TODOs are yours. The reasoning is written down so there is
# something to check the finished code against.
#
# Scope, deliberately: containers only. Not the venv, not Docker, not the apt
# repo, not the docker group, and never the host's time sync. Those are things
# bootstrap.sh installed, not things the lab is running, and a teardown that
# uninstalls shared host packages is how these scripts break the machine.

set -euo pipefail

# --- TODO 0 -- root, or not? -------------------------------------------------
#
# bootstrap.sh needs root; this does not. Talking to the docker socket needs
# membership in the docker group, which add_docker_group already granted -- so
# require_root here would only force a sudo nobody needs.
#
# Worth an explicit check the other way: if `docker ps` fails, say "you are not
# in the docker group, log out and back in" rather than letting the raw
# permission-denied surface. That is the failure people actually hit.

# --- TODO 1 -- helpers -------------------------------------------------------
#
# log/warn/die live in bootstrap.sh and are now needed twice. Copy them, extract
# a lib.sh both files source, or accept plain echo here. Whichever you choose is
# one line in docs/decisions.md -- and it decides whether the README's "one
# twenty-line bash file" is still true.

# --- TODO 2 -- --yes and confirmation ----------------------------------------
#
# Default to asking. Print WHAT will be removed -- names, not a count -- then
# read the answer from /dev/tty rather than stdin, so piping this script into
# bash cannot have it swallow its own source as the reply.
#
# Enterprise equivalent: `terraform destroy` shows a plan and demands the word
# "yes". Phase 6 makes that literal; this is the same instinct at small scale.

# --- TODO 3 -- the label, and why it is the whole design ---------------------
#
# The shortcut is `docker rm -f $(docker ps -aq)`. It removes every container on
# the host, including any this lab never created, and it will do that silently
# the first time you run it somewhere else.
#
# So: everything the lab starts carries a label, and this removes only what
# matches. That means 1.2 and 1.3 have to APPLY one --
#
#   1.2   docker run --label lab=singlecluster ...
#   1.3   labels: in the compose service (compose also sets
#         com.docker.compose.project=<dir name>, which is close but is derived
#         from a directory name rather than chosen)
#
# Pick the label now. Retrofitting one onto running services in Phase 9 is far
# more annoying than deciding it today.
#
#   docker ps -aq --filter "label=lab=singlecluster"
#
# Running containers need stopping before removal, or `rm -f`, which sends
# SIGKILL rather than SIGTERM. For nginx that is harmless; for anything holding
# state it is not, and knowing the difference is the point.
remove_lab_containers() {
  :
}

# --- TODO 4 -- volumes, separately -------------------------------------------
#
# A container is disposable; a volume is the data. `docker volume ls -q --filter
# label=...` finds the lab's, but removing them should be its own decision --
# a flag, or its own prompt. Nothing in Phase 1 has a volume yet. Gitea and
# Vault will, and that is when deleting one by reflex costs you an evening.
#
# Decide now whether this script touches volumes at all. "It does not" is a
# perfectly good answer, written down.

# --- TODO 5 -- idempotence ---------------------------------------------------
#
# Same rule as bootstrap.sh: running it twice must not fail. With nothing left
# to remove, the filter returns an empty list -- and `docker rm` with no
# arguments is an error, so guard the empty case and say "nothing to remove".
main() {
  :
}

main "$@"
