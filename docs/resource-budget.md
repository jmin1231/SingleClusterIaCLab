# Resource Budget

**32 GB is a ceiling, not a target.** Everything this lab eventually runs does not
fit at once. This document decides in advance what runs when, so the constraint
is met by plan rather than discovered as an out-of-memory event mid-phase.

## The budget

Every figure in the *estimated* column is a planning guess made before the host
existed. Replace them with real numbers as each component comes up — an estimate
that looks authoritative is worse than one that admits what it is.

Measure with `free -m`, `docker stats --no-stream`, and `virsh dominfo <vm>`.

| Layer | Component | Estimated | Measured |
|---|---|---|---|
| Host | Ubuntu + KVM/QEMU overhead | ~2 GB | |
| Cloud | CloudStack management server (JVM) | 2–4 GB | |
| Cloud | MySQL | ~1 GB | |
| Cloud | Secondary storage VM + console proxy | ~2 GB | |
| Cloud | VPC virtual router | ~1 GB | |
| Control plane | Gitea + PostgreSQL | ~0.7 GB | |
| Control plane | MinIO, Vault, CoreDNS, proxy | ~0.6 GB | |
| Control plane | CI runner, idle | ~0.2 GB | |
| Guests | frontend + tunnel tiers | ~2 GB | |
| Guests | backend tier (k3s server) | 8 GB | |
| **Baseline** | | **~20 GB** | |
| Later | two k3s agents, 3 GB each | +6 GB | |
| Later | authentik (server, worker, postgres, redis) | +2 GB | |
| Transient | a Packer build in flight | +3–4 GB | |

Baseline leaves roughly 12 GB of headroom. Adding the agents and authentik puts
the total near 28 GB before page cache and before any CI job runs — an image
build on top of that is what tips it over.

## Three rules this implies

1. **k3s agents are sized 2–3 GB, not like the backend.** They exist to make
   scheduling observable, not to add capacity; two 3 GB nodes teach everything
   two 8 GB nodes would. At 8 GB each they would put the total 6 GB over the
   ceiling before authentik exists.
2. **Never run an image build with the full estate up.** Phase 6 happens before
   the agents exist, which is convenient rather than accidental. Any *rebuild*
   later needs the stop-order applied first.
3. **authentik is the last thing started and the first thing stopped.** It is
   the largest optional consumer and only Phase 14 needs it running.

## Stop-order

Ordered by **blast radius, not by size**. The question is not "what is biggest"
but "what can go away without taking something else with it".

| Order | Stop | Frees | Why it is safe |
|---|---|---|---|
| 1 | One k3s agent | ~3 GB | Workloads reschedule onto the remaining nodes. Nothing depends on a specific node, and two nodes still demonstrate every scheduling concept three do. |
| 2 | authentik | ~2 GB | Only human logins route through it. Machine authentication — Flux, ESO, CI — deliberately does not, so nothing automated notices. |
| 3 | Monitoring stack | ~2–3 GB | Visibility is lost while it is down, which is a real cost; nothing breaks. Prometheus and Loki both resume on restart. |

Those three free roughly 8 GB with no functional loss beyond observability.
Below that line, every option trades function for memory, and it should hurt.

## Do not stop

| Component | Why not |
|---|---|
| **Vault** | Small footprint, large blast radius. It **seals on restart** — bringing it back needs the unseal key, and until then ESO stops refreshing every secret in the cluster. The cost is nothing like the 200 MB it occupies. |
| **Gitea** | Flux pulls from it. Stopping it makes reconciliation fail quietly rather than obviously, which is the worst failure mode available. |
| **Backend tier VM** | It is the entire cluster. |
| **CloudStack management server** | Running VMs survive without it — the data plane is independent — but nothing can be created, destroyed or reconfigured. Acceptable in an emergency, never as routine. |

## The scenario this exists for

**Rebuilding a VM image once the cluster is up.** That is the collision the whole
budget anticipates: a Packer build wants 3–4 GB transiently, at a point where the
estate is already near 28 GB.

The answer, written down so it is not improvised at the moment memory runs out:
**stop both k3s agents before starting the build, and authentik if it is running.**
That frees ~8 GB, leaving the build comfortable headroom. Restart the agents
afterwards; workloads redistribute on their own.

## Note on disk

Memory is the binding constraint, but disk is contended the same way and by the
same components. The reference's CI deletes its built images at the end of every
run precisely because the disk is shared with CloudStack's primary and secondary
storage. Budget 200 GB minimum, and treat a full root filesystem as a first-class
failure mode: it presents as pods being evicted and containerd write errors, not
as anything mentioning disk.
