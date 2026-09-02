# Resource Budget

**16 GB is a hard ceiling.** Not a target, not a guideline — the number the
target VM has. Everything this lab eventually runs does not fit at once, and at
16 GB it does not even fit *mostly*. This document decides in advance what runs
when, so the constraint is met by plan rather than discovered as an OOM kill
mid-phase.

Target VM: **16 GB RAM · 12 vCPU · 200 GB disk.**

> **Superseded numbers.** This document previously assumed a 32 GB ceiling and a
> ~20 GB baseline. At 16 GB that baseline is 4 GB **over the ceiling** before the
> k3s agents, authentik, or any image build. The old plan did not fit; the whole
> budget below is a rewrite, not an adjustment.

> **The development host is not the target.** It has 125 GB of RAM, 40 cores and
> a 457 GB disk — eight times the memory. Nothing built and tested there will
> ever exercise this constraint. Run the lab inside a 16 GB / 12 vCPU / 200 GB
> guest on that host (nested virtualization; `check_kvm` already handles it), or
> every "it works" is measured on a machine that cannot reproduce the binding
> limit.

## The memory budget

Every figure in the *estimated* column is a planning guess. Replace them with
real numbers as each component comes up — an estimate that looks authoritative is
worse than one that admits what it is.

Measure with `free -m`, `docker stats --no-stream`, and `virsh dominfo <vm>`.

| Layer | Component | Estimated | Measured |
|---|---|---|---|
| Host | Ubuntu + KVM/QEMU overhead | ~2.0 GB | |
| Cloud | CloudStack management server (JVM, heap pinned — see rule 1) | ~2.0 GB | |
| Cloud | MySQL (buffer pool trimmed) | ~0.5 GB | |
| Cloud | Secondary storage VM + console proxy (512 MB each) | ~1.0 GB | |
| Cloud | VPC virtual router | ~0.5 GB | |
| Control plane | Gitea + PostgreSQL, MinIO, Vault, CoreDNS, proxy, runner idle | ~1.5 GB | |
| Control plane | Alloy on the host, scraping journald (L-6) | ~0.15 GB | |
| Guests | frontend tier (768 MB) + tunnel tier (512 MB — see rule 6) | ~1.25 GB | |
| **Fixed subtotal** | | **~8.9 GB** | |
| Guests | backend tier (k3s + workloads) | **5.1 GB** | |
| **Baseline** | | **~14.0 GB** | |
| Reserve | page cache, kernel, burst | ~2.0 GB | |
| **Committed** | | **~16.0 GB** | |

There is no headroom. That is the finding, not a formatting accident.

### What does not fit any more

| Was budgeted | Now |
|---|---|
| backend tier at 8 GB | **5 GB.** The single line that broke the budget |
| two k3s agents at 3 GB | **impossible while the estate is up** — see rule 3 |
| authentik at +2 GB | **impossible alongside monitoring** — see rule 4 |
| a replicated/distributed Postgres | **single StatefulSet**, as build-order 12.1 always specified. Replicas were never budgeted and the tier has no room for them |
| Packer build at +3–4 GB | **only with the estate stopped** — see rule 5 |

## Five rules this implies

1. **CloudStack's JVM heap is pinned, not defaulted.** Set `-Xmx` in
   `/etc/default/cloudstack-management` rather than letting the JVM size itself
   against host RAM. An unpinned heap on a 16 GB host will happily claim several
   GB it does not need, and it claims it from the tiers.

2. **The backend tier is 5.1 GB and every workload in it is sized deliberately.**
   Nothing in Phase 9–13 may be installed at chart defaults. Prometheus retention
   and scrape interval, Loki in single-binary mode with filesystem storage, and
   Kyverno's controller count are all budget decisions, not tuning. Rough split:
   k3s ~0.8, Flux ~0.3, cert-manager ~0.15, ESO ~0.1, Kyverno ~0.4, **NGINX
   Gateway Fabric ~0.2**, Postgres ~0.3, api + web ~0.3, **kube-prometheus-stack
   ~1.4** (Prometheus, Alertmanager, kube-state-metrics, node-exporter and the
   operator — *not* the ~1.0 a bare Prometheus would cost), Grafana ~0.2, Loki
   ~0.5, Alloy ~0.15. That totals **~4.8 GB in a 5.1 GB tier**, leaving ~0.3 GB
   for the guest's own kernel and userland. It closes, and only just.

   **The correction that made it close:** an earlier version of this list said
   "Prometheus ~1.0" and omitted NGINX Gateway Fabric entirely. 13.1 installs a
   *stack*, and 13.3 configures an Alertmanager receiver — so Alertmanager,
   kube-state-metrics, node-exporter and the operator were always going to be
   there, unbudgeted, to the tune of ~0.6 GB. A single Postgres rather than a
   replicated one is what absorbs that; build-order 12.1 specified exactly that
   from the start, so this costs nothing against the written plan.

3. **k3s agents (9.2) do not coexist with the full estate.** Two 3 GB agents were
   the old plan and there is no 6 GB to give them. Either size them at ~1 GB and
   accept they demonstrate scheduling rather than capacity, or treat 9.2 as a
   *scheduled exercise*: stop what rule 5 stops, add agents, observe placement,
   remove them. Write down which, because "add two agents" no longer means what
   it did.

   **And the CNI is now part of that number.** 9.1 replaces flannel with Cilium,
   whose agent runs on *every* node — including these. On a 1 GB agent a
   few hundred megabytes of CNI is a large fraction of the node, not a rounding
   error. Measure `kubectl top pod -n kube-system` straight after 9.1 and put the
   real figure here. If it does not fit, 9.1 names the fallbacks in order: Calico,
   then k3s's built-in kube-router controller — which costs almost nothing and
   shows you nothing.

4. **authentik (14.1) and the monitoring stack (13.x) do not run together.**
   Roughly 2 GB against roughly 2 GB with nothing spare. Phase 14 means stopping
   monitoring first. This is the clearest case of the whole document's point: the
   phases are a *schedule*, not a set of things that end up co-resident.

6. **The tunnel tier is 512 MB, not 768.** WireGuard is in-kernel and the tier
   routes rather than computes. The 256 MB this frees goes to the backend tier,
   which is the only place in the budget where 256 MB decides whether something
   installs. Verify with `free -m` inside the guest once 8.3 is up; raise it back
   only against a measurement.

7. **kube-prometheus-stack is pinned or it does not fit.** Retention and scrape
   interval are the two knobs that matter, and both must be set before first
   install rather than tuned after an OOM. Left at chart defaults the stack
   drifts past ~2 GB and takes the tier with it.

5. **Never run an image build with the estate up.** Phase 6 happens before the
   agents exist, which is convenient rather than accidental. Any *rebuild* later
   needs the stop-order applied first — and at 16 GB that is mandatory, not
   prudent.

## Stop-order

Ordered by **blast radius, not by size**. The question is not "what is biggest"
but "what can go away without taking something else with it".

| Order | Stop | Frees | Why it is safe |
|---|---|---|---|
| 1 | k3s agents, if any are running | ~1–2 GB | Workloads reschedule onto the server. Nothing depends on a specific node. |
| 2 | authentik | ~2 GB | Only human logins route through it. Machine authentication — Flux, ESO, CI — deliberately does not, so nothing automated notices. |
| 3 | Monitoring stack | ~2 GB | Visibility is lost while it is down, which is a real cost; nothing breaks. Prometheus and Loki both resume on restart. |
| 4 | Gitea + runner | ~0.9 GB | **New at 16 GB.** Nothing deploys while it is down and Flux reconciliation fails quietly — the worst failure mode available — so this is emergency-only and never routine. |

The first three free ~5–6 GB with no functional loss beyond observability. The
fourth is the line where it starts to hurt, which is the point of listing it.

## Do not stop

| Component | Why not |
|---|---|
| **Vault** | Small footprint, large blast radius. It **seals on restart** — bringing it back needs the unseal key, and until then ESO stops refreshing every secret in the cluster. |
| **Backend tier VM** | It is the entire cluster — and from Phase 13 it is also where Loki lives, so stopping it blinds the thing you would use to find out why. |
| **CloudStack management server** | Running VMs survive without it — the data plane is independent — but nothing can be created, destroyed or reconfigured. |
| **CoreDNS** | Every name in the lab, including the ones the cluster resolves. |

## The disk budget

200 GB is the floor the old document named as a minimum, with no margin above it.
Memory is still the binding constraint, but disk is contended by the same
components and fails in a way that does not mention disk.

| Consumer | Estimated | Note |
|---|---|---|
| Ubuntu + packages + Docker images | ~30 GB | containerd grows with every CI build |
| CloudStack secondary storage | ~30 GB | system VM template, your templates, snapshots |
| CloudStack primary storage | ~60 GB | three tier VMs, thin-provisioned but growing |
| journald | 2 GB | capped by `SystemMaxUse` (L-5) |
| Bootstrap transcripts | <1 GB | newest 20 kept (L-4) |
| **Subtotal** | **~123 GB** | |
| Transient | +10–20 GB | a Packer build in flight, plus its output image |

That leaves roughly 60 GB of margin, and qcow2 files only grow. Two consequences:

- **CI must delete its built images every run**, with `if: always()`. The
  reference lab does this because the disk is shared with CloudStack storage; at
  200 GB it stops being good practice and becomes required.
- **`SystemKeepFree=20G` (L-5) is doing real work.** It reserves space for
  CloudStack, not for journald.

### Verify the disk is actually 200 GB

**Open question, and it invalidates the table above if it goes the wrong way.**
Subiquity's default LVM layout sizes the root logical volume well below the disk
and leaves the rest of the volume group **unallocated** — `build-order.md` §6.2
documents exactly this for the Packer guest image, and nobody has applied it to
the host. The development host is a plain partition and does not exercise it.

On the target VM, before trusting any figure here:

```
df -h /      # is / actually ~200 G?
vgs          # unallocated extents in the volume group?
lsblk        # LVM or a plain partition?
```

If it is LVM with unallocated space, fix it where §6.2 says to fix the guest — in
the install-time storage layout, so the machine is born correct — not by growing
it later.

## CPU

12 vCPU is not the binding constraint and no rule here is about it. One mechanism
to know: CloudStack refuses to deploy a VM once allocated memory exceeds host
capacity × `mem.overprovisioning.factor` (defaults to 1.0 — verify on 4.21), and
it reserves a slice for the host on top. So tier sizing is enforced by a
scheduler that reports "insufficient capacity", not discovered as an OOM. That is
better — it fails clearly — but it means the tiers must be planned before the
zone is deployed, not adjusted afterwards.

## The scenario this exists for

**Rebuilding a VM image once the cluster is up.** A Packer build wants 3–4 GB
transiently at a point where the estate has none.

Written down so it is not improvised at the moment memory runs out: **stop the
k3s agents, then authentik, then monitoring** — stop-order 1 through 3 — before
starting the build. That frees ~5–6 GB. Restart them afterwards; workloads
redistribute on their own.

At 32 GB this was contingency planning. At 16 GB it is the procedure.
