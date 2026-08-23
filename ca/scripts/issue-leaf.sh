#!/usr/bin/env bash
#
# issue-leaf.sh — issue one server certificate from the intermediate CA.
#
# Usage: sudo ./issue-leaf.sh <name> [alt-name ...]
#
# Called by hand in Phase 2.4, by the proxy's installer in 2.5, and retired in
# 3.4 when Vault's PKI engine takes over issuance. Worth knowing now: the job of
# this script is to teach the flow, not to still be issuing certificates six
# phases from here.
#
# ---------------------------------------------------------------------------
# SKELETON. Every TODO is a decision to make, not just code to write. Grep for
# TODO to see what is left; they are numbered by the step they belong to.
#
# One sentence settles most of them, and it is already recorded in 2.4-1:
#
#     the requester chooses the key and the name;
#     the CA chooses what the certificate may do.
#
# The CSR carries the first half. [ leaf_ext ] in intermediate-ca.cnf carries
# the second, and `copy_extensions = none` is what stops a request from reaching
# across that line. When you cannot decide which side a value belongs on, that
# sentence answers it — and the answer has a consequence that bites in step 4.
#
# Three artifacts, and only one of them is secret:
#
#   the key          never moves, never leaves this host, is not in the CSR
#   the CSR          travels to the CA; it is a request, not an instruction
#   the certificate  comes back; it is the CA's statement, not yours
# ---------------------------------------------------------------------------

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SOURCE_SCRIPT}/../../lib/common.sh"

PKI_DIR="$(cd -- "${SOURCE_SCRIPT}/.." && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_SCRIPT}/../.." && pwd)"
ROOT_DIR="${PKI_DIR}/root"
INT_DIR="${PKI_DIR}/intermediate"
INT_CNF="${PKI_DIR}/intermediate-ca.cnf"
INT_CRT="${INT_DIR}/intermediate-ca.crt"
INT_PASS="/root/.intermediate-ca.pass"
ROOT_CRT="${ROOT_DIR}/root-ca.crt"

# Issued leaves live with the service that reads them, never under ca/. Three
# reasons, heaviest first:
#
#   1. Everything secret under ca/ is encrypted, and 2.3-5 leans on exactly
#      that — a copy of the tree is survivable because the passphrases are in
#      /root. A leaf key is unencrypted by necessity (3.1), so one stored under
#      ca/ makes that claim false while the sentence asserting it still stands.
#   2. ca/root and ca/intermediate are 0700 root; a leaf must be readable by
#      the service. Opposite postures as siblings invite a single chmod -R.
#   3. Leaves are retired wholesale at 3.4 when Vault takes over issuance.
#      Kept outside ca/, that retirement is a directory delete.
#
# The CA keeps its own record regardless: `openssl ca` archives every issued
# certificate in ca/intermediate/newcerts/ by serial, and index.txt is the
# register. What lives here is a distribution copy, which is why it belongs with
# its consumer. See 2.4-5.
#
# One flat directory, because the consumer is what mounts it and what teardown
# removes. A second consumer is the trigger to make this an argument; a constant
# is honest about there being one.
#
# Off REPO_ROOT rather than a "../" hop off PKI_DIR: PKI_DIR is already ca/, so
# relative arithmetic from it lands back inside ca/ with one ".." too few and
# outside the repository with one too many — and both still look plausible until
# something writes a key there. cd/pwd also normalises it, so a path printed by
# die reads cleanly.
LEAF_DIR="${REPO_ROOT}/docker/proxy/certs"

# TODO 0.1: the directory's own mode is still open. Settle it together with 3.3
#           — the answer differs for a container bind-mount and a host process,
#           and the key's mode and the directory's have to agree.

# The DN every leaf must carry, less the CN. Not a style choice: [ leaf_pol ] in
# intermediate-ca.cnf lists domainComponent and organizationName as `match`, so
# openssl compares them against the intermediate's own subject and refuses a CSR
# that differs. See 2.4-2.
LEAF_DN_BASE="/DC=test/DC=lab/O=SingleClusterIaCLab"

# --- Arguments --------------------------------------------------------------

# TODO 1.1: <name> is the CN and the first SAN. Every additional argument is
#           another SAN. Decide whether a bare `issue-leaf.sh` with no arguments
#           is an error or prints usage — and note that a CN is required by
#           leaf_pol (`supplied`), so there is no "SAN-only" certificate here.
# TODO 1.2: validate the names. A typo becomes a certificate that is silently
#           wrong for the host it is installed on, and you will debug it as an
#           nginx problem. What makes a name acceptable — a regex, a suffix
#           check against lab.test, or nothing at all? Say why in the comment.
# TODO 1.3: IP SANs. build-order 2.3 calls certificates for IP addresses
#           painful; 0.4-1 has services binding 0.0.0.0 and everything reached
#           by name from Phase 2 on. Decide whether `IP:` is supported at all.
#           Refusing is a real answer, and the cheaper one to maintain.
parse_args() {
  die "TODO 1.1: parse_args() not implemented"
}

# --- Preflight --------------------------------------------------------------

# TODO 2.1: the intermediate must be present AND usable before anything is
#           generated. intermediate-ca-create.sh:require_root_ca is the shape to
#           copy — it checks the passphrase opens the key rather than checking
#           the file exists. Which files does signing actually need? Work it out
#           from the [ intermediate_ca ] section, not from memory.
# TODO 2.2: this script needs the intermediate's CA database to record what it
#           issues. init_ca_db() already created it. Decide whether to verify
#           that, or to let openssl produce its own error.
require_intermediate_ca() {
  die "TODO 2.1: require_intermediate_ca() not implemented"
}

# TODO 2.3: what happens when <name> already has a certificate? Three options,
#           and this is the most consequential decision in the file:
#             - refuse, like root-ca-create.sh — safe, and useless for renewal
#             - reissue every time — simple, and churns a working service
#             - reissue only when missing or near expiry — what 3.5 automates
#           `unique_subject = no` is already set in intermediate-ca.cnf, so
#           openssl will not stop you reissuing. That was deliberate; the guard
#           has to be yours. If you pick the third, decide the threshold in days
#           and where it is written down.
check_existing() {
  die "TODO 2.3: check_existing() not implemented"
}

# --- The three artifacts ----------------------------------------------------

# TODO 3.1: generate the leaf private key. Both CA keys are AES-256 encrypted
#           with a passphrase in /root. A leaf key must NOT be — nginx, Vault
#           and CoreDNS all start unattended, and a passphrase makes every
#           restart a manual step. Write down that this reverses 2.3-5 on
#           purpose, and what protects the key instead.
# TODO 3.2: algorithm and size. 2.3-2 chose RSA-4096 for the root and gave a
#           reason that was about long-lived trust anchors and unknown clients.
#           A 397-day server key is a different question. Decide, and if you
#           land somewhere other than the root's choice, say why the argument
#           does not carry over.
# TODO 3.3: mode and ownership. 0400 root-only is what the CA keys use. Can the
#           service that needs this key actually read it? Answer for a container
#           bind-mount as well as a host process — they differ.
create_key() {
  die "TODO 3.1: create_key() not implemented"
}

# TODO 4.1: build the CSR. The obvious call is wrong, and this is the trap the
#           header warned about: `openssl req -new -config "${INT_CNF}"` loads
#           [ req ], whose distinguished_name is ca_dn, whose commonName is
#           "lab.test Issuing CA". You would request a certificate naming
#           itself the CA. Override the subject with -subj and LEAF_DN_BASE.
# TODO 4.2: the SAN does NOT go in the CSR. copy_extensions = none means the CA
#           discards anything the request asks for, so a SAN put here is
#           silently dropped and the leaf comes back with none — which modern
#           clients reject outright, having ignored CN since 2017. The SAN is
#           applied at signing, in step 5. Write the comment that stops the next
#           person putting it back.
# TODO 4.3: given 4.2, does this call need ${INT_CNF} at all? A CSR is a key
#           plus a subject. Decide, and if you do pass the config, remember it
#           expands $ENV::LEAF_SAN at load time whether or not you use the
#           section it appears in — see 2.4-2.
create_csr() {
  die "TODO 4.1: create_csr() not implemented"
}

# TODO 5.1: sign with `openssl ca`, not `req -x509` — 2.4-1 explains what the
#           second one skips. Two environment variables have to be right on this
#           one command, and both fail quietly:
#             CA_DIR    must be the INTERMEDIATE's directory, so openssl finds
#                       its index.txt and newcerts/. Point it at the root's and
#                       you record the issuance in the wrong CA's database.
#             LEAF_SAN  the full openssl SAN string, e.g. DNS:a.lab.test,DNS:b
# TODO 5.2: build LEAF_SAN from the CN and the alt-names of 1.1. The CN must
#           appear in it — a certificate whose CN is absent from its own SAN is
#           the single most common way to produce something that looks right and
#           serves nothing.
# TODO 5.3: -extensions leaf_ext, even though [ intermediate_ca ] already sets
#           x509_extensions = leaf_ext. root-ca-create.sh passes it explicitly
#           for the same reason; match that, or decide not to and say why.
# TODO 5.4: no -days. [ intermediate_ca ] sets default_days = 397 and 2.4-2
#           explains the number. Passing -days here would move that decision out
#           of the config and into an argument nobody reads.
sign_csr() {
  die "TODO 5.1: sign_csr() not implemented"
}

# --- What the server actually consumes --------------------------------------

# TODO 6.1: assemble the bundle. A server needs leaf + intermediate, in that
#           order, and NOT the root — the client already has the root or it does
#           not trust you at all, and sending it wastes a round trip's bytes on
#           every handshake. Note this is a different file from
#           intermediate/ca-chain.crt, which is intermediate + root and exists
#           for verification, not for serving.
# TODO 6.2: omitting the intermediate is the failure build-order 2.4 tells you
#           to go and reproduce: it works in a browser that cached the
#           intermediate from an earlier visit and fails in curl on a clean
#           machine. Decide whether this script emits the bundle at all or
#           leaves assembly to Phase 2.5 — but if it does not, write down where
#           that responsibility went.
build_bundle() {
  die "TODO 6.1: build_bundle() not implemented"
}

# --- Prove it before claiming it --------------------------------------------

# TODO 7.1: verify the chain the way a client will:
#             openssl verify -CAfile <root> -untrusted <intermediate> <leaf>
#           -untrusted is the part people leave out. It is where the
#           intermediate goes; -CAfile is trust anchors only.
# TODO 7.2: assert the SAN actually landed, and that it contains every name
#           asked for. If LEAF_SAN was empty or misspelled, everything above
#           still succeeds and you get a certificate no client will accept. This
#           check is the only thing between that and a two-hour nginx hunt.
# TODO 7.3: assert CA:FALSE. Cheap, and it is the property copy_extensions
#           protects — so it is worth confirming the protection is on.
# TODO 7.4: 0.3-7 applies to every die above. Short, and name the fix.
verify_leaf() {
  die "TODO 7.1: verify_leaf() not implemented"
}

# --- Housekeeping the repo will need ----------------------------------------
#
# Done ahead of the first key rather than after it, which is the whole lesson of
# 2.3-6: docker/proxy/certs/ is in .gitignore, and a probe path under it is in
# the Makefile's CA_KEYS, so `make lint` fails if that rule stops matching.
#
# TODO 8.1: teardown. Leaves are NOT under ca/, so teardown.sh TODO 3.1's "two
#           directories under ca/" stays correct as written. What is missing is
#           the proxy's certs directory — and it belongs with the Phase 2.5
#           proxy teardown, not with teardown_ca, or --keep-ca would strand it.
#           Decide where that step goes when 2.5 gives it a home.
# TODO 8.2: this is the first unencrypted private key in the repo. Every earlier
#           one was safe to copy; this one is not. Anything that archives or
#           snapshots the tree wants re-reading in that light — 2.3-5's
#           "accepted risk" paragraph is the one that changes.

# Run every step in order.
main() {
  require_root
  parse_args "$@"
  require_intermediate_ca
  check_existing
  create_key
  create_csr
  sign_csr
  build_bundle
  verify_leaf
}

main "$@"
