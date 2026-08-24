#!/usr/bin/env bash
#
# issue-leaf.sh — issue the lab's server certificate from the intermediate CA.
#
# Usage: sudo ./issue-leaf.sh
#
# Called by hand in Phase 2.4, by the proxy's installer in 2.5, and retired in
# 3.4 when Vault's PKI engine takes over issuance. Worth knowing now: the job of
# this script is to teach the flow, not to still be issuing certificates six
# phases from here.
#
# Takes no arguments, for the same reason root-ca-create.sh and
# intermediate-ca-create.sh take none: there is exactly one of the thing it
# makes. TLS terminates at one place in this lab — the reverse proxy of 2.5 —
# so there is one certificate, carrying every host-tier name as a SAN, read by
# one consumer. See 2.5-1 for why Vault is included rather than holding its own.
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT ISSUES, AND WHAT IT DOES NOT
#
# One leaf, for the proxy. gitea, cloudstack, minio, vault and grafana sit
# BEHIND it and hold no certificate of their own — the proxy holds one covering
# all of them, and the hop from proxy to each backend is plain HTTP on the host.
#
# Everything else gets its certificate somewhere else, by design:
#
#   k3s control plane      k3s's own internal CA — self-managed, auto-rotated
#   gateway fabric, web    cert-manager, from Vault's PKI engine (3.4)
#   app, postgres,
#   kube-prometheus, flux
#   anything in the VPC    Vault — 3.4 lands before Phase 4 exists
#   tiers (frontend,
#   tunnel, backend)
#   wg0 / wg1              nothing. WireGuard uses Curve25519 keypairs, not
#                          x509. Encrypted is not the same as TLS.
#
# All of it still chains to the same offline root, which is what 2.6's trust
# distribution buys. The root's `intermediate_ca_ext` sets pathlen:0, so this
# intermediate can sign leaves but NOT another CA — Vault's PKI intermediate is
# signed by the root directly, making the two intermediates siblings rather than
# parent and child. That is why 3.4 says "sign that with your offline root".
#
# If you find yourself wanting a second certificate here, check first whether
# the thing needing it arrives after 3.4. If it does, this is the wrong script
# and the answer is a Vault PKI role. If it arrives before 3.4 and genuinely
# cannot sit behind the proxy, that is the trigger to reopen 2.5-1 — the shape
# it would take is an argument selecting one of several named profiles, and the
# reasoning for and against is recorded there rather than lost.
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

# The DN every leaf must carry, less the CN. Not a style choice: [ leaf_pol ] in
# intermediate-ca.cnf lists domainComponent and organizationName as `match`, so
# openssl compares them against the intermediate's own subject and refuses a CSR
# that differs. See 2.4-2.
LEAF_DN_BASE="/DC=test/DC=lab/O=SingleClusterIaCLab"
LEAF_CN="proxy.lab.test"
LEAF_ALT_NAME=(
  cloudstack.lab.test
  gitea.lab.test
  minio.lab.test
  vault.lab.test
  test.lab.test
)

# --- What this certificate is -----------------------------------------------
#
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

# TODO 1.1: name the certificate. Two values, and the second is a list:
#
#             LEAF_CN         the Common Name
#             LEAF_ALT_NAMES  every OTHER name the proxy answers for
#
#           The CN is added to the SAN list in step 5, not here — see 5.2 — so
#           this array holds only the others. Pick the CN to name the HOLDER,
#           not one of its tenants: clients have ignored CN since 2017, so it is
#           documentation, and promoting a backend's name to CN implies a
#           hierarchy among the SANs that does not exist. Do not forget the name
#           build-order 2.4's acceptance check actually curls, or vault.lab.test
#           — 2.5-1 puts Vault behind the proxy, so this certificate answers for
#           it and Vault holds none of its own.
#
#           ENTERPRISE EQUIVALENT: per-service certificates selected by SNI, not
#           one certificate carrying six names. nginx and Envoy both hold many
#           certs and choose by the hostname in the handshake. Multi-SAN is an
#           anti-pattern at scale for two reasons worth knowing: adding a seventh
#           name reissues and redeploys the certificate the other six depend on,
#           and one key compromise is a compromise of every name on it. We take
#           it here because per-service certs are only cheap once issuance is
#           automated — which is 3.4 — and six certificates by hand is busywork,
#           not learning. A deliberate debt, not a default.
#
# TODO 1.2: these names and the A records in
#           docker/coredns/zones/lab.test.zone.tmpl are one decision, not two.
#           The zone currently has ns, cloudstack, gitea, minio and vault. A name
#           in the certificate with no A record is a certificate for something
#           unreachable; an A record with no SAN is a padlock warning. They
#           change in the same commit, always.
#
# TODO 1.3: the file paths — the key, the certificate, the bundle, and the CSR.
#           Declare them here beside LEAF_DIR, the way the two CA scripts declare
#           theirs, so a reader finds "what does this write" in one place.
#
#           Let the DIRECTORY identify the consumer and the FILENAME identify the
#           role. ENTERPRISE EQUIVALENT, and here the lab and the enterprise
#           agree exactly: Kubernetes' `kubernetes.io/tls` secret type mandates
#           the keys `tls.crt` and `tls.key` (plus `ca.crt` for the trust
#           bundle), and cert-manager writes precisely those. Use the same names
#           and the consumer's configuration does not change at 3.4 — only the
#           thing writing the files does. The cheapest foreshadowing available.
#
#           What enterprise does differently is HOW the file arrives: not a
#           script writing to a bind mount, but an agent — vault-agent
#           templating, cert-manager reconciling a Secret, or SPIFFE/SPIRE
#           handing a workload an SVID over a socket with no file at all. In the
#           strongest form the private key never touches disk, or never leaves an
#           HSM. We are skipping the delivery mechanism, not the layout.
#
#           The CSR is the odd one out: transient, not secret, and read by
#           nothing after step 5. Decide whether it lands in LEAF_DIR at all —
#           shipping it into a directory a container mounts is clutter.

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

# TODO 2.3: what happens when the certificate already exists? The siblings answer
#           this and the shape is worth copying exactly: check_existing() in
#           intermediate-ca-create.sh:35 builds present[] and missing[], returns
#           when nothing exists, dies when the set is partial, and exits 0 when
#           it is complete. Three states, one of which refuses rather than
#           guessing.
#
#           `unique_subject = no` is set in intermediate-ca.cnf, so openssl will
#           not stop you reissuing. That was deliberate; the guard has to be
#           yours.
#
#           Renewal is NOT this script's verb. 3.5 automates it, from Vault,
#           after 3.4 has replaced this issuance path entirely — so "reissue
#           when near expiry" is a threshold you would write here, exercise
#           roughly twice, and delete. Refuse, and leave renewal to the phase
#           that owns it. If you disagree, the argument to beat is that a create
#           script and a renew script have different failure modes: one can
#           safely refuse, the other must not.
#
#           One wrinkle the siblings do not have: adding a name to LEAF_ALT_NAMES
#           must reissue, and a refusing check_existing will not. Decide how that
#           is done — a documented "delete and re-run", or a flag — and write it
#           down, because a multi-SAN certificate makes it a routine event rather
#           than an exceptional one.
check_existing() {
  die "TODO 2.3: check_existing() not implemented"
}

# --- The three artifacts ----------------------------------------------------

# TODO 3.1: generate the leaf private key. Both CA keys are AES-256 encrypted
#           with a passphrase in /root. A leaf key must NOT be — nginx starts
#           unattended, and a passphrase makes every restart a manual step.
#           Write down that this reverses 2.3-5 on purpose, and what protects the
#           key instead.
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
#           itself the CA. Override the subject with -subj, built from
#           LEAF_DN_BASE and LEAF_CN.
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
# TODO 5.2: build LEAF_SAN from LEAF_CN and LEAF_ALT_NAMES. The CN must appear in
#           it — a certificate whose CN is absent from its own SAN is the single
#           most common way to produce something that looks right and serves
#           nothing. Compose it here rather than up top: the constants hold
#           names, this holds openssl's format for them, and keeping the "CN is
#           also a SAN" rule next to the command that depends on it is what stops
#           the two drifting.
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
#
#           This one file is the whole of "implementing TLS" downstream: nginx
#           needs three directives, and the only one that can be wrong is
#           `ssl_certificate`, which must point HERE and not at the bare leaf.
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
# TODO 7.2: assert the SAN actually landed, and that it contains every name in
#           LEAF_CN and LEAF_ALT_NAMES. If LEAF_SAN was empty or misspelled,
#           everything above still succeeds and you get a certificate no client
#           will accept. This check is the only thing between that and a two-hour
#           nginx hunt — and with one certificate serving six names, a single
#           missing SAN breaks one service while five keep working, which is
#           harder to notice than a total failure.
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
  check_existing
  require_intermediate_ca
  create_key
  create_csr
  sign_csr
  build_bundle
  verify_leaf
}

main "$@"
