# Resource Budget

Target: **16 GB RAM · 12 vCPU · 200 GB disk.**

Unlike the previous version of this lab, **this one fits, with room.** That is
worth stating plainly: the old budget committed ~14 GB of 16 and then spent five
rules explaining what could not run at the same time as what. Removing CloudStack
(~4 GB) and MinIO, and dropping identity and log aggregation, took the pressure
off entirely.

> **The development host is not the target.** If your workstation has far more
> memory, run the lab inside a 16 GB guest on it — nested virtualization, checked
> at 6.1. Otherwise every "it works" is measured on a machine that cannot
> reproduce the limit.

## The budget

Estimates until measured. Replace them as each component arrives — an estimate
that looks authoritative is worse than one that admits what it is.

Measure with `free -m`, `docker stats --no-stream`, `virsh dominfo <vm>`.

| Layer | Component | Estimated | Measured |
|---|---|---|---|
| Host | Ubuntu + KVM/QEMU overhead | ~2.0 GB | |
| Control plane | Gitea + Postgres, Vault, CoreDNS, proxy, runner idle | ~1.2 GB | |
| VM | frontend | ~0.75 GB | |
| VM | app — k3s server, workloads, Prometheus + Grafana | ~4.0 GB | |
| VM | data — Postgres | ~1.0 GB | |
| VM | second k3s node (8.5) | ~1.5 GB | |
| **Subtotal** | | **~10.5 GB** | |
| Reserve | page cache, kernel, burst | ~2.0 GB | |
| **Committed** | | **~12.5 GB** | |

Roughly **3.5 GB spare**. That headroom is what lets a Packer build or an image
rebuild happen without stopping anything, which was impossible before.

## Two things still worth pinning

1. **Prometheus and Grafana are sized deliberately.** Retention and scrape
   interval are set *before* first install, not tuned after an OOM. Left at chart
   defaults a monitoring stack drifts past 2 GB on its own.
2. **CI deletes its build artefacts every run**, with `if: always()`. Disk is not
   the binding constraint here, but qcow2 files only grow and nothing reclaims
   them.

## Disk

| Consumer | Estimated |
|---|---|
| Ubuntu, packages, container images | ~30 GB |
| libvirt images and VM disks | ~60 GB |
| Gitea — repos, packages, container images, state | ~20 GB |
| **Subtotal** | **~110 GB** |
| Transient — an image build in flight | +10–20 GB |

Comfortable at 200 GB.

**Check the disk is actually 200 GB before trusting this.** Ubuntu's installer
defaults to an LVM layout that sizes the root volume well below the disk and
leaves the rest of the volume group unallocated:

```sh
df -h /      # is / actually ~200 G?
vgs          # unallocated extents?
lsblk        # LVM or a plain partition?
```

Fix it in the install-time storage layout, so the machine is born correct, rather
than growing it afterwards.
