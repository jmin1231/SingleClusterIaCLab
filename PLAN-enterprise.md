# issue_191 — Enterprise-style VPC + VPN on CloudStack (full target)

> **Scope note:** this is the full enterprise-shaped build, kept for exam prep and
> later hardening. The **core JQR demo** is built first — see [`PLAN.md`](PLAN.md).
> Build the core, then layer these phases on top. Phases are tagged **[core]**
> (also in `PLAN.md`) or **[ent]** (enterprise hardening added here).

**Goal:** `sudo ./bootstrap.sh up` takes a fresh Ubuntu 24.04 VM and stands up a
small but enterprise-shaped private cloud: Apache CloudStack as the IaaS, a golden
image built by Packer and shipped through an object store, a VPC with two
**isolated** subnets (one VM each — no direct path between them), and a WireGuard
**site-to-site** VPN, configured by Ansible, as the *only* route between the
subnets. Everything is secrets-managed, remote-stated, policy-gated, and
pipeline-drivable. `sudo ./bootstrap.sh down` tears it all down and restores the
host to its original fresh-VM state (including the original netplan), then
verifies the revert.

Satisfies JQR 191 (*construct a VPC and implement a VPN to provide access*) while
mirroring how a platform team would actually run this.

## What "enterprise, but local" means here

The lab deliberately mirrors enterprise practices with local stand-ins:

| Enterprise practice | Local realization in this lab |
|---|---|
| Cloud IaaS (AWS/Azure/GCP) | Apache CloudStack + KVM on one host |
| GitOps / PR-gated CI/CD | Gitea + containerized Gitea Actions runner |
| Secrets manager (Vault/KMS/Secrets Manager) | HashiCorp Vault (or OpenBao) container |
| Remote Terraform state + locking | MinIO S3 backend with lockfile |
| Least-privilege deploy identity | Scoped CloudStack **account + role** for IaC (not global admin) |
| Golden-image factory + registry | Packer + CIS hardening + Trivy scan → MinIO image bucket, versioned |
| Policy-as-code guardrails | Conftest/OPA over the Terraform plan |
| Security & quality gates | shellcheck, yamllint, ansible-lint, tflint, tfsec/checkov, trivy |
| Network segmentation + egress control | VPC tiers, default-deny ACLs, default-deny egress allow-list |
| Site-to-site VPN | WireGuard subnet routing (AllowedIPs = peer CIDR) + systemd |
| Observability | node + WireGuard metrics → Prometheus/Grafana/Loki |
| Immutable, reversible infra | tracker idempotency + full teardown + revert verification |
| ADRs / runbooks | `docs/adr/*`, `docs/runbook.md` |

## Architecture

```
                              host (Ubuntu 24.04, KVM)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  control plane (docker):  Gitea + Actions runner · Vault · MinIO          │
 │        │ pipeline: lint → scan → policy → plan → apply → ansible → verify │
 │        ▼                                                                   │
 │  Apache CloudStack (mgmt+agent+MySQL+NFS)   Packer/qemu → golden image     │
 │        │  IaC uses a scoped 'iac' account; secrets pulled from Vault       │
 │   ┌──────────────────── VPC 10.0.0.0/16 ─────────────────────┐            │
 │   │  mgmt/bastion shared net (cloudbr0) ── Ansible/SSH ──┐    │            │
 │   │   tier-a 10.0.1.0/24            tier-b 10.0.2.0/24   │    │            │
 │   │   ┌──────────┐   ACL: deny      ┌──────────┐         │    │            │
 │   │   │  vm-a    │── direct + ──────│  vm-b    │         │    │            │
 │   │   │  wg0     │   default-deny   │  wg0     │◄────────┘ mgmt NIC        │
 │   │   └────┬─────┘   egress         └────┬─────┘                          │
 │   │        └── WireGuard site-to-site (AllowedIPs = peer subnet) ──┘       │
 │   └──────────────────────────────────────────────────────────────────────┘
 └──────────────────────────────────────────────────────────────────────────┘
```

- **Data plane:** tier-a ↔ tier-b direct traffic is denied by ACLs; egress is
  default-deny with an allow-list. The WireGuard tunnel (subnet-routed) is the
  only path between the two subnets.
- **Management plane:** Ansible/SSH ride a separate bastion/mgmt shared network,
  out-of-band from the data path.
- **Control plane:** Gitea/Vault/MinIO run in Docker and drive the whole thing.

## Principles

- **Pipeline-driven** — every phase is a CI job; `bootstrap.sh` is the local/dev
  path that runs the identical logic.
- **Idempotent** — guards before acting (tracker + `dpkg -s`/`systemctl`/`cmk list`/`[ -e ]`).
- **Reversible & verified** — `down` restores the host and then asserts it matches baseline.
- **Least privilege** — scoped CloudStack account for IaC; no global admin in automation.
- **Secrets never on disk in clear** — Vault issues them at run time.
- **Immutable, versioned images** — hardened, scanned, content-addressed; never patched in place.
- **Policy-as-code** — the plan is checked against guardrails before apply.
- **Pinned** — repos, providers, plugins, images, tool versions.
- **Fresh-VM assumption** — nothing pre-installed; guards no-op on an already-provisioned host.

## Tools

| Purpose | Tool |
|---|---|
| IaaS / hypervisor | Apache CloudStack 4.22 + KVM/libvirt |
| CI/CD | Gitea + `act_runner` (containerized, pinned toolchain image) |
| Secrets | HashiCorp Vault / OpenBao (container) |
| Object store (images + TF state) | MinIO (container) |
| Image build | Packer (`qemu`) + Ubuntu autoinstall (subiquity) + cloud-init |
| Image hardening/scan | ansible CIS hardening + Trivy + Syft (SBOM) |
| VPC provisioning | Terraform + `cloudstack/cloudstack` (remote state in MinIO) |
| Config / VPN | Ansible + WireGuard (site-to-site, systemd) |
| Policy / quality | Conftest/OPA, tflint, tfsec or checkov, ansible-lint, yamllint, shellcheck |
| Observability | node_exporter + WireGuard metrics → Prometheus/Grafana/Loki |
| CLIs | CloudMonkey (`cmk`), `mc`, `jq`, `qemu-utils`, `cloud-localds` |

## Directory layout

```
issue_191/
  PLAN.md  PLAN-enterprise.md  README.md
  bootstrap.sh                single entry point (local path; mirrors CI)
  lib.sh                      log/die, tracker, netplan backup/restore, vault/mc helpers
  .gitea/workflows/           CI pipeline definitions (lint, scan, plan, apply, ansible, verify)
  docker/                     control plane: gitea/, vault/, minio/ compose + bootstrap
  cloudstack/                 KVM prep, install, scoped iac account, offerings (idempotent)
  packer/                     qemu template, autoinstall, cloud-init, hardening, scan
  terraform/                  provider(remote state), vpc, tiers+ACLs, mgmt net, 2 VMs, outputs
  policy/                     OPA/Conftest rules run against the tf plan
  ansible/                    inventory, wireguard (site-to-site) role, templates
  tests/                      lint + integration (verify/demo) harness
  docs/                       adr/*.md, runbook.md
  state/                      tracker, generated inventory (secrets come from Vault; gitignored)
```

## bootstrap.sh command map

| Command | Runs |
|---|---|
| `up` | platform → provision → image → template → setup → tunnel → verify |
| `platform` | Phase 2 (Vault, MinIO, Gitea + runner) |
| `provision` | Phase 1 (backup netplan, install CloudStack, scoped iac account, offerings) |
| `image` | Phase 3 (Packer build + harden + scan + publish, versioned) |
| `template` | register the image as a CloudStack template, wait ready |
| `lint` | shellcheck/yamllint/ansible-lint/tflint |
| `scan` | tfsec/checkov (tf) + trivy (image) |
| `policy` | Conftest/OPA over `terraform plan` |
| `setup` | Phase 4 (terraform plan → apply, remote state, secrets from Vault) |
| `tunnel` | Phase 5 (ansible-playbook: site-to-site WireGuard) |
| `verify` | automated checks (handshake, subnet-over-VPN reachability, isolation, egress deny); exit non-zero on failure |
| `demo` | human-readable proof: direct path blocked, WireGuard path works |
| `status` | read-only inventory of what exists |
| `down` | terraform destroy → CloudStack uninstall → restore netplan → reboot → **verify revert** |

Phases tagged **[core]** (needed for the JQR demo) or **[ent]** (enterprise
hardening layered on). Build core first for a working demo, then layer ent.

---

## Phases and steps

Each step is scoped to a single focused work session with a clear exit check.

### Phase 0 — Scaffolding **[core]**
- **0.1** Repo skeleton, `bootstrap.sh` dispatch (stubs), `lib.sh` (log/die, tracker,
  logging to `state/bootstrap.log`), `state/` + `.gitignore`, `docs/` seed.
  Exit: `./bootstrap.sh` prints usage; `bash -n` + `shellcheck` clean.

### Phase 1 — CloudStack bring-up + netplan preservation + scoped identity
- **1.1 [core]** Netplan backup (one-time `cp -a /etc/netplan → /var/backups/cloudstack-lab/netplan.orig/`, guarded, tracked) then KVM host prep (root/password SSH drop-in).
  Exit: pristine backup exists; `sshd -T` shows root+password; re-run is a no-op.
- **1.2 [core]** Install CloudStack all-in-one (mgmt+agent+MySQL+NFS+advanced zone with public range + mgmt shared network); install/configure `cmk`; disable bridge-netfilter + preflight.
  Exit: `cmk list zones` shows an Enabled Advanced zone; system VMs Running; re-run skips via tracker.
- **1.3 [ent]** Scoped IaC identity: create a CloudStack **domain/account `iac`** with a **role** limited to VPC/network/VM/template/keypair ops; generate its API key; store the key in Vault. Terraform authenticates as `iac`, not the global admin.
  Exit: `cmk` as the `iac` key can create networks but is denied a global-admin op.
- **1.4 [core]** Offerings: compute, VPC offering (note the **redundant VPC offering** for an HA-shaped VR), VPC tier network offering (ConfigDrive userdata), mgmt shared-network offering. Create-if-absent.
  Exit: `cmk list …offerings` show the lab offerings.

### Phase 2 — Control plane: Vault, MinIO, Gitea **[ent]**
- **2.1** MinIO container (pinned): buckets `images` and `terraform-state`; policy/user for each; reachable from the CloudStack SSVM network.
  Exit: `mc` round-trips objects in both buckets.
- **2.2** Vault container (pinned): enable KV; seed paths for CloudStack `iac` creds, MinIO creds, the lab SSH keypair, and WireGuard keys; an AppRole the runner/`bootstrap.sh` uses to read them.
  Exit: `vault kv get` returns the seeded secrets via AppRole.
- **2.3** Gitea + `act_runner` (pinned): a repo mirror of `issue_191/`, a runner image baked with terraform/ansible/packer/cmk/trivy, and the runner registered.
  Exit: a trivial workflow runs green on the runner.

### Phase 3 — Golden image factory **[core build, ent hardening]**
- **3.1 [core]** Packer `qemu` build: Ubuntu 24.04 autoinstall (cidata seed) → qcow2 with cloud-init, qemu-guest-agent, openssh-server, python3. WireGuard installed later by Ansible.
  Exit: `packer validate` passes; `packer build` yields a bootable, cloud-init-ready qcow2.
- **3.2 [ent]** Harden + scan + SBOM: apply a CIS-style hardening pass in the build; **Trivy** scan (fail on HIGH/CRITICAL); **Syft** SBOM saved as a build artifact.
  Exit: image passes the Trivy gate; SBOM emitted.
- **3.3 [ent]** Version + publish: tag the artifact by content hash/date, upload to MinIO `images/<version>/`, keep a `latest` pointer; **build-skip if the same hash already published**.
  Exit: versioned qcow2 in MinIO; re-run without changes skips the build.
- **3.4 [core]** Register template in CloudStack by MinIO URL, wait `isready`; idempotent by name+version.
  Exit: `cmk list templates` shows the versioned template ready.

### Phase 4 — Terraform: VPC, isolated tiers, VMs **[core + ent]**
- **4.1 [core]** Provider + inputs + **remote state**: `cloudstack/cloudstack ~>0.6`, backend `s3` → MinIO with lockfile; creds (`iac` API key, MinIO) injected from Vault as `TF_VAR_*`/`AWS_*` at run time. Data lookups for zone/offerings/template.
  Exit: `terraform init` (remote backend) + `validate` succeed; state object appears in MinIO.
- **4.2 [core]** Network: VPC `10.0.0.0/16`; two data tiers each with an ACL — **deny inter-tier except WireGuard UDP `51820`**, allow SSH from mgmt, **default-deny egress with an allow-list** (DNS, updates, WireGuard); mgmt/bastion shared network on `cloudbr0`. `parallelism=1` on ACL rules.
  Exit: apply; `cmk list networks` shows VPC + tiers + mgmt; egress allow-list in place.
- **4.3 [core]** Compute + inventory: lab keypair (public from Vault) + ConfigDrive userdata; two multihomed VMs (mgmt NIC + one data tier each); `outputs.tf` writes IPs + Ansible inventory to `state/`.
  Exit: both VMs Running, SSH-reachable on mgmt; **direct data-tier ping between them FAILS** (isolation proven).

### Phase 5 — Ansible: WireGuard site-to-site VPN **[core]**
- **5.1** `wireguard` role: install WG, fetch/generate keys (via Vault), enable `net.ipv4.ip_forward`, template `wg0.conf` with **AllowedIPs = the peer tier's CIDR** (subnet routing, not just /32), `PersistentKeepalive=25`, and manage it with `systemd` (`wg-quick@wg0`, enabled + restart-on-failure).
  Exit: `wg show` on both VMs shows a recent handshake; `systemctl is-enabled wg-quick@wg0` is enabled.
- **5.2 Verify**: over the VPN a host in tier-a reaches tier-b's **subnet** (not just the peer overlay IP); direct (non-tunnel) inter-tier probe still fails; a disallowed egress destination is blocked. Non-zero on any wrong expectation.
  Exit: verify prints pass (VPN subnet routing works, direct blocked, egress filtered).
- **5.3 Demo**: human-readable proof — (1) direct data-tier probe BLOCKED, (2) tier-a→tier-b over WireGuard CONNECTED, (3) the working path is `dev wg0` and dropping `wg0` breaks it. Non-destructive; prints `direct: BLOCKED ✓ · WireGuard: CONNECTED ✓`.
  Exit: demo shows blocked + connected; non-zero if not.

### Phase 6 — Quality & policy gates **[ent]**
- **6.1** Lint: shellcheck (bash), yamllint, ansible-lint, tflint. Wire into `lint` + CI.
  Exit: all linters clean (or documented, suppressed exceptions).
- **6.2** Security scan: tfsec or checkov on Terraform; Trivy on the image (also in Phase 3). `scan` + CI gate.
  Exit: no HIGH/CRITICAL, or risk-accepted with a comment.
- **6.3** Policy-as-code: Conftest/OPA rules over `terraform plan -json` — e.g. no `0.0.0.0/0` ingress except mgmt, egress is allow-listed, VMs use the scoped account, tiers are isolated. `policy` + CI gate before apply.
  Exit: policy passes; a deliberately bad plan is rejected.

### Phase 7 — Observability **[ent, stretch]**
- **7.1** node_exporter + a WireGuard metrics collector (handshake age, transfer) on the VMs; Prometheus + Grafana + Loki in the control plane; a dashboard for tunnel health and an alert on stale handshake.
  Exit: Grafana shows both VMs and the tunnel; killing `wg0` fires the alert.

### Phase 8 — CI/CD wiring **[ent]**
- **8.1** `.gitea/workflows/`: `ci.yml` (lint → scan → policy → `plan`, on PR) and `cd.yml` (`apply` → ansible → verify, on merge/manual gate). The runner reads secrets from Vault via AppRole; state is the MinIO backend. `bootstrap.sh` and CI call the same scripts.
  Exit: a PR runs the gates; a merge provisions and verifies end-to-end on the runner.

### Phase 9 — Teardown, revert & verification **[core + ent]**
- **9.1 [core]** `terraform destroy`; delete the CloudStack template + MinIO image objects; stop control-plane containers (or keep, per flag).
  Exit: lab CloudStack resources gone.
- **9.2 [core]** CloudStack uninstall (services, VMs, DB, packages, config, NFS, drop-ins, repo, `cmk`) then `restore_netplan()` (restore backup, `netplan try`, remove `cloudbr0`/`cloud0`/`virbr10`), reboot.
  Exit: no CloudStack; networking via original netplan.
- **9.3 [ent]** Revert verification: after reboot assert baseline — no `cloudstack-*` packages, no zone, `/etc/netplan` byte-identical to the backup, lab bridges gone, host online, `state/` cleared. Emit a pass/fail report.
  Exit: revert report is green.

### Phase 10 — Docs **[core + ent]**
- **10.1** README (what/why, prerequisites, `up`/`down`, expected output, the isolation+VPN demo, caveats). `docs/adr/` for the key decisions (CloudStack, WireGuard site-to-site, Vault, remote state, scoped account). `docs/runbook.md` for failure recovery (zone won't enable, template stuck, tunnel down, restore failed).
  Exit: a new operator can run `up → demo → down` from the docs alone.

---

## Recommendations & gotchas

- **MinIO does double duty:** image registry *and* Terraform remote-state backend
  (its lockfile gives state locking). Keep the two buckets separate.
- **Vault is the source of truth for secrets** at run time; `state/` holds only
  non-secret generated files (inventory). Nothing sensitive is committed.
- **Scoped `iac` account** is the single biggest realism win — automation must not
  wield global admin. Verify a global-only op is denied to it.
- **Site-to-site, not host overlay:** AllowedIPs = peer *subnet* + IP forwarding
  makes this a real VPN between networks, and `systemd` + `PersistentKeepalive`
  make it survive reboots/NAT — the enterprise expectation.
- **Default-deny egress** with an allow-list is the posture reviewers look for;
  demonstrate a blocked egress in `verify`.
- **ConfigDrive** for cloud-init userdata (proven by the `iac-*-configdrive`
  offerings here); avoids depending on the VR metadata service.
- **`parallelism=1`** for ACL rules (CloudStack races otherwise).
- **`netplan try`** on restore (auto-reverts); backup lives outside the repo so
  the purge can't remove it.
- **Bridge-netfilter preflight** before Terraform (silently breaks VPC port-forwarding).
- **Idempotent image builds:** content-hash the inputs; skip build + publish when unchanged.

---

## VPN alternative — Tailscale / Headscale (3-network transit)

For exam prep the topology grows to **three** networks — **frontend → middle →
backend** — where the frontend may talk to the backend **only through the middle,
never directly**, and frontend VMs are **ephemeral** (exist for days) while the
backend is the always-on service plane. This is where an identity-based mesh
(Tailscale, self-hosted via **Headscale**) fits better than hand-managed WireGuard.

### Why Tailscale here

- **Ephemeral frontends:** register them with an **ephemeral, tagged auth key** baked
  into cloud-init. When a frontend VM is destroyed it **auto-removes** from the
  tailnet — no stale peers to clean off the backend (the toil raw WireGuard imposes).
- **Tag-based ACLs:** rules key off `tag:frontend` / `tag:middle` / `tag:backend`, so
  churn never requires editing config. New FE VM joins → rights apply instantly.
- **Subnet router:** the middle advertises the backend subnet; the backend need not be
  a direct peer of the frontend at all.
- **Self-hosted control plane:** **Headscale** (OSS, ~43k★, HuJSON ACLs in Git, OIDC,
  Postgres backend) keeps it local and free — no SaaS dependency.

### How it works (control vs data plane)

```
      CONTROL PLANE (metadata/keys only)        DATA PLANE (your traffic)
   ┌───────────────────────────────┐
   │ Headscale (self-hosted) + OIDC │        node A ══ WireGuard ══ node B
   │  - authenticates nodes          │          (direct P2P; DERP relay
   │  - distributes public keys      │           only if NAT blocks it)
   │  - pushes HuJSON ACL policy      │
   └───────────────────────────────┘
```
Nodes authenticate (auth key or OIDC), send their **public** key up, receive the
peer list + ACL they're allowed, and configure WireGuard themselves.

### Three-network transit design

Tailscale defaults to a **flat mesh** (everyone reaches everyone) — the opposite of
what we want. We enforce transit with **default-deny ACLs + a subnet router on the
middle**, and by keeping the **backend off the tailnet as a direct peer**:

```
 tag:frontend (ephemeral)     tag:middle (persistent)        backend 10.0.3.0/24
 FE VMs 10.0.1.0/24           Tailscale node + SUBNET         BE VMs (service plane)
                              ROUTER for 10.0.3.0/24
      │                             │                                │
      │  Tailscale (WireGuard)      │   routes (ip_forward)          │
      └──── ACL: FE → middle ──────►│──── ACL: middle → backend ────►│
            (e.g. :443)             │                                │
   ✗ no ACL FE → 10.0.3.0/24  AND backend is not a direct peer
     ⇒ frontend's only path to backend is through the middle
```

Two layers make "no direct FE↔BE" airtight: (1) backend is reachable only via the
middle's advertised route — no FE→BE tunnel exists; (2) ACLs are default-deny and you
never write an FE→backend rule.

### ACL policy (HuJSON — versioned in Git, GitOps-friendly)

```jsonc
{
  "tagOwners": {
    "tag:frontend": ["autogroup:admin"],
    "tag:middle":   ["autogroup:admin"],
    "tag:backend":  ["autogroup:admin"]
  },
  "autoApprovers": { "routes": { "10.0.3.0/24": ["tag:middle"] } },
  "acls": [
    { "action": "accept", "src": ["tag:frontend"], "dst": ["tag:middle:443"] },
    { "action": "accept", "src": ["tag:middle"],   "dst": ["10.0.3.0/24:*"] }
    // no tag:frontend -> 10.0.3.0/24 rule => denied by default
  ]
}
```

### Ephemeral frontend vs persistent backend

```yaml
# cloud-init on an ephemeral frontend VM
runcmd:
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --login-server https://headscale.lab --authkey tskey-... \
      --advertise-tags tag:frontend
# middle VM additionally: --advertise-routes 10.0.3.0/24  (approved via autoApprovers)
# keys made once: FE = ephemeral+reusable+tag:frontend ; BE = reusable+tag:backend
```

### WireGuard hub-and-spoke (raw, no control plane) **[ent]**

Same three-network outcome as above on plain WireGuard. The core JQR demo is a
**2-tier point-to-point** tunnel (tier-a ↔ tier-b directly). The 3-tier version makes
the **middle a transit hub (tunnel router)**: frontend (A) and backend (B) are
**spokes that peer only with the hub**, never with each other. A and B never learn
each other's specifics — the hub is the sole holder of the full routing map and the
cross-tier policy.

```
tier-a 10.0.1.0/24        tier-mid 10.0.3.0/24 (HUB)       tier-b 10.0.2.0/24
 ┌────────┐  wg tunnel     ┌──────────────────┐  wg tunnel  ┌────────┐
 │  A-gw  │═══════════════►│ hub  ip_forward=1 │◄═══════════│  B-gw  │
 └────────┘                │ knows A + B + pol │             └────────┘
  "internal → hub"         └──────────────────┘              "internal → hub"
```

**AllowedIPs asymmetry — the mechanism that keeps spokes ignorant.** `AllowedIPs` is
both routing *and* inbound ACL, so:

- **spoke → hub:** `AllowedIPs = <overlay>/24, 10.0.0.0/8` (an **aggregate**) — "send
  all internal traffic to the hub, accept all internal back." The spoke has no route
  for the far subnet specifically; it's swallowed by the aggregate, so A is oblivious
  to B's existence.
- **hub → spoke A:** `AllowedIPs = <A overlay>/32, 10.0.1.0/24`; **hub → spoke B:**
  `<B overlay>/32, 10.0.2.0/24`. The hub alone holds the per-subnet specifics.

```ini
# spoke A-gw — one peer, the hub only
[Peer]
PublicKey  = <hub pubkey>
Endpoint   = <hub tier-mid IP>:51820
AllowedIPs = 10.99.0.0/24, 10.0.0.0/8

# hub — one [Peer] per spoke
[Peer]
PublicKey  = <A pubkey>
AllowedIPs = 10.99.0.2/32, 10.0.1.0/24
[Peer]
PublicKey  = <B pubkey>
AllowedIPs = 10.99.0.3/32, 10.0.2.0/24
```

`ip_forward=1` on the hub is mandatory — forwarding between the two tunnels is its
entire job.

**"A↔B only via the middle" is enforced in three independent layers:**
1. **Network ACLs:** allow UDP 51820 on `tier-a↔tier-mid` and `tier-mid↔tier-b`,
   **deny `tier-a↔tier-b` outright** — A physically cannot address B.
2. **WG peering:** A has no `[Peer]` for B — no key, no endpoint, no tunnel exists.
3. **Hub policy:** all cross-tier traffic transits the hub, so `nftables` there is the
   single enforcement/inspection/logging chokepoint (e.g. A→B:8080 only, B→A denied).

**Enterprise mapping:** this is a **transit hub** — the self-managed analog of a
transit VPC / AWS Transit Gateway / Azure vWAN hub: spokes route to the hub, the hub
routes between them and enforces policy, spokes stay simple and ignorant of the wider
topology. The chokepoint is where L4/L7 firewalling, IDS, and audit live.

**Caveats:** the hub is a SPOF + bandwidth funnel (run an HA pair); routing must be
symmetric through the hub both ways, or NAT/masquerade at the hub (trading away the
source identity the per-VM SG rules depend on); on real clouds the hub instance needs
**source/dest check disabled** to forward. Dead ephemeral spokes must be pruned by
hand — exactly the toil Headscale automates.

**Lab delta from the 2-tier core:** add `tier-mid` + a hub VM in Terraform; change the
ACLs to A↔mid / mid↔B allow + A↔B deny; split the Ansible `wireguard` role into a
**hub** play (loops over all spoke peers) and a **spoke** play (single `[Peer] = hub`
with the aggregate `AllowedIPs`).

**When to pick which:** WireGuard hub-spoke for the 2-network core (mechanics, no
control plane); Tailscale/Headscale for the 3-network churn topology (ephemeral nodes
+ tag ACLs + subnet-router transit pay off).

---

## Open-source tool choices (2026 review)

Researched swaps where a more standard / better-licensed OSS tool fits. Optional;
decide per phase.

| Layer (phase) | Plan default | Stronger/again-standard OSS | Why / when |
|---|---|---|---|
| IaC engine (4.x) | Terraform | **OpenTofu** | OSI MPL-2.0 under the Linux Foundation/CNCF vs Terraform's BSL (now IBM-owned); drop-in, full provider compat; lower-risk for new/regulated projects |
| IaC PR automation (8) | Gitea runs `tofu` | **Atlantis** (Apache-2.0) | Standard "plan on PR, apply on comment" gate; alts OpenTaco (ex-Digger, runs in your CI), Terrateam |
| Secrets (2.2) | Vault | **OpenBao** (MPL-2.0 fork) | Truly-open license, LF governance; namespaces/multi-tenancy free (Enterprise-only in Vault) |
| Identity/SSO (2.x) | — | **Keycloak** (OIDC) | Anchor SSO for Headscale, OpenBao, Gitea — ties the "identity-based" story together |
| Image hardening (3.2) | ad-hoc CIS | **dev-sec/ansible-collection-hardening** (or ansible-lockdown) + **OpenSCAP**/SCAP Security Guide | dev-sec applies controls; OpenSCAP *validates* against a CIS profile and reports |
| TF security scan (6) | tfsec | **Trivy** (`trivy config`) | tfsec is being folded into Trivy; Trivy also does the image scan — one tool |
| VPN (5) | WireGuard | **Tailscale/Headscale** | Ephemeral nodes + tag ACLs + subnet-router transit for the 3-network churn case (above) |
| CI platform (8) | Gitea + runner | **GitLab CE** (heavier) | If you want registry/CI/issues in one; Gitea stays the lightweight default |

**Sources (2026):**
[OpenTofu](https://www.turbogeek.co.uk/opentofu-vs-terraform-2026/) ·
[Atlantis/alternatives](https://scalr.com/learning-center/selecting-a-terraform-cloud-alternative) ·
[Headscale](https://bex.co/blog/2026/09/04/headscale-self-hosted-mesh-fleet) ·
[OpenBao](https://www.openbao.ch/comparison/) ·
[CIS hardening](https://www.ansiblebyexample.com/articles/ansible-compliance-as-code-cis-benchmarks-stig-hardening)

## Risks

- **CloudStack advanced-zone bring-up** is the most fragile step; the tracker makes
  it resumable — budget iteration.
- **Control-plane sprawl:** Vault+MinIO+Gitea add moving parts; keep them in one
  `docker/` compose project with health checks so `platform` is one command.
- **Secrets bootstrapping (chicken-and-egg):** Vault/MinIO must exist before
  Terraform can read creds/state — hence Phase 2 precedes Phase 4; a small
  two-stage init (unseal/seed Vault, create buckets) handles it.
- **Template fetch** can take minutes; poll `isready`.
- **`down` networking** is the one step that can drop host connectivity; `netplan
  try` + external backup + the Phase 9.3 revert check mitigate it.
- **Packer needs `/dev/kvm`** — present here; confirm on any target VM.
- **Headscale (if used for the VPN):** PostgreSQL backup is mandatory (it holds nodes,
  keys, and ACL state — losing it loses the mesh); no official web console; server-side
  ACL linting is weak, so validate the HuJSON ACL in CI.
