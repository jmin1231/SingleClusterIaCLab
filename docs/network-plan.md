# Network Plan

Every address range this lab uses, decided before anything claims one.

Three kinds of value appear here and the distinction matters:

- **Discovered** — inherited from the host's network. Not ours to choose.
- **Chosen** — ours, and recorded so nothing else takes them.
- **Derived** — computed by a tool at run time. Nobody types these anywhere,
  which is exactly why they are written down: a range nothing configures is a
  range nobody remembers is taken.

## The ranges

| # | Range | Value | Kind |
|---|---|---|---|
| 1 | Bridge subnet | *pending — the VM's LAN* | discovered |
| 2 | Bridge gateway | *pending* | discovered |
| 3 | Host address on the bridge | *pending — DHCP lease, pinned static by the installer* | discovered |
| 4 | CloudStack public IPs | ~`.11–.30` of row 1 | **derived** |
| 5 | CloudStack pod IPs | ~`.31–.50` of row 1 | **derived** |
| 6 | CloudStack guest CIDR | `172.16.1.0/24` | installer default |
| 7 | VPC | `10.0.0.0/16` | chosen |
| 8 | Tier subnets | `10.0.1.0/24` frontend · `10.0.2.0/24` tunnel · `10.0.3.0/24` backend | chosen |
| 9 | WireGuard wg0 — frontend ↔ tunnel | `10.10.0.0/24` | chosen |
| 10 | WireGuard wg1 — tunnel ↔ backend | `10.10.1.0/24` | chosen |
| 11 | k3s pod CIDR | `10.42.0.0/16` | k3s default |
| 12 | k3s service CIDR | `10.43.0.0/16` | k3s default |
| 13 | Docker bridges | `172.17.0.0/16` – `172.31.0.0/16` | auto-allocated, on demand |

Rows 1–3 are filled once the VM exists. Rows 7–10 follow the reference's values,
which were checked against rows 11–13 rather than inherited on trust.

## Rows 4 and 5 are the point of this document

CloudStack derives its entire zone from the bridge's own `/24`. It scans for
addresses that **do not answer** and claims roughly twenty public IPs and twenty
pod IPs from what it finds free.

Two consequences:

- Nobody configures those ranges, so nothing in the repository mentions them.
  Without this table there is no record that `.11–.50` is spoken for.
- The allocation depends on a **liveness probe**, not a reservation. Anything of
  ours that happens to be stopped when the installer runs can have its address
  claimed.

The host address (row 3) sits inside that scanned space and is spared only
because it responds. In practice DHCP pools start well above `.50`, so this
resolves itself — verified by running the reference stack on a fresh VM with no
collision. It is recorded because "it works for a reason nobody wrote down" is
how it stops working later.

**Check when the VM exists:** does the LAN's DHCP pool overlap `.11–.50`? If it
does, either shrink the pool or reserve CloudStack's range on the router.

## What this plan does not contain: reverse DNS

Every row above is a forward mapping. There is no `in-addr.arpa` zone anywhere in
this lab — CoreDNS is authoritative for `lab.test` and nothing answers a PTR
query for any address in it.

That has cost nothing so far, and it is worth understanding why: forward-only DNS
is invisible until something resolves an address back to a name and compares the
answer to what it expected. Nothing here does that yet. The things that would:
Kerberos, which derives service principals from hostnames and fails with an error
naming the *principal* rather than the DNS (see 14.0-1); `sshd`'s `UseDNS`; and
TLS clients that log peer names.

Recorded for the same reason rows 4 and 5 are: a mapping nothing configures is a
mapping nobody remembers is absent.

## Overlap check

The three ranges that allocate **automatically**, and therefore collide silently:

- **k3s** takes `10.42.0.0/16` and `10.43.0.0/16` by default. A collision with
  the VPC or the overlay presents as **DNS failure**, not as a routing problem —
  which is why it costs hours rather than minutes.
- **Docker** hands itself `172.17.0.0/16` onward as compose stacks are added.
  Row 6 at `172.16.1.0/24` sits one subnet below that pool: clear, but only
  just. If the guest CIDR ever changes, this is the range to stay out of.
- **Link-local** `169.254.0.0/16` is used by CloudStack's `cloud0` bridge.

Rows 7–10 are clear of all three. Confirmed rather than assumed.

## What depends on the bridge address

Row 3 is the lab's single point of contact — every component reaches the control
plane on it. It is discovered at run time rather than written down, and fed to
every consumer from one function (`cloudbr0_ip()` in the reference):

- service bind addresses — though see decision `0.4-1`, we bind `0.0.0.0`
- the container registry string, in `daemon.json`, k3s `registries.yaml`, Vault
- `VAULT_ADDR`, for CI and for the cluster's ClusterSecretStore
- the git URL `flux bootstrap` bakes into `gotk-sync.yaml`
- DNS records, from Phase 2 onward
- `cloudstack-setup-databases -i <ip>`, and the zone derivation above

Most of those become names in Phase 2. The address does not stop being needed —
it is what the names resolve to — but it stops being copied into a dozen places.
