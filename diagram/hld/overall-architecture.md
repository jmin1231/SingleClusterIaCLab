# Overall architecture

What each box in `overall-architecture.drawio` is, in words. Names in *italics* in the
diagram are per-site values set in `config/lab.toml`.

## Outside the host

| Part | What it is |
|---|---|
| Admin | On the LAN; opens the app at `https://app.lab.test` (port 443). |
| Remote Admin | On the LAN; SSHes to the host at `HOST_IP` (port 22). |
| LAN gateway | The site router (`LAN_GATEWAY`). The host's default route. |
| Internet | Package mirrors and container registries. Reached only through Squid. |

## Host

One Ubuntu 24.04 machine with KVM (8 cores, 32 GB RAM, 250 GB disk; bare metal or a VM).
It has two bridges:

- **cloudbr0** puts the host on the LAN at `HOST_IP`.
- **cloudbr1** is the management network, `10.250.0.0/24`. It is host-only: no physical
  port, so the LAN cannot reach it. The host is `10.250.0.1` on it.

## Control plane

Containers run by Podman and started together by Compose, on the address pool
`172.30.0.0/16`. Everything is served on `10.250.0.1`.

| Part | What it does |
|---|---|
| Traefik | The front door on port 443. Routes by name (`*.lab.test` → `10.250.0.1`) to the services behind it. Port 80 serves only the VM template images, for CloudStack's SSVM to download. |
| Gitea | Git hosting and the container registry. |
| MinIO | S3 storage for VM images, Terraform state and logs, plus a web console. |
| Grafana | Dashboards over the metrics and logs. |
| Prometheus | Stores metrics. Alloy on the cluster pushes to it (remote write). |
| Loki | Stores logs. Alloy pushes to it. |
| Tempo | Traces (OpenTelemetry). An option, not in the core build. |
| Vault | Secrets and encryption, on its own port 8200 (not behind Traefik). |
| Squid | The egress proxy on port 3128. VMs reach the internet only through it, and only to allow-listed domains. |

## CI

`act_runner` runs as a systemd service under the `lab-runner` user. It runs the pipeline
jobs: Terraform, Ansible and Flux delivery.

## CloudStack

An all-in-one install on the host's KVM.

| Part | What it does |
|---|---|
| Management server | The UI and API on port 8080. Uses MySQL on `127.0.0.1`, NFS for storage, and the KVM agent to run VMs. |
| System VMs | SSVM (handles templates), CPVM (VM consoles) and the router for the management network. |

## VPC

The tenant network, `10.0.0.0/16`. Its ACLs deny by default and it has no route to the
internet.

- **VPC router**: applies the ACLs, does source NAT, and port-forwards.
- **VPC public IP**: an address from the LAN's public range. Port 443 on it is forwarded to fe-1.

| Tier | VM | Size | Addresses | Role |
|---|---|---|---|---|
| tier-frontend `10.0.1.0/24` | fe-1 | 1 vCPU / 1 GB | eth0 `10.0.1.10`, wg0 `10.99.0.2`, eth1 `10.250.0.110` | Caddy on 443 in front of the frontend container (Podman). |
| tier-tunnel `10.0.2.0/24` | tun-1 | 1 vCPU / 1 GB | eth0 `10.0.2.10`, wg0 `10.99.0.1`, wg1 `10.99.1.1`, eth1 `10.250.0.111` | WireGuard hub. Forwards only fe-1 → be-1 port 8000. |
| tier-backend `10.0.3.0/24` | be-1 | 4 vCPU / 6 GB | eth0 `10.0.3.10`, wg1 `10.99.1.2`, eth1 `10.250.0.112` | Single-node k3s (detail in the backend LLD). |

- **eth1** on each VM is its management NIC, on cloudbr1.
- **WireGuard tunnels:**
  - wg0 is `10.99.0.0/24` between fe-1 and tun-1, over UDP 51820 on eth0.
  - wg1 is `10.99.1.0/24` between tun-1 and be-1, over UDP 51821 on eth0.
- **fe-1 ↔ be-1:** no direct path. The VPC ACLs deny it, so the tunnels through tun-1
  are the only way between the two.
