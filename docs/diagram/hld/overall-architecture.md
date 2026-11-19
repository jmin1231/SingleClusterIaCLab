# Overall architecture

What each box in `overall-architecture.drawio` is, in words. Names in *italics*
(`HOST_IP`, `LAN_CIDR`) are per-site values that bootstrap reads from the host's default route.

## Outside the host

| Part | What it is |
|---|---|
| Admin | A browser on the LAN (or on the host itself) opening `https://app.lab.test`. The lab's CoreDNS answers with `HOST_IP`. |
| LAN gateway | The site router and the host's default route. |
| Internet | The host goes out directly. The VMs go out only through Squid. |
| `HOST_IP:443 → fe-1` | Host nftables forwards the app's HTTPS to fe-1. |

## Host

One Ubuntu 24.04 machine with KVM (target 4 cores / 16 GB).

- **`HOST_IP`**: the host's LAN address, on the NIC behind the default route.
- **mgmt (cloudbr1, `10.250.0.0/24`)**: a host-only bridge, so the LAN cannot reach it. The host is `10.250.0.1` on it.

## Podman

Containers on the host, started with Compose, on `10.250.0.1`.

| Part | What it does |
|---|---|
| Traefik | HTTPS on `:443`, routes `gitea.lab.test` to Gitea. |
| Gitea | Git repo and Gitea Actions (the pipeline). |
| CoreDNS | DNS for `lab.test` (`app.lab.test` → `HOST_IP`). |
| Squid | Proxy on `:3128`, the VMs' only way to the internet. |
| Vault | Secrets for the pipeline, on `:8200`. |

## Host services

Run natively on the host under systemd.

| Part | What it does |
|---|---|
| runner | Runs the pipeline on every push: check → image (build + Trivy scan) → terraform → ansible. |
| nftables | DNATs `HOST_IP:443` to fe-1, and blocks VM traffic the lab does not allow. |
| chrony | NTP server on `10.250.0.1`. |
| PKI | The lab CA and its certificates (Vault, Gitea, the app). |

## KVM · libvirt

The host's KVM, managed through libvirt. Terraform builds the networks, disks and VMs.

| Part | What it does |
|---|---|
| libvirt / QEMU | Runs the three VMs. |
| Storage pool | The Ubuntu cloud image and one disk per VM. |
| mgmt network | Each VM's management NIC on cloudbr1. Ansible connects over it; the VMs reach DNS and Squid on `10.250.0.1`. |
| wan network | `198.51.100.0/24`. Carries the WireGuard tunnels and the HTTPS forwarded to fe-1. |

## VPC

Three isolated networks, one VM each, with no route between them.

| Network | VM | Role |
|---|---|---|
| site-a `10.1.1.0/24` | fe-1 `10.1.1.10` | The frontend container: Flask web app on `:443`. |
| site-hub `10.2.1.0/24` | tun-1 `10.2.1.10` | WireGuard hub between fe-1 and be-1. |
| site-c `10.3.1.0/24` | be-1 `10.3.1.10` | k3s with PostgREST and Postgres (see the backend LLD). |

- **wg0 / wg1**: WireGuard tunnels fe-1 ↔ tun-1 and tun-1 ↔ be-1.
- **fe-1 ↔ be-1**: no direct path. The only way is through the hub, and only tcp 8000.
