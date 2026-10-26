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
| Directory / host login | Samba AD DC (VM) + `realmd`/`adcli`/SSSD on the tier VMs |
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
| `directory` | Phase 11 (Samba AD DC, join the VMs, directory logins) **[ent]**; run after `tunnel` |
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

### Phase 11 — Directory login: AD users on the VMs **[ent]**
Design and rationale: see *Directory login with Samba AD DC* under "Human & user access to the VMs".
- **11.1** Shared-services tier + DC VM: Terraform adds `tier-svc` `10.0.10.0/24` and a `dc` VM (Medium Instance, 1 GB) at `10.0.10.10`; tier ACLs allow the data tiers to reach `tier-svc` **on the AD ports only**; an `sg_directory` group on `dc` does the same per VM; members get a route to `10.0.10.0/24` via their tier gateway.
  Exit: `dc` Running; from a tier VM, `nc -zv 10.0.10.10 88` and `389` succeed and `22` from a tier VM fails.
- **11.2** Provision the domain (Ansible `samba_dc` role): install `samba-ad-dc krb5-user`; stop and mask `smbd`/`nmbd`/`winbind`; point the DC's own resolver at itself (disable the `systemd-resolved` stub); `samba-tool domain provision --realm=AD.LAB.TEST --domain=LAB --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass=<Vault>`; install the generated `krb5.conf`; enable `samba-ad-dc`. Then create the reverse zone (`samba-tool dns zonecreate dc 0.10.in-addr.arpa`), `OU=LabServers`, a delegated `joiner` account (may only create computer objects in that OU), groups `lab-users` and `lab-admins`, and demo users `alice` (lab-admins), `bob` (lab-users), `carol` (no group), passwords from Vault.
  Exit: `host -t SRV _ldap._tcp.ad.lab.test 10.0.10.10` answers; `kinit administrator@AD.LAB.TEST` works on `dc`; `samba-tool user list` shows the demo users.
- **11.3** Join the members (Ansible `ad_member` role): FQDN hostname (`vm-a.ad.lab.test`); DNS: the lab resolver forwards `ad.lab.test` and `0.10.in-addr.arpa` to the DC (with no lab resolver, a `systemd-resolved` drop-in with `DNS=10.0.10.10` and `Domains=~ad.lab.test`); `chrony` syncs from `dc`; `realm join --user=joiner --computer-ou=OU=LabServers ad.lab.test` with the joiner password from Vault on stdin. SSSD: `use_fully_qualified_names = False`, `fallback_homedir = /home/%u`, `ad_gpo_access_control = permissive`. Access: `realm deny --all` then `realm permit -g lab-users lab-admins`; `pam-auth-update --enable mkhomedir`; `/etc/sudoers.d/lab-admins` with `%lab-admins ALL=(ALL) ALL`; sshd allows password/keyboard-interactive auth.
  Exit: `realm list` shows `ad.lab.test`; `id alice` resolves with no local account; `/etc/krb5.keytab` exists **on the VM** (and never in the image).
- **11.4 [stretch]** Kerberos SSO: PTR records for every member; `GSSAPIAuthentication yes` on the VMs. Test on a joined VM against itself: log in as `alice`, `kinit alice@AD.LAB.TEST`, then `ssh -K alice@vm-a.ad.lab.test` with no password. Self-SSH is deliberate: the tiers are isolated from each other, and the bastion cannot reach the KDC on `tier-svc`, so this is the one path that exercises the full ticket flow without opening a new hole.
  Exit: `klist` on `vm-a` shows a `host/vm-a.ad.lab.test@AD.LAB.TEST` service ticket after the login.
- **11.5** Verify (add to `verify`): `alice` logs in with her AD password and can `sudo`; `bob` logs in and cannot `sudo`; `carol` is refused at login; `samba-tool user disable alice` makes her next login fail, and re-enabling restores it. Passwords come from Vault (`sshpass` in the test only).
  Exit: all five pass; non-zero on any wrong expectation.
- **11.6** Teardown: `realm leave` (removes the computer object) before `terraform destroy`; delete the `secret/ad/*` paths in Vault.
  Exit: no computer objects or AD secrets left behind.

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

## Human & user access to the VMs **[ent]**

Access splits into **two planes**, and conflating them is the classic mistake. The
core lab is management-plane-only (admin SSH scoped to `mgmt_cidr`, service reachable
only over the tunnel); enterprise adds the data plane and a brokered privileged plane.

| | Data / service plane | Privileged plane |
|---|---|---|
| **Who** | end users ("conduct business") | admins *and* any human who needs a shell |
| **What** | the application (HTTP/API/DB), never the OS | interactive OS login (SSH/RDP) |
| **Grant by** | published service endpoint | **identity**, not a network hole |

### Data-plane ingress (users use the app, not the OS)

Expose the *service*, never SSH or the mgmt NIC:
- **CloudStack:** acquire a public IP on the VPC, add a **port-forward or LB rule**
  (`cloudstack_ipaddress` + `cloudstack_port_forward`/`cloudstack_loadbalancer_rule`)
  to the tier VM; open the **tier ACL** for the service port only; the VM's nftables
  allows the app port on the **tier NIC** (contrast the core demo, which pins the
  service to `iifname wg0` = internal-only).
- **Enterprise front door:** LB + **WAF** + **API gateway** terminate TLS and do
  authn/z; backends never see raw internet. Scope the ACL source where possible.

### Privileged-plane login (someone needs a shell)

Treat "log in to the VM" as privileged **regardless of the person's title**. Never
widen `mgmt_cidr`, share `lab_ssh_key`, or scatter static per-user keys (no
attribution, no MFA, no revocation). Instead **broker login by identity**.

**1. One controlled entry point — users never hit the VM directly:**

| Approach | Path | Inbound SSH on the VM |
|---|---|---|
| Bastion / jump host | user → bastion (authn) → VM | from bastion only |
| Access proxy (Teleport, Boundary) | user → proxy (SSO+MFA) → VM | from proxy only, short-lived cert |
| Agent dials out (AWS SSM, Cloudflare Tunnel, Tailscale SSH) | VM agent → broker → user | **none** (VM connects outbound) |

The agent-based options are strongest: the VM opens an **outbound** session, so there
is **zero inbound SSH** to firewall — the network attack surface for login disappears.

**2. Identity + short-lived credentials instead of static keys:**
- **SSO/OIDC** (Keycloak) as the identity source; **MFA** enforced at login.
- **SSH certificate authority** — the broker issues a **short-lived cert** bound to the
  user's identity+role+TTL; the VM trusts the **CA**, not individual keys, so expiry =
  automatic revocation and nothing permanent lands on the host.
- **RBAC** — which users may log into which VMs as which account.
- **Session recording + audit** — every interactive session logged (compliance).
- **JIT / approval** — access granted for a window on request, not standing.

**3. Accounts:** never share `ubuntu` for real users (lose attribution). Use
**directory-integrated** accounts (SSSD + LDAP/AD, configured by Ansible) or
**broker-mapped** logins (the proxy maps an SSO identity to an OS user on the fly).

**Firewall end state:** the SG allows SSH **only from the bastion/proxy**
(`ip saddr <broker_cidr> tcp dport 22 accept`), tighter than `mgmt_cidr`; with an
agent-based broker, **drop the inbound SSH rule entirely**.

**Tooling:** Teleport · HashiCorp Boundary · Cloudflare Access+Tunnel · AWS SSM
Session Manager · Tailscale SSH — all pair with Keycloak (OIDC) and the
Headscale/Tailscale identity model above (access by `tag:`/identity, not by subnet).

**Core-lab note:** the host already *is* the bastion — `ssh -J user@host
ubuntu@<vm mgmt IP>` is the scoped admin path and needs no firewall change. That is
sufficient for the JQR demo; the broker/CA/RBAC stack is the enterprise layer on top.


### Directory login with Samba AD DC **[ent]**

**Goal:** a person who exists only in Active Directory (`alice`) logs into a tier VM
with her **AD username and password**, gets `sudo` only because of an AD group, and
loses access the moment she is disabled in AD. No local account, no SSH key, nothing
per-user on the VM. Built as Phase 11.

**Why Samba AD DC** (recorded as decision 14.0-2 in `docs/decisions.md`, replacing
14.0-1's FreeIPA pick for the host-identity plane):
- It speaks Active Directory's own protocols (Kerberos, LDAP, AD-style DNS, SMB), so the
  VMs join exactly as they would join a Windows domain: `realm join`, `adcli`, SSSD's
  `ad` provider. What you learn transfers directly to a real AD.
- It runs on Ubuntu 24.04 from the **same golden image**. FreeIPA needs a RHEL-family
  guest, which means a second Packer pipeline.
- About 1 GB of RAM.
- Trade-off: no FreeIPA-style HBAC rules. Per-tier login policy is AD groups plus
  `realm permit -g` on each tier instead (e.g. only `db-admins` on the backend).

**Login methods, in build order:**

| Step | Method | What it proves | Why this order |
|---|---|---|---|
| core | SSH with AD password | The VM accepts directory credentials; SSSD checks them with the DC over Kerberos | The requirement itself; needs only the join and sshd password auth |
| core | Group-based access + sudo | Authorization comes from the directory, and revocation is central (disable in AD, refused everywhere) | Two config lines on top of the join, and the strongest demo |
| stretch | Kerberos SSO (`kinit` once, GSSAPI) | What makes a *domain* more than a user database: tickets and host principals | Depends on SRV records, PTR records and the clock, which fail with misleading errors, so build it on a working base |

**Topology:**
```
 tier-svc 10.0.10.0/24 (shared services)
   dc 10.0.10.10  Samba AD DC: realm AD.LAB.TEST, DNS for ad.lab.test, KDC, LDAP, NTP
        ▲  allowed in (ACL + sg_directory): 53 dns · 88 kerberos · 123 ntp ·
        │  389/636 ldap/ldaps · 445 smb · 464 kpasswd · 3268/3269 global catalog
        │
 tier-a / tier-b VMs: realm-joined members (SSSD), route 10.0.10.0/24 via tier gw
        ▲
        │  ssh alice@<vm>  →  password  →  SSSD on the VM  →  KDC on dc
 bastion (the host, per the core-lab note above)
```
Identity is a shared service, so it gets its own tier: the ACL and the DC's security
group allow only AD ports into it, and the data tiers stay isolated from each other.
The bastion needs no `alice` account; the SSH client side never checks her identity,
the VM does.

**DNS breaks first.** The domain is the **subdomain `ad.lab.test`** (realm
`AD.LAB.TEST`), not `lab.test`: an AD domain controller must be authoritative for its
own DNS zone, and `lab.test` already belongs to the lab's resolver. Members find the
DC through SRV records (`_ldap._tcp.ad.lab.test`, `_kerberos._udp.ad.lab.test`), which
Samba's internal DNS publishes automatically. The lab resolver **forwards** `ad.lab.test`
and the reverse zone to the DC, so members keep one resolver and every other name
resolves as before. The SSO step needs those PTR records, which closes the reverse-DNS
gap noted in `docs/decisions.md`.

**Image vs instance (Phase 3).** Bake trust, never identity:
- **Bake:** `sssd`, `sssd-tools`, `libnss-sss`, `libpam-sss`, `realmd`, `adcli`,
  `samba-common-bin`, `krb5-user`, `chrony`; the CA root; the `mkhomedir` PAM profile.
- **Never bake:** a completed join, `/etc/krb5.keytab`, `/etc/sssd/sssd.conf`, the SSSD
  cache, a hostname. A keytab is the machine's identity; every clone would authenticate
  as the same computer. A build check fails the image if `/etc/krb5.keytab` exists.

**Secrets (Phase 2, Vault):** `secret/ad/administrator` (used only to provision the DC),
`secret/ad/joiner` (the delegated join account), `secret/ad/test-users` (demo passwords for
`verify`). The domain administrator password never reaches a member VM.

**Enterprise hardening on top:**
- **One-time-password join:** pre-create each computer with
  `adcli preset-computer --one-time-password`, store the OTP in Vault per host, and join
  with `realm join --one-time-password`. That removes the joiner password from the VMs;
  the OTP is spent on use.
- **LDAPS / signing:** trust the lab CA on the DC and members; require LDAP signing.
- **MFA:** AD password login over SSH has none. Add it at the broker (Teleport/Boundary
  with OIDC) or with a PAM module; or federate authentik to AD as an LDAP source so
  web SSO and host login share one identity.
- **Cached credentials:** SSSD caches logins by default, so a disabled user may still log
  in while the DC is unreachable. Decide per tier (`cache_credentials = False` on the
  backend).
- **Churn:** ephemeral frontends must `realm leave` (or have their computer object
  deleted) on destroy, or AD fills with stale computer accounts.

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

---

## Live-run lessons (from the core-lab first run — engineer these in)

The first end-to-end `up` on a **non-pristine host** surfaced failures a fresh VM would
have hidden. Bake these in so the enterprise build (CI runners, re-used hosts) does not
repeat them.

1. **Preflight the apt state; fail fast and loud.** The vendored installer runs
   `set -euo pipefail`, so any apt source that makes `apt-get update` exit non-zero — a
   leftover `docker.sources` with an unexpanded `${UBUNTU_CODENAME}`, or a rotated
   HashiCorp key (`NO_PUBKEY`) — **silently kills the install** mid-run. Run a strict
   `apt-get update` preflight that dies naming the offending source *before* any heavy
   step, and make our own repo setup **always (re)install the signing key** rather than
   skipping because the `.list` already exists (keys rotate).

2. **A reused host's old `cloud` database is poison.** A prior install's
   `cloud`/`cloud_usage` with an older schema (e.g. missing
   `configuration.default_value`) makes the 4.22 management server loop on HTTP 503 and
   never become ready — and the installer tracker's `db_deployed=yes` makes a re-run
   **skip** redeploying, so it never self-heals. Teardown must drop the databases **and**
   delete the installer tracker; the enterprise build should assert schema/version
   compatibility (or always deploy fresh) before trusting an existing DB.

3. **All-in-one agent↔management startup is a race.** The KVM agent must not connect
   before the management API is serving. The readiness gate polls `/client/` for a real
   HTTP 200 (not just an open port), but systemd's default `TimeoutStartSec=90s` is
   shorter than the gate's wait budget, so on first boot — where management init takes
   minutes — the agent **start times out**. Raise `TimeoutStartSec` on
   `cloudstack-agent` above the readiness budget, gate on a 200 (not port-open), and
   expect multi-minute first-boot management init.

4. **Teardown must not depend on state it just deleted, and must be `set -e`-safe.**
   `restore_netplan` read the backup path from the tracker that `remove_files` had
   already deleted, and a lookup helper that returned non-zero on a missing key aborted
   `down` under `set -e` **before the reboot**. Rules: keep the netplan backup *outside*
   the repo and reference it **directly** (not via a tracker); make tracker/lookup
   helpers return success on "not found"; order teardown so network restore never
   depends on deleted markers; keep the reboot out of the reach of an earlier failure.

5. **Leftovers from prior runs cause silent, confusing failures.** Custom systemd
   drop-ins, `/usr/local/sbin` wait scripts, extra bridges, and third-party apt sources
   from earlier installs all bit us. Teardown must remove **everything** the lab and its
   vendored installer create; CI/enterprise runs should start from an
   **ephemeral/throwaway host or image** so no cross-run state exists, and/or run a
   preflight that refuses to proceed when prior-install artifacts are detected.

6. **Make provision idempotency health-based, not flag-based.** The core lab guards the
   install with a `cloudstack_installed=yes` tracker flag that is only written *after* a
   fully successful run — so a mid-run failure (e.g. the zone-deploy timeout) leaves the
   flag unset and re-runs re-enter the installer. The enterprise build should gate on
   **actual health**: skip provision only when the management API returns `200` **and** a
   deployed, Enabled zone exists **and** the required offerings are present. Pair this
   with lesson 2 — on a *fresh* provision (no installer tracker yet), **drop any
   pre-existing `cloud`/`cloud_usage` DB** so the installer can never inherit an ancient,
   un-migratable schema. (A fresh deploy seeds the DB at the `4.0.0` baseline and the
   management server migrates it to the target on first start; that migration is normal
   but can run long — gate on `200`, don't assume a fixed timeout.)

7. **Scripts invoked directly need the executable bit.** `cmd_image` ran
   `image-build-all.sh` directly; a freshly-authored file without `+x` fails with
   "Permission denied." Set `+x` on every script (git preserves it once committed) or
   invoke via `bash <script>`.

8. **A sourced helper must not set generic globals.** `cloudmonkey-install.sh` set
   `SOURCE_DIR`, which clobbered the `SOURCE_DIR` of the scripts that sourced it, sending
   `packer build` / `terraform -chdir` to the wrong directory. Give sourced files
   private variable names (e.g. `CMK_DIR`).

9. **Keep Packer's build target and `${path.root}` paths consistent with the layout.**
   Moving the `.pkr.hcl` files into a `hcl/` subdir broke both the build invocation and
   the `http_content` / `output_directory` paths. Point the build at the subdir and use
   `${path.root}/../…` for sibling dirs; add a build-skip when the artifact already
   exists locally (so a failed upload re-run doesn't rebuild or hit "output dir exists").

10. **The Chainguard `minio-client` entrypoint is `mc`.** `docker run <img> sh -c "…"`
    passes `sh` to `mc` ("not a recognized command"); override with `--entrypoint sh`.

11. **Terraform's cloudstack provider can't create an untagged shared network** — its
    `vlan` field is numeric, and a tagged VLAN isn't host-reachable on a flat LAN.
    Create the mgmt shared network out-of-band via `cmk` (`vlan=untagged`) and hand its
    UUID to Terraform as a variable.

12. **ConfigDrive userdata is delivered by the VM's default NIC's network.** With a
    ConfigDrive-pinned image, the default NIC's network offering must serve
    `UserData=ConfigDrive` or the SSH key never lands — shared networks default to
    VirtualRouter userdata, so create a shared offering with `UserData=ConfigDrive`.

13. **Pick the right Terraform inventory plugin.** `ansible_host`/`ansible_group`
    resources are read by `cloud.terraform.terraform_provider` (point `project_path` at
    the initialized project), NOT `terraform_state` (which only maps native cloud-instance
    types like `aws_instance`). Paths these plugins receive must be **absolute** (they run
    `terraform` from elsewhere), and `terraform_state` requires the config file be named
    `*terraform_state.yml`.

14. **SSH-launched background processes must detach all three stdio.** A long-running
    listener started over SSH hangs/aborts unless **stdin** is redirected too
    (`nohup … </dev/null >/dev/null 2>&1 &`), not just stdout/stderr.

15. **A WireGuard Endpoint must never fall within its own AllowedIPs.** Endpoint = peer
    tier IP while `AllowedIPs` covered that tier → the handshake routed *into* the tunnel
    and never completed. Run the tunnel transport over an underlay the tunnel does not
    route (here, the mgmt network); for the enterprise build use a **dedicated transit
    network** for the VPN underlay, separate from the data tiers and the admin network.

16. **Remote verification listeners must outlive the SSH session.** The `verify` demo
    service started over SSH with `nohup`/`setsid` didn't persist, so the "service
    reachable over the tunnel" check saw a connection-refused (RST) and failed. Start
    such helpers as **transient `systemd-run` units** (stopped on teardown) so they run
    independently of the SSH connection. (A fast `rc=7` refused vs. a `rc=28` timeout also
    distinguishes "no listener" from "firewall dropped it" — useful when debugging.)

**Meta-lesson:** the first batch (1–6) appeared only because the test host was *reused* —
so make "fresh, ephemeral host" a hard precondition (a dedicated CI runner image or a
disposable VM) with the preflight checks as the safety net. The rest (7–16) are build /
integration-design bugs to fix in code: tight CloudStack/Terraform/Ansible/WireGuard
integration has many sharp edges, so budget real end-to-end iteration and keep every
cross-tool assumption (paths, NIC defaults, userdata delivery, tunnel underlay) explicit.
