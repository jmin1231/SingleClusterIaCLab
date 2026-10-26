# Build plan — enterprise VPC, identity and zero-trust lab on CloudStack

## Context

A single Ubuntu 24.04 host becomes a small but enterprise-shaped private cloud:
Apache CloudStack as the IaaS, a Packer golden image shipped through an object store, a
VPC with isolated tiers, and an identity-based overlay as the only route between them.
Everything is secrets-managed, remote-stated, policy-gated and pipeline-driven, with a
`down` that restores the host and proves it.

It satisfies JQR 191 (*construct a VPC and implement a VPN to provide access*) while
mirroring how a platform team actually runs this: central accounts, SSO, short-lived
credentials, default-deny networking and a reviewable change path.

**Built from scratch.** Nothing in the repo root and nothing in `reference/` is reused
or adapted. Git history is what preserves the prior attempt, which is also the repo's
own stated method — *a file you can open is a file you will copy, so read it from
history where it is inconvenient enough to be deliberate*. The sole exception is the
vendored upstream CloudStack installer, which is third-party code we re-vendor, never
author.

**Resource sizing is out of scope here.** Tools get tailored or cut once it runs.
`docs/resource-budget.md` is written against a Kubernetes estate this plan does not
have and needs rewriting regardless.

This document is a **design review plus a step list**. The review comes first because
nine findings change the phase ordering, and two of them decide whether the lab is
achievable at all.

---

## What changed in this revision

| | Was | Now |
|---|---|---|
| **Overlay** | hand-managed WireGuard, hub-and-spoke | **Tailscale**, self-hosted control plane, tag-based ACLs, subnet-router transit |
| **Host login** | local accounts, Ansible-placed SSH keys | **Active Directory** — central accounts, groups, sudo policy, Kerberos |
| **Service login** | local admin password per service | **SSO** — OIDC brokered from AD, MFA on privileged groups |
| **SSH access** | static `authorized_keys` | **Vault SSH CA** — short-lived signed certificates, principals from AD groups |
| **Phases / steps** | 10 phases | 14 phases, 70 steps — identity and access are new, the overlay is built once |

Three identity planes now exist, and `14.0-1` is explicit that conflating them is where
the confusion starts. They must never cross:

| Plane | Who → what | Mechanism | Phase |
|---|---|---|---|
| **Host identity** | humans + machines → hosts | LDAP + Kerberos (AD) | 7 |
| **Application SSO** | humans → services | OIDC via Keycloak, federated from AD | 8 |
| **Workload identity** | services → secrets, PKI | Vault AppRole / JWT | 3 |

A human never gets an AppRole. A machine never gets an OIDC login. Keycloak is **not**
a directory — it has no KDC, no machine enrolment, no host keytabs, and a VM cannot be
joined to it. That is what AD is for, and it is why both exist.

---

## Design review

The source design is strong: it identifies the genuinely hard parts (bootstrap
circularity, the CloudStack ACL race, ConfigDrive over the VR metadata service, the
transit-hub mapping to a Transit Gateway, Tailscale's flat-mesh default). The findings
below are where it is wrong, under-specified, contradicts decisions this repo already
paid for, or hides a multi-day step in a one-line bullet.

### Blocking — settle before writing code

**R1 · There is no DNS, CA or proxy phase, and nothing works without all three.**
MinIO must be reachable from the SSVM network, `vault kv get` runs over an API,
templates register **by URL**, and the Terraform `s3` backend points at MinIO over TLS.
Every one needs a name and a certificate. CloudStack has **no HTTPS listener at all** —
until a proxy existed in the prior build, the admin password crossed the bridge in
cleartext on every login. This is a recorded failure here: `bootstrap.sh` once exited
**7** (curl's *failed to connect*, no error named) because two steps needed a proxy that
ran after them. *Fix:* a phase between CloudStack and the control plane — CoreDNS, Vault,
Vault's PKI as the only CA, then the proxy.

**R2 · `down` is not achievable as written, and the window closes in Phase 1.**
Verified in the vendored installer: `configure_network()` writes
`/etc/netplan/01-bridge-$BRIDGE.yaml`, then at **line 2353** runs
`rm -f /etc/netplan/50-cloud-init.yaml` — deleting the host's original network
configuration **with no backup** — and at **line 2355** runs `netplan generate && netplan
apply`, not `netplan try`, so a bad config costs the host rather than auto-reverting.
The installer has **no uninstall path**: all 70 functions are install or query, and
`cleanup()` (line 2622) is an exit-trap that prints and removes nothing. So the
one-line "CloudStack uninstall … then `restore_netplan()`" is a from-scratch build whose
only prerequisite — a pristine copy of the host's networking — must be taken before the
installer ever runs.
Two refinements from `1.3-6`, which got this wrong once: **snapshot the whole
`/etc/netplan/` directory, not the file the installer names** — on that host
`50-cloud-init.yaml` did not exist and the bridge-governing file was
`01-network-manager-all.yaml`, so saving the named file would have captured nothing.
Also snapshot `libvirtd.conf` and the four `/etc/default` files, and **guard on the
snapshot directory's existence, not the files inside it**, or a second bootstrap
overwrites the snapshot with post-install state.

**R3 · `CLOUDSTACK_UNATTENDED=1` does not make the installer headless.**
It defines `show_dialog()` (line 559) which degrades to `printf` when silent — but
**27 direct `dialog` calls bypass it**, against 19 silent-mode guards in the whole file,
including the netplan/bridge path (line 2325) and four error paths (773, 864, 1232,
1239). With no usable `TERM`/TTY those block or fail. And `cleanup()` calls `clear`
unconditionally, which exits non-zero without a terminal — a successful install
reporting failure. *Fix:* headlessness is our wrapper's job: supply a TTY
(`script -qec`), pin `TERM`, assert on the tracker and `cmk`, never on the installer's
exit code. **Phase 1 is not CI-runnable**; the CD pipeline covers Terraform and Ansible.

**R4 · There is no reverse DNS anywhere in this lab, and Kerberos is the thing that
notices.** `network-plan.md` says it plainly: every row is a forward mapping, CoreDNS
serves no `in-addr.arpa` zone, and nothing answers a PTR query for any lab address.
That has cost nothing so far *because forward-only DNS is invisible until something
reverse-resolves and compares the answer to what it expected* — and AD is exactly that
something. Kerberos derives service principals from hostnames and reverse-resolves, so
**a missing PTR fails with an error naming the principal**, which sends the search into
Kerberos when the fault is in DNS. `14.0-1` lists this as obstacle 2 of 4 and it has
never been closed. *Fix:* reverse zones for every tier subnet, built in Phase 2 with
the forward zone, not bolted on when AD fails.

**R5 · AD wants to own DNS, and CoreDNS already does.**
Domain members discover controllers through `SRV` records — `_ldap._tcp.dc._msdcs`,
`_kerberos._udp`, `_kpasswd._udp` — and an AD DC normally runs DNS itself.
`14.0-1` names the choice: add the records by hand, or delegate a subdomain. Hand-written
`SRV` records in a CoreDNS zone file will drift from what `samba-tool` actually
registers, and the failure is a client that cannot find a KDC. *Fix:* delegate.
AD owns `ad.lab.test`; CoreDNS stub-forwards that zone to the DC and stays
authoritative for `lab.test`; the DC forwards everything else back to CoreDNS. **Guard
the loop** — two resolvers pointing at each other answer nothing and log nothing, which
is the same failure mode as forwarding to `127.0.0.53`.

**R6 · SSO makes identity a single point of failure for *all* access, including the
hypervisor.** Once Gitea, Grafana, MinIO, Vault, CloudStack and the tailnet all
authenticate through Keycloak, and Keycloak federates AD, then AD down means **no human
can log into anything** — including the console you would use to fix it. The source
design has no break-glass model. *Fix:* every service keeps a local administrative
account whose password lives in Vault, logged distinctly from SSO logins so its use is
visible; every VM keeps a local account; and the recovery order is written down before
it is needed. `3.1-3`'s rule applies — if the tier-1 credential list grows beyond the
unseal key and root token, something upstream is wrong, so break-glass passwords go in
Vault, not in a second file beside it.

**R7 · Headscale's database *is* the mesh.**
It holds every node, every key and the ACL state. Losing it does not degrade the
tailnet, it ends it — and re-registering every node by hand is the recovery. The source
design files backup under operations, which is too late. *Fix:* backup exists from the
step that creates it, not from Phase 12.

### Significant — cheap now, expensive later

**R8 · Tailscale defaults to a flat mesh, which is the opposite of transit.**
Every node reaching every node is the default. Two layers make "frontend reaches backend
only through the middle" airtight, and only one of them is configuration: default-deny
ACLs with no frontend→backend rule, **and keeping the backend off the tailnet entirely**
so no frontend→backend tunnel can exist to be permitted. *Fix:* backend VMs are not
tailnet nodes. Transit becomes structural rather than configured — an ACL is one edit
from being wrong, a peer that was never registered is not.

**R9 · SSSD caches credentials, so "we disabled the account" is not true by default.**
A user disabled in AD keeps logging into VMs from the SSSD cache until it expires. If
the joiner/mover/leaver story is the point of having AD, this is the mechanism that
decides whether it is real. *Fix:* set the cache and offline-credential lifetimes
deliberately, and make the leaver drill prove denial on a **live** host rather than
assuming it.

**R10 · The bootstrap order has five cycles and the source names one.**
"Secrets before Terraform" solves state. It does not solve: the CloudStack key going
*into* Vault before Vault exists; **MinIO's root credential needing to be generated in
Vault before MinIO exists** (the generate-before-the-service ordering is the whole
argument of `3.6-1` and `4.1-1`); MinIO's certificate coming from Vault's PKI; the
runner image baking the CA Vault mints; and anything touching Gitea's **API** needing
the proxy, which must itself start *after* Gitea. *Fix:* one published dependency order
with the break points named. **MinIO moves after Vault.**

**R11 · Revert verification by checklist is the design `T-4` rejected.**
Asserting absence — no packages, no zone, netplan byte-identical, bridges gone — *"passes
while missing everything nobody thought to list, which is precisely the failure mode a
teardown has."* The decided criterion is a loop: **snapshot → `up` → `down --yes` →
`up`**, green and matching. *Fix:* the loop is the exit criterion; the checklist becomes
diagnostics that explain a failure rather than constituting the pass.

**R12 · Teardown acts by default, which `T-1` rejected, and cannot report what it fails
to revert.** `T-1`: dry-run by default, `--yes` to act — *"a script that printed when you
wanted it to act costs one re-run; one that acted when you wanted it to print costs the
lab."* `T-2` requires every artifact sorted into reversible / reconstructable / shared /
unrecoverable **before** the line that removes it, the last two **reported, never
guessed**. The sharpest case: the inverse of *created the bridge netplan file* is **not**
*delete it* — do that and the host has no network configuration at all.

**R13 · The egress allow-list has no return-traffic rules, so it cannot work.**
CloudStack network ACLs are **stateless**: allowing outbound does not allow the reply.
Explicit return rules on ephemeral ports are required, and *"that single fact explains
most of the rule numbering."* Tailscale changes which ports, not the principle: UDP
**41641** for direct peers, TCP **443** to the control plane, STUN outbound, and a DERP
fallback path when NAT blocks direct. Prometheus additionally **scrapes**, so it needs
9100 **inbound** — the opposite direction from everything that pushes. Write the push
rules first; they go one direction and they work.

**R14 · The policy gate exists only on the CI path.**
Policy runs over `terraform plan -json` before apply in the pipeline, but the local
`setup` path runs plan→apply directly, bypassing it — while claiming both call the same
scripts. *Fix:* `setup` calls the same `policy` script and refuses to apply on a
violation.

**R15 · Role scoping is demanded before the consumer exists, which `1.2-2` argued must
wait.** *"Scoping the role before the consumer exists means guessing which APIs Terraform
calls; being wrong surfaces as a permission failure part-way through an apply."*
*Fix:* create the account early — that buys attribution and habit, not least privilege,
and should say so — and narrow the role once an apply log shows which APIs are called.
Use **`createAccount`, not `createUser`**: the role lives on the account, and so do
ownership and event-log attribution. `listall=true` is required to see another account's
users even as Root Admin.

**R16 · The root-SSH hole is opened and never closed.**
CloudStack adds the KVM host over SSH even when that host is itself, so root login with
a password gets enabled — and the source design's own exit criterion *asserts the hole is
open*. Nothing closes it. *Fix:* an explicit close step once the host is added, asserted
with **`sshd -T`**, not `sshd -t`: `-t` checks syntax only, and the **first** value wins
across drop-ins, so a lower-numbered file silently outranks ours.

**R17 · CloudStack 4.22 is named and is measurably broken.**
`1.3-4` has the measurements: **4.22 → apt exit 100** (signed `Release` declares
`Packages.bz2` at 5670 bytes, the CDN serves 6848), **4.21 → exit 0**, **4.20 → exit
100**. Not a transient sync — that `Release` was inconsistent for three months. And the
failure is **silent**, which is worse: the installer's error handling sits after the
failing command under `set -euo pipefail`, so it is unreachable. *"An error handler
placed after a failing command in a `set -e` script is decoration."* *Fix:* pin **4.21**
and write the apt list ourselves — the installer's silent path returns early when the
list file exists, so writing it is how you choose the version without patching upstream.

**R18 · Three address plans disagree, and the source contradicts itself.**
`network-plan.md` has **committed** `10.0.1.0/24` frontend, `10.0.2.0/24` tunnel,
`10.0.3.0/24` backend, checked against k3s's and Docker's auto-allocating ranges
("confirmed rather than assumed"). The source design uses `10.0.2.0/24` as an endpoint,
uses `10.0.3.0/24` as the hub in one section and the backend fifty lines later, and
introduces an overlay range that appears in no row and has been through no overlap
check. *Fix:* keep the committed plan. Frontend `10.0.1.0/24`, **transit** `10.0.2.0/24`
(already named "tunnel" and already sized as a routing tier), backend `10.0.3.0/24`.
Tailscale assigns its own `100.64.0.0/10` CGNAT range, which collides with nothing here
and replaces the overlay rows — amend the table rather than leaving two dead rows.

**R19 · Certificate and keytab renewal do not exist.**
The prior build worked around it by issuing an 8760h certificate for the thing
everything authenticates to, because *"renewal automation does not exist yet."* Adding
AD, Keycloak, Headscale and per-service OIDC multiplies the certificate count and adds a
**keytab** lifecycle. Unattended expiry on the identity plane locks everyone out of
everything. *Fix:* a renewal mechanism with a reload hook, and an expiry alert, both
before the certificate count grows.

**R20 · Entitlements will sprawl across six service configs.**
"Which AD group grants what" would otherwise live in Gitea's OIDC claim mapping,
Grafana's role attribute path, Vault's policy binding, MinIO's policy claim, the tailnet
ACL and sudoers — six places, drifting independently, with no way to answer "what can
this group do?" *Fix:* one versioned file is the source of truth for group → entitlement,
and every service's config is generated from it.

**R21 · Headscale's server-side ACL validation is weak.**
A malformed or over-permissive HuJSON policy can be accepted. *Fix:* validate in CI, and
add a policy rule asserting no frontend→backend grant exists — the one invariant the
whole segmentation story rests on.

**R22 · Tailscale deletes a lesson, and that should be named rather than hidden.**
Hand-rolled WireGuard taught `AllowedIPs` as simultaneously a routing table and an
inbound ACL, and the spoke/hub asymmetry that keeps spokes ignorant of each other.
Tailscale manages all of it. Per `0.2-8` — *build the half that carries the lesson and
state plainly which half is missing* — the transit, subnet-router and tag-ACL lessons
remain; the key-and-route mechanics go. Record it, and keep a one-step appendix that
builds the raw version once for comparison.

### Minor — carry into the steps so they survive

- **R23** `parallelism=1` belongs in **two** places: on the ACL rule resource *and* on
  the whole `apply`. "When a provider has a known race, belt and braces is the right
  instinct."
- **R24** One `cloudstack_port_forward` **per public IP**, every rule a `forward` block
  inside it — the resource's ID *is* the IP's ID and it owns that IP's whole rule set.
  Two resources on one IP race to own the same rules and each tears down an IP the other
  is also tearing down.
- **R25** **`terraform apply` returns when CloudStack marks a VM *Running*** — before the
  guest has booted and before the VR has programmed the port forward. A cloud API
  returning success does not mean the thing is usable; you will need
  `wait_for_connection`.
- **R26** **MTU.** Tailscale sets 1280 itself, which removes the common case, but an
  encapsulated path still gives you a network where `ping` works and TLS handshakes and
  git clones hang forever. Keep a large transfer in the exit check — ping and handshake
  are exactly the pair that passes under a broken MTU.
- **R27** A tracker must test **`== yes`**, not non-empty. The vendored one tests
  `[[ -n … ]]` (line 294), so `db_deployed=no` reads as *done* — two full installer runs
  were lost to this. To genuinely re-run a step you delete its line.
- **R28** `registerUserKeys` is **not a read** — it mints new keys and invalidates the
  old. `getUserKeys` is the read. Handle **four** states: absent + remote has one →
  capture; absent + none → generate; present + matches → done; **present + differs →
  refuse**, because CloudStack's admin account is recreated whenever its database is
  redeployed and every consumer then fails with an opaque 401.
- **R29** Time stops being hygiene and becomes a security dependency: Kerberos rejects
  tickets outside five minutes of skew, and the error says nothing about time. The DC is
  the authoritative source for domain members.
- **R30** Tailscale node keys are generated by `tailscaled` locally and only public keys
  reach the control plane — so the prior build's rule (*"an architecture that removes a
  secret entirely beats one that protects it well"*) is satisfied by default. Do not
  reintroduce it by seeding node keys into Vault.
- **R31** Make the IaC binary an indirection (`TF_BIN`). The source's own 2026 review
  recommends OpenTofu; a variable makes that one line instead of a sweep.
- **R32** Teardown enumerates by a **label** applied at create time
  (`lab=singlecluster`), never `docker rm -f $(docker ps -aq)`. Retrofitting is much
  harder than deciding it in Phase 0.
- **R33** Prove behaviour, not configuration: resolve a name rather than check a file;
  ask the registry what it holds rather than trust a push's exit code. And **capture, do
  not pipe, into `grep -q`** — grep exits on first match, the producer takes SIGPIPE,
  `pipefail` reports 141, and a successful match reads as a failure. It is a race on
  output length, so it passes on a quiet host.
- **R34** `json-file` is Docker's default log driver and has **no size limit**, on a disk
  shared with CloudStack's storage. Per-container `log-opts` everywhere, and CI deletes
  its built images with `if: always()`.
- **R35** The DC is a Terraform-created VM that every other VM depends on for login, so
  **teardown order and bring-up order are both constrained by it** — and a second `up`
  must either re-provision the domain or restore it. Decide which; they are different
  scripts.

---

## Decisions taken (reject any on review)

| # | Decision | Why |
|---|---|---|
| D1 | **Samba AD DC**, on its own VM | `14.0-1` rules out FreeIPA: it does not package for Ubuntu and would need a RHEL-family guest. Samba *does* run here and speaks AD's own protocols — LDAP, Kerberos KDC, DNS, SYSVOL — at under 1 GB. A DC on the hypervisor is not how anyone deploys one, so it gets a VM. Windows Server is the real-world answer and a documented swap; the licensing is the only reason it is not the default. |
| D2 | **AD owns `ad.lab.test`; CoreDNS stays authoritative for `lab.test`** | R5. Delegation beats hand-written `SRV` records that drift from what `samba-tool` registers. |
| D3 | **Reverse zones built in Phase 2**, with the forward zone | R4. Not when Kerberos fails. |
| D4 | **Keycloak for application SSO**, LDAP-federating AD read-only | `14.0-1`: Keycloak is not a directory. AD is the source of truth; Keycloak brokers it to OIDC clients. One-way, so there is one place a user is disabled. |
| D5 | **Headscale**, not Tailscale SaaS | Keeps the control plane local, and the lab must be runnable on a fresh VM with no external account. Costs: no official web console, and weak server-side ACL linting (R21). |
| D6 | **Backend VMs are not tailnet nodes** | R8. Transit becomes structural rather than configured. |
| D7 | **Vault SSH CA for access; AD/SSSD for identity and sudo** | Short-lived signed certificates mean no `authorized_keys` to distribute or revoke, and principals come from AD groups. Kerberos GSSAPI is the alternative and gets an ADR, not an implementation. |
| D8 | **Three identity planes never cross** | Humans → OIDC. Machines → AppRole/JWT. Hosts → Kerberos. |
| D9 | **Break-glass per service, local, password in Vault, logged distinctly** | R6. |
| D10 | **Keep Vault**, not OpenBao | OpenBao's differentiator is free namespaces; a single-tenant lab uses none. |
| D11 | **Terraform behind `TF_BIN`** | R31. |
| D12 | **Trivy, not tfsec** | tfsec is folding into Trivy; `trivy config` covers the IaC and `trivy image` the qcow2. One tool, two gates. |
| D13 | **MinIO stays, after Vault** | Needed for the image registry and the `s3` backend. Ordering per R10. |
| D14 | **CloudStack 4.21** | R17, measured. |
| D15 | **Committed address plan wins** | R18. |
| D16 | **No Kubernetes** | Not in scope. The identity and overlay work is the subject. |

---

## Dependency order

```
netplan snapshot + restore ──► CloudStack ──► CoreDNS (fwd + reverse) ──► Vault ──► Vault PKI
  (R2: before the installer,                                                           │
   or `down` is impossible)         ┌──────────────┬──────────────┬───────────────┬─────┴────────┐
                                    ▼              ▼              ▼               ▼              ▼
                                MinIO creds    MinIO cert    Gitea creds     lab CA for      Keycloak
                                generated in   (R10)         generated in    the toolbox     cert
                                Vault (R10)                  Vault           image
                                    └──────┬───────┘              │               │
                                           ▼                      ▼               ▼
                                        MinIO            Gitea ──► PROXY ──► toolbox ──► runner
                                                            ▲        │
                                                            └────────┘  the cycle break (R10):
                                                     the proxy starts AFTER Gitea — it joins
                                                     Gitea's network and resolves a container
                                                     name at startup — but BEFORE anything calls
                                                     Gitea's API, because Gitea publishes no
                                                     ports. Exactly one point satisfies both.
                                           │
   CloudStack `iac` account (Ph 1) ──► key captured into Vault ──► Packer ──► template
                                           │
                                           ▼
                                      Terraform ──► mgmt + identity tier ──► DC VM
                                           │                                   │
                                           │                     ┌─────────────┴─────────────┐
                                           │                     ▼                           ▼
                                           │              AD provisioned            CoreDNS delegates
                                           │              (realm, OUs, groups)      ad.lab.test (R5)
                                           │                     │
                                           │                     ├──► domain join + SSSD (all VMs)
                                           │                     ├──► Keycloak LDAP federation ──► OIDC clients
                                           │                     └──► Vault OIDC + SSH CA
                                           ▼                              │
                                      data tiers + ACLs ──► Headscale ◄───┘ (OIDC: joining the
                                                               │            tailnet is an AD decision)
                                                               ▼
                                                      tags · ACLs · subnet router
```

Five rules this encodes: **Vault's PKI precedes every certificate**; **every generated
credential is created in Vault before its service exists**; **the proxy sits between
Gitea's start and Gitea's API**; **AD precedes every identity consumer**; and **the
tailnet is joined with an AD identity, so Headscale comes after Keycloak.**

---

## Target layout

```
bootstrap.sh              subcommand dispatch; the local path, mirroring CI
lib/                      lib.sh — log/die, transcript, tracker, netplan, vault helpers
cloudstack/               our wrapper + the re-vendored installer (excluded from lint)
docker/                   coredns/ vault/ minio/ gitea/ proxy/ toolbox/ keycloak/ headscale/
packer/                   qemu template, autoinstall, cloud-init, hardening, scan
terraform/                provider+backend, vpc, tiers+ACLs, mgmt+identity nets, VMs, outputs
policy/                   OPA/Conftest over the plan JSON, and over the tailnet ACL
identity/                 entitlements.yml — the single group→entitlement map (R20)
ansible/                  inventory, base, samba-dc, domain-join, tailscale roles
tests/                    lint, gitignore assertions, verify/demo harness
.gitea/workflows/         ci.yml · cd.yml
docs/adr/                 one file per decision · runbook.md
state/                    tracker, generated inventory — gitignored
```

---

## Phases and steps

**70 steps, 14 phases.** Each is one working session with one exit check, and a step is
done when the check **exits zero**, not when it prints something plausible. `[core]` is
the JQR demo; `[ent]` is hardening layered on.

Two structural choices keep the count down. **The tailnet is built once, at Phase 7, with
pre-auth keys** — it does not wait for AD or Keycloak, so `demo` passes before the
identity work starts, and identity-based join is added at 9.4 as one additive step rather
than a rebuild. **There is no raw-WireGuard version**; what Tailscale hides is recorded in
an ADR instead of built for comparison (R22).

### Phase 0 · Scaffolding

- **0.0** Remove the prior attempt from the root: `bootstrap.sh`, `lib/common.sh`,
  `cloudstack/`, `services/`. History preserves them; `reference/` stays as the explicitly
  frozen prior lab. **Blocked on committing the uncommitted work in
  `services/vault/scripts/`, which exists only in the working tree.**
  *Exit:* the root holds only files this plan created; `git show` still retrieves the old.
- **0.1 ✅** `.gitignore` with the three-bucket rule, plus `.editorconfig`,
  `.shellcheckrc`, `.yamllint`, `.trivyignore`. Checked by `tests/gitignore-assert.sh` in
  **both** directions — paths that must be ignored (none of which exist yet, which is the
  point) and paths that must stay committable, because a rule too broad silently drops the
  provider lock file and the templates, and that surfaces on someone else's machine weeks
  later. *Exit:* 34 ignored, 12 committable. **Passing.**
- **0.2 ✅** `lib/lib.sh`: output whose `die` names the likely cause, guards, an apt
  lock-wait wrapper, host facts discovered rather than declared — `host_ip`/`gateway_ip`
  scan `ip route get` for the `src`/`via` keywords rather than field positions, since
  `via` appears only when the target is off-link. *Exit:* both resolve, double-sourcing is
  a no-op, both execute-guards fire. **Passing.**
- **0.3** Finish `lib.sh`: the transcript and the tracker.
  The transcript has four traps already paid for — one `exec` redirect in `main()`
  **after** `verify_root` (at file scope a non-root run dies on a permission error instead
  of the readable message), so children inherit the descriptor and the 2,704-line vendored
  installer is captured for free; terminal saved on **fd 3**; ANSI stripped on the **file**
  branch only, because after the `exec` stdout is a pipe and making `log()` conditional on
  `[[ -t 1 ]]` would drop colour from the terminal too; wait on the writer in an `EXIT`
  trap or a `die` truncates the log; timestamp with bash's `printf '%(…)T'`, **not** `ts`
  (absent) and **not** `awk`'s `strftime` (a gawk extension — a fresh Ubuntu is mawk, so
  it would fail only on the machine it was written to serve). `set -x` is **no**: the
  installer runs `cloudstack-setup-databases cloud:cloud@localhost` and trace would put
  that credential in a file permanently. The tracker's `is_done` tests **`== yes`** (R27).
  *Exit:* a `die` mid-run still produces a complete, timestamped, ANSI-free log, the
  terminal keeps colour, newest 20 retained; and a harness proves `key=no` and a deleted
  line both read not-done while `key=yes` reads done.
- **0.4** `bootstrap.sh` dispatch — `up down platform provision image template tailnet
  identity sso lint scan policy setup verify demo status`, all stubs, with `usage()` and
  up-front `[[ -x ]]` resolution of every sub-installer — plus the `lab=singlecluster`
  label and `log-opts` conventions (R32, R34) and their ADRs, applied from the first
  compose file written.
  *Exit:* bare invocation prints usage, every subcommand reaches a stub and exits 0, and a
  grep proves the label and log-opts conventions are documented before anything uses them.

### Phase 1 · Host, CloudStack, reversibility

- **1.1 [core]** `netplan_backup()` **and** `restore_netplan()` together (R2):
  whole-directory `cp -a` plus `libvirtd.conf` and the four `/etc/default` files, to
  `/var/backups/` outside the repo, guarded on the **directory**, tracked. Restore uses
  `netplan try`. A restore path must not depend on the thing it restores — no container,
  no name resolution.
  *Exit:* byte-identical backup; a dry-run restore prints exactly what it would change;
  re-running is a no-op. **Nothing else in Phase 1 runs until this passes.**
- **1.2 [core]** Host prep: root guard, `verify_kvm` (fails fast, fixes nothing),
  **clock before apt** — a skewed clock fails `apt-get update` with "Release file is not
  valid yet", which reads like a network fault, and `timedatectl` has a window where
  `NTPSynchronized` is not yet true — CLI tools, Docker from its own deb822 repo.
  *Exit:* `docker run hello-world` works and `docker compose version` answers (a binary on
  `PATH` proves neither a running daemon nor a compose plugin); second run changes nothing.
- **1.3 [core]** KVM host prep and the resolver floor. The SSH drop-in asserted with
  **`sshd -T`**, not `sshd -t`: `-t` checks syntax only, and the **first** value wins
  across drop-ins, so a lower-numbered file silently outranks ours (R16).
  Bridge-netfilter disabled and verified — with it on, iptables sees bridged frames and VPC
  port forwards drop them **silently**. Then the floor: `netplan apply` moves the NIC into
  the bridge, sets `dhcp4: false` (taking the DHCP nameserver with it) and returns when
  networkd *accepts* the config, not when it has converged, and the installer's next act is
  to `curl` the signing key. Measured: netplan at `09:53:07.975`, curl failing in the same
  second. Two errors, one cause — `curl (6) Could not resolve host` then `gpg: no valid
  OpenPGP data found` — and reading them as independent sends you hunting a keyserver
  problem that does not exist. Consistently curl **6**, never 7, so it is resolution
  lagging, not routing; a `wait-online` loop aims at the wrong layer.
  *Exit:* `sshd -T` shows root and password login, all three `bridge-nf-call-*` read 0, and
  `download.cloudstack.org` resolves **during** the rebuild window — proved by resolving,
  not by checking a file exists (R33).
- **1.4 [core]** Re-vendor the installer unmodified; write the apt list and keyring
  ourselves pinned to **4.21** (R17) and prove the component yields an installable package
  before the 40-minute run. Exclude the vendored file from lint with a guard that **errors
  if the path moves**, since an exclusion matching nothing looks exactly like none. Note the
  near miss: a failed run once left a 0-byte keyring because `tee` created the file before
  the step failed — *a failing step that writes a file before it fails is not idempotent,
  merely lucky.*
  *Exit:* `apt-cache policy cloudstack-management` shows a 4.21 candidate; lint skips the
  vendored file and fails loudly if its path changed.
- **1.5 [core]** The headless wrapper (R3) and the read-back. Supply a TTY (`script -qec`),
  pin `TERM`, and assert on the tracker and `cmk` rather than the installer's exit code.
  Then verify what it built: `cmk` configured as root with one profile — it resolves config
  from `$HOME` with no per-invocation override, and a profile nothing else reads produces
  **no error**, it simply behaves as though never configured — zone enabled, system VMs
  running, bridge holding the host's now-static address.
  *Exit:* the install completes and reports success under `TERM=dumb` with no controlling
  terminal; one Enabled Advanced zone; both system VMs `Running`; re-running reports every
  step done.
- **1.6 [core]** Close the SSH hole (R16) and create the `iac` account via
  **`createAccount`** — the role lives on the account, and so do ownership and event-log
  attribution; `listall=true` is required to see another account's users even as Root
  Admin. Root Admin for now, narrowed at 5.7, and saying so: this buys attribution and
  habit, not least privilege (R15).
  *Exit:* `sshd -T` shows `permitrootlogin no`, CloudStack still reports the host `Up`, and
  the account shows as distinct from `admin`.
- **1.7 [core]** Offerings, create-if-absent: compute, VPC, VPC tier network with
  **ConfigDrive** userdata — pin cloud-init's datasource list to `[ConfigDrive, None]`
  rather than leaving CloudStack's datasource in play, because being explicit about where a
  machine gets its identity avoids a whole class of first-boot mystery — plus mgmt and
  identity shared-network offerings.
  *Exit:* `cmk list …offerings` shows all five.

### Phase 2 · Names and trust

- **2.1 [core]** CoreDNS with **forward and reverse** zones generated from one service list
  (R4/D3). Publish **UDP and TCP** — Docker publishes TCP by default and DNS is UDP, so a
  bare `53:53` looks completely dead, and TCP is needed above 512 bytes anyway — bound to
  the bridge address, not `0.0.0.0`, which collides with `systemd-resolved` on
  `127.0.0.53` and makes you an open resolver for anything that can route to you.
  `in-addr.arpa` zones come from the same source as the forward records so they cannot
  disagree. Serial advances on every render. `envsubst` gets an **explicit allow-list** or
  it eats `$ORIGIN` and `$TTL`, which are directives, not variables; a name without a
  trailing dot silently becomes `ns.lab.test.lab.test`.
  *Exit:* `dig` and `dig -x` both answer for every lab address — **both directions, one
  generated source** — public names still resolve, and rendering twice yields a higher
  serial.
- **2.2 [core]** Point the host's resolver at CoreDNS and **delete** the 1.3 floor rather
  than writing a higher-numbered file — `DNS=` **accumulates** across drop-ins, both
  answer, and lab names fail intermittently. `Domains=~lab.test`: the `~` routes only that
  domain; without it a lab VM is the resolver for your whole machine. Never forward to
  `127.0.0.53` — that is the resolver you are about to point here, and the loop answers
  nothing and logs nothing.
  *Exit:* one lab DNS entry; lab and public names both resolve across 20 consecutive
  queries with no intermittent failure.
- **2.3 [core]** Vault up: compose, `vault.hcl`, bind mounts owned **before** the container
  starts (Docker creates a missing source as root; fixing it after is a repair and a race),
  a uid pinned high enough that no Ubuntu package can claim it — 100–999 goes to whichever
  package installs first, so the image's default means a different daemon on every machine,
  and that daemon could read Vault's key. A self-signed bootstrap certificate breaks the
  "Vault needs a cert / Vault issues certs" circularity. The image's default command is
  **`server -dev`**: in memory, self-unsealing, indistinguishable from success until a
  restart loses everything. `address` is where it binds, `api_addr` what it advertises —
  wrong second value and it works while sending clients nowhere.
  *Exit:* HTTPS answers `503` with the expected certificate; the pinned uid and non-dev
  command visible in `docker inspect`.
- **2.4 [core]** Init, unseal, audit, and the standalone unseal script. Guard against
  **four** states: cross-check Vault's health against whether the key file exists, because
  an emptied data directory reports "uninitialised" exactly like a fresh one and
  re-initialising there abandons real data. `operator init` happens once, ever. The unseal
  key and root token are the only credentials that cannot live in Vault, and they go in
  **separate files**, because in one file every rotation rewrites the thing that is
  irreplaceable. Vault **stops serving** if it cannot write its audit log, which makes that
  mount load-bearing in a way the data directory is not. The standalone script is the
  load-bearing half: seal is not stop — a restarted Vault is running, listening and
  answering everything `503`, so `docker ps` says healthy and the first symptom is some
  other service failing to read a secret. It must be a no-op when unsealed, work after a
  reboot without re-running an installer that would also `operator init`, and be the same
  command in a drill as in normal operation. Ask Vault, not Docker.
  *Exit:* unsealed, audit log growing, a restart leaves it sealed, and with everything else
  absent the standalone script recovers it and is a clean no-op on a second run.
- **2.5 [core]** The PKI and the second pass. One self-signed root, honest about being one
  tier — two tiers in the same Vault is the shape without the property, since a two-tier
  PKI exists so the root can be **offline**. Issuing and CRL URLs. **Two roles**, because
  one TTL does not fit both a service leaf and the certificate on the thing everything
  authenticates to. Then Vault reissues its own certificate from its own PKI and restarts,
  both halves guarded on the issuer CN so a re-run neither regenerates the bootstrap cert
  nor reissues every time. Serve **leaf plus chain**, verify against the **CA alone** — two
  files, two jobs; a bare leaf works in a browser that cached the issuer and fails in
  `curl` on a clean machine.
  *Exit:* a role refuses a name outside the lab domain, both roles issue, and `vault status`
  works over HTTPS with **no `-k`** from a clean trust store.
- **2.6 [ent]** Certificate renewal (R19): a renew-and-reload mechanism, since a reissued
  certificate otherwise sits on disk ignored, plus an expiry alert. Built now, before the
  certificate count grows through Keycloak, Headscale and per-service OIDC — and before
  keytabs add a second lifecycle.
  *Exit:* a certificate inside its renewal window is reissued and the consumer picks it up
  with no manual restart; forcing near-expiry fires the alert.

### Phase 3 · Control plane

- **3.1 [core]** KV v2, policies, the AppRole machines authenticate with, and the seeding
  pattern. v1 and v2 both report type `kv`; only the option tells them apart, and the read
  paths differ. Each secret is sorted by **direction** first: **generated** (Vault is the
  origin, created before the service) or **captured** (the service minted it and will show
  it again). Both `ensure`-shaped — create if absent, leave alone if present, **never
  rotate silently**. Usernames are not generated: a username is an identity, not a secret.
  Break-glass passwords land here (D9).
  *Exit:* `vault kv get` returns a seeded value **via AppRole**, not the root token; an ADR
  records the direction of every secret; re-running changes nothing.
- **3.2 [core]** Capture the CloudStack `iac` key (R28). **`getUserKeys` to read, never
  `registerUserKeys`** — that one mints new keys and invalidates the old. Four states, one
  refusal: absent + remote has one → capture; absent + none → generate; present + matches →
  done; **present + differs → refuse**, because CloudStack's admin account is recreated
  whenever its database is redeployed and every consumer then fails with an opaque 401.
  Write Vault before CloudStack always, or a failed Vault write loses the credential.
  *Exit:* the key reads back via AppRole and authenticates; a deliberately mismatched stored
  key makes the script **refuse** rather than overwrite.
- **3.3 [ent]** MinIO and its provisioning (R10): root credential **generated in Vault
  first**, certificate from Vault's PKI, buckets `images` and `terraform-state`, versioning
  on state, one policy and one scoped service account per bucket — root keys never leave
  the host. Two traps: the cert filenames are mandated and wrong names fall back to
  self-signed **silently**; and `mc` reads `~/.mc/certs/CAs/`, not the system bundle. Then
  the anonymous-read prefix for template fetch, with the cost stated rather than discovered:
  CloudStack's SSVM fetches a template URL with **no credentials**, so a private bucket puts
  the credential in the URL and thence into CloudStack's database and logs. Anonymous read
  means **the VM images are readable by anything on the lab network** — accept it
  deliberately or authenticate the SSVM, but decide.
  *Exit:* `mc` round-trips in both buckets with no `-k`; each account is **denied** on the
  other's bucket; an anonymous `GET` of an image succeeds and a `PUT` fails.
- **3.4 [core]** Gitea and its database, credentials **generated in Vault before Gitea
  exists** so nobody ever chooses a password. No published ports. No defaults — only
  `${VAR:?}`, which fails loudly if `.env` was never rendered, because a default password in
  a repository is a password in the repository. `ROOT_URL` is `https://` only because the
  proxy genuinely terminates TLS: an `https` ROOT_URL marks cookies `Secure` and an HTTP
  login silently loops. Docker socket GID from `stat` on the socket, not `getent group`.
  The admin user is create-if-missing, not ensure-matches — Gitea will not read a password
  back after creation.
  *Exit:* Gitea answers on its container network and is unreachable from the host by port.
- **3.5 [core]** The proxy: TLS terminated once at the edge, routing by Host header,
  certificates from Vault. nginx **silently promotes the first `server` block to the
  default** — measured in the prior build, every lab name returned CloudStack's app with
  CloudStack's certificate — so an explicit default server with **`ssl_reject_handshake
  on`** makes unknown names fail to *connect* rather than fail to *validate*. Reissue then
  **reload**: nginx reads config once at start and `compose up -d` leaves a running
  container alone, so a fresh certificate sits on disk, visible inside the container,
  ignored — hit twice. `envsubst` gets an allow-list or it eats nginx's own `$host`. Raise
  `proxy_read_timeout`: the 60s default is shorter than Vault's blocking queries. Note what
  terminating costs — the proxy sees every token and is one `log_format` change from storing
  them, so its access log format is not cosmetic.
  *Exit:* every lab name loads over HTTPS with **no `-k`**; an unknown name fails to connect
  (curl 35), not to validate.
- **3.6 [core]** The Gitea API token and the repo push — and this step is *why* 3.5 precedes
  it (R10). Tokens cannot be read back, so guard on whether the stored one still
  **authenticates**, not on whether it exists; delete the stale named token first. **Scope
  it to the job**, not `all`: a registry push needs package write, not administrative
  control of your source of truth. Push with the credential in `http.extraHeader` — not in
  the remote URL, which lands in `.git/config` and survives every clone, and not on a
  command line, visible in `ps` to every user on the host. `set-url` rather than add, so a
  URL that once held a credential is corrected. Run git as the repository's **owner**, or
  `.git/` fills with root-owned objects. **Only committed history pushes** — obvious until
  the twenty minutes spent wondering why a fix visible in your editor had no effect.
  *Exit:* the token authenticates and re-running replaces a revoked one with no manual step;
  the remote has the current `HEAD`; `.git/config` holds no credential.
- **3.7 [core]** The toolbox image: every version pinned in an `ARG`, every download
  checksummed, each tool carrying a comment naming the pipeline that needs it — what stops
  the image accumulating things nobody can justify. No `apt-get install` at run time. Bake
  the lab CA. Include the gate tools from the start — shellcheck, shfmt, yamllint,
  ansible-lint, tflint, conftest, trivy, syft, cosign — plus the Tailscale and `samba-tool`
  clients the later phases need. Two gaps recorded rather than solved: it is the image every
  job runs in, so it **cannot be built by a job**, and therefore the scan-before-push gate
  never applies to it; and a local tag is mutable with no digest to cite.
  *Exit:* every tool reports its version inside the image with no runtime download, and the
  CA filename the runner config references **is** the one the Dockerfile writes.
- **3.8 [core]** Register the runner: `container.docker_host: "-"` so the host socket is
  never mounted into job containers, a dind sidecar on an isolated network reached by
  `DOCKER_HOST`, `--device /dev/kvm` for Packer, and `force_pull: false` — an unqualified
  `toolbox:latest` with `force_pull: true` resolves to `docker.io/library/toolbox` and goes
  to Docker Hub. The residual is named in an ADR: **the runner process itself holds host
  root**, because mounting the host socket is what starts jobs, and rootless dind does not
  work here — Ubuntu 24.04 ships `kernel.apparmor_restrict_unprivileged_userns=1`, which
  blocks the namespace RootlessKit needs and loops on `fork/exec /proc/self/exe: operation
  not permitted`. `privileged: true` does not help; disabling the sysctl host-wide was
  rejected. The real fix is **rootless BuildKit** so nothing needs a daemon.
  *Exit:* a smoke workflow asserts the host socket is **absent**, no lab container is
  visible from a job, `/dev/kvm` **opens** (not merely exists), and Gitea is reachable while
  its database is not.

### Phase 4 · Golden image

- **4.1 [core]** Packer `qemu` + Ubuntu 24.04 autoinstall → bootable qcow2 with cloud-init,
  qemu-guest-agent, openssh-server, python3, and the identity and overlay clients baked but
  **inert**: SSSD, `realmd`, `adcli`, `krb5-user`, chrony, Tailscale. Install only — no
  configuration and no keys, because an image is not a secret store and a baked node key
  would be a credential copied to every VM. **Fix the disk in the autoinstall storage
  layout**: subiquity's default LVM gives a root LV well below the disk with the rest of the
  VG unallocated and nothing growing into it. Correcting it here means the image is born
  right, and deletes a playbook from Phase 6 instead of inheriting one.
  *Exit:* `packer validate` passes; the image boots, shows a root filesystem matching its
  disk size, and has joined nothing and registered nowhere.
- **4.2 [ent]** Harden, validate, scan, sign — in that order, all before publish so a
  failing gate leaves nothing behind. CIS-style hardening, then **OpenSCAP validation**
  against the profile, because applying controls and proving they applied are different jobs
  and only the second produces a report. Trivy gate on HIGH/CRITICAL, Syft SBOM, cosign
  signature.
  *Exit:* the SCAP report shows the profile's result, the Trivy gate passes, the SBOM is
  emitted, `cosign verify` succeeds, and a deliberately vulnerable package fails the build
  before anything is published. Record that nothing yet *verifies* the signature at point of
  use — signing without verification is decoration, and this is the half that exists.
- **4.3 [core]** Version, publish, register: tag by content hash, `latest` pointer, **skip
  build and publish when the hash is unchanged**, then register the template by URL and poll
  `isready`, idempotent by name+version.
  *Exit:* a versioned object in MinIO, a second run with no input change skips both, and the
  template is ready without a duplicate.
- **4.4 [ent]** The build in CI — the hardest thing this pipeline does, nested virtualization
  inside a job container. `PACKER_LOG=1` plus a grep for qemu/kvm lines on failure is the
  difference between a debuggable failure and "Qemu failed to start". Delete built images
  with `if: always()` (R34).
  *Exit:* it runs on the runner and the workspace is clean afterwards even on failure.

### Phase 5 · Terraform

- **5.1 [core]** Provider, inputs, the **`s3` backend** on MinIO with a lockfile, and the
  state-model drill. Settle the backend **before** the first apply — migrating state is a
  real operation and there is no reason to perform it on a lab you could have configured
  correctly. A backend block **cannot interpolate**, so endpoint and credentials arrive as
  `AWS_*` environment variables, which is exactly why they come out of Vault as env vars.
  `TF_BIN` lands here (R31). Then apply a config creating nothing but a random value, delete
  `.terraform`, and re-init from the backend: the backend, not your machine, is the source
  of truth.
  *Exit:* `init` and `validate` succeed, a state object appears, a fresh `init` on a cleaned
  checkout produces an **empty** plan, two concurrent applies leave the second blocked by
  the lock, and no credential is on disk, in `state/`, or in shell history.
- **5.2 [core]** All the networks: VPC, mgmt/bastion, the **identity** network for the DC,
  and the three data tiers — frontend `10.0.1.0/24`, transit `10.0.2.0/24`, backend
  `10.0.3.0/24` (R18/D15). Note what the installer owns (zone, pod, cluster, host) versus
  what code owns; offerings sit across that line, which is why ensuring them with a script
  invoked from Terraform is an honest workaround rather than a smell. Record the risk that a
  network on the bridge draws from the `.11–.50` range CloudStack claimed by **liveness
  probe rather than reservation** — anything of ours that is stopped when the installer runs
  can have its address taken.
  *Exit:* `cmk list networks` shows all six with the committed CIDRs; a re-plan is empty.
- **5.3 [core]** The ACLs (R13): **frontend↔backend denied outright**, frontend↔transit and
  transit↔backend permitted, Tailscale's UDP **41641** and TCP **443** to the control plane
  on the overlay legs, SSH from mgmt, AD's ports from every tier to the identity network
  (Kerberos 88, LDAP 389/636, DNS 53, kpasswd 464, and the ephemeral range AD actually
  uses), default-deny egress **with explicit return-traffic rules on ephemeral ports**
  because these ACLs are **stateless**, and 9100 inbound for the scrape.
  `parallelism=1` **twice** — on the rule resource *and* on the whole apply (R23).
  *Exit:* the rule sets match intent rule-for-rule; three consecutive applies are clean with
  no intermittent ordering failure.
- **5.4 [core]** Compute: ConfigDrive userdata, the DC on the identity network, tier VMs each
  multihomed with a mgmt NIC. No `authorized_keys` material — access comes from the Vault
  SSH CA at 9.3, so the only bootstrap credential is the local break-glass account.
  *Exit:* every VM `Running` and reachable on mgmt, **and a direct frontend→backend probe
  FAILS**. Isolation is proven here, before any overlay exists.
- **5.5 [core]** Public IPs and NAT: **one `cloudstack_port_forward` per public IP**, every
  rule a `forward` block inside it (R24) — the resource's ID *is* the IP's ID and it owns
  that IP's whole rule set, so two resources on one IP race to own the same rules and each
  tears down an IP the other is also tearing down. And `wait_for_connection`, because apply
  returns when CloudStack marks a VM *Running* — before the guest has booted and before the
  VR has programmed the forward (R25). If a forward is configured and nothing arrives, check
  `bridge-nf-call-iptables` **first**.
  *Exit:* the forwards work, and destroying just that resource is clean — no two resources
  printing the same ID.
- **5.6 [core]** Outputs → `state/`: addresses, the generated Ansible inventory, and the
  dynamic half of **both** DNS zones, so forward and reverse records come from the same
  outputs and cannot disagree (R4).
  *Exit:* `dig` and `dig -x` both answer for a Terraform-created host with no hand editing,
  and nothing carries a typed-in address.
- **5.7 [ent]** Narrow the `iac` role (R15) now that an apply log shows which APIs are
  called.
  *Exit:* `iac` completes a full apply **and is denied** a named global-admin operation.
  Both halves, or the step is not done.

### Phase 6 · Ansible and the base estate

- **6.1 [core]** Inventory from Terraform state, and **three guards**, in this order: refuse
  to start when the **platform** is unhealthy (one `cmk list hosts` check — a host in
  `Alert` explains every downstream failure at once and makes the rest of the search
  pointless; without it a disconnected agent once surfaced as a name-resolution error thirty
  tasks deep and sent an hour of diagnosis into the guests' resolvers); fail loudly when
  state contains **no hosts**, because an empty inventory exits 0 and matches nothing, so
  every step below passes having done nothing — *a pipeline that succeeds while doing
  nothing is worse than one that fails, because you will believe it*; and wait for SSH
  rather than assuming it.
  *Exit:* each guard fails for the right reason when its condition is forced.
- **6.2 [core]** The base role: the lab CA in every trust store, resolver pointed at
  CoreDNS, baseline hardening, chrony, and an **egress preflight** that curls from each tier
  so a broken source-NAT fails as "no egress" rather than as a confusing installer error
  twenty steps later. Time is set up here but becomes a *security* dependency at 8.2.
  *Exit:* a second run reports `changed=0` on every host, the preflight passes, and a VM
  validates a lab certificate with no `-k`.
- **6.3 [ent]** Patch management: unattended-upgrades configured, with upgradable-package
  counts exported as a metric rather than a mailed report nobody reads.
  *Exit:* the metric appears for every VM and increments when a package is held back.

### Phase 7 · The tailnet — *built once, no identity dependency*

- **7.1 [core]** Headscale and its database on the host, certificate from Vault, a name, a
  proxy vhost — **and its backup in the same step** (R7), because that database holds every
  node, key and ACL, and losing it ends the mesh rather than degrading it: every node
  re-registers by hand.
  *Exit:* `headscale nodes list` answers over TLS, and a backup restores into a working
  control plane.
- **7.2 [core]** Tags, HuJSON ACLs versioned in git, node registration, and the subnet
  router — the whole data path in one step, because the pieces are meaningless apart.
  Default-deny with `tagOwners` and `autoApprovers` for the transit route, and **no
  frontend→backend rule, ever**. **Ephemeral, tagged pre-auth keys** in ConfigDrive userdata
  for the frontend, persistent for transit; node keys are generated by `tailscaled` locally
  and only public keys leave, so do not seed any into Vault (R30). The transit tier
  advertises the backend CIDR with `ip_forward` on, and **backend VMs are not tailnet
  nodes** (D6/R8) — which is what makes transit structural rather than configured: Tailscale
  defaults to a flat mesh, an ACL is one edit from being wrong, and a peer that was never
  registered is not.
  *Exit:* the frontend reaches a backend address through the transit; `tailscale status` on
  the frontend lists **no backend peer**; the backend runs no `tailscaled`; destroying a
  frontend VM removes it from `headscale nodes list` with no manual prune; and applying the
  ACL file twice is idempotent.
- **7.3 [core]** `verify` and `demo`: direct CloudStack path BLOCKED, tailnet path CONNECTED
  through the transit, the working route on the Tailscale interface, a disallowed egress
  destination blocked — and a **large transfer**, because ping and handshake are exactly the
  pair that passes under a broken MTU (R26). Tailscale sets 1280 itself, which removes the
  common case but not the failure mode.
  *Exit:* both verdicts print, a large file transfers without stalling, and stopping
  `tailscaled` on the transit breaks frontend→backend and nothing else. **This is the JQR
  191 claim, and it passes here — before any identity work.**

### Phase 8 · Active Directory — *the host identity plane*

- **8.1 [core]** The DNS delegation (R5/D2) before the DC exists, so it provisions into a
  zone that already routes: CoreDNS stub-forwards `ad.lab.test` to the identity network
  address and stays authoritative for `lab.test`; the DC forwards everything else back; and
  **the loop is guarded** — two resolvers pointing at each other answer nothing and log
  nothing, the same failure mode as forwarding to `127.0.0.53`. Delegation beats hand-written
  `SRV` records, which drift from what `samba-tool` actually registers and fail as a client
  that cannot find a KDC.
  *Exit:* from a tier VM and from the DC, both a public name and a lab name resolve; a
  deliberately broken forward is detected rather than hanging.
- **8.2 [core]** Samba AD DC provisioning (D1), idempotent, and time as a **security**
  dependency. `samba-tool domain provision` is a once-ever operation like `operator init`,
  so it needs the same four-state guard — a half-provisioned DC must not be re-provisioned
  over. Kerberos rejects tickets outside five minutes of skew and **the error says nothing
  about time**, so the DC becomes the authoritative source for domain members (R29).
  *Exit:* `samba-tool domain level show` reports the realm, `kinit` succeeds for the domain
  administrator, the `SRV` records a client uses to find a KDC resolve — including
  `_ldap._tcp.dc._msdcs` — `chronyc sources` on a member shows the DC, and deliberately
  skewing a member by ten minutes breaks `kinit` while fixing it restores it, so the symptom
  is one you have seen before it matters.
- **8.3 [core]** `identity/entitlements.yml` (R20): the **single** source of truth mapping AD
  groups to sudo rights, Gitea orgs, Grafana roles, Vault policies, MinIO policies,
  CloudStack roles and tailnet tags. Then the OU and group structure created from it, with
  seeded users, and **service accounts kept separate from humans** — a service account that
  can log into a workstation is the thing this separation exists to prevent.
  *Exit:* the file is the only place a group→entitlement mapping is written, applying it is
  idempotent, and a group added to the file appears in AD on the next run with no other edit.
- **8.4 [core]** Domain join and SSSD on every VM: `realm join`, the AD provider, sudo rules
  from AD groups, home directories, and **the cache lifetimes set deliberately** (R9) — a
  user disabled in AD keeps logging in from the SSSD cache until it expires, so the default
  makes "we disabled the account" false.
  *Exit:* an AD user logs into a VM over SSH and `id` shows their AD groups; a user **not**
  in the sudo group is denied sudo; a second run reports `changed=0`; and the host's keytab
  authenticates without a password in any file.
- **8.5 [core]** Break-glass and DC backup (R6/D9/R35). A local account on every VM whose
  password lives in Vault, usable with the DC down and logged distinctly so its use is
  visible rather than indistinguishable from an ordinary login. Then
  `samba-tool domain backup online`, because the DC is now a hard dependency for every login
  in the lab.
  *Exit:* with the DC **stopped**, break-glass still gets you in, AD login fails cleanly
  rather than hanging, the break-glass login is separately identifiable in the logs, and a
  restore drill succeeds from the backup alone. The single-DC risk is written down with its
  recovery order rather than mitigated by a second DC.

### Phase 9 · Access — *SSO and privileged access*

- **9.1 [core]** Keycloak, its database, a certificate from Vault, a name, a proxy vhost, its
  admin account as break-glass in Vault — and **LDAP user federation AD → Keycloak**
  (D4), read-only, with group mapping. One-way, so there is exactly one place a user is
  disabled. Keycloak is **not** a directory: no KDC, no machine enrolment, no host keytabs,
  and a VM cannot be joined to it. AD is the source of truth; Keycloak brokers it to OIDC.
  *Exit:* it loads over HTTPS with no `-k`; an AD user authenticates and their AD groups
  appear as Keycloak groups; disabling the user in AD denies them at Keycloak.
- **9.2 [core]** OIDC clients — Gitea, Grafana, MinIO console — with roles derived from 8.3's
  entitlement file, plus **MFA**: TOTP required for privileged groups, conditional for the
  rest. Local admin retained as documented break-glass.
  *Exit:* each service logs in via SSO with the role its AD group implies; a privileged-group
  user is forced to enrol TOTP and a standard user is not; local login still works as
  break-glass and is logged distinctly.
- **9.3 [core]** Vault OIDC for humans with AppRole staying for machines (D8), and the Vault
  SSH secrets engine as the SSH CA (D7): short-lived signed certificates with principals from
  AD groups, and **host-key signing** so clients stop trusting on first use. No static
  `authorized_keys` anywhere in the lab.
  *Exit:* `vault login -method=oidc` lands the policy the user's AD group implies; a machine
  credential cannot be used to log in as a human; SSH into a VM works with a five-minute
  certificate and **nothing in `authorized_keys`**; the certificate expires and access stops;
  the host presents a signed host key and the client does not prompt.
- **9.4 [core]** Identity-based tailnet join — the additive step that closes the loop.
  Headscale OIDC → Keycloak → AD, so joining is an AD identity decision rather than a shared
  key. Pre-auth keys from 7.2 remain for machine nodes.
  *Exit:* `tailscale up` sends a human through Keycloak and the node registers under their AD
  identity; a **disabled** AD user cannot register; machine nodes still join unattended.
- **9.5 [ent]** CloudStack SSO, so the IaaS console is not the one thing left with a local
  password — `admin` becomes break-glass only.
  *Exit:* an AD user logs into CloudStack with a role from their group.

### Phase 10 · Gates

- **10.1 [ent]** `make lint` / `make fmt` and secret hygiene. `lint` never writes, `fmt` is
  the only target that does. The file list comes from `git ls-files`, so `.gitignore` is
  honoured for free and no linter walks a root-owned `data/`. A missing linter warns locally
  and **fails under `STRICT=1`**, which CI sets. `tests/gitignore-assert.sh` wired in, plus a
  secret scanner.
  *Exit:* both targets clean; the vendored installer excluded with the exclusion erroring if
  its path moves; a commit containing a fake credential rejected; `lint` fails when a key is
  made committable.
- **10.2 [ent]** `trivy config` on the IaC and `trivy image` on the qcow2 (D12), scanning
  before publish.
  *Exit:* an image with a fixable HIGH CVE fails **before** it is pushed; every exception is
  in `.trivyignore` with a reason.
- **10.3 [ent]** The three policy gates, all audit-mode first then promoted to enforce.
  **Infrastructure:** Conftest/OPA over `terraform plan -json` — no `0.0.0.0/0` ingress
  except mgmt, egress allow-listed, VMs on the scoped account, tiers isolated.
  **Network:** lint the HuJSON ACL, since Headscale's server-side validation is weak (R21),
  and assert the invariant the whole segmentation story rests on — **no rule grants
  frontend→backend**. **Identity:** `identity/entitlements.yml` schema-validated and every
  generated service config checked against it, so drift between the map and the six places it
  is applied fails a build rather than surfacing in an audit (R20).
  *Exit:* all three pass on real inputs, and each rejects its own deliberately bad input — a
  bad plan, a frontend→backend ACL rule, and a hand-edited OIDC mapping.
- **10.4 [ent]** Wire `policy` into `bootstrap.sh setup` (R14), so the local path cannot apply
  past a violation the pipeline would have caught.
  *Exit:* `setup` refuses to apply a plan `policy` rejects — same script, same verdict, as CI.

### Phase 11 · CI/CD and observability

- **11.1 [ent]** `ci.yml` on PR: lint → scan → policy → `plan`. Workflows live in
  `.gitea/workflows/` and **nowhere else** — anywhere else and CI is silently dead:
  registered, idle, and green because it ran nothing.
  *Exit:* a PR with a formatting error, a hardcoded password and an unpinned image tag is
  **blocked from merging**, and opens again as each is fixed.
- **11.2 [ent]** `cd.yml` on merge: `apply` → ansible → verify, the runner authenticating to
  Vault by AppRole for short-lived credentials per run. The composing workflow owns **no
  steps of its own** — delegate via `needs`, so every stage stays independently runnable
  while one button still does a cold build. Two things to get right: **secret propagation**
  (a called workflow does not inherit credentials, and without it each authenticates to Vault
  with an empty secret id) and **trigger loops** (anything automation commits back can
  re-fire the chain).
  *Exit:* a merge provisions and verifies end to end, and an early failure **visibly skips
  the rest**.
- **11.3 [ent]** Drift detection and branch protection. A **scheduled** plan that fails
  loudly when non-empty, with the limit stated — it will never cover the zone, pod, cluster
  and host, which live outside Terraform's state entirely. Protection comes **last**:
  requiring a status check no pipeline yet produces, plus blocking direct pushes, makes the
  default branch unreachable both ways.
  *Exit:* a manual change in the CloudStack UI to a managed object makes the scheduled plan
  fail; a PR is required and the required check is one that actually runs.
- **11.4 [ent]** Metrics and logs. Metrics **pull**, so they need the 9100 rule from 5.3, and
  retention and scrape interval are pinned **before** first install rather than tuned after a
  failure. Logs **push**, so nothing needs an inbound path into a VM — write the push rules
  first, they go one direction and they work. Keep the agent's write-ahead log: it buffers,
  which is what makes an agent safe to start before the store exists.
  *Exit:* both tiers and the overlay are visible over HTTPS at a real name with **no password
  anywhere in git**, and a line from every tier is queryable by host within a minute.
- **11.5 [ent]** The **authentication plane** in one place, plus alerts. AD security events,
  Keycloak logins, Headscale registrations, Vault audit, sudo, and SSH certificate issuance —
  operational logs answer *what happened*, these answer *who did what*. CloudStack's events
  matter most, because it is the one system whose configuration lives outside git, so its
  event log is the only record of changes to the zone. Alerts on symptoms someone would feel
  plus **certificate and keytab expiry** (R19); an installed alertmanager with no receivers
  is a monitoring system that cannot tell you anything.
  *Exit:* one query returns every authentication event for a single named user across all six
  sources; breaking something deliberately produces an alert that **reaches a real
  destination**; a certificate inside its expiry window fires before it expires.

### Phase 12 · Operations

- **12.1 [core]** Classify, then build `down`'s mechanics (R12). Every artifact into
  reversible / reconstructable / shared / unrecoverable **before** the line that removes it:
  an installer and its teardown are not mirror images, and assuming they are is what makes
  teardown scripts dangerous. The sharpest case — the inverse of *created the bridge netplan
  file* is **not** *delete it*; do that and the host has no network configuration at all.
  Order is broadly reverse-of-install but **checked, not assumed**: a service stops before
  the database it holds open can be dropped. Then **dry-run by default, `--yes` to act** —
  *"a script that printed when you wanted it to act costs one re-run; one that acted when you
  wanted it to print costs the lab"* — and two runners, one that reports and continues
  (removing something already gone is success, and one absent file must not abandon the forty
  steps after it) and one that does not, both taking `argv` and running `"$@"`, never a
  string through `eval`, which re-parses and turns `rm -f "/export/a dir/x"` into two paths
  that cheerfully fail to delete anything.
  *Exit:* every artifact is in exactly one bucket with the asymmetries named; a bare `down`
  changes nothing and prints a complete plan; `--yes` acts.
- **12.2 [core]** Back up what cannot be rebuilt from code, **before** destroying anything:
  Terraform state pulled local, Vault by `operator raft snapshot save`, the AD domain,
  Headscale's database, Keycloak's database, and **CloudStack's database** — the interesting
  case, because the zone, pod, cluster and host were built by an installer rather than
  declared in git, so that database *is* their only definition. Losing it means re-running
  the installer, not re-running a plan. The unseal key is part of the backup or the backup is
  ciphertext.
  *Exit:* a restore drill succeeds from the backups alone, with measured RTO. **An untested
  backup is a hypothesis.**
- **12.3 [ent]** Secret and credential rotation: 3.1's `ensure`-shaped seeding never rotates,
  which is right for idempotency and wrong as a final answer. A deliberate rotation path per
  credential, with each one's blast radius written down.
  *Exit:* rotating one service credential completes with no outage, and rotating the
  CloudStack key is correctly **refused** by the four-state guard rather than silently
  invalidating every holder.
- **12.4 [core]** `terraform destroy`, including from the local state copy with the backend
  stopped (R9); delete the template and image objects; stop the control plane **by label**
  (R32), volumes a separate explicit decision. Sequence the DC last among VMs (R35), since
  everything else depends on it for login. Then the CloudStack uninstall, written from
  scratch because upstream provides none (R2): services, VMs, database, packages, config,
  NFS, drop-ins, repo, `cmk`.
  *Exit:* lab resources gone, destroy succeeds with MinIO stopped, nothing labelled
  `lab=singlecluster` remains, no `cloudstack-*` package, no zone, no lab bridge.
- **12.5 [core]** `restore_netplan()` for real — written in 1.1, exercised here — then the
  resumable second stage, because `down` reboots and verification cannot be the same process:
  a `down --verify` invocation or a systemd oneshot. Report the **shared and unrecoverable
  buckets** (R12): if that report is empty after a real run, something was mis-sorted rather
  than perfectly torn down.
  *Exit:* the host returns on its original network configuration, the report names
  `libvirtd.conf` and the appended `/etc/default` values as unrecoverable rather than
  claiming to have reverted them, and `down` is idempotent — a second run is a no-op.
- **12.6 [core]** **The proof, and the real exit criterion for the whole lab** (R11):
  snapshot the VM → `up` → `down --yes` → `up`. The second `up` must come up green and match
  the first. Decide and implement whether it re-provisions the domain or restores it (R35) —
  they are different scripts. Run this loop as soon as 12.1 exists, not when 12.5 does; the
  snapshot means a failed run costs nothing.
  *Exit:* the loop passes twice, `demo` passes after the second `up`, and the count of
  irreducibly manual steps is written down. Expect the installer run and the Vault unseal; the
  interesting question is what else you find.

### Phase 13 · Documentation and the capstone

- **13.1 [core]** All of it: `README.md` (what and why, prerequisites, `up`/`down`, expected
  output, the isolation and overlay demo, caveats — nested virtualization is set on the
  **hypervisor** and cannot be fixed from inside the guest, so get it wrong and you rebuild
  the VM); `docs/adr/` one file per decision, including D1–D16 and the residuals this plan
  deliberately leaves open — the world-readable image bucket, the runner holding host root,
  the single-tier CA, the single DC, and **what Tailscale now hides** (R22: `AllowedIPs` as
  simultaneously a routing table and an inbound ACL, and the hub/spoke asymmetry that keeps
  spokes ignorant of each other); `docs/runbook.md` for the failures that will happen — zone
  will not enable, template stuck, overlay down, **DC down and nobody can log in**, Keycloak
  down and SSO is dead, restore failed; and an amended `docs/network-plan.md` where
  Tailscale's `100.64.0.0/10` replaces the two WireGuard overlay rows and the reverse zones
  are recorded. The standing rule: where a design has a convenient lab answer and a different
  real-world answer, take the real-world one; where one host cannot supply it, build the half
  that carries the lesson and **write down which half is missing**.
  *Exit:* a new operator runs `up → demo → down` from the docs alone; every decision has an
  ADR; the runbook covers all six; and every range in use has a row and a kind — discovered,
  chosen or derived.
- **13.2 [core]** **The capstone: joiner, mover, leaver.** Create an AD user and prove they
  reach exactly what their groups allow across every service and tier. Move them between
  groups and prove it propagates. Then **disable them** and prove every service and every VM
  denies them — including from the SSSD cache (R9), including the tailnet, including SSH where
  their certificate has not yet expired.
  *Exit:* all three pass, and the leaver case names the **maximum window** between disabling
  an account and the last place that still honours it. That number is the honest measure of
  whether this lab has an identity plane or a collection of logins.

## Verification

Four levels, each a real command:

1. **Per step** — the *Exit* check, exiting zero.
2. **The demo** — `bootstrap.sh demo`: direct inter-tier path BLOCKED, overlay path
   CONNECTED through the transit. This is the JQR 191 claim.
3. **The identity claim** — 13.2's joiner/mover/leaver drill, with a measured leaver window.
4. **The whole claim** — 12.6's loop. Nothing else proves the lab is code.

Five drills worth running deliberately, each from this repo's own failure history:
**cold-start** with every container stopped, because a start-order cycle is invisible while
the proxy is already running; **destroy and rebuild the VPC**, timed, repeated after every
later phase; **break the overlay on purpose** and diagnose it; **stop the DC** and find out
what you actually cannot do; and **check platform health first** when anything fails,
because a control plane reports its database, not reality — `cmk` once described three
running VMs for an hour after they had ceased to exist, and both Terraform and Ansible
believed it.

---

## Risks

- **CloudStack advanced-zone bring-up is the most fragile step.** The tracker makes it
  resumable; budget iteration, not a clean first run.
- **12.4 holds the largest unbudgeted work here** — an uninstall path upstream does not
  provide, for software that rewrote the host's networking. Sized as one step; it may need
  splitting, which is a plan defect to report, not a failure.
- **12.5 can drop host connectivity.** `netplan try`, a backup outside the repo, and the VM
  snapshot are the mitigations. Have console access.
- **The identity plane is a single point of failure for all human access** until 8.5 and
  the break-glass model exist (R6). Build them in the same phase as the DC, not later.
- **Headscale's database is the mesh** (R7), and **the DC is every login** (R35). Both are
  backed up in the step that creates them (7.1, 8.5), not in Phase 12.
- **MinIO is on the teardown critical path** until 12.2 exists — lose it and
  `terraform destroy` cannot run, which breaks the reversibility the whole design rests on.
- **Packer is another qemu guest** and will not share the host with everything running;
  schedule it rather than discovering it.
- **Nested virtualization cannot be fixed from inside the guest.** Check
  `egrep -c '(vmx|svm)' /proc/cpuinfo` and `/dev/kvm` before building anything.
- **Never run the installer from an IDE's integrated terminal** — VS Code's AppArmor
  profile blocks MySQL's post-install script from signalling its own temporary server, and
  the run stalls with a timeout three layers from the cause.
