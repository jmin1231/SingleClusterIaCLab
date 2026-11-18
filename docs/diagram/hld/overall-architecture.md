# Overall architecture

Companion to [overall-architecture.drawio](overall-architecture.drawio).
Updated 2026-11-18 from the current repository configuration.

This is a configuration view, not a new live-system verification. The frontend
role and image workflow are included, but their end-to-end deployment acceptance
is still pending in [build-order.md](../../../build-order.md). Future components
are described separately below.

## Host and networks

One Ubuntu 24.04 host runs KVM/libvirt, the platform services, and a root Gitea
Actions runner. The README describes a 4-core, 16 GiB host. Terraform talks to
`qemu:///system`; there is no CloudStack management server, VPC router, or system VM.

The host keeps its existing LAN interface. Bootstrap discovers the interface,
host address, and gateway from the default route; it does not create `cloudbr0`
or read a TOML configuration file.

| Network / bridge | Subnet | Host address | Purpose |
|---|---|---|---|
| `site-a` | `10.1.1.0/24` | None configured | fe-1 private network; routes reserve `10.1.0.0/16` |
| `site-hub` | `10.2.1.0/24` | None configured | tun-1 private network; routes reserve `10.2.0.0/16` |
| `site-c` | `10.3.1.0/24` | None configured | be-1 private network; routes reserve `10.3.0.0/16` |
| `wan` | `198.51.100.0/24` | `198.51.100.1` | Simulated WAN, WireGuard transport, and frontend ingress |
| `cloudbr1` | `10.250.0.0/24` | `10.250.0.1` | Host-only management bridge |

Terraform creates the three private bridges and the routed WAN network. The
private bridges have no configured host IP, DHCP, DNS, or forwarding. Host Python
code creates `cloudbr1`. The WAN is a local simulation, not public internet
addressing. There is no WAN masquerading rule for guest internet access.

## Guests

| VM | CPU / RAM / disk | `eth0`: private | `eth1`: WAN | `eth2`: management |
|---|---|---|---|---|
| fe-1 | 1 vCPU / 1 GiB / 10 GiB | `10.1.1.10/24` | `198.51.100.11/24` | `10.250.0.110/24` |
| tun-1 | 1 vCPU / 512 MiB / 10 GiB | `10.2.1.10/24` | `198.51.100.12/24` | `10.250.0.111/24` |
| be-1 | 2 vCPU / 4 GiB / 40 GiB | `10.3.1.10/24` | `198.51.100.13/24` | `10.250.0.112/24` |

Cloud-init names NICs by MAC address. Each guest has a default route through
`198.51.100.1` on `eth1` and uses DNS `10.250.0.1` over `eth2`.

- **fe-1:** Flask frontend served directly by Gunicorn with TLS on port 443.
  Podman/Quadlet uses host networking; the image process runs as UID 65532.
- **tun-1:** WireGuard hub with IPv4 forwarding and a default-drop forwarding rule.
- **be-1:** Single-node k3s, Flux, PostgREST, and PostgreSQL.

## WireGuard and application routing

| Link | Tunnel addresses | Transport |
|---|---|---|
| `wg0` | fe-1 `10.99.0.2/24` ↔ tun-1 `10.99.0.1/24` | fe-1 initiates to `198.51.100.12:51820` |
| `wg1` | tun-1 `10.99.1.1/24` ↔ be-1 `10.99.1.2/24` | be-1 initiates to `198.51.100.12:51821` |

The spokes use keepalives and the hub learns their endpoints. WireGuard carries
remote private `/16` routes. The spoke route configuration explicitly selects
the private source IP, so the application flow is:

```text
fe-1 source 10.1.1.10 → wg0 → tun-1 → wg1 → be-1 destination 10.3.1.10:8000
```

The hub permits that new TCP flow and established/related replies. Other
forwarded traffic is counted and dropped. There is no NAT inside the tunnels.
WireGuard encrypts each link; the HTTP payload is visible at the hub between
decapsulation and re-encapsulation. No end-to-end application mTLS is configured.

## Host services

| Service | Listener / network | Role |
|---|---|---|
| CoreDNS | Host networking; LAN IP and `10.250.0.1`, port 53 | Explicit lab DNS records; other queries forwarded to host systemd-resolved |
| chrony | `10.250.0.1:123` | NTP service available to the management subnet |
| Squid | Host networking; `10.250.0.1:3128` | Allowlisted VM package/image egress |
| Traefik | `10.250.0.1:443` published to container port 8443 | TLS termination for `gitea.lab.test` |
| Gitea | `gitea:3000` on `lab-backend` | Git repository and Actions; Traefik forwards HTTP to it |
| Vault | `10.250.0.1:8200`, separate `lab-vault` network | TLS API; KV secrets consumed by bootstrap and the pipeline |
| cfssl tooling | Host files in `state/pki/`; no deployed CA network service | Issues lab CA certificates, including frontend `app-edge` |

Traefik and Gitea share the `lab-backend` Podman network. Vault has its own
network. Compose does not pin these networks to a `172.30.0.0/16` address pool.
There is no Traefik port-80 template server or wildcard service routing.

DNS maps `app.lab.test` to the detected host LAN IP; `gitea.lab.test`,
`vault.lab.test`, and `proxy.lab.test` to `10.250.0.1`; and `k3s.lab.test` to
`10.250.0.112`. A LAN client must use a resolver that knows these records.

## Ingress, egress, and filtering

LAN packets to `HOST_IP:443` are DNATed to `198.51.100.11:443`. Gunicorn on fe-1
terminates TLS. Traefik's management listener remains separate. The DNAT rule
matches packets arriving on the LAN interface; it does not provide host-local
hairpin access to the frontend.

The host's `bridge lab_vmfw_l2` table blocks guest-to-guest management traffic and
permits only the selected WireGuard exchanges and ARP between WAN peers. The
`inet lab_vmfw` table blocks direct guest routed egress and host-routing bypasses,
allows LAN frontend ingress and replies, and allows be-1's management HTTPS
traffic through the Podman DNAT path to Traefik/Gitea.

All VMs may use Squid for the allowed Ubuntu package domains. Only be-1 is also
allowed the configured k3s/GitHub/container-registry domains. Host bootstrap and
runner downloads use the host's ordinary internet access.

The firewall is not a general host-service allowlist: its input chain only drops
new WAN-originated host traffic. General host input filtering and separate
frontend/backend guest input policies are not implemented here. The diagrams do
not claim comprehensive LAN-console isolation or per-tap IP/MAC anti-spoofing.

## Delivery and secrets

`gitea-runner` runs as root under the service name `lab-runner`. The workflow is
`check → image → terraform → ansible`. The image job builds with rootful Podman,
saves `/var/lib/lab/images/frontend.tar`, and publishes Trivy reports; scanning
is report-only. Ansible copies the tar over management SSH to fe-1 and loads it
locally. Frontend delivery does not require a registry pull from fe-1.

Terraform state remains local at `/var/lib/lab/tfstate`. Ansible connects as the
guest user `user`, then uses become. It reads credentials and the `app-edge`
certificate/key from Vault, installs the frontend TLS files, and delivers
`Secret/db/app-db` through k3s's manifest directory. Flux independently reads
Gitea and reconciles `kubernetes/apps`. There is no runtime application-to-Vault
request or Vault Secrets Operator in the current build.

## Future work and sources

Istio ambient, Vault Secrets Operator, host firewall hardening, and monitoring
remain future work in `build-order.md`; Vault Transit is deferred. They are not
shown as installed services. CloudStack, Caddy, and CloudNativePG are absent from
the current configuration.

Source of truth: [Terraform networks](../../../terraform/network.tf),
[VM definitions](../../../terraform/compute.tf),
[host firewall](../../../src/host/files/nftables-vmfw.nft),
[WireGuard role](../../../ansible/roles/wireguard/),
[service configuration](../../../src/services/), and
[pipeline](../../../.gitea/workflows/deploy.yml).
