#!/usr/bin/env bash
#
# teardown.sh — undo bootstrap.sh: remove CoreDNS, CloudStack, the CA, and the
# host changes their installers made, in the reverse of the order they were made.
#
# Usage: sudo ./teardown.sh [--yes] [--restore-network] [--purge-storage]
#                           [--purge-packages] [--keep-ca]
#
# DRY RUN BY DEFAULT. Without --yes it prints what it would do and changes
# nothing.
#
# LAB ONLY, and destructive by design.
#
# ---------------------------------------------------------------------------
# SKELETON. Every TODO is a decision to make, not just code to write. Grep for
# TODO to see what is left; they are numbered by the step they belong to.
#
# Sort every artifact you find into one of four buckets before writing the line
# that removes it:
#
#   reversible      the installer created it, nothing else wants it -> remove
#   reconstructable the installer destroyed prior state -> rebuild, or refuse
#   shared          predates the lab, or others depend on it -> flag, or leave
#   unrecoverable   edited in place over unsaved values -> report, never guess
#
# The bucket decides the code. Most of the work here is the sorting.
# ---------------------------------------------------------------------------

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/lib/common.sh"

BRIDGE="${BRIDGE:-cloudbr0}"

DRY=1
RESTORE_NETWORK=0
PURGE_STORAGE=0
PURGE_PACKAGES=0
KEEP_CA=0

# Things this script cannot put back, collected as it goes and printed at the
# end. A teardown that silently leaves a host altered is worse than one that
# says so — every "unrecoverable" bucket item should end up in here.
declare -a FOLLOW_UPS=()

# --- Arguments --------------------------------------------------------------

# TODO 0.1: decide the default. Dry run, or act? Consider which mistake you can
#           recover from: a teardown that printed when you wanted it to act, or
#           one that acted when you wanted it to print.
# TODO 0.2: each flag below gates one decision you are choosing not to make for
#           the operator. If you find yourself adding a fifth, ask whether the
#           thing behind it is really a decision or just a step you are unsure
#           about — those belong in the code, not the interface.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --yes) DRY=0 ;;
    --restore-network) RESTORE_NETWORK=1 ;;
    --purge-storage) PURGE_STORAGE=1 ;;
    --purge-packages) PURGE_PACKAGES=1 ;;
    --keep-ca) KEEP_CA=1 ;;
    -h | --help) usage ;;
    *) die "Unknown option: $1. Run with --help." ;;
    esac
    shift
  done
}

usage() {
  # TODO 0.3: print the header block above rather than a second copy of it, or
  #           the two will drift. Bound it on the first non-comment line, not a
  #           line number a later edit would push past.
  die "TODO: usage"
}

# --- Helpers ----------------------------------------------------------------

# TODO 0.4: you need two runners, not one, and the difference is the interesting
#           part. Most teardown steps are best-effort — removing something that
#           is already gone is success, not failure, and must not abandon the
#           steps after it. A few must not be stepped over: if `netplan
#           generate` fails, carrying on and deleting the bridge is how you lose
#           the host. Write `try` for the first kind and `run` for the second,
#           and make both print instead of executing when DRY is set.
try() {
  die "TODO 0.4: try() not implemented"
}

run() {
  die "TODO 0.4: run() not implemented"
}

# TODO 0.5: apt exits non-zero when handed a package that is not installed,
#           which buries the failures that matter. Filter to what dpkg actually
#           reports installed before purging.
purge_pkgs() {
  die "TODO 0.5: purge_pkgs() not implemented"
}

# TODO 0.6: `systemctl disable --now` on a unit that was never installed is
#           noise on every run of a teardown that is supposed to be re-runnable.
#           Decide how you detect "this unit does not exist" and skip quietly.
stop_unit() {
  die "TODO 0.6: stop_unit() not implemented"
}

# --- Step 1 · CoreDNS -------------------------------------------------------

# Reverse docker/coredns/coredns-installer.sh.
teardown_coredns() {
  log "Step 1/5: removing CoreDNS..."

  # TODO 1.1: stop and remove the container. `docker compose down` is the
  #           obvious move, but read docker-compose.yml:24 first — the port
  #           mapping is ${CLOUDBR0_IP:?...}, so compose refuses to parse its
  #           own file once .env is gone. What is the fallback, and what makes
  #           it safe to rely on? (container_name is pinned at line 16.)
  # TODO 1.2: the image was pulled by us. Removing it is cheap and repullable;
  #           leaving it saves a download on the next bootstrap. Pick one and
  #           say why in a comment.
  # TODO 1.3: remove the two generated files — installer lines 36 and 41. Both
  #           are gitignored and regenerated on the next run, so this is the
  #           easiest bucket call in the script. Which bucket, and why?
  # TODO 1.4: remove the resolved drop-in written at installer line 74. Then ask
  #           what happens if bootstrap died between Phase 1 and here: installer
  #           line 66 deletes 05-cloudstack-bootstrap.conf, so it survives only
  #           on a partial run. Handle the partial-run case.
  # TODO 1.5: restart systemd-resolved, or the host keeps answering lab.test
  #           from a resolver that no longer exists.
  :
}

# --- Step 2 · CloudStack ----------------------------------------------------

# Reverse cloudstack-install-all.sh and the vendored installer beneath it.
# Ordering here is not simply "reverse of install": see TODO 2.1.
teardown_cloudstack() {
  log "Step 2/5: removing CloudStack..."

  # TODO 2.1: order these yourself before writing them. Two constraints that
  #           reverse-of-install gives you for free — but check rather than
  #           assume: a service must stop before the database it holds open can
  #           be dropped, and the database must be dropped before MySQL could be
  #           purged. Write the order down as a comment; it is the part of this
  #           function a reader cannot reconstruct.

  # TODO 2.2: services. Three units — management, agent, usage. Which order,
  #           and does it matter?
  # TODO 2.3: databases. cloudstack-setup-databases at installer line 1148 is
  #           invoked as `cloud:cloud@localhost --deploy-as=root:`. Work out
  #           from that what it created: how many schemas, and what user at
  #           which hosts. Then decide what happens when MySQL is not running —
  #           silently skipping leaves the databases behind, so this is a
  #           FOLLOW_UPS case.
  # TODO 2.4: /etc/mysql/mysql.conf.d/cloudstack.cnf (installer line 1222) is a
  #           drop-in the lab owns outright. Easy.
  # TODO 2.5: /etc/exports — the one you have already worked through. If the
  #           installer now writes /etc/exports.d/cloudstack.exports, this is an
  #           rm. If it still appends, you need the narrower legacy path, and a
  #           comment saying when it can be deleted.
  # TODO 2.6: the three /etc/default seds at installer lines 1341-1344. Two are
  #           reversible substitutions. The third — NEED_STATD=yes — is not:
  #           line 1343 appends only when absent, so a present one may be
  #           yours. Which bucket does that put it in, and what do you do?
  # TODO 2.7: /export. Check its size before deciding the default (it holds
  #           downloaded system templates). Flag-gated: PURGE_STORAGE.
  # TODO 2.8: libvirt. Installer line 1452 masks five sockets — unmask them.
  #           Lines 1466-1480 symlink two AppArmor profiles into
  #           /etc/apparmor.d/disable/ — remove the links and re-parse.
  #           Then read lines 1434-1449: five keys rewritten in place over
  #           whatever was there, saved nowhere. That is the unrecoverable
  #           bucket. Do not guess at defaults; report it.
  # TODO 2.9: ufw. Six rules added around installer line 1503. `ufw delete`
  #           takes the rule as it was written. Were any of them present before?
  #           You cannot tell — note the consequence.
  # TODO 2.10: packages and state directories: the cloudstack-* packages, plus
  #            /etc/cloudstack and friends.
  # TODO 2.11: cmk (cloudmonkey-install.sh line 48) and the profile it keeps in
  #            root's home. See decisions.md 1.2-1 for why it is root's.
  # TODO 2.12: the apt repo and keyring written by cloudstack-install-all.sh,
  #            and the sysctl file it writes at the end.
  # TODO 2.13: prepare-kvm-host.sh:36 set a root password and :42 opened root +
  #            password SSH. Closing the drop-in is easy. The password is not:
  #            you do not know whether root was locked before. Decide, and note
  #            which installer fix would have made this knowable.
  # TODO 2.14: the installer's own state — the tracker and installer.log at the
  #            repo root. Removing the tracker is what makes a later re-install
  #            actually re-run; see failure-log.md on why editing it does not.
  # TODO 2.15: the shared packages the vendored installer pulled in — mysql,
  #            nfs, qemu-kvm, and a grab-bag at installer line 937. All shared
  #            bucket. Gate on PURGE_PACKAGES and say so in FOLLOW_UPS.
  if ((PURGE_STORAGE)); then :; fi
  if ((PURGE_PACKAGES)); then :; fi
}

# --- Step 3 · The CA --------------------------------------------------------

# Reverse ca/ca-install-all.sh.
teardown_ca() {
  if ((KEEP_CA)); then
    log "Step 3/5: keeping the CA (--keep-ca)."
    return 0
  fi

  log "Step 3/5: removing the CA..."

  # TODO 3.1: four things — two directories under ca/, two passphrases in /root.
  #           Read root-ca-create.sh:32 (check_existing) before you write this.
  #           It refuses to start against a half-state: a key without its
  #           passphrase, or a passphrase without its key. That tells you
  #           something about how this removal has to behave. What?
  # TODO 3.2: the root certificate may have been copied into a trust store —
  #           this host's, a browser's, a container image's. Phase 2.6 is
  #           entirely about how many copies that becomes. You cannot find them
  #           all from here. FOLLOW_UPS.
  :
}

# --- Step 4 · Docker --------------------------------------------------------

teardown_docker() {
  if ! ((PURGE_PACKAGES)); then
    log "Step 4/5: keeping Docker (pass --purge-packages to remove it)."
    return 0
  fi

  log "Step 4/5: removing Docker..."

  # TODO 4.1: bootstrap.sh:79 returns early if docker already exists, so this
  #           script cannot tell "we installed it" from "it was already here".
  #           That is why Docker is behind a flag rather than simply removed.
  #           Note the installer fix that would let you drop the flag.
  # TODO 4.2: packages, /var/lib state, the apt keyring and sources file
  #           (bootstrap.sh:89-101).
  :
}

# --- Step 5 · The bridge ----------------------------------------------------

# Reverse the vendored installer's netplan rewrite. Opt-in, and last, because it
# is the one step that can end the session running it.
teardown_network() {
  if ! ((RESTORE_NETWORK)); then
    log "Step 5/5: leaving ${BRIDGE} in place (pass --restore-network to remove it)."
    # TODO 5.1: say why in FOLLOW_UPS. Deleting the bridge by hand is not safe
    #           either, and the reader deserves to know that before they try.
    return 0
  fi

  log "Step 5/5: restoring the network..."

  # TODO 5.2: read cloudstack-install.sh:2329-2353. It writes the bridge config
  #           and then runs `rm -f /etc/netplan/50-cloud-init.yaml`. There is no
  #           original to restore. This is the reconstructable bucket: the only
  #           evidence left is the bridge file itself, which names the physical
  #           interface, the address and the gateway.
  # TODO 5.3: parse those three out of the bridge yaml. One trap: `addresses:`
  #           appears twice — once for the bridge, once under nameservers. Find
  #           a discriminator that does not depend on line order.
  # TODO 5.4: if any of the three is missing, STOP. A partial netplan file
  #           leaves the host unreachable, and this is the one place in the
  #           script where continuing is worse than failing. `run`, not `try`.
  # TODO 5.5: write the replacement, delete the bridge file, generate, apply.
  #           Warn first: this reconfigures the interface the operator is most
  #           likely connected over. Tell them which address to reconnect on.
  # TODO 5.6: FOLLOW_UPS — what you wrote is a reconstruction, not the config
  #           this host had before CloudStack. Say so.
  :
}

# --- Reporting --------------------------------------------------------------

report() {
  if ((DRY)); then
    log "Dry run: nothing above was executed. Re-run with --yes to apply."
  else
    log "Teardown complete."
  fi

  # TODO 6.1: print FOLLOW_UPS, and make it hard to miss. Everything in the
  #           unrecoverable and shared buckets should have landed here. If this
  #           list is empty at the end of a real run, you have almost certainly
  #           mis-sorted something rather than achieved a perfect teardown.
  [[ ${#FOLLOW_UPS[@]} -eq 0 ]] || warn "TODO 6.1: ${#FOLLOW_UPS[@]} follow-ups to print"
}

# Never removed, and worth saying so in a comment when you get there: bootstrap
# installs curl, jq, gettext-base, openssl and ca-certificates, and enables NTP.
# Those are base system tools that predate this lab on most hosts — purging
# ca-certificates would break TLS for everything else on the machine.
main() {
  parse_args "$@"
  require_root

  if ((DRY)); then
    log "DRY RUN — printing what would be removed. Re-run with --yes to apply."
  else
    warn "Removing the lab. This is not reversible."
  fi

  teardown_coredns
  teardown_cloudstack
  teardown_ca
  teardown_docker
  teardown_network
  report
}

main "$@"
