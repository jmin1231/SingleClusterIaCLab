# Design review — `PLAN-enterprise.md`

**Reviewer:** infrastructure tech lead
**Scope:** `PLAN-enterprise.md` only, reviewed on its own terms
**Target:** one nested VM — **32 GB RAM · 16 cores · 200 GB disk**

---

## Verdict

**Approve the architecture, block the build until five gaps are closed.**

This is a better plan than most production runbooks. It correctly identifies the hard
parts — the secrets/state bootstrap cycle, CloudStack's silent ACL race, ConfigDrive over
the VR metadata service, `AllowedIPs` as simultaneously a routing table and an inbound
ACL, the netplan destruction — and its enterprise-practice-to-local-realization mapping is
honest about what is a stand-in. The phase structure is sound and the `verify`/`demo`
split (machine-checkable versus human-readable, both non-zero on failure) is exactly right.

What it is missing is **operations**. The plan knows how to build the lab and how to
destroy it. It does not know how to *run* it. Specifically it has no resource plan, no
name resolution, no trust, no backup, and no answer to what happens when the host reboots
— which on a nested VM is a daily event, not an incident.

### Evidence for that claim

A vocabulary audit of the document:

| Term | Occurrences | Note |
|---|---|---|
| `RAM`, `memory`, `GB`, `vCPU`, `storage` | **0** | no resource plan of any kind |
| `CPU` | **0** | the 24 hits for "core" are all the `[core]` phase tag |
| `disk` | **1** | *"secrets never on disk in clear"* — not storage planning |
| `DNS` | **1** | an **egress allow-list entry**. No resolver exists in the plan |
| `TLS`, `certificate`, `proxy`, `nginx`, `CoreDNS` | **0** | no trust or ingress layer |
| `backup` / `restore` | 10 / 8 | **every one is netplan**, plus one Headscale caveat in Risks |
| `reboot` | 4 | **all four are in the teardown path** |
| `retention`, `prune` | 0 / 1 | nothing bounds growth on a 200 GB disk |
| `nested`, `overprovision` | **0** | the stated deployment model is unaddressed |
| `chrony`, `NTP`, `renew`, `break-glass` | **0** | — |
| `RTO` | **0** | `down` claims reversibility with no recovery objective |

---

## What the plan gets right — do not rewrite these

Listing these because a reviewer who only lists problems gets their good decisions
undone by the next revision.

1. **The two-phase secrets bootstrap.** Phase 0 local state → Phase 1 remote state in
   MinIO with secrets from Vault. The chicken-and-egg is named and solved, not hand-waved.
2. **Scoped `iac` account, not global admin**, with the exit criterion that a global-admin
   operation is *denied*. Asserting the negative is the part most people skip.
3. **`parallelism=1` on ACL rules.** This is hard-won knowledge — CloudStack drops
   concurrently-created ACL rules silently.
4. **Netplan backup outside the repo, restored with `netplan try`.** Correct on both
   counts: the purge cannot remove the backup, and `try` auto-reverts.
   **Independently verified:** the vendored installer runs
   `rm -f /etc/netplan/50-cloud-init.yaml` at line 2353 with no backup, and `netplan
   generate && netplan apply` — not `try` — at line 2355. This step is load-bearing.
5. **ConfigDrive over the VR metadata service**, which removes a dependency on the router
   being healthy at first boot.
6. **Default-deny egress with an allow-list**, and demonstrating a *blocked* destination in
   `verify`. The posture reviewers actually look for.
7. **Content-hash build skip** for images — idempotency at the artifact level, not just the
   script level.
8. **`AllowedIPs` asymmetry** in the hub-and-spoke section. The aggregate-on-spokes,
   specifics-on-hub explanation is the clearest statement of that mechanism I have read in
   a lab document, and the three-independent-layers argument (ACL deny, no peer, hub
   policy) is how segmentation should be reasoned about.
9. **Revert verification as a concept** — most teardown scripts are never checked at all.
10. **Risks section names the fragile step** (advanced-zone bring-up) rather than
    pretending the plan is smooth.

---

## The resource plan the document does not have

At 32 GB and 16 cores, **disk is the only binding constraint** — and the plan budgets
none of the three. Compute is comfortable; 200 GB is what decides how much of this plan
you can actually build.

### Memory — 32 GB, fits with real headroom

| Layer | Component | MB |
|---|---|---|
| Host | Ubuntu, kernel, libvirtd, NFS | 2,560 |
| Cloud | CloudStack management — **pin `-Xmx` to 2 GB** | 2,560 |
| Cloud | MySQL — trim `innodb_buffer_pool_size` to 512 MB | 1,024 |
| Cloud | Secondary Storage VM | 512 |
| Cloud | Console Proxy VM | 1,024 |
| Cloud | VPC virtual router | 512 |
| Cloud | mgmt shared-network router (see finding **F7**) | 512 |
| Control | Gitea + Postgres | 1,024 |
| Control | Vault | 256 |
| Control | MinIO | 512 |
| Control | CoreDNS + reverse proxy *(added — see **B1**)* | 128 |
| Control | Gitea runner + dind, idle | 512 |
| Guests | tier-a | 2,048 |
| Guests | tier-b | 2,048 |
| Guests | tier-mid, 3-tier variant | 1,024 |
| **Steady state** | | **≈16.2 GB** |
| Burst | CI job running in the toolbox | +1,536 |
| Burst | Observability — Prometheus + Grafana + Loki | +2,048 |
| Burst | **Packer build in flight** | +4,096 |
| **All of it at once** | | **≈23.8 GB of 32** |

**Finding: memory is no longer a constraint.** At 32 GB the full enterprise stack runs
*including* observability *and* a concurrent Packer build, with ~8 GB spare. Phase 7
observability should be promoted from `[ent, stretch]` to a normal phase — the budget
objection to it no longer exists.

**One rule survives: do not overcommit memory.** Set `mem.overprovisioning.factor = 1`.
Memory overcommit on a KVM host trades a scheduler error you can read for an OOM kill you
have to diagnose.

**Recommendation: disable swap on the host.** With 32 GB there is no capacity argument for
it, and it removes a real exposure — Vault runs with `disable_mlock` in most container
deployments, so its plaintext secrets can be paged to disk. Turning swap off is a
one-line mitigation for the plan's own principle (*"secrets never on disk in clear"*),
which is otherwise not true.

### CPU — 16 cores, comfortable, but set the factors deliberately anyway

The plan allocates, without ever counting:

| Consumer | vCPU |
|---|---|
| Secondary Storage VM | 1 |
| Console Proxy VM | 1 |
| VPC virtual router | 1 |
| mgmt shared-network router (**F7**) | 1 |
| tier-a | 1 |
| tier-b | 1 |
| tier-mid, 3-tier variant | 1 |
| **Guest allocation** | **6–7** |
| Host services — CloudStack JVM, MySQL, NFS, Docker control plane, under CI load | **3–4** |
| Packer build, when one is running | **+2** |
| **Worst realistic concurrency** | **11–13 of 16** |

**CPU is not a constraint at 16 cores** — 3 to 5 cores spare at the busiest moment the plan
describes. Two actions regardless:

- **Set `cpu.overprovisioning.factor` to 2 explicitly.** At 16 cores the default would
  happen to work for the plan exactly as written, and that is the problem: the first
  addition past it — a third tier, a domain controller, a second runner — reintroduces
  *"Insufficient capacity"*, which **blocks provisioning rather than degrading
  performance**. Phase 4.3's exit ("both VMs Running") becomes unreachable with no obvious
  cause, weeks after the decision that caused it. Set it because you decided it, not
  because it is incidentally fine.
- **Leave `mem.overprovisioning.factor` at 1.** Memory overcommit on a KVM host trades a
  scheduler error you can read for an OOM kill you have to diagnose.

**What 16 cores buys that 8 did not**, and worth spending:

| Spend it on | Effect |
|---|---|
| Runner `capacity: 2` | parallel CI jobs, so lint/scan/policy do not queue behind each other |
| 4 cores to the Packer build | partially offsets nested overhead on the slowest step in the plan |
| The 3-tier topology | tier-mid and its router stop being a budget question |
| **A domain controller VM** | the identity plane in **F14** becomes buildable rather than aspirational — see that finding |

**Nested overhead is unchanged: still budget 2–3×.** Core count does not help a
mostly-serial installer, and L2 VM exits still trap through L1's KVM to L0. More cores make
the lab hold more, not run faster.

**Budget 2–3× the plan's time estimates.** Nested L2 guests trap VM exits through L1's
KVM to L0. The plan's "~40 minutes" for CloudStack is a bare-metal figure; expect 90+
minutes, and expect Packer builds to be slow enough that the content-hash build skip
(3.3) moves from a nice-to-have to the thing that makes iteration tolerable.

### Disk — 200 GB, and now the only thing that constrains the design

With memory and CPU both comfortable, **disk is what decides how much of this plan gets
built.** Two scenarios, because the identity plane in **F14** is now affordable on compute
and lands entirely here.

| Consumer | GB |
|---|---|
| Ubuntu + apt + journald | 15 |
| Docker images — toolbox is 3–4 GB alone, plus Gitea, PG, Vault, MinIO, nginx, dind, Prom/Grafana/Loki | 25 |
| Docker volumes — Gitea repos and packages, Postgres, MinIO, Loki chunks | 20 |
| CloudStack secondary storage — system VM template | 3 |
| CloudStack secondary storage — our templates, 2 versions | 6 |
| CloudStack primary storage — 4–5 thin VMs, realistic growth | 70 |
| Packer — Ubuntu ISO cache | 3 |
| Packer — build and output qcow2, transient | 12 |
| MinIO — image versions, **a second copy of each** | 6 |
| MinIO — Terraform state, versioned | <1 |
| Container logs | 4 |
| **Subtotal — plan as written** | **≈164** |
| **Margin** | **≈36**, and qcow2 files only grow |
| | |
| *Plus* a domain controller VM — primary storage + its backups (**F14**) | +20 |
| *Plus* a third tier VM, if tier-mid is in the core (**F8**) | +15 |
| **Subtotal — plan plus identity and 3 tiers** | **≈199 of 200** |

**That second row is the finding.** 16 cores and 32 GB make the full enterprise build —
three tiers, a domain controller, observability, CI — comfortable on compute and
**impossible on disk**, at 199 GB of 200 with no margin and qcow2 files that only grow.

So the retention policy below stops being hygiene and becomes **the gating requirement for
scope**. With it, the full build fits with ~40 GB spare. Without it, the plan as written
runs out of disk somewhere around week three, and the symptom will be CloudStack failing to
start a VM for reasons that look nothing like a full filesystem.

**Finding (F1): every golden image is stored twice, and nothing prunes either copy.**
Step 3.3 publishes the qcow2 to MinIO `images/<version>/` with a `latest` pointer; step 3.4
registers it in CloudStack *by URL*, which makes the SSVM **download and keep its own copy**
in secondary storage. Versioned retention is explicit in 3.3 and no step deletes anything.
At ~3 GB per image that is 6 GB per version, unbounded.

**The plan has no retention policy for anything.** Required additions:

| What | Policy |
|---|---|
| MinIO image versions | keep newest 2, delete on publish |
| CloudStack templates | delete the superseded template when registering a new one |
| Registry of record | **pick one.** MinIO holds versions; CloudStack holds only `latest`. Do not version in both |
| CI-built container images | delete every run, with `if: always()` — a failed job must still clean up |
| Docker logs | `log-opts` with `max-size` and `max-file` on **every** service. The default `json-file` driver has **no size limit**, on a disk shared with CloudStack's storage |
| journald | cap `SystemMaxUse`, and set `SystemKeepFree` sized for CloudStack rather than for journald |
| Packer | cache the ISO outside the repo tree and reuse it; `packer_cache/` is not a build artifact |
| Thin volumes | enable `discard`, and run `fstrim` periodically, or thin provisioning only ever grows |

**Check the host's own layout before trusting any of this.** Ubuntu's installer defaults to
an LVM layout that sizes the root logical volume well below the disk and leaves the rest of
the volume group **unallocated**. Run `df -h /`, `vgs`, `lsblk` on the target first; if
there is unallocated space, fix it in the install-time storage layout so the machine is
born correct rather than growing it later.

---

## Nested virtualization — the deployment model the plan does not address

The plan says *"Packer needs `/dev/kvm` — present here; confirm on any target VM."* That
materially understates it. **Every CloudStack guest is an L2 nested VM** — the Secondary
Storage VM, the Console Proxy VM, the virtual router and every tier VM. Nested
virtualization is not a Packer prerequisite; it is a prerequisite for the control plane to
reach a usable state at all.

**Finding (F2): there is no nested-virt verification procedure, and it cannot be fixed
from inside the guest.** Get it wrong and you rebuild the VM. Add this as step 0.0, before
anything else runs.

**On L0, before the lab VM is created** — platform-specific, and none of it settable later:

| L0 platform | What to set |
|---|---|
| VMware Workstation / ESXi | *Virtualize Intel VT-x/EPT* (or *AMD-V/RVI*); `vhv.enable = "TRUE"` in the `.vmx` |
| KVM / libvirt | `<cpu mode='host-passthrough'/>`, and `kvm_intel nested=1` / `kvm_amd nested=1` on L0 |
| Proxmox | CPU type `host` |
| Hyper-V | `Set-VMProcessor -ExposeVirtualizationExtensions $true`, **and disable Dynamic Memory** |
| Windows host, any | Hyper-V and WSL2 claim the hypervisor — disable them or nothing else gets VT-x |

**Inside L1, as a gate:**

```sh
egrep -c '(vmx|svm)' /proc/cpuinfo          # > 0
ls -l /dev/kvm                              # exists
kvm-ok                                      # "KVM acceleration can be used"
cat /sys/module/kvm_intel/parameters/nested  # Y  (or kvm_amd)
```

**And the real test, which is behavioural:** boot one throwaway L2 guest with
`virt-install` and confirm it reaches a login prompt *before* starting a 90-minute
CloudStack install. The plan's current first proof of nested virt is CloudStack's system
VMs coming up, which is 90 minutes and several thousand lines of installer into the run.

**Also:** do not assign all of L0's cores to L1. 16 for the lab VM means the physical host
wants ~20 to be comfortable — otherwise L1's scheduler competes with the hypervisor that is
emulating it, and the symptom is uniform slowness nobody can attribute.

---

## Blocking gaps

### B1 · No DNS, no CA, no reverse proxy — and four phases assume all three

Zero mentions of TLS, certificate, proxy or CoreDNS. The single DNS mention is an egress
allow-list entry. Yet the plan requires:

- 2.1 — MinIO *"reachable from the CloudStack SSVM network"*
- 2.2 — `vault kv get` over an API
- 2.3 — a runner cloning a repo mirror
- 3.4 — **`registerTemplate` by URL**
- 4.1 — a Terraform `s3` backend pointed at MinIO

Every one needs a resolvable name and a certificate a client will accept. Without them
each becomes an IP literal plus `curl -k`, which is not an enterprise-shaped anything, and
CloudStack in particular has **no HTTPS listener of its own** — its admin password crosses
the bridge in cleartext on every login until something terminates TLS in front of it.

**Add a phase between 1 and 2:** CoreDNS authoritative for the lab domain → Vault →
Vault's PKI as the lab's only CA → a reverse proxy terminating TLS for everything. Then
give 2.1, 2.2 and 2.3 reachability exit criteria, which they currently lack entirely.

### B2 · `down` cannot work, because CloudStack has no uninstaller

Step 9.2 reads as one line: *"CloudStack uninstall (services, VMs, DB, packages, config,
NFS, drop-ins, repo, `cmk`)."*

**Verified:** the vendored installer has no uninstall path. All 70 of its functions are
install or query; `cleanup()` at line 2622 is an exit-trap that prints and removes
nothing. So 9.2 is a from-scratch build of a destructive script for software that rewrote
the host's networking — the largest single piece of unestimated work in the document,
presented as a bullet.

**Split it**, and size it honestly. It will take longer than Phase 4.

### B3 · `down` reboots and then verifies, so it cannot be one process

The command map says `down` → *"… restore netplan → reboot → **verify revert**."* A
process cannot verify anything after rebooting the machine it runs on. The revert check
needs to be a second, resumable stage — a `down --verify` invocation or a systemd oneshot
that fires on the next boot.

### B4 · Teardown destroys by default, and has nowhere to report what it cannot revert

`down` is specified as a command that acts. For a script whose failure mode is *losing the
host's network configuration*, that is the wrong default: **dry-run by default, `--yes` to
act.** A script that printed when you wanted it to act costs one re-run; one that acted
when you wanted it to print costs the lab.

Worse, 9.3 verifies by asserting absence — no packages, no zone, netplan byte-identical,
bridges gone. **That passes while missing everything nobody thought to list**, which is
precisely the failure mode a teardown has. Two changes:

- Classify every artifact *before* writing the line that removes it: **reversible**
  (installer made it, remove it) / **reconstructable** (installer destroyed prior state,
  rebuild or refuse) / **shared** (predates the lab, leave it) / **unrecoverable** (edited
  in place over unsaved values — **report, never guess**). The sharpest case: the inverse
  of *created `01-bridge-cloudbr0.yaml`* is **not** *delete it*; do that and the host has
  no network configuration at all. The installer also edits `libvirtd.conf` in place and
  appends to `/etc/default/*` only when absent, so a present value cannot be attributed —
  those belong in the unrecoverable bucket with a report, not in a silent revert.
- **Verify by loop, not by checklist:** snapshot the VM → `up` → `down --yes` → `up`. The
  second `up` must come up green and match the first. That catches what a list of paths
  cannot, and the snapshot means a failed run costs nothing.

### B5 · Nothing is backed up except netplan

Ten mentions of backup, all netplan, plus one buried Risks caveat about Headscale's
Postgres. Unbacked-up state that the plan creates and depends on:

| State | Why losing it hurts | Recovery without a backup |
|---|---|---|
| **CloudStack's MySQL** | the zone, pod, cluster and host were built by an *installer*, not declared in Git — **that database is their only definition** | re-run the 90-minute installer |
| Terraform state in MinIO | **MinIO is on the teardown critical path** — lose it and `terraform destroy` cannot run, which breaks the reversibility the whole design rests on | import every resource by hand |
| Vault | every credential in the lab | re-seed everything, rotate everything downstream |
| Vault's unseal key | **it is not in Vault — it cannot be** | the Vault backup is ciphertext and worthless |
| Headscale's Postgres (if used) | holds nodes, keys and ACL state — it *is* the mesh | re-register every node by hand |
| MinIO image objects | the golden image | rebuild via Packer |

The plan's own principle is *"secrets never on disk in clear — Vault issues them at run
time."* That is not achievable for the unseal key, which must be on disk for an unattended
`up` to work. **Say so explicitly** and protect it with file mode and a documented
location, rather than leaving a principle in the document that the implementation
contradicts.

**Add a backup phase with an RPO and a measured RTO**, separate from teardown. An untested
backup is a hypothesis. `down`/`up` is not a DR drill — it destroys deliberately; DR is
about destruction you did not choose.

---

## Significant gaps

### F3 · There is no resume story, and on a nested VM that is a daily event

"Reboot" appears four times, all in the teardown path. Nothing covers the host restarting
— which for a VM on someone's workstation happens constantly, including from suspend.

After a host reboot, the plan's lab is in this state and nothing addresses any of it:

- **Vault is sealed.** It is running, listening, and answering every request `503`.
  `docker ps` shows healthy. The first symptom is some unrelated service failing to read a
  secret. Unsealing is manual and needs the unseal key — the plan mentions "unseal" once,
  in a Phase 2.2 parenthesis, and never as an operation.
- **CloudStack's system VMs and the virtual router** must be restarted, and the agent must
  reconnect. Until it does, the host sits in `Alert` and every API call touching a guest
  fails — with errors that point at the guest, not at the host.
- **Container start order** is undefined. The proxy resolves Gitea's container name at
  startup and will fail if it comes up first.
- **`tailscaled` / WireGuard** must re-establish; `wg-quick@wg0` enabled handles this, and
  the plan does say so — credit where due.

**Add a `resume` subcommand** beside `up` and `down`: unseal Vault, wait for the
hypervisor agent, assert the system VMs and router are running, bring containers up in
dependency order, re-run `verify`. Without it, every reboot is a manual recovery, and the
`status` subcommand will cheerfully report a database's opinion rather than reality.

### F4 · Secret zero is unaddressed

Step 8.1: *"the runner reads secrets from Vault via AppRole."* An AppRole needs a role-id
*and a secret-id* — so the runner needs a credential in order to get credentials. The plan
does not say where that one comes from, and it is the only credential in the design that
cannot itself be issued at run time.

Name the mechanism and its trust boundary: a secret-id delivered at runner provisioning
time, a response-wrapped token with a short TTL, or Vault Agent auto-auth. Any is
defensible; silence is not, because the default is a long-lived secret-id pasted into
Gitea — which is exactly the *"no long-term keys in Gitea"* outcome 8.1 claims to avoid.

### F5 · Certificates are issued and never renewed

No mention of renewal. Everything the plan builds gets a certificate from Vault's PKI and
then expires unattended, including the one on the service every other service
authenticates to. A proxy also reads its config once at start, so a reissued certificate
sits on disk, visible inside the container, **ignored** until something reloads it.

Add a renew-and-reload mechanism and an expiry alert. Without the reload hook, renewal is
a cron job that changes nothing.

### F6 · CloudStack's ACLs are stateless, so the egress allow-list will not work

Step 4.2 specifies *"default-deny egress with an allow-list (DNS, updates, WireGuard)."*
CloudStack network ACLs are **stateless**: permitting outbound traffic does not permit the
reply. The allow-list as written produces a tier that can send and never receive, and the
symptom looks like an application hang.

Add explicit return-traffic rules on the ephemeral port range. This also interacts with
Phase 7: Prometheus **scrapes**, so it needs an *inbound* rule on every VM — the opposite
direction from everything that pushes. Write the push rules first; they go one direction
and they work.

### F7 · The mgmt "bastion" is a flat network, not a bastion — and it probably costs a router

Step 4.2 adds a *"mgmt/bastion shared network on `cloudbr0`"* and 4.3 gives both VMs a mgmt
NIC. Two problems:

- **There is no bastion.** A bastion is a jump host with its own access controls and
  session logging. A shared network every VM has an interface on is a flat management
  plane — which is a legitimate lab choice, but calling it a bastion overstates the
  control, and the out-of-band claim in the architecture diagram does not hold if anything
  on `cloudbr0` can reach every tier directly.
- **An advanced-zone shared network normally gets its own virtual router**, which is
  another vCPU and another 512 MB that the plan does not count. Use an L2 offering if a
  router is not wanted, and either way say which.

### F8 · The plan contradicts itself on `10.0.3.0/24`

The hub-and-spoke section (line ~344) uses `tier-mid 10.0.3.0/24 (HUB)`. The
Tailscale section fifty lines earlier uses `10.0.3.0/24` as the **backend**. The overlay
range `10.99.0.0/24` appears in the WireGuard section and nowhere else. Settle one address
plan, write it in one table, and check it against the ranges that allocate *automatically*
and therefore collide silently — Docker's `172.17.0.0/16` onward, and CloudStack's
link-local `cloud0`.

Also: the plan's core is **2-tier** while its two VPN variants are both **3-tier**. Decide
whether tier-mid exists in the core, because it changes the ACLs, the VM count and the
vCPU budget.

### F9 · The policy gate exists only on the CI path

6.3 gates Conftest/OPA over `terraform plan -json` *"before apply"*, and 8.1 wires it into
the pipeline. But 4.1's `bootstrap.sh setup` runs plan→apply directly — so the local path
bypasses the gate, while the Principles section claims *"`bootstrap.sh` is the local/dev
path that runs the identical logic."* Make `setup` call the same `policy` script and refuse
to apply on a violation.

### F10 · Signing is specified without verification, and the image bucket's exposure is unstated

3.2 produces a Trivy gate and a Syft SBOM but no signature; nothing anywhere verifies an
artifact at the point of use. A signature nobody checks is decoration — but so is a scan
whose result is not bound to the artifact that gets deployed. Add signing, and state
plainly that nothing yet verifies it, rather than leaving the gap unmarked.

Related and more urgent: **3.4 registers the template by URL, and CloudStack's SSVM fetches
that URL with no credentials.** So either the images bucket allows anonymous read — meaning
**your VM images are readable by anything on the lab network** — or the credential is
embedded in the URL, where it lands in CloudStack's database *and its logs*. The plan
chooses neither. Choose one deliberately and write the ADR; this is the kind of thing that
is discovered during a review rather than decided during a design.

### F11 · `root` SSH is enabled in 1.1 and never closed

1.1 enables root login with a password because CloudStack adds the KVM host over SSH even
when that host is itself — and the exit criterion *asserts the hole is open*
(`sshd -T` shows root+password). No later step closes it. Add a close step once the host is
added, and keep `sshd -T` as the assertion: `sshd -t` only checks syntax, and the **first**
value wins across drop-ins, so a lower-numbered file silently outranks yours.

### F12 · CloudStack 4.22 is pinned in the Tools table and is broken upstream

The Tools table specifies *"Apache CloudStack 4.22."* That is the installer's own default
and the repository's signed `Release` for noble has been internally inconsistent — apt
refuses the index and exits 100. **4.21 installs cleanly.** Pin 4.21 and prove the
component yields an installable package *before* the 90-minute install rather than during
it. The plan's own "Pinned" principle is right; the version chosen is not.

### F13 · No time synchronisation

Zero mentions of chrony or NTP. A skewed clock fails `apt-get update` with *"Release file
is not valid yet"*, which reads like a network fault; it also breaks TLS validation and
every token with an expiry. It becomes a hard dependency the moment any directory service
appears. Sync it in Phase 1 and **wait for convergence** — there is a window where
`timedatectl` has not yet reported synchronised.

### F14 · No identity plane at all, which is the largest missing enterprise capability

The plan has workload identity (Vault AppRole) and a scoped cloud account. It has **no
human identity**: no central accounts, no central sudo policy, no SSO, and no answer to
*"who may log into the backend tier"* other than who holds an SSH key placed by Ansible.
Keycloak appears only as an optional row in the 2026 tools table.

For a mock-*enterprise* build this is the conspicuous gap — identity is usually the first
thing an enterprise reviewer asks about and the last thing a lab builds. It is a legitimate
scope decision to defer it, but it should be an explicit one with the shape written down,
because retrofitting it touches DNS (SRV records, **and reverse DNS, which this lab has
none of** — Kerberos reverse-resolves and fails with an error naming the *principal*, so
the search starts in the wrong place), time, the golden image, and every service's auth
configuration.

If it is in scope, it is two planes, not one: a directory with a KDC for **host** login,
and an OIDC broker federated from it for **service** login. An OIDC provider alone cannot
join a VM to anything.

**At 16 cores and 32 GB, this is now buildable rather than aspirational** — a domain
controller is 1–2 vCPU and 2 GB, both of which are spare, and an OIDC broker with its
database is another 1 GB. The constraint has moved: **it costs ~20 GB of disk**, which the
budget above shows is the scarce resource. So the decision is no longer "can the host carry
it" but "is it worth a tenth of the disk" — and that is a scope conversation, which is the
right shape of question to be having.

Two prerequisites it would add, both cheap now and expensive later, and both currently
absent from the plan: **reverse DNS zones** built alongside the forward zone in **B1**, and
**time synchronisation** from **F13** with the controller as the authoritative source for
domain members. Kerberos rejects tickets outside five minutes of skew and the error says
nothing about time.

---

## Recommended changes to the phase order

| | Change | Why |
|---|---|---|
| 1 | **New 0.0 — nested-virt gate** | F2. Cannot be fixed later; boot one throwaway L2 guest before a 90-minute install |
| 2 | **New Phase 1.5 — DNS, CA, proxy** | B1. Four later phases assume all three |
| 3 | **Vault before MinIO** (swap 2.1 and 2.2) | MinIO's root credential should be *generated in* Vault, and its certificate *issued by* Vault. As ordered, neither is possible |
| 4 | **Capacity settings into Phase 1.2** | Set both overprovisioning factors with the zone, not after `Insufficient capacity` blocks 4.3 |
| 5 | **Split 9.2** | B2. The uninstaller is a phase, not a bullet |
| 6 | **New phase — backup and restore**, before teardown | B5. With an RPO and a measured RTO |
| 7 | **New `resume` subcommand** | F3. The lab's most frequent real operation is absent from the command map |
| 8 | **Promote Phase 7 observability** out of `[ent, stretch]` | 32 GB and 16 cores both afford it; the budget objection is gone |
| 9 | **A retention policy, in Phase 0** | At 16 cores the full build fits on compute and **not on disk** (199 of 200 GB). Retention is no longer hygiene — it is what decides scope, so it belongs before anything starts writing artifacts |

---

## What I would cut

Compute is no longer the reason to cut anything — **disk is.** These earn the least
against their cost in gigabytes and in complexity:

- **One VPN mechanism, not three.** The document specifies WireGuard point-to-point,
  WireGuard hub-and-spoke, *and* Tailscale/Headscale. Pick one for the build and keep the
  others as ADRs. Headscale adds a Postgres that *is* the mesh; raw WireGuard adds stale-peer
  pruning on every VM rebuild. Either is defensible; building two is not.
- **The second golden-image store.** F1 — one registry of record, versioned in one place.
- **`[ent]` steps that do not gate anything**: a Syft SBOM nothing consumes, and the
  redundant VPC offering. At 16 cores the resource objection to the second router is gone —
  but it still buys an HA property that a **single-host** lab cannot demonstrate, because
  both routers in the pair land on the same hypervisor. Keep the note as an ADR explaining
  why it was declined; that is worth more than the offering.

What I would **not** cut, despite cost: the scoped `iac` account, default-deny ACLs,
remote state with locking, and the revert verification. Those four are the reason this
reads as enterprise-shaped rather than as a lab with extra steps.
