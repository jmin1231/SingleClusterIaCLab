# Network Plan

Every address range this lab uses, decided before anything claims one.

Two kinds of value, and the distinction matters:

- **Discovered** — inherited from the host's network. Not ours to choose.
- **Chosen** — ours, and recorded so nothing else takes them.

## The ranges

| # | Range | Value | Kind |
|---|---|---|---|
| 1 | Host LAN subnet | *pending — fill in when the VM exists* | discovered |
| 2 | Host address on it | *pending* | discovered |
| 3 | libvirt network for the VMs | `192.168.100.0/24` | chosen |
| 4 | k3s pod CIDR | `10.42.0.0/16` | k3s default |
| 5 | k3s service CIDR | `10.43.0.0/16` | k3s default |
| 6 | Docker bridges | `172.17.0.0/16` onward | auto-allocated |

Row 3 is deliberately **not** libvirt's `default` network at `192.168.122.0/24`.
Picking our own means a stock libvirt install on the same host cannot collide
with it, and it makes the choice visible rather than inherited.

## The names

CoreDNS is authoritative for `lab.test` and forwards everything else upstream.

| Name | Points at |
|---|---|
| `web.lab.test`, `git.lab.test`, `vault.lab.test` | the host, via the reverse proxy |
| `frontend.lab.test`, `app.lab.test`, `data.lab.test` | the VMs, from Terraform outputs (6.5) |

There is no reverse (`in-addr.arpa`) zone. Nothing in this lab resolves an
address back to a name, and it is recorded here because a mapping nothing
configures is a mapping nobody remembers is absent.

## Collision check

Three ranges allocate **automatically**, so they collide silently rather than
loudly:

- **k3s** takes rows 4 and 5 by default. A collision with row 3 shows up as *DNS
  failure*, not as a routing problem, which is why it costs hours.
- **Docker** hands itself `172.17.0.0/16` onward as compose stacks are added.
- **Link-local** `169.254.0.0/16` is reserved and used by some hypervisors.

Row 3 is clear of all three. Confirmed rather than assumed.

## What to fill in when the host exists

```sh
ip -4 addr show          # rows 1 and 2
ip route show default    # the upstream CoreDNS forwards to
```
