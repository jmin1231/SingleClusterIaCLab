# SingleClusterIaCLab — Build Plan

One Ubuntu 24.04 host becomes a small, enterprise-shaped private cloud, built,
updated and torn down by one script, `bootstrap.sh`:

- **IaaS:** Apache CloudStack on KVM, provisioned by Terraform from a hardened golden image.
- **Network:** a VPC with three tiers (frontend, tunnel, backend), one VM each,
  default-deny ACLs, no direct internet from any tier. The frontend reaches the
  backend **only** through WireGuard tunnels that terminate on the tunnel tier's VM.
- **Application:** an HTML frontend on its own VM, calling over end-to-end mutual TLS an
  API that runs with PostgreSQL in k3s on the backend VM, inside an Istio ambient mesh,
  with Vault as the encryption service and the CA. Flux keeps k3s equal to `main`;
  Grafana Alloy in k3s ships the cluster's, the mesh's and the api's metrics and logs to
  Prometheus and Loki on the host, where Grafana shows them.
- **Control plane:** Vault, CoreDNS, MinIO, Gitea, Prometheus, Loki, Grafana, an egress
  proxy and a TLS gateway on the host, driving everything with secrets issued at run
  time. Every console
  (CloudStack, Vault, Gitea, MinIO, Grafana) is reachable from the host only, over
  trusted TLS, behind its own login.

`sudo ./bootstrap.sh up` bootstraps the host, the control plane, CloudStack and a
CI runner, then hands over to the **delivery pipeline**, which builds everything
else; `up` follows the pipeline until it finishes, then runs the Vault DR drill
locally. The evidence is a green pipeline run ending in the `verify` job, plus that
drill's output (§13). `sudo ./bootstrap.sh update` applies changed configuration to a
built lab. `sudo ./bootstrap.sh teardown` removes the VPC and its VMs and keeps the
host platform, so the next `up` is quick. `sudo ./bootstrap.sh destroy` removes
everything and restores the host; run again after the reboot, it proves the host
matches its original baseline.

This document is complete on its own: everything needed to build the lab is here.

---

## 1. Requirements and how each is proven

| ID | Requirement | Built in | Proven by (check IDs, §12) |
|---|---|---|---|
| **R1** | Construct a VPC and implement a VPN to provide access | Phases 5, 6 | N1–N6 |
| **R2** | Deploy a database and an encryption service for a cloud application | Phases 2, 8 | E1–E3, T1–T3, Z1–Z2, P1–P5, S1–S4, K1, A1 |
| **R3** | Back up and restore the encrypted data; show key loss destroys it | Phase 9 | B1–B3 |
| **R4** | Reversible infrastructure: `destroy` removes the lab's packages, users and files and restores the network (each phase's list, rule 26) | Phase 13 | V1–V5 |
| **R5** | Pipeline-driven: after bootstrap, every build and change is a CI run with gates; k3s converges to `main` through Flux | Phases 2.10, 3.5, 8.1b, 10 | G1–G4 |
| **R6** | Observability: metrics, logs and dashboards for the cluster, the mesh and the api | 2.7b, 8.8a, 8.8b, 8.8d | O1–O5 |
| **R7** | Operator consoles: CloudStack, Vault, Gitea, MinIO and Grafana, from the host only, over trusted TLS, each behind its own login | 3.5c, 2.7b | C1 |

Every step in §9 is required: it builds or proves something R1–R7 needs. What was left
out, and why, is in §15.

---

## 2. Principles

- **Security first.** Where a more secure option costs little extra complexity, it is the
  one built: a separate root per trust domain, mutual TLS where the client can hold a
  certificate, read-only console logins, default deny everywhere (ACLs, firewalls,
  mesh). What was weighed and left out is in §15.
- **Bash at the door, Python inside.** `bootstrap.sh` checks for Python ≥ 3.12 and,
  only when it is missing or older, installs `python3.12` from the Ubuntu archive (so an
  unchanged re-run makes no apt call), then changes to its own directory and runs
  `exec python3 -B -m lab "$@"` (`-m` puts the repo root on the import path), nothing
  more. It has five commands and no
  subcommands or options: `up`, `update`, `teardown` and `destroy` (each local) and
  `--help`; the shim refuses all five without root, so Python has no root check of its
  own. Every command, phase, check and teardown
  is Python in the `lab/` package at the repo root (no `src/` level). External
  tools (`cmk`, `terraform`, `ansible-playbook`, `packer`, `kubectl`, `vault`,
  `istioctl`, `flux`, `helm`, `mc`, `podman`) are called through thin wrappers, never
  re-implemented. `lab` itself uses the Python standard library only (`tomllib`,
  `subprocess`, `json`, `urllib`), so running it installs nothing. The only shell in
  the repo is the shim; CloudStack is installed by an Ansible role (3.1a), not a
  vendored script.
- **Bootstrap by hand, everything else by pipeline.** `bootstrap.sh` builds only what
  must exist before CI can run: the host, the control plane, CloudStack and the
  runner (Phases 1–3). From Phase 4 on, every phase is a job in the delivery
  pipeline, and each job runs its phase module directly (`python3 -B -m lab.<module>`,
  e.g. `python3 -B -m lab.setup`).
  Inside k3s, **Flux** applies what `main` holds (GitOps); jobs never `kubectl apply`
  manifests, they only write the run-time Secrets Flux waits for (§6).
  A pipeline phase has no `bootstrap.sh` command: it runs as a `deliver.yml` job, as
  `lab-runner` (never as root, so it leaves no root-owned files behind for later jobs),
  from a clone of Gitea's `main`; a merge, `up` or `update` dispatches the run. While
  developing it, the operator runs the same module by hand, also as `lab-runner`, from
  a clone of their branch (§9). Only the four `bootstrap.sh` commands run
  locally, as root with the `lab-bootstrap` identity: bootstrap, unsealing Vault after a
  reboot, the Vault DR drill and teardown, because CI cannot exist before them, would
  not survive them, or must never hold the unseal key or break-glass credentials they
  use.
- **The development loop.** The working checkout (cloned from GitHub) has a second
  remote, `gitea` = `https://gitea.lab.test/lab/lab.git`, which is the origin the
  pipeline builds from. The operator works as the Gitea user `operator` (write access
  to `lab/lab`, not a site admin), pushing over HTTPS with a personal access token; the
  Gitea admin account is break-glass only. A change is: branch → `git push gitea
  <branch>` → open a pull request in Gitea → `pr.yml` passes → merge → `deliver.yml`
  runs. A Gitea push mirror copies `main` back to GitHub (optional: skipped when no
  GitHub token was given). Each job clones `lab/lab` (private) with the job's own
  short-lived token (`GITEA_TOKEN`, which act_runner provides) into its work directory;
  the runner never runs code from the operator's checkout.
- **Every phase owns its teardown.** Each phase module exports `up()`, `down()` and
  `check()`. `teardown` and `destroy` compose the `down()`s in reverse build order
  (`teardown` stops before the host platform), so a phase can't be built without the
  code to remove it.
- **Always converge; skip only expensive builds.** Every job runs its idempotent
  converge on every run (`terraform plan/apply`, Ansible, Flux reconciling `main`), so a
  merged change always reaches the lab and an unchanged lab produces no changes.
  Only costly builds are skipped, and only by content: the golden image by its input
  hash, the container images by git SHA. `check()` compares **desired with actual**
  (versions, image tags, plan diff), not just health. There is no local "done" tracker:
  a re-run asks the real system every time. **One run at a time:**
  `up`, `update`, `teardown` and `destroy` each take an exclusive lock on
  `state/run.lock` (0.2a), so a second command started while one runs is refused at
  once instead of racing it on apt, Vault init or Terraform state.
- **Least privilege.** Terraform uses a scoped CloudStack account. Each workload and
  the pipeline gets its own Vault identity and policy. The Vault root token is
  revoked after bootstrap. The CloudStack global admin is used only where nothing
  less works: installing CloudStack (bootstrap) and removing it (`destroy`). Terraform runs as `iac`;
  the golden image is registered by a separate account, `publisher` (3.2a). Flux reads
  git with a read-only token; console logins are read-only identities (3.5c). The k3s
  API follows the same rule (8.2c): Flux's own controllers do every apply; jobs and people
  get short-lived, Vault-issued ServiceAccount tokens bound to namespaced Roles (people:
  read-only `view`); cluster-admin is a break-glass kubeconfig in Vault, read only by
  `lab-bootstrap` and audited by Vault and by the k3s API audit log (8.2d).
- **Secrets are issued at run time**, with the exceptions in §6, each named and
  protected. None is ever in git: the `pr.yml` gate rejects a Secret with data under
  `clusters/` (10.1).
- **Pinned and immutable.** Every version, image digest, provider and chart is
  pinned in `config/versions.toml`. Images are built, scanned and published once, then
  never patched in place. Nothing installs software at container start.
- **Gates before change.** Terraform cannot apply
  without passing the policy gate, on the local path and in CI alike.
- **Fresh host assumed, dirty host refused.** Preflight refuses a host showing
  leftovers from an earlier install rather than trying to work around them.

---

## 3. Enterprise practice → local realization

| Enterprise practice | In this lab |
|---|---|
| Cloud IaaS | Apache CloudStack + KVM |
| Least-privilege deploy identity | CloudStack account `iac` with a restricted role |
| Secrets manager + KMS | Vault: KV v2, **Transit** (encryption as a service), AppRole, Kubernetes auth |
| Private CA | Vault PKI, one root per trust domain: `lab.test CA` (everything hosts and people trust), `pki_mesh` (only the istiod CA), `pki_app` (the frontend ↔ backend-gateway mTLS pair) |
| Edge / API gateway | Traefik on the host terminates TLS for every control-plane web service (Grafana and the telemetry write paths included) and routes by hostname; Vault stays direct |
| Remote Terraform state + locking | MinIO S3 backend, lockfile |
| Golden-image factory | Packer, built through the egress allow-list → versioned in MinIO |
| Container registry | Gitea registry; images scanned before push |
| Policy-as-code | Conftest/OPA on `terraform plan -json`, before every apply |
| GitOps | Flux CD: k3s converges to `main` in Gitea; run-time Secrets are written by jobs or synced from Vault, never committed |
| Secrets sync | Vault Secrets Operator: Vault KV → the one Kubernetes Secret a component cannot read from Vault itself |
| Network segmentation | VPC tiers (frontend, tunnel, backend), default-deny ACLs both directions |
| Transit / hub network | the tunnel tier: a WireGuard hub that is the only path from frontend to backend, with its own forwarding allow-list |
| Egress control | No tier has internet; an allow-listing forward proxy (Squid) on the host |
| Site-to-site VPN | WireGuard, hub-and-spoke (frontend ↔ hub ↔ backend), systemd-managed |
| Managed Kubernetes | k3s, Secrets encrypted at rest |
| Zero-trust service traffic | Istio ambient: STRICT mTLS (required), SPIFFE identities, mesh-wide default deny plus `AuthorizationPolicy` ALLOWs |
| Managed database | CloudNativePG operator: one PostgreSQL 16 `Cluster`, schema and grants declared in its spec; the app password in Vault, synced to the operator |
| Web front door | the frontend VM: Caddy terminates TLS with a Vault-signed certificate |
| Private API ingress | Istio Gateway (Gateway API) on the backend, mutual TLS with the frontend, reachable only from the tunnel |
| Backup / DR | Vault Raft snapshot + `pg_dump`, with a restore drill |
| CI/CD | Gitea Actions with one self-hosted runner; every change after bootstrap is a pipeline run |
| Monitoring | k8s-monitoring (Grafana Alloy) in k3s, installed by Flux → Prometheus (remote write) and Loki on the host; Grafana a host console |
| Operator consoles | each tool's own login, read-only identities, host-only, `lab.test CA` TLS |

---

## 4. Architecture

```
 LAN (LAN_CIDR)  ── browser / operator
   │
 ┌─┴──────────────────────────────── host: Ubuntu 24.04, KVM (bare metal or VM)─────────────────┐
 │ cloudbr0 = HOST_IP (LAN)                 cloudbr1 = VMNET_HOST_IP 10.250.0.1 (host-only)     │
 │ control plane (Podman):  Traefik :443 ─▶ Gitea(+registry) · MinIO · CloudStack UI (host+VMs) │
 │                          Traefik :443 ─▶ Grafana · Prometheus (write) · Loki (push)          │
 │                          Traefik :80 ─▶ MinIO images/ only (SSVM template download)          │
 │                          Vault :8200 (direct, own TLS) · CoreDNS · Squid · runner (systemd)  │
 │ CloudStack: management + MySQL + NFS + KVM agent          Packer/qemu (image builds)         │
 │                                                                                              │
 │  mgmt shared network (untagged, on cloudbr1 10.250.0.0/24): every VM's mgmt NIC (eth1)       │
 │  ════════════════════════════════════════════════════════════════════════════════════════    │
 │   │ fe-1 .110          │ tun-1 .111            │ be-1 .112                                   │
 │  ┌┴────────────────────┴───────────────────────┴─────────────────────────────────────────┐   │
 │  │ VPC 10.0.0.0/16   (virtual router: ACLs, source NAT, port-forward)                    │   │
 │  │  tier-frontend 10.0.1.0/24  tier-tunnel 10.0.2.0/24  tier-backend 10.0.3.0/24         │   │
 │  │   fe-1 .10 ─────UDP 51820────▶ tun-1 .10 ◀────UDP 51821───── be-1 .10 (k3s)           │   │
 │  │   wg0 10.99.0.2 ═══════════ wg0 10.99.0.1 │ wg1 10.99.1.1 ═══════════ wg1 10.99.1.2   │   │
 │  │   fe-1 ✗─────────────── no ACL path ──────────────────────────────✗ be-1              │   │
 │  └───────────────────────────────────────────────────────────────────────────────────────┘   │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
   VPC public IP :443 ──port-forward──▶ fe-1:443 (Caddy → frontend)
```

**Three planes, kept apart:**

- **Data plane:** the VPC tiers. Every inter-tier flow is denied by ACL except two:
  UDP 51820 between tier-frontend and tun-1, and UDP 51821 between tier-backend and
  tun-1. The tiers have **no egress to the internet**. The WireGuard underlay is the
  tier network itself, so tunnel traffic crosses the VPC router and its ACLs.
- **Management plane:** each VM's **mgmt NIC** (its second NIC) on the shared mgmt
  network, which lives on a **host-only bridge** (`cloudbr1`, no physical port), with
  a fixed address per VM (§5). The LAN cannot reach it and its DHCP cannot answer on
  it. A per-VM nftables policy lets the mgmt NIC talk **only to the host at
  `10.250.0.1`** (SSH from it; DNS, NTP, proxy, Vault, gateway and Kubernetes API
  traffic to and from it). The mgmt NIC carries no default route; the default route
  is the tier NIC, so replies to LAN clients always leave through the VPC router they
  came in by. **Named limit:** VM-to-VM isolation on this shared bridge is enforced
  only by in-guest nftables, which root on a VM could flush; the enterprise answer is
  L2 isolation of the management network (private VLANs), not built here.
- **Control plane:** the host's containers. Every VM reaches the internet only
  through Squid on `10.250.0.1:3128`, against a domain allow-list.

**Application path:**

```
 user ─HTTPS :443─▶ fe-1: Caddy ─HTTP─▶ frontend ═mTLS (pki_app), inside wg0═▶ tun-1 ═inside wg1═▶ be-1:8000
                    (app-edge cert)     (loopback)  client cert frontend.app    (forwards one flow;  Istio Gateway
                                                                                 sees TLS records)   `backend`: ends mTLS
                                                                                                        │ HBONE mTLS
                                                                                                        ▼
                                  Vault ◀──HTTPS── api (ns app) ──HBONE mTLS──▶ postgres (CNPG, ns db)
                                 (host)                     card_number = vault:v1:…
 be-1: Alloy (ns monitoring) ─HTTPS, basic auth (mgmt NIC)─▶ host gateway ─▶ Prometheus · Loki ◀── Grafana ◀─HTTPS── host browser
 be-1: alloy-audit (ns node-agents) ─HBONE─▶ Alloy ─scrapes (on-node)─▶ kubelet, API server, Istio, node-exporter, api
 be-1: Flux ─HTTPS (mgmt NIC)─▶ host gateway ─▶ Gitea `lab/lab` main
 be-1: Vault Secrets Operator ─HTTPS─▶ Vault: kv/app/db ─▶ Secret db/app-db ─▶ CNPG role `app`
```

- fe-1 runs only the frontend (Podman, two containers: Caddy and the frontend). It has
  no database driver, no Vault token and no route to the backend except the tunnel; it
  holds one client certificate, which only the backend gateway accepts.
- tun-1 is the **only** path from frontend to backend. It forwards one flow (the
  frontend's overlay address to the backend gateway on TCP 8000) and logs and drops
  everything else. The frontend's TLS runs inside the tunnels, so tun-1 forwards
  ciphertext only (T3).
- **Every network hop is encrypted** (§6): TLS to Caddy; mutual TLS from the frontend to
  the backend gateway, end to end, carried by WireGuard fe-1 → tun-1 → be-1. Plaintext
  exists only inside a host: fe-1's loopback, and the gateway pod on be-1, where the
  frontend's TLS ends and HBONE begins.
- **STRICT mTLS inside k3s is required (R2):** every pod-to-pod hop is mTLS through
  ztunnel; applications speak plain HTTP/TCP. Traffic from the tunnel enters the mesh
  only through the Istio Gateway, after its client-certificate check, and a mesh-wide
  default deny admits only the flows an ALLOW names.
- **Flux** keeps k3s equal to `main` (§7 `clusters/backend/`). **Operators** see every
  console from the host only (§5 Consoles).
- **Vault stays outside the cluster and the mesh.** It is the mesh's root of trust;
  if the mesh depended on Vault and Vault on the mesh, neither could recover alone.

---

## 5. Address, VM, port and DNS plan (single source of truth)

The host's LAN (`HOST_IP`, its prefix, `LAN_GATEWAY`, the card) is **read from the
host** on the first `up` and kept in the baseline (1.1, 1.2a), so the same repo runs
on any host. Choices the operator makes live in `config/lab.toml` (committed,
non-secret); the values below are the defaults and examples. The file is built **step
by step** (decided 2026-11-10): the first step that reads an operator choice creates
it, and each later step adds the keys it uses, with this section's default, to
`lab.toml` and to the loader's key table in the same change. Pins grow the same way in
`config/versions.toml`, which 1.3 creates. No key is added before a step reads it.

**Host and management network**

| Item | Value |
|---|---|
| `LAN_CIDR` | host LAN, read from the host (address + prefix), e.g. `192.168.50.0/24` |
| `HOST_IP` | host LAN address, read from the host, **static** in netplan (preflight refuses DHCP: the address must not change when CloudStack moves it onto `cloudbr0`), e.g. `192.168.50.10` |
| `LAN_GATEWAY` / upstream DNS | read from the host (the default route) / from the LAN |
| CloudStack pod (system VM) range | on the LAN, e.g. `.180–.189` |
| CloudStack public range (VPC source NAT and public IPs) | on the LAN, e.g. `.190–.209` |
| `VMNET_CIDR` (mgmt shared network) | `10.250.0.0/24` on host-only bridge `cloudbr1`; router DHCP `.100–.199`; lab VMs get **fixed** addresses from that range through `cloudstack_nic`'s `ip_address` (fe-1 `.110`, tun-1 `.111`, be-1 `.112`), and each VM's userdata writes that address into a **static** netplan for eth1, so nothing depends on a lease or on the mgmt router being up; the router itself is pinned outside `.110–.112`, at `.100` (`routerip`, 3.3a) |
| `VMNET_HOST_IP` | `10.250.0.1`, the host's address on `cloudbr1`: every VM reaches the control plane here |
| Container address pool (Podman) | `172.30.0.0/16` (pinned in `containers.conf`; must not overlap any range here): default network `.0.0/24`, `lab_edge` `.1.0/24`, `lab_backend` `.2.0/24`, `lab_egress` `.3.0/24` (fixed: Vault `.3.10`, Gitea `.3.11`, the only two addresses 2.2 lets out; any other container gets an address from `.3.128/25`) |

**VPC `10.0.0.0/16`**

| Tier | CIDR | VM | Size | Role |
|---|---|---|---|---|
| tier-frontend | `10.0.1.0/24` | `fe-1` `.10` | 1 vCPU · 1 GB · 10 GB | frontend application (Caddy + frontend container); public 443 lands here |
| tier-tunnel | `10.0.2.0/24` | `tun-1` `.10` | 1 vCPU · 1 GB · 10 GB | WireGuard hub: the only path from frontend to backend |
| tier-backend | `10.0.3.0/24` | `be-1` `.10` | 4 vCPU · 6 GB · 40 GB | k3s, Flux, mesh, api, database, telemetry agents (Alloy) |
| WireGuard `wg0` overlay | `10.99.0.0/24` | tun-1 `.1`, fe-1 `.2` | | frontend ↔ hub, tun-1 listens on UDP 51820 |
| WireGuard `wg1` overlay | `10.99.1.0/24` | tun-1 `.1`, be-1 `.2` | | hub ↔ backend, tun-1 listens on UDP 51821 |
| k3s pods / services | `10.42.0.0/16` / `10.43.0.0/16` | | | inside be-1 only |

**Application ports.** Caddy on fe-1 `:443` (public) → frontend container `:8080`
(loopback). The frontend's `API_URL` is `https://api.backend.lab.test:8000` (the name
is pinned to `10.99.1.2` in the container's hosts file): the backend Istio Gateway's
mutual-TLS listener, exposed on be-1's node addresses by k3s ServiceLB. The api Service
listens on `:8000` (metrics `:9090`), Postgres (`postgres-rw.db`) on `:5432`, all
cluster-internal. node-exporter (host network, behind kube-rbac-proxy: HTTPS with a
ServiceAccount token) listens on be-1's node address `10.0.3.10:9100`, on-node only
(eth0 drops it, 6.1b).

**Host ports.** All services listen on `0.0.0.0`, so they keep working when
CloudStack moves `HOST_IP` onto `cloudbr0`. The host firewall is default-drop on
input, accepts `established,related`, and allows each port only from the sources
listed. "VMs" means `VMNET_CIDR`; "containers" means the container pool. Web services
publish **no** host ports: they are reached only through the gateway.

| Service | Port | Allowed from | Name → address |
|---|---|---|---|
| SSH (as Ubuntu ships it; hardening is a §15 option) | 22 | LAN | `host.lab.test` → `HOST_IP` |
| CoreDNS | 53 tcp/udp | LAN, VMs | — |
| aardvark-dns (container name resolution; forwards other names to CoreDNS from the host) | 1053 tcp/udp | containers | — |
| chrony (NTP server) | 123/udp | VMs | — |
| **Gateway** (Traefik): Gitea web + registry, MinIO S3 + console, CloudStack UI/API, Grafana, Prometheus remote write (POST `/api/v1/write` only) and Loki push (POST `/loki/api/v1/push` only), both from be-1 only | 443 | VMs, containers, host (never the LAN) | `gitea`, `minio`, `minio-console`, `cloudstack`, `grafana`, `prometheus`, `loki` `.lab.test` → `10.250.0.1` |
| Gateway, plain HTTP: `GET /images/*` only (MinIO's anonymous-read `images` bucket) | 80 | system-VM range | by address: `http://HOST_IP/images/…` (4.3) |
| Vault (direct, its own TLS) | 8200 | VMs, containers, host | `vault.lab.test` → `10.250.0.1` |
| Squid | 3128 | VMs, host (Packer build VM) | `proxy.lab.test` → `10.250.0.1` |
| CloudStack UI/API backend (plain HTTP) | 8080 | host and containers only (the gateway, 3.1a's readiness probe) | — |
| CloudStack agent | 8250 | system-VM range, host | — |
| NFS (rpcbind, mountd, statd, lockd, nfsd; all pinned) | 111 · 20048 · 32765 · 32768 · 2049 | system-VM range | — |

Everything else that listens on the host (CloudStack's cluster port 9090, libvirt,
MySQL on `127.0.0.1`) is dropped from any non-local source.

Other names: `app.lab.test` → the VPC public IP; `k3s.lab.test` → be-1's mgmt
address `10.250.0.112`. Both are written by the `setup` job (5.4b). The one gateway certificate carries every gateway name and no IP
SAN; Vault's carries `vault.lab.test` and `10.250.0.1`.

Every name resolves the same for every asker. The gateway names point at `10.250.0.1`,
which the LAN cannot route to, so the gateway is host-only by address as well as by
firewall.

**DNS.** CoreDNS on the host is authoritative for `lab.test` and for the reverse
zones of `VMNET_CIDR` and `10.0.0.0/16`, and forwards everything else upstream. Every
VM resolves through the host. Pods resolve through k3s's CoreDNS, which forwards to
the node's resolver.

**Consoles** (R7). Each is reached from a browser **on the host** (from a workstation:
`ssh -D` to the host and browse through that SOCKS proxy with remote DNS, so the traffic
still originates on the host). Every URL serves a `lab.test CA` certificate; nothing
answers from the LAN. Credentials are generated at run time into Vault (3.5c) and read
by hand as `lab-bootstrap`, on a terminal and never into a log (runbook, 14.4).

| Console | URL | Login (read-only unless noted) | Credential in Vault |
|---|---|---|---|
| CloudStack | `https://cloudstack.lab.test/client/` | account `operator`, role *Read-Only Admin* | `kv/lab/bootstrap/cs-operator` |
| Vault | `https://vault.lab.test:8200/ui/` | userpass `operator`, policy `operator-ui` (no secret reads) | `kv/lab/bootstrap/vault-operator` |
| Gitea | `https://gitea.lab.test/` | `operator` (write to `lab/lab`, not an admin) | `kv/lab/bootstrap/gitea-operator` |
| MinIO | `https://minio-console.lab.test/` | `operator`, policy `readonly` | `kv/lab/bootstrap/minio-operator` |
| Grafana | `https://grafana.lab.test/` | `operator`, role *Viewer* | `kv/lab/bootstrap/grafana-operator` |

**Host capacity: 32 GB RAM is the ceiling, not a target.** The lab must fit
under it with a reserve, at its peak, with no memory overcommit (CloudStack
`mem.overprovisioning.factor = 1.0`, no swap counted). Figures are estimates until
measured; after each phase, `up` logs the host's measured steady-state
RSS, and the operator records it in `docs/capacity.md` through a normal pull request, and `up` refuses to start a phase if the host's available memory
would drop below the **4 GB reserve**.

| Consumer | Memory |
|---|---|
| Host OS + page-cache floor | 2.0 GB |
| CloudStack management (JVM) + MySQL + KVM agent (the 4.22 docs' 4 GB management-server minimum, until measured) | 4.0 GB |
| System VMs: SSVM, CPVM, redundant VPC router pair, mgmt-network router | 2.5 GB |
| Control plane: CoreDNS, Vault, MinIO, Gitea, Squid, Traefik, Prometheus ~0.55, Loki ~0.4, Grafana ~0.15 | 2.7 GB |
| fe-1 + tun-1 (1 GB each) + be-1 (6 GB) + KVM overhead | 9.0 GB |
| Gitea runner (idle host service) | 0.2 GB |
| **Steady state** | **20.4 GB** |
| Peak transient, one job at a time: golden-image build (Packer VM) | +2.0 GB |
| *(container build + scan, +1.5 GB, never overlaps it: the runner runs one job at a time)* | |
| **Peak** | **22.4 GB** |
| **Headroom under 32 GB** (must stay ≥ 4 GB reserve) | **9.6 GB** (9.2 GB with §15's tracing option, Tempo ~0.4) |

**What be-1's 6 GB holds** (requests in the manifests must sum to ≤ 4.5 GB): k3s
server ~0.6, Flux (three controllers) ~0.2, istiod ~0.3, ztunnel + istio-cni ~0.15,
the backend Istio gateway ~0.1, CNPG operator + Vault Secrets Operator ~0.2, Postgres
~0.3, api ~0.15, Alloy ~0.55 (512 Mi request, 1 Gi limit, plus its config-reloader),
Alloy Operator, kube-state-metrics, node-exporter (with kube-rbac-proxy) and
alloy-audit ~0.05 each: about 2.75 GB, ~1.75 GB under the cap. Metrics, logs and
dashboards are stored on the host (2.7b). Disk is not budgeted: Prometheus is capped at
2 GB on the host, Loki keeps roughly 1–2 GB for 7 days in MinIO (estimate), and Alloy's
WAL and alloy-audit's positions on be-1 carry `ephemeral-storage` limits, since the WAL
grows while the host is down. CloudStack's KVM agent sets
`host.reserved.mem.mb` to the host OS, CloudStack and control-plane rows only (system
VMs are VMs CloudStack already plans for), so CloudStack never plans VMs into the
control plane's memory.

**If measurements overrun:** drop the redundant VPC router (a single router saves
~0.25 GB but loses the HA story).

**Host:** 8 cores · **32 GB RAM (ceiling)** · 250 GB disk · `/dev/kvm`. The host may
be bare metal **or a VM**. As a VM, every CloudStack guest (system VMs, lab VMs, the
Packer build VM) runs **nested**, which needs two things from the outer hypervisor,
checked by hand once before the build:

- nested virtualization exposed to the host (`vmx`/`svm` in `/proc/cpuinfo`, and
  `/dev/kvm` usable)
- the host's LAN vNIC allowed to carry other MAC addresses: system VMs and VPC
  routers put their own MACs on the LAN through `cloudbr0` (ESXi: promiscuous mode,
  forged transmits and MAC changes accepted on the port group; Hyper-V: MAC address
  spoofing on; Proxmox/libvirt bridges: no setting needed)

Nested guests are slower, so every wait budget is scaled by `timeouts.nested_factor`
in `config/lab.toml` (1.0; set it to 2.0 by hand on a VM host).

---

## 6. Secrets and the trust bootstrap

**Rule:** a secret is created in Vault or by its consumer, read at run time, and
never written to the repo. The bootstrap secrets below are the only secrets that
exist outside Vault, and each one is listed with its location and protection.

| Secret | Lives in | Protection / rotation |
|---|---|---|
| Vault unseal key + initial root token | `/var/lib/lab/vault-init.json` (outside the repo) | root `0600`. The root token is used for steps 2.4b–2.5e only, then **revoked**; regenerate it with `vault operator generate-root` when needed. The unseal key is the one thing to back up offline. A later `up` never overwrites it: 2.4 archives it first (with the backups it opens) |
| Runner registration and pipeline AppRole (`lab-pipeline`) role_id + secret_id | `/var/lib/lab/runner/` | owned by `lab-runner`, `0600`; secret_id TTL 30 days, re-issued by the renewal that every `up` and `update` runs (as `lab-bootstrap`, inside the platform phase) when under 7 days remain; never stored in Gitea or the repo. Every job, PR jobs included, runs on the host as `lab-runner` and can use this identity: an accepted risk for a single-operator lab (§15) |
| Gitea `operator` password and its personal access token | the password in `kv/lab/bootstrap/gitea-operator`; the token in the operator's own git credential store | created in 2.8; the token is the operator's, scoped to repository write |
| Pipeline registry credential (Gitea user `lab-ci`, token with `write:package` on org `lab` only) | `kv/lab/pipeline/gitea-ci` | created in 2.8; read by the `app` job into a temp `REGISTRY_AUTH_FILE` |
| Flux's Gitea credential (user `lab-flux`, Read on `lab/lab` only, token scoped `read:repository`) | `kv/lab/pipeline/gitea-flux`; Secret `flux-system/gitea-auth` | created in 2.8; written to k3s on stdin by the `cluster` job (8.1b); it cannot push |
| GitHub mirror token (optional) | `kv/lab/bootstrap/github-mirror`, and Gitea's mirror settings | fine-grained token with push to the one GitHub repository, entered by the operator at the 2.8 prompt; no token → no mirror |
| Bootstrap AppRole (`lab-bootstrap`) role_id + secret_id | `/var/lib/lab/approle.json` | root `0600`; secret_id TTL 30 days. Every `bootstrap.sh` command re-issues it when under 7 days remain (it authenticates with the current one). If it ever expires, recovery is `vault operator generate-root` with the unseal key |
| Lab SSH private key (Ansible → VMs) | Vault KV; written to a per-job `0600` temp directory with its own `known_hosts` (`StrictHostKeyChecking=accept-new`, so replaced VMs do not break SSH) | deleted when the job ends |
| Tool credentials (`cmk` API keys, `mc` aliases, registry login) | per-job temp configs only: `cmk` with a temp config file, `mc` through `MC_HOST_*` variables, Podman through a temp `REGISTRY_AUTH_FILE` | nothing credential-bearing persists in `lab-runner`'s home between jobs |
| k3s break-glass kubeconfig (cluster-admin: k3s's `system:admin` client certificate, group `system:masters`) | Vault `kv/lab/breakglass/k3s-admin`; the node's own copy `/etc/rancher/k3s/k3s.yaml` on be-1, root `0600` | deposited by the `cluster` job whenever the `k3s` role (re)installs k3s; its `lab-pipeline` policy may only **write** that path (create and update, never read or list it); read only by `lab-bootstrap`, by `teardown` (§14 rows 0–3) and by hand through the runbook (14.4; e.g. 8.4a's port-forward and 12.1f's drift test), each read in Vault's audit log and each API call in k3s's (8.2d). A client certificate cannot be revoked (only `k3s certificate rotate-ca` ends it), which is why it is never on disk beyond one command's `0600` temp file. Until 8.2c it sits at `kv/lab/pipeline/k3s` as the build's scaffold; 8.2c moves it. Deleted by `teardown` |
| k3s API tokens for jobs and people (ServiceAccounts `lab-ci`, `lab-dbops`, `lab-operator` in ns `lab-access`) | nowhere at rest: Vault's Kubernetes secrets engine `k3s-creds/` requests each one from the API (TokenRequest) when a command starts | `lab-ci` 1 h, `lab-dbops` 15 min, `lab-operator` 1 h; written into a per-command `0600` temp kubeconfig with the k3s CA (rule 21) and deleted after; they expire, so none needs revoking. `lab-pipeline` may request all three, `lab-bootstrap` all three (8.2c) |
| Token-issuer JWT (SA `lab-access/vault-token-issuer`) | its long-lived token Secret in k3s, and Vault's `k3s-creds/config` | read on be-1 by the `k3s` Ansible role, never by a job's k3s identity; it may only create tokens for the three ServiceAccounts above (`serviceaccounts/token` with `resourceNames`), so a rewritten Vault role cannot mint anything stronger; rotated by re-running the `cluster` job |
| WireGuard private keys | generated **on** each VM; never leave it | public keys published to Vault KV |
| Postgres superuser | none: the CNPG `Cluster` sets `enableSuperuserAccess: false`, so no superuser password exists, and `pg_hba` rejects `postgres` from every network address, a `kubectl port-forward` included (8.4a, S4) | maintenance (`pg_dump`, `pg_restore`) runs as `postgres` over the instance pod's local socket through `kubectl exec` as `lab-dbops`, the only identity allowed to exec, and only into `postgres-1` (8.2c, 9.1a) |
| Postgres `app` password | `kv/app/db` (create-once, 8.4b); synced by the Vault Secrets Operator into Secret `db/app-db`, which only CNPG reads to set the role's password | the api reads it from Vault directly, never from the Secret. A new KV version re-syncs the Secret and CNPG re-sets the role (rule 23) |
| CNPG's own TLS (server certificate, its CA) | Secrets `db/postgres-ca`, `db/postgres-server` | generated by the operator in the cluster; never in git; encrypted at rest |
| k3s node token and Secrets-encryption key | `/var/lib/rancher/k3s/server/` on be-1 | root-only. The encryption key sits on the same node, so encryption at rest protects datastore copies and backups, not a compromised node. Without `--secrets-encryption` (k3s's default) every Secret is only base64 in `server/db/state.db` (kine/SQLite) and in every copy of it |
| Mesh workload keys (ambient) | ztunnel's memory on be-1; never inside a pod | ztunnel holds the key of every meshed workload on its node, so a compromised ztunnel (or node root) can impersonate every identity on that node: on this one-node cluster, all of them. istiod signs only for pods on the requesting ztunnel's node, which caps the blast radius at one node |
| istiod signing CA key | k8s Secret `istio-system/cacerts` | generated in the `mesh` job's memory, signed by `pki_mesh` (8.3a), written on stdin; encrypted at rest; 1-year TTL, so no rotation in the lab |
| Backend gateway TLS key (`api.backend.lab.test`) | Secret `ingress/backend-tls` | generated in the `app` job's memory, signed by `pki_app/sign/backend-gw`, written on stdin, never on disk; re-issued under 10 days (8.7d) |
| fe-1's client key (`frontend.app.lab.test`) | `/etc/frontend/tls/` on fe-1, `0600`, owned by the frontend container's UID | generated **on** fe-1; only its CSR leaves, signed by `pki_app/sign/frontend-client` (8.7g); re-signed under 10 days |
| Grafana admin password | `kv/lab/bootstrap/grafana-admin`; rendered to `/var/lib/lab/platform/grafana.env` | generated once by the platform phase (rule 18); used only to create Grafana's `operator` login and verify service account (2.7b, 3.5c) |
| Alloy write credential (username `alloy-v<N>`, password) | `kv/app/alloy-write`; its bcrypt hash in `/var/lib/lab/traefik/alloy.htpasswd`; Secret `monitoring/alloy-write` | created once by the platform phase (rule 18); synced by VSO (SA `monitoring/vso-monitoring`, role `vso-monitoring`); it can only append metrics and logs, and only from `10.250.0.112` (2.7b). Rotation: a new KV version with the next username; the users file keeps the current and the previous entry until VSO has re-synced, so no batch is refused |
| Grafana verify token (a Viewer service account) | `kv/lab/pipeline/grafana-verify` | created by the platform phase through Grafana's API (2.7b); `verify` and the `monitoring` job query Prometheus and Loki with it through Grafana |
| Console logins (Vault, MinIO, CloudStack, Grafana `operator`) | `kv/lab/bootstrap/{vault,minio,cs,grafana}-operator` | read-only identities created in 3.5c (Grafana's: role Viewer); read by hand on a terminal, never into a log (runbook, 14.4) |
| Vault Secrets Operator's Vault token | the operator's memory | Kubernetes login as SA `db/vso-db` to role `vso-db`, which may read `kv/data/app/db` only, and as SA `monitoring/vso-monitoring` to role `vso-monitoring`, `kv/data/app/alloy-write` only; 1-hour TTL |
| Vault token-reviewer JWT | k8s Secret for SA `vault-auth`, and Vault's `auth/k3s/config` | encrypted at rest; read on be-1 by the `k3s` role (from 8.2c); rotated by re-running the `cluster` job |
| CloudStack DB password and database encryption keys | `/etc/cloudstack/management/db.properties` and `key`, MySQL, Vault `kv/lab/bootstrap/cloudstack` | root-only; generated per install by 3.1a (never `cloud:cloud` or the `password` key defaults); removed by `destroy` |
| Control-plane start-up credentials (MinIO root, Gitea admin, Grafana admin, Loki's MinIO user), the gateway's users file (Alloy's bcrypt hash) and the two host TLS keys (Vault's listener, the gateway) | `/var/lib/lab/platform/*.env`, `/var/lib/lab/traefik/alloy.htpasswd`, `/var/lib/lab/certs/` | root `0600`, rendered from Vault by the platform phase and the renewal, on every `up` and `update`; never in the repo |
| fe-1's TLS key (`app.lab.test`) | `/etc/caddy/tls/` on fe-1 | generated **on** fe-1; only its CSR leaves the VM, signed by the `app` job through `pki/sign/app-edge`; an `app` run re-signs it when under 10 days remain |

**Everything else lives only in Vault** (the start-up credentials above are rendered
copies of Vault entries, refreshed by the platform phase), split by who may read it:

- `kv/lab/bootstrap/*` (only `lab-bootstrap`): CloudStack admin API keys, MinIO
  root, Gitea admin, Grafana admin, the runner registration token, the console logins
- `kv/lab/pipeline/*` (`lab-pipeline` and `lab-bootstrap`): the `iac`, `publisher`
  and `health` API keys, the per-bucket MinIO users (Loki's included), the lab SSH key,
  WireGuard public keys, Flux's Gitea token, the Grafana verify token
- `kv/lab/breakglass/*` (read: `lab-bootstrap` only; `lab-pipeline` may write
  `k3s-admin` but never read it): the k3s cluster-admin kubeconfig
- `kv/app/*`: the Postgres `app` password, the Alloy write credential

**Run-time objects in k3s (never in git).** Flux applies everything under
`clusters/backend/`. A value that exists only at run time reaches the cluster one of two
ways: the Vault Secrets Operator syncs it from Vault (`db/app-db`, `monitoring/alloy-write`), or a job writes it on
stdin as `lab-ci`, whose Roles name exactly these objects (8.2c): `istio-system/cacerts` (`mesh`), `ingress/backend-tls`, the public CA as Secret
`vault-ca` in `db` and `app`, ConfigMap `flux-system/app-images` (image digests) (`app`),
`monitoring/vault-ca` (`monitoring`), and
`flux-system/gitea-auth` and `flux-system/lab-ca` (`cluster`). Flux never prunes them
(they are not in its inventory). A **gate** Kustomization per job health-checks that
job's objects, and the Kustomizations that use them `dependsOn` the gate, so Flux never
starts istiod before `cacerts` exists (8.3a) or the api before its digests are known.

Paths are written as the CLI takes them (`kv/lab/pipeline/ssh`). In policies and raw
API calls, KV v2 inserts `data/` (`kv/data/lab/pipeline/ssh`) and `metadata/` for
listing and deleting, which is the usual cause of an unexpected 403.

**Trust bootstrap order (the chicken-and-egg, broken explicitly):**

1. Vault starts with a **self-signed bootstrap certificate**, valid for one day.
2. `init` → unseal → enable PKI → generate the **single self-signed CA**
   `lab.test CA` (10 years; key never leaves Vault).
3. Vault issues its **own** listener certificate from that CA and reloads with
   `SIGHUP`. The bootstrap certificate is gone.
4. The CA is installed into the host trust store. It is baked into the golden image,
   so every VM trusts it from first boot.
5. Every other certificate comes from Vault: the gateway's via the renewal that every
   `up` and `update` runs (30-day TTL, longer than the build window: re-issued under 10
   days, no timer); fe-1's edge certificate via `pki/sign/app-edge` (8.7f); the backend
   gateway's server certificate and fe-1's client certificate via `pki_app` (8.7d,
   8.7g); the istiod CA via
   `pki_mesh/root/sign-intermediate` (8.3a). Mesh workload certificates come from
   istiod.

**Three roots, one trust domain each (2.5a, 2.5f), and no intermediates:**

- `pki/` (`lab.test CA`): everything hosts and people trust; the only root in any
  system trust store.
- `pki_mesh/`: signs only the istiod CA; mesh workloads trust only it. **Decided
  2026-11-05** (security first, §2), from the k3s precursor (issue_197 A1): there an
  unconstrained mesh CA under the services root forged a `vault.vault.svc` certificate
  that passed `openssl verify`. A sub-CA under `lab.test CA`, even constrained to
  `cluster.local`, could still mint any `*.svc.cluster.local` certificate (and IP SANs if
  the IP constraint is unavailable) that every `lab.test CA` client accepts. Under its own
  root, no host or VM trusts it at all. The istiod CA keeps its `cluster.local`
  constraint as defence in depth, and every role keeps `allowed_uri_sans` empty (no leaf
  outside the mesh may carry a SPIFFE ID).
- `pki_app/`: the frontend ↔ backend-gateway mutual-TLS pair. The gateway accepts
  client certificates from this root only, so no other lab certificate (Vault's, the
  gateway's, fe-1's edge) can act as the frontend, and the frontend trusts only this
  root for the api.

A two-tier PKI exists so the root can be kept **offline**; inside one Vault both tiers
would have the shape without that property. The one sub-CA belongs to istiod (8.3),
because Istio must hold a signing key of its own.

**Transport encryption: two platforms.** The three roots sign every certificate the lab
issues (CloudStack, k3s and CNPG keep their own internal CAs). The rule:
every hop that crosses a network is TLS, WireGuard or SSH; traffic that never leaves one
machine (loopback, an internal Podman network, an on-node DNAT) may stay plain. Where
encrypting a network hop is complicated, the table says so and why.

*The host platform* (Vault, CoreDNS, chrony, Squid, the gateway, Gitea, MinIO,
Prometheus, Loki, Grafana, the runner, CloudStack). Two certificates only: Vault's
listener and **one** gateway certificate for every web name, both `host-svc`, 30 days. The control plane does not run
in a host Kubernetes cluster (§15).

| Hop | Encryption | Notes |
|---|---|---|
| VMs, containers, host, runner → Gitea, registry, MinIO, CloudStack UI/API, Grafana | TLS at the gateway | clients verify against the system trust store, never `-k` |
| gateway → those backends; Grafana → Prometheus, Loki | plain HTTP | skipped: internal Podman network and host loopback, no published ports |
| anything → Vault | TLS, Vault's own listener | Vault is the CA, so it is never behind the gateway |
| Vault, `lab` → k3s API (be-1) | TLS, k3s CA | k3s CA pinned in `auth/k3s/config`, `k3s-creds/config` and every kubeconfig |
| be-1 (Flux, containerd, VSO, Alloy) → Gitea, registry, chart repo, Vault; Alloy → Prometheus, Loki write paths | TLS, `lab.test CA` | pod traffic leaves be-1's mgmt NIC to `10.250.0.1` only (6.1b); Alloy also sends basic auth, accepted only from `10.250.0.112` (2.7b) |
| CloudStack management ↔ KVM agent / system VMs (8250) | TLS, CloudStack's own CA | CloudStack manages that CA itself |
| CloudStack → MySQL | plain | skipped: MySQL binds `127.0.0.1` |
| SSVM → host: NFS, and the template download (`:80`, `images/` only) | plain | skipped: CloudStack has no NFS over TLS, and the SSVM would need `lab.test CA` in its own trust store; the firewall limits both to the system-VM range, and CloudStack checks the template's SHA-256 (4.3) |
| VMs, containers → CoreDNS (53), chrony (123) | plain | skipped: records and time are not secret; DoT and NTS are out of scope |
| VMs → Squid (3128) | plain to the proxy, TLS end to end | HTTPS passes as `CONNECT`; plain-HTTP apt is signature-verified |
| host → VMs SSH (22) | SSH | its own encryption |

*The tier path* (fe-1 → tun-1 → be-1). Every network hop is encrypted:

| Hop | Encryption | Notes |
|---|---|---|
| user → fe-1 | TLS at Caddy | Vault-signed `app-edge` certificate, key generated on fe-1 (8.7f) |
| Caddy → frontend | plain HTTP | fe-1's loopback only |
| frontend → backend gateway | **mutual TLS, end to end** (`pki_app`) | the frontend presents `frontend.app.lab.test` and verifies `api.backend.lab.test` against the `pki_app` root only; the gateway requires the client certificate (8.7d, 8.7g) |
| fe-1 → tun-1 | WireGuard `wg0`, around the TLS | |
| tun-1 → be-1 | WireGuard `wg1`, around the TLS | |
| across tun-1 | TLS records only | the kernel decrypts WireGuard and re-encrypts it, and what lies between is the frontend's TLS: tun-1 forwards by address and port and never sees the payload (T3). It stays the policy point (6.2b) |
| be-1 `wg1` → backend gateway pod | the frontend's TLS, still | on-node DNAT (ServiceLB); the gateway pod terminates it |

*k3s on be-1* (api, Postgres, telemetry agents). **STRICT mTLS is required (R2):** Istio
ambient with a mesh-wide STRICT `PeerAuthentication` (8.3c), a mesh-wide default deny,
and `AuthorizationPolicy` ALLOWs for each named flow: gateway → api, api → postgres,
Alloy → the api, Postgres and kube-state-metrics metrics ports, alloy-audit → Alloy
(8.4c, 8.7h, 8.8a, 8.8b, 8.8d). The frontend reaches the database only through the api.

| Hop | Encryption | Notes |
|---|---|---|
| backend gateway → api → postgres | mTLS (HBONE, SPIFFE identities); api → postgres also CNPG's TLS inside it (`sslmode=require`) | checks Z1, Z2, T1, T2, P2 |
| CNPG operator → instance status port 8000 | CNPG's own TLS | the operator is outside the mesh, so port 8000 alone is PERMISSIVE and allowed only from the pod CIDR (8.4a, 8.4c); 5432 stays STRICT |
| Alloy → api `:9090`, Postgres exporter `:9187`, kube-state-metrics `:8080`; alloy-audit → Alloy `:3500` | mTLS (HBONE) | 8.8a, 8.8b, 8.8d |
| Alloy → targets outside the mesh (kubelet, API server, istiod, ztunnel, istio-cni, backend gateway, CoreDNS, Flux, CNPG operator, VSO, node-exporter) | plain HTTP, except kubelet, API server, VSO and node-exporter (HTTPS with Alloy's ServiceAccount token) | never leaves be-1 (the on-node rule above); ztunnel passes it through (8.8a, 8.8b, 8.8d) |
| api → Vault, VSO → Vault | TLS, Vault's listener | leaves the mesh as plain TCP carrying its own TLS (8.3c) |

`verify` proves the rule (check P4, §12) from the outside in: on the host, fe-1 and be-1,
every TCP port in §5's tables (host ports, application ports, 6443 and SSH) either
completes a TLS handshake verifying against `lab.test CA` (the k3s CA for 6443, the
`pki_app` root for be-1's 8000) or is an exception above (be-1's node-exporter 9100:
HTTPS with kube-rbac-proxy's self-signed certificate and a token check, answering on the
node only); and every gateway backend port is unreachable from a VM.

---

## 7. Repository layout

```
bootstrap.sh                 shim: check Python ≥ 3.12 (install python3.12 only if not), exec python3 -B -m lab "$@"
config/lab.toml              environment values (§5), non-secret
config/versions.toml         every pin, as data (no code in config/): CloudStack (version, repo key
                             fingerprint), Terraform provider, k3s, Flux, Istio,
                             Gateway API, Helm charts (version + SHA-256), images (by
                             digest: Prometheus, Loki and Grafana included), the
                             kubernetes-mixin and node-mixin commits, Python deps;
                             loaded and type-checked (1.3)
lab/
  __main__.py                argparse map: up, update, teardown, destroy, --help (§8);
                             the run lock (0.2a) and the config loader (1.3)
  lib/                       log (Phase 0). A helper module is added only when a
                             second step needs the same code (candidates later:
                             netplan, cloudstack (cmk), terraform, vault, kube); until
                             then the code lives where it is used
  __init__.py                `LabError`: a refusal main() logs, exit 1 (1.2a)
  policies/                  Vault policy bodies (HCL), written by bootstrap only (2.5d)
  phases/                    one module per phase, each with up/down/check (1.1), so
                             lab/ itself shows only the entry point:
    preflight.py toolchain.py platform.py provision.py image.py setup.py base.py
    tunnel.py cluster.py mesh.py app.py monitoring.py backup.py verify.py consoles.py
    teardown.py revert.py maintain.py
platform/                    compose.yaml + config: traefik/ (static config, dynamic
                             routes), coredns/, vault/, minio/, gitea/, squid/
                             (allowlist.txt), prometheus/ (config, the rendered mixin
                             recording rules), loki/, grafana/ (datasources, dashboard
                             provider)
observability/dashboards/    Grafana dashboards as JSON, synced to the host by the
                             `monitoring` job: kubernetes/ (the rendered mixins), lab/
                             (the three lab dashboards, 8.8b)
packer/                      qemu template, autoinstall seed, provisioners
terraform/                   provider + backend, vpc, tiers, acls, compute, ingress, outputs
policy/                      Conftest/OPA rules over the plan JSON
ansible/                     roles: cloudstack (the host install: repo, packages,
                             databases, `cloudbr0` netplan, 3.1a), base, wireguard_hub,
                             wireguard_spoke, frontend, k3s (k3s also holds the API
                             audit policy, 8.2d, and the on-node Flux bootstrap, 8.2c)
clusters/backend/            everything Flux applies to k3s (no Secret values, ever: 10.1)
  kustomization.yaml         the root: flux-system/ + kustomizations.yaml
  flux-system/               gotk-components.yaml (`flux install --export`, pinned),
                             gotk-sync.yaml (GitRepository `lab`, root Kustomization)
  kustomizations.yaml        Flux Kustomizations and their order: platform → operators;
                             platform → gate-mesh → mesh; gate-app, operators, mesh →
                             apps; gate-monitoring, mesh, operators → monitoring
  platform/                  namespaces (PSA, ambient labels), vault-auth, Gateway API
                             CRDs, the chart source `lab-charts`; access/ (ns `lab-access`,
                             its ServiceAccounts, every Role and binding for jobs and
                             people, the probe namespaces: 8.2c)
  operators/                 HelmReleases: CloudNativePG, Vault Secrets Operator
  gates/{mesh,app,monitoring}/  empty Kustomizations whose health checks wait for a job's
                             run-time objects (§6)
  mesh/                      Istio HelmReleases (base, istiod, cni, ztunnel),
                             PeerAuthentications, mesh-wide allow-nothing
  apps/                      db/ (CNPG Cluster, VSO objects), app/ (api), ingress/
                             (Gateway `backend`, HTTPRoute), policies/ (ALLOWs)
  monitoring/                HelmRelease k8s-monitoring, Alloy's ClusterRole and Role,
                             VSO objects (`alloy-write`), policies/ (ALLOWs),
                             node-agents/ (alloy-audit, 8.8d)
app/                         api/ and frontend/ (Flask), each with Dockerfile and
                             requirements.txt (hash-pinned); frontend/ also holds the
                             Caddyfile and the Podman quadlet units for fe-1
.gitea/workflows/            pr.yml (gates on every PR), deliver.yml (Phases 4–12 on
                             main), schedules.yml (nightly backup and verify)
docs/                        capacity.md, runbook.md
state/                       local run state (gitignored): bootstrap log, run lock. Pipeline
                             jobs keep **no** local state between jobs (§9 intro)
```

---

## 8. Commands and build order

`bootstrap.sh` execs `python3 -B -m lab "$@"` and has exactly five commands: `up`,
`update`, `teardown`, `destroy` and `--help` (last table below). There are no
subcommands and no flags. The phases are Python modules with `up/down/check`, not
commands: `up` and `update` run them, and a pipeline job runs its phase module
directly, `python3 -B -m lab.<module>` (e.g. `python3 -B -m lab.setup`). The first two
tables are in **build order**.

**Bootstrap: local, run by `up`** (CI cannot exist before these)

| # | Stage | Phase | Needs |
|---|---|---|---|
| 1 | `preflight` | 1 | — |
| 2 | `platform` | 2, 3 | preflight. Runs Phase 2 (control plane, gateway, telemetry stores and Grafana, runner), then Phase 3 (CloudStack), then the 3.5 hand-off (3.5a–3.5b) |

`preflight` runs Phase 1 (1.2a checks, 1.1 baseline, 1.3 toolchain). Phase → module
(all in `lab/phases/`):
1 `preflight.py` + `toolchain.py`; 2 `platform.py` (2.7b's telemetry stores and Grafana
included); 3 `provision.py`; 4 `image.py`;
5 `setup.py`; 6 `base.py` + `tunnel.py`; 8 `cluster.py`, `mesh.py`, `app.py`,
`monitoring.py`; 3.5c `consoles.py`;
9 `backup.py`; 12 `verify.py`; 13 `teardown.py` + `revert.py`. (Phases 7 and 11 were
removed; their numbers are kept free so the others keep theirs.)

**Delivery pipeline: `deliver.yml` jobs on the runner** (one job per phase)

| # | Job | Phase | Needs |
|---|---|---|---|
| 3 | `golden-image` | 4 | platform. Skipped when the input hash is already published |
| 4 | `setup` | 5 | golden-image; runs **plan → policy → apply** |
| 5 | `base` | 6.1a–6.1b | setup |
| 6 | `tunnel` | 6.2a–6.2b | base; three plays: keys on all three VMs → the hub → both spokes |
| 7 | `cluster` | 8.1–8.2d | base; k3s with its API audit log (8.2d), Flux (8.1b), the chart mirror (8.1c), Vault's Kubernetes auth and the scoped k3s identities (8.2c) |
| 8 | `mesh` | 8.3a–8.3c | cluster; writes `cacerts`, then waits for Flux's `mesh` |
| 9 | `app` | 8.4a–8.7h | mesh and tunnel; writes `kv/app/db` once, builds, scans and pushes the container images, writes the run-time objects (§6) and waits for Flux's `apps`, configures Vault for the api, then deploys the frontend to fe-1 |
| 10 | `monitoring` | 8.8a, 8.8b, 8.8d | app; writes `monitoring/vault-ca` and Vault role `vso-monitoring`, syncs the dashboards to the host, waits for Flux's `monitoring` |
| 11 | `verify` | 12 | everything built; non-zero on any failure |

No job applies a manifest to k3s: a merge that changes `clusters/backend/` is applied by
Flux within a minute, and each job only waits for its Kustomizations to report Ready at
the merged revision (`cmd.flux-wait`).

**Commands: `bootstrap.sh`** (all local; the shim refuses all five without root; each of the four takes the run lock, `state/run.lock` (0.2a), `--help` does not)

| Command | Runs |
|---|---|
| `up` | First build and resume. `preflight` → `platform` (Phases 2–3 and the 3.5 hand-off) → dispatches `deliver.yml` and follows it. Each step resumes at the first phase whose `check()` fails. Unseals Vault when it is sealed (after a host reboot, before the pipeline can read secrets) and runs the renewal: issues Vault's and the gateway's certificates when missing or under 10 days (the gateway's also when its SAN set in `gw.hosts` changed), and re-issues the runner's `lab-pipeline` secret_id when under 7 days (the `platform` phase runs the same renewal). After the pipeline is green, its **local stage** runs as root: the Vault DR drill (9.3a–9.4, proves B2/B3; it needs the unseal key, which the runner can never read), then it prints the `verify` job's pass/fail summary |
| `update` | For a lab already built; otherwise it refuses with "run `up` first". Applies what changed in `config/lab.toml` or the YAML, Compose and manifest files: unseals when sealed, runs the renewal, re-runs the platform phases so each converges to the current files (a changed host service is re-applied, e.g. `docker-compose up -d` recreates the changed containers), then dispatches `deliver.yml` on `main` and follows it. Changes under `clusters/` still reach k3s through git and Flux. No preflight dirty-host refusal, no DR drill |
| `teardown` | The tenant side only: the VPC, tiers and VMs (fe-1, tun-1, be-1, so the k3s cluster goes with be-1) and the state and Vault entries that belong only to them (e.g. the break-glass kubeconfig). Keeps the host platform (control plane, Vault, Gitea, MinIO, telemetry, CloudStack, runner, golden-image template), so the next `up` is quick |
| `destroy` | First asks: it prints what it is about to delete (the VPC and VMs, CloudStack with its `cloud` databases and all of MySQL's data, the platform, every package and user the lab added) and continues only if the operator types `destroy`; anything else, or no terminal on stdin, stops it with nothing changed (no flag skips the question). Then teardown's rows (always run: each is a no-op if `teardown` already ran), then the platform and host restore, in §14 order. Ends with a reboot (it removes the runner, so it cannot run in CI). Run again after the reboot, it asks again, finds nothing left, runs the revert checks V1–V5 and writes the pass/fail report. Every row tolerates "already gone" |
| `--help` | Lists the four commands (run with `sudo`, like the others: the shim checks root first) |

**Pipeline-only jobs** (not `bootstrap.sh` commands; each runs `python3 -B -m lab.<module>`)

| Job | Where | Runs |
|---|---|---|
| `verify` | last job of `deliver.yml`; nightly in `schedules.yml` | Phase 12; non-zero on any failure. A green run ending in `verify`, plus `up`'s local-stage output, is the lab's evidence (§13) |
| `backup` / `restore-drill` | `schedules.yml` nightly / dispatch | Phase 9.1a–9.2 (`restore-drill` takes a fresh backup first) |

Hand work that is not a command (reading a console login from Vault, a Vault shell
with the `lab-bootstrap` AppRole, the break-glass k3s kubeconfig) is a short procedure
in `docs/runbook.md` (14.4). A read-only `status` inventory is a §15 option.

---

## 9. Phases and steps

Each step fits one focused session and ends with an **Exit** you can run. Phases
0–3 run locally through `bootstrap.sh`. **From Phase 4 on, each phase is a job in
`deliver.yml`, and its Exit is checked on the pipeline run.** Jobs share nothing on
disk: Terraform state is in MinIO, the inventory comes from it, the kubeconfig and
every secret come from Vault, and "is this phase done?" is answered by `check()`. While developing a
phase, run its module by hand as `lab-runner` from a clone of your branch
(`sudo -u lab-runner python3 -B -m lab.<module>`), then prove it from the pipeline.

**Steps and handoffs.** Every step is sized for one session (one context window): one
outcome, a few files, **S** (60 min) or **M** (105 min) in the study loop. A split step
keeps its old number plus a letter (2.5 → 2.5a–2.5e); a bare number (`2.5`) means the
whole group. Each step ends with a **handoff contract** that a later session reads cold:

`⤷` **Needs** steps that must be closed · **Recalls** registry keys it reads · **Produces**
files, objects, endpoints · **Records** registry keys it writes (closing-note extras after
`;`) · **Check** its Exit, plus the §12 IDs it first proves

A step only Recalls keys Recorded by itself or by a step it Needs, directly or
transitively. Removed steps keep their numbers unused (§17.5).

Every step also writes its own `down()` and `check()` slice (§2), so those are not
repeated under Produces. The registry, the session protocol and the importable step index
are in §17.

### Phase 0 — Scaffolding

- **0.1 Shim and package.** `bootstrap.sh` (check Python ≥ 3.12; only if that fails,
  install `python3.12` and check again; then `cd` to its own directory and `exec`);
  `lab/__init__.py`; `lab/lib/__init__.py`; `lab/lib/log.py` (`[+]/[!]/[x]` to the
  console, timestamped `state/bootstrap.log`, `state/` created on first use, its path
  anchored to the file with `pathlib`, not the working directory); `.gitignore`
  (`/state/`, `__pycache__/`, `*.tfstate*`, `.terraform/`, `/builds/`). No tracker
  (2026-11-10: `check()` decides, §2).
  Exit: from the repo root, `python3 -c 'import lab.lib.log'`.

  ⤷ **Needs** — · **Recalls** — · **Produces** `bootstrap.sh`, `lib/log.py`,
  `.gitignore` · **Records** `path.repo` (checkout, remotes), `path.state` ·
  **Check** Exit
- **0.2a Command map and phase interface.** `__main__.py` with the four §8 commands
  (`up`, `update`, `teardown`, `destroy`) as logged stubs, plus `--help`; no subcommands
  and no flags; no root check in Python (the shim does it). Each command takes the
  **run lock**, written inline in `__main__.py`: an exclusive, non-blocking
  `fcntl.flock` on `state/run.lock`, held for the whole run and released by the kernel
  when the process exits (a crash leaves no stale lock); if another run holds it, the
  command stops with "another bootstrap.sh run is in progress". The phase interface
  (`up/down/check`). No `lib/system.py`: commands are run with `subprocess.run(...,
  check=True)` where they are needed, until a second step repeats the pattern (§7).
  Exit: `sudo ./bootstrap.sh --help` lists exactly `up`, `update`, `teardown`,
  `destroy`; `sudo ./bootstrap.sh up` logs each stub; a second `sudo ./bootstrap.sh up`
  started while the first is still running is refused at once and the first is
  unaffected.

  ⤷ **Needs** 0.1 · **Recalls** `path.state` · **Produces** `__main__.py` ·
  **Records** `code.phase-interface`, `code.run-lock` · **Check** Exit
- **0.2b** removed (2026-11-10): the config files are built **step by step** (§5) —
  1.3 creates `config/versions.toml` and `load_config()`; `config/lab.toml` comes with
  the first step that reads an operator choice.

### Phase 1 — Host preflight and reversibility

**Preflight grows with the lab** (decided 2026-11-10). It starts as one check, that
`/dev/kvm` is usable, in `lab/phases/preflight.py`. Each later step adds to it the
check or the dependency it needs, in the same change, and nothing goes in before a step
needs it. **Dependencies are split by what installing them does** (decided 2026-11-10):
- **inert ones, installed by preflight:** the pinned CLIs (1.3), `qemu-utils`,
  `qemu-system-x86`, `dnsutils`, Python libraries. Nothing in this group runs on
  install, so a broken mirror or pin fails in the first minute
- **packages that start a service, installed by the step that configures them**,
  right before its configuration and after 2.2's firewall exists: on Ubuntu a
  package's install script enables and starts its service at once (`nfs-kernel-server`
  would listen on 111 before the firewall, `mysql-server` would run unconfigured,
  `libvirt-daemon-system` creates `virbr0`, `chrony` removes `systemd-timesyncd`,
  `cloudstack-management` needs its repository first)

Both groups are listed in **one table**, `PACKAGES` in `preflight.py`, keyed by the
step that installs them; a step installs its own entry. That one table is what
`destroy` purges (row 9b). The steps below describe where
preflight ends up; each part is built when the step that first needs it is built (the
LAN detection and the baseline, for example, with the first step that changes the
network).

- **1.1 Baseline and netplan backup.** `destroy` purges the packages each phase
  installed (row 9b), deletes what rule 26 names, removes users by difference and
  restores a few backed-up files. So the baseline records only what that needs, in
  `/var/backups/lab/baseline.json`:
  - the LAN as 1.2a detected it: card, `HOST_IP`, prefix, `LAN_GATEWAY` (later steps
    and V2 read it here, never from the host again)
  - local users and groups, with group memberships
  - where `/etc/resolv.conf` links to

  One-time copies, never refreshed: `/etc/netplan` to `/var/backups/lab/netplan.orig/`,
  and the shared files the lab cannot avoid editing (root's
  `~/.ssh/authorized_keys`, `/etc/hosts`) to `/var/backups/lab/files.orig/`, outside
  the repo and outside `state/`. The baseline is written last (temp file, then
  `os.replace`), so it exists only once the copies do, and **its existence is the
  marker**: a baseline means the lab owns this host (an `up` in progress or a lab not
  yet destroyed); `destroy` deletes `/var/backups/lab/` only after a green V1–V5
  report (13.2). No install-id file, no hashes, no package list (kept simple,
  2026-11-10).
  Exit: the baseline and both copies exist; a re-run changes none of them.

  ⤷ **Needs** 0.2a · **Recalls** — · **Produces** baseline writer
  (`lab/phases/preflight.py`, the first phase module with `up/down/check`) · **Records** `path.baseline`,
  `path.netplan-orig` · **Check** Exit
- **1.2a Preflight checks.** In `lab/phases/preflight.py`; no config file (the host's
  network is read from the host, the minimums are constants: they are the lab's needs,
  the same on every host). `up` runs the checks **before** 1.1's baseline writer, and
  reports every problem in one run (each check returns messages, then one refusal):
  - Ubuntu 24.04; `/dev/kvm` usable; at least 8 cores; at least 200 GB on `/` (a
    250 GB disk gives about 210); `MemTotal` ≥ 30 GiB (a 32 GB host reports about
    31 GiB). The `/proc/meminfo` reader is reused later: `up` checks the §5 reserve
    before each phase with it
  - strict `apt-get update` (fail naming any broken source)
  - first run only (no baseline yet):
    - **the LAN, detected:** exactly one default route via a gateway, and exactly one
      IPv4 address on its card, not from DHCP (`ip -j route`, `ip -j addr`: the
      `dynamic` flag). The card, address, prefix and gateway go into the baseline
      (1.1) and are never detected again: once CloudStack moves the address onto
      `cloudbr0`, the same commands would name the bridge, not the card
    - **leftovers** refused, each named: `/var/lib/mysql`, the bridges `cloudbr0`,
      `cloudbr1`, `cloud0`, `virbr0`, `cloudstack-*` packages, Docker (its
      FORWARD-drop policy would undercut 2.2), an active `ufw` or `firewalld` (each
      sets FORWARD to drop or rewrites the ruleset), `lab-*` units, the user
      `lab-runner` (its rootless containers and networks go with it), any apt source
      but `ubuntu.sources`
  - a resumed run (baseline exists: the lab's own partial install) skips both and logs
    the recorded network
  Config cross-checks arrive with the step that adds the key (the runner's sub-ID
  range, 2.10, against every range already in `/etc/subuid` and `/etc/subgid`).
  Exit: passes on a fresh host with a static address and logs its network; fails
  naming each problem on a host with a DHCP address, a planted `cloudbr0` and no
  baseline. (Once Phase 2 exists: passes, and resumes, after an `up` interrupted in
  Phase 2.)

  ⤷ **Needs** 1.1 · **Recalls** `path.baseline` · **Produces** `preflight.py` checks,
  the memory reader, `LabError` (in `lab/__init__.py`, logged by `main()`, exit 1) ·
  **Records** `net.host` (card, `HOST_IP`, prefix, `LAN_GATEWAY`, as recorded in the
  baseline), `host.memory` · **Check** Exit
- **1.3 Toolchain.** Creates `config/versions.toml` with this step's pins (data only:
  values in TOML, code in `lab/`; later steps add theirs, §5) and `load_config()` in
  `__main__.py`: it loads the TOML files with the stdlib `tomllib` and checks each key
  in its key table is present with the right type (`type(v) is int`: TOML `true` is
  not an int), refusing with the file and the key. It moves to its own module when the
  first pipeline job needs it (Phase 4: jobs run `python3 -m lab.<module>` and never
  pass through `__main__`). Pinned CLIs into `/opt/lab/bin`, each verified against a
  SHA-256 in `config/versions.toml`: terraform, packer, ansible (venv in `/opt/lab/ansible`,
  with the `cloud.terraform` collection), conftest, trivy, cmk (CloudMonkey, CloudStack's
  CLI), docker-compose (v2, run against Podman's socket, 2.1b), kubectl, istioctl, flux, helm, vault, mc, kubeconform. Host packages, from the Ubuntu
  archive at pinned versions: `qemu-system-x86` and `qemu-utils` (Packer), `dnsutils`
  (`dig`). Every package the lab adds is removed by
  `destroy`, so V1 holds. An archive is never extracted whole: the one named member is read
  and written to a fixed path (no `extractall`, so no path traversal from the archive),
  and "already installed" means an exact word match on the version (`1.31.30` is not
  `1.31.3`).
  Exit: `up` logs every tool and its version, and each tool's own version command
  (e.g. `/opt/lab/bin/terraform version`) matches `config/versions.toml`; a corrupted download
  is rejected; a pin with a missing key or a wrong type is refused naming the file and
  the key.

  ⤷ **Needs** 1.2a · **Recalls** — · **Produces** `config/versions.toml`,
  `load_config()`, `toolchain.py`, `/opt/lab/bin/*` · **Records** `code.config`,
  `code.versions`, `path.toolchain` ·
  **Check** Exit

### Phase 2 — Control plane

Until 2.5e creates the `lab-bootstrap` AppRole, steps 2.4b–2.5f authenticate with the
initial root token from `vault-init.json`; 2.5e ends by revoking it. Nothing after 2.5e
uses it. After that, a Vault shell for the operator is a manual procedure in the
runbook (14.4): a subshell with `VAULT_TOKEN` from a `lab-bootstrap` AppRole login.

- **2.1a Host-only bridge.** The host-only bridge `cloudbr1` with `10.250.0.1/24` (a lab
  netplan file, no physical port, `ignore-carrier: true`: a bridge with no ports has no
  carrier, and networkd would otherwise not configure the address until a VM attaches),
  first, because every control-plane name resolves to that address.
  Exit: `cloudbr1` is up with `10.250.0.1`, and stays so after `netplan apply` and a reboot.

  ⤷ **Needs** 1.2a · **Recalls** `path.netplan-orig`, `net.host` · **Produces** the lab
  netplan file · **Records** `net.vmnet` (bridge, host address, file name) · **Check** Exit
- **2.1b Podman and Compose** (decided 2026-11-09, Compose chosen over quadlets
  2026-11-10, §15 "Control-plane runtime"). Podman from the Ubuntu 24.04 archive at a
  pinned version (4.9.3, with netavark and aardvark-dns 1.4.0, and `iptables`, which
  netavark 1.4 calls; each installed by name, since Podman only recommends or suggests
  them); no third-party apt repo or key. `iptables -V` must report `nf_tables`; the
  legacy variant is refused. A lab drop-in `/etc/containers/containers.conf.d/` file
  pins the container pool (`default_subnet = 172.30.0.0/24` for the default `podman`
  network, and `default_subnet_pools` of `172.30.0.0/16`, size 24) and moves
  aardvark-dns to `dns_bind_port = 1053`, since CoreDNS holds port 53 on every host
  address. The services are defined in **one Compose file** and run by rootful Podman:
  - Compose is the `docker-compose` v2 binary, pinned with its SHA-256 in `config/versions.toml`
    and installed by 1.3 into `/opt/lab/bin`, talking to rootful Podman's API socket
    (`podman.socket`, `/run/podman/podman.sock`, `root:root 0660`) through
    `DOCKER_HOST`. Ubuntu's `podman-compose` package is not used (older; health-gated
    `depends_on` and `ip_range` **[verify]**)
  - the platform phase (`platform.py`, run by `up` and `update`) renders the repo's
    `platform/` into `/var/lib/lab/platform/` (config
    and `compose.yaml`, root-owned), so the running control plane never depends on the
    operator's checkout. The file names its project (`name: lab`), and each service
    sets `container_name: <service>`, the name the other services and the health
    commands use
  - one systemd unit, `lab-platform.service` (`Type=oneshot`, `RemainAfterExit=yes`,
    `Requires=` and `After=` `lab-nftables.service` and `podman.socket`, `WantedBy=
    multi-user.target`), runs `docker-compose up -d` at boot and `docker-compose stop`
    on stop, so no lab container starts without the firewall table (2.2)
  - every service has `restart: unless-stopped`: Podman restarts a crashed container
    itself, and Podman's `podman-restart.service` (which starts only `always`
    containers at boot, with no firewall ordering) is left disabled; the boot start is
    `lab-platform.service`'s
  - images are fully qualified and pinned by digest (they change only through
    `config/versions.toml`); the platform phase pulls every image first. Credentials stay in root
    `0600` `*.env` files (`env_file:`), not Compose or Podman secrets, whose `file`
    driver would keep a second copy in container storage. Named volumes have fixed
    names (`name: prometheus-data`)
  - Podman never updates an existing network, so when a network's definition changes
    the platform phase stops the services on it, runs `podman network rm` and brings them up
    again (rule 19)

  Networks, each with a fixed `name:` and a fixed `subnet` and no DNS override:
  aardvark-dns answers container names and forwards every other name to the host's
  resolver, which from 2.3a is `127.0.0.1`, CoreDNS:
  - `lab_edge` (`172.30.1.0/24`): Traefik only; its 443 and 80 are the only published
    web ports
  - `lab_backend` (`172.30.2.0/24`, `internal: true`, no route out, no published
    ports): Gitea, MinIO, and Prometheus, Loki and Grafana (2.7b), reached only by
    Traefik and each other
  - `lab_egress` (`172.30.3.0/24`, normal bridge, outbound only as 2.2 allows, with
    `ip_range: 172.30.3.128/25` so no other container takes a fixed address): Vault at
    `172.30.3.10` (to k3s's API) and Gitea at `172.30.3.11` (push mirror to GitHub),
    set with `ipv4_address` under the service's `lab_egress` entry **[verify that
    Podman 4.9's API keeps `ip_range` and that netavark accepts a fixed address outside
    it]**. 2.2 lets only these two addresses out
  - CoreDNS and Squid use `network_mode: host`, so they see real client addresses (the
    `view` plugin and Squid's ACL depend on it) and are filtered by the input chain

  Each service has a `healthcheck:` and is added to the file, and started with
  `docker-compose up -d --wait <service>`, by its own step below; the platform phase also
  checks health itself (`podman healthcheck run`).
  Exit: `podman run --rm` of a pinned `docker.io/library/hello-world` works (pulled
  from Docker Hub directly: the host itself is not behind Squid); `docker-compose
  config` accepts the rendered file; `sudo ./bootstrap.sh up` creates the three networks with
  the names, subnets and range above (`podman network inspect`); `lab-platform.service`
  is enabled and active; a re-run changes nothing.

  ⤷ **Needs** 2.1a, 1.3 · **Recalls** `net.vmnet`, `code.versions`, `decision.runtime` ·
  **Produces** `platform.py` (render + compose), `platform/compose.yaml`,
  `lab-platform.service`, the `containers.conf` drop-in · **Records** `podman.pool`,
  `podman.networks` (names, subnets, Vault's and Gitea's fixed `lab_egress`
  addresses), `path.platform` · **Check** Exit
- **2.1c Spike: netavark's firewall driver and rule order** (a gate: 2.2 is written
  against what this proves). Facts to confirm on this host: `podman info` names
  netavark as the network backend; netavark 1.4 uses its iptables driver (its other
  one, firewalld, needs a running firewalld, which 1.2a refuses; the nftables driver
  came in 1.10), and Ubuntu's `iptables` is the nf_tables variant, so its
  rules land in the `ip filter` and `ip nat` tables (`iptables -V` reports `nf_tables`);
  it turns `ip_forward` on, inserts only ACCEPT rules in FORWARD and leaves the policy
  at accept (so, unlike Docker, it drops nothing); published ports are DNAT'd in
  `PREROUTING` for local addresses, so they reach the forward chain, not input, with the
  outside source kept; it sets `route_localnet=1` on a bridge with published ports; it
  does not load `br_netfilter`; its port 53 → 1053 DNS redirect covers UDP only (TCP
  came in 1.12.2); an internal network gets no default route, no NAT and no DNS
  redirect.
  With a throwaway network in the pool, a `traefik/whoami` container published on a
  test port and a scratch `inet labspike` table (forward chain at `filter - 1`, policy
  drop; nat chain at `dstnat - 1`), from a namespace address (the recipe 2.2 records as
  `cmd.netns-test`):
  - with no accept in the scratch chain, the published port times out (a drop in the
    lab's chain wins over netavark's accept); with an accept for `ct status dnat`, the
    original port and the source, it answers and whoami prints the namespace address
  - attached to a second, internal network whose name sorts first (as `lab_backend`
    does before `lab_edge` for Traefik), whoami's published port still reaches it on
    the normal network's address **[verify: netavark forwards ports on one network
    only; if it picks the internal one, `lab_edge` is renamed so it sorts first]**
  - a container on an internal network resolves another container by name through
    aardvark-dns on 1053 only once the scratch table redirects its port 53 queries;
    on a normal network netavark's own redirect does it for UDP, and `dig +tcp`
    answers only with the scratch table's TCP redirect
  - `nft -f` of the scratch table and a restart of the container, in either order,
    leave both rule sets in place
  - through `docker-compose` on the Podman socket: a throwaway network with `ip_range`
    and a container at a fixed address outside that range come up as declared, an
    `internal: true` network has no route out, and `up -d --wait` returns only once the
    container's health check passes
  Exit: every point above holds; the scratch table, network and container are removed.
  If any fails, 2.2 waits and `decision.podman-fw` is opened. Its named fallback is
  Podman 5.x with netavark ≥ 1.10, whose nftables driver (chosen with
  `firewall_driver = "nftables"` in the lab's `containers.conf` drop-in) keeps its rules
  in its own table, from a third-party apt repository: today the openSUSE Build Service
  `home:alvistack` repository for `xUbuntu_24.04` **[verify that it is still maintained
  and ships netavark ≥ 1.10 for 24.04, and the `firewall_driver` key at that
  version]**. That adds a repository and its key (the key pinned by fingerprint,
  packages by version, both removed by `destroy` and checked by V1), and this spike is
  re-run against it. Returning to Docker is the last resort.

  ⤷ **Needs** 2.1b · **Recalls** `podman.pool`, `net.vmnet` · **Produces** nothing kept
  · **Records** `spike.netavark-fw` (driver, versions, chain names, the rule order that
  passed) · **Check** Exit
- **2.2 Host firewall.** The lab's own nftables table `inet lab`, so
  netavark's and libvirt's iptables-nft rules are never edited. It is persisted as its
  own file, `/etc/lab/nftables-lab.nft` (`table inet lab` declared empty, deleted,
  then recreated, all in one `nft -f` transaction, so the first load after boot, with
  no table yet, does not fail and a bad file changes nothing), loaded by its own unit
  `lab-nftables.service`, **never** through `/etc/nftables.conf`, whose
  default `flush ruleset` would wipe netavark's rules. Netavark only adds ACCEPT rules
  (2.1c), so this table is the only default deny on forwarded traffic, and no lab
  container runs without it: at boot, or with the table missing, Traefik's 443 would be
  open to the LAN through `HOST_IP`. So `lab-nftables.service` is `Type=oneshot` with
  `RemainAfterExit=yes`, ordered like Ubuntu's own `nftables.service`
  (`DefaultDependencies=no`, `Before=network-pre.target`, so the table is in place
  before any interface comes up), `lab-platform.service` (2.1b), which starts every
  lab container, has `After=` and `Requires=lab-nftables.service`, and a rule change is applied with `systemctl reload`
  (`ExecReload=` runs `nft -f`), never a restart, so it never restarts Vault.
  - input chain, default drop: `iif lo` and `fib saddr type local` (the packet's
    source is one of the host's own addresses: the host talking to itself, e.g.
    resolved → CoreDNS, KVM agent → 8250, NFS) accepted first; then
    `established,related`; then new traffic to `127.0.0.0/8` from any interface but
    `lo` dropped (netavark sets `route_localnet` on bridges with published ports; after
    `established,related`, so replies to the host's own connections to a published port
    on `127.0.0.1` still pass); then each §5 port from its listed sources (tcp 22
    from `LAN_CIDR`, so the operator keeps SSH), and
    aardvark-dns on 1053 from the container pool. Rules match addresses, never
    interface names, because Phase 3 moves `HOST_IP` onto `cloudbr0`.
  - nat chain at `dstnat - 1`: TCP and UDP port 53 from the container pool to a local
    address (`fib daddr type local`) is redirected to 1053, on every network: netavark
    1.4 adds that redirect only for UDP, and not at all on internal networks (2.1c)
  - forward chain at priority `filter - 1`, policy drop, in this order:
    1. `ct state established,related` → accept (replies, e.g. be-1 answering Vault)
    2. `ct status dnat`: published container ports are DNAT'd past input, so they are
       matched here by `ct original proto-dst` and source, accepted if the source is
       listed for that port and dropped otherwise
    3. source in `VMNET_CIDR` → drop: the host never routes between VMs or out to the
       LAN for them
    4. from Vault's fixed address `172.30.3.10` only: to `10.250.0.112` tcp 6443 →
       accept (Vault to the k3s API); from Gitea's fixed address `172.30.3.11` only:
       tcp 443 to an address outside `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`
       → accept (Gitea's push mirror to GitHub). Any other container on `lab_egress`
       gets neither
    5. everything else is dropped by the policy. An accept here still passes netavark's
       FORWARD rules, which run after this chain
  - SSH itself is left as Ubuntu ships it; hardening it is a §15 option ("Host SSH
    hardening")
  Exit (each test from a network namespace, `ip netns add t; ip link add veth-t type
  veth peer name veth-h; ip link set veth-t netns t`, with an address from the source
  range under test on `veth-t` and `veth-h` attached to `cloudbr1`), against a
  temporary `traefik/whoami` container on `lab_edge` published on 443 (a §5 port,
  removed after): with a source address outside every §5 range it **times out**
  (dropped, not refused, rule 10); from a `VMNET_CIDR` address it answers; a VMNET
  source cannot reach a LAN address through the host. A test container on `lab_edge`
  cannot reach a LAN address; from a namespace attached to `lab_edge`'s bridge (with
  `route_localnet` on inside it and a route to `127.0.0.1` through the bridge gateway),
  a temporary listener on the host's `127.0.0.1` times out **[verify that the
  namespace can send it]**. A test container on `lab_egress` at Gitea's address
  (Gitea comes in 2.8; on a re-run after 2.4a or 2.8, the test runs by `podman exec` in
  Vault or Gitea instead) reaches tcp 443 on an external address (by address: CoreDNS
  comes in 2.3a), while `LAN_GATEWAY` times out; one at Vault's address answers a
  namespace listener at `10.250.0.112` tcp 6443, while tcp 22 times out; a container on
  `lab_egress` at any other address gets neither; a container on `lab_backend` resolves
  another by name, also with `dig +tcp`. With a broken rules file,
  `lab-nftables.service` fails and no lab container starts. SSH from a LAN machine
  still logs in.

  ⤷ **Needs** 2.1c · **Recalls** `net.host`, `net.vmnet`, `podman.pool`,
  `podman.networks`, `spike.netavark-fw` · **Produces**
  `/etc/lab/nftables-lab.nft`, `lab-nftables.service`, its `Requires=` in
  `lab-platform.service` · **Records** `fw.host`, `cmd.netns-test` (the
  namespace recipe, reused by later firewall tests) · **Check** Exit
- **2.3a CoreDNS.** Forward and reverse zones from §5, one zone file for `lab.test`
  (every asker gets the same answer, §5); upstream forwarding. Records `setup` writes
  (5.4b) go into the file with the SOA serial bumped, and the `file` plugin's `reload`
  interval (10 s) picks them up; the `reload` plugin only watches the Corefile.
  systemd-resolved: `DNSStubListener=no` (its 127.0.0.53:53 would block CoreDNS
  binding port 53), `DNS=127.0.0.1`, and `/etc/resolv.conf` re-linked to
  `/run/systemd/resolve/resolv.conf` (the default stub file would point at nothing).
  The original resolv.conf link is in the baseline.
  Exit: `dig vault.lab.test` and a PTR lookup answer; `dig gitea.lab.test` answers
  `10.250.0.1` from the host and from a LAN machine; a test record written to the file
  resolves within 15 s; external names resolve from the host; a test container on
  `lab_egress` resolves `vault.lab.test` and an external name through aardvark-dns.

  ⤷ **Needs** 2.2 · **Recalls** `net.host`, `net.vmnet`, `fw.host`, `podman.networks` · **Produces**
  `platform/coredns/` (Corefile, zone file), resolved drop-in · **Records**
  `dns.zones` (file path), `dns.add-record` (record + SOA bump) · **Check** Exit
- **2.3b NTP.** chrony serves time to `VMNET_CIDR` (`allow 10.250.0.0/24`). Installing
  `chrony` on Ubuntu 24.04 **removes** the `systemd-timesyncd` package (they conflict), so
  the baseline records it and `destroy` reinstalls it (rule 16).
  Exit: `chronyc tracking` is synchronised; `chronyc clients` is allowed from the
  namespace test address in `VMNET_CIDR` (`cmd.netns-test`).

  ⤷ **Needs** 2.2 · **Recalls** `cmd.netns-test`, `path.baseline` · **Produces** chrony
  config · **Records** `ntp.server` · **Check** Exit
- **2.4a Vault server.** Integrated **Raft** storage (snapshots in
  Phase 9); the web UI on (`ui = true`; its login comes in 3.5c); TLS listener on the bootstrap certificate (regenerated if it expired
  before 2.5b completed; a re-run never puts it back over a Vault-issued certificate);
  audit device to a file, rotated daily by a logrotate rule
  that sends Vault `SIGHUP` (Vault stops answering requests if its only audit
  device cannot be written, so a full disk or a broken rotation is an outage; the
  rotation keeps 14 days and the platform phase's check logs a warning on every `up`
  and `update` when the volume is over 80%).
  - Every restart comes back **sealed**, and a sealed Vault is running but unhealthy
    (`sys/health` 503). So the service's `healthcheck:` accepts sealed
    (`/v1/sys/health?sealedcode=200&uninitcode=200`) and nothing waits for "unsealed"
    before the unseal step: in the precursor a rollout that waited on readiness before
    unsealing deadlocked. Seal state is read by `up` and `update`, which unseal a sealed
    Vault themselves; the health check does not report it.
  - Vault's config is a bind-mounted file, which Compose does not watch; the platform phase
    compares each file it renders with the one in place and restarts the services whose
    config files changed (`docker-compose restart <service>`, rule 19), then unseals
    straight after.
  - The pinned image's user decides `mlock`: an image that runs as non-root without
    `IPC_LOCK` (Vault 2.x) needs `disable_mlock = true` (recommended with Raft anyway).
  Exit: `vault status` (against the bootstrap certificate) shows Initialized false,
  Sealed true, Storage raft; `podman healthcheck run vault` passes while sealed; a config
  edit restarts the container.

  ⤷ **Needs** 2.3a · **Recalls** `path.platform`, `podman.networks` · **Produces**
  `platform/vault/` (config, bootstrap cert), logrotate rule · **Records** `vault.addr`,
  `vault.audit`, `vault.image` · **Check** Exit
- **2.4b Init and unseal.**
  **Before** `operator init`: if `/var/lib/lab/vault-init.json` exists (kept by a
  previous `destroy`), move it and the backups it can open to
  `/var/lib/lab/archive/<timestamp>/`, so a rebuild never orphans an old snapshot.
  `operator init` (1 share for the lab; production uses 5/3 or KMS auto-unseal) to
  `/var/lib/lab/vault-init.json`; unseal. After a host reboot, `up` or `update` (local, root) finds Vault sealed
  and unseals it; pipeline jobs only detect a sealed Vault and stop.
  - `init` acts on the pair (Vault initialized?, key file present?): (no, no) → init;
    (yes, yes) → skip; (yes, no) → stop, the keys are lost; (no, yes) → the archive move
    above, never an overwrite. The file is created with `O_CREAT|O_EXCL`, mode `0600` from
    creation, and `fsync`ed before anything relies on it. The unseal key goes to
    `sys/unseal` on stdin (`key=-`), never in argv.
  Exit: `vault status` unsealed; restart the container, run `sudo ./bootstrap.sh up`,
  and it is unsealed with data intact.

  ⤷ **Needs** 2.4a · **Recalls** `vault.addr` · **Produces** init/unseal in
  `platform.py` (the automatic unseal in `up` and `update`), `vault-init.json` ·
  **Records** `path.vault-init`, `path.archive`; how `up` and `update` unseal ·
  **Check** Exit
- **2.5a PKI: the CA and its roles.**
  - Enable `pki/` and tune its `max_lease_ttl` to 10 years **before**
    generating the CA (the default 32 days would cap the CA and everything under it);
    `lab.test CA`. Generating a CA on a mount that already has one does not fail, it
    silently adds a second, so generation is guarded by `pki/config/issuers` (`default`
    is empty on a fresh mount). Roles:
    - `host-svc`: the host's service names, 30 days (Vault and the gateway; the
      gateway names include `grafana`, `prometheus` and `loki`, 2.7b, and `tempo` with
      §15's tracing option). The only
      role allowing IP SANs: a PKI role cannot restrict *which* IPs, so
      `allow_ip_sans=true` means any IP
    - `app-edge`: `app.lab.test` only, 30 days (fe-1, 8.7f)
    - all: `allow_wildcard_certificates`, `allow_localhost` and `allow_ip_sans`
      (except `host-svc`) set false explicitly (they default to allowed), and
      `allowed_uri_sans` empty (§6: no SPIFFE ID outside the mesh)
  Exit: `vault read pki/cert/ca` shows a 10-year `lab.test CA`; a re-run adds no second
  issuer; `pki/issue/app-edge` refuses `vault.lab.test`, `*.lab.test`, an IP SAN and a
  URI SAN.

  ⤷ **Needs** 2.4b · **Recalls** `vault.addr`, `path.vault-init` · **Produces** PKI
  setup in `platform.py` · **Records** `vault.mount.pki`, `vault.pki.roles` · **Check**
  Exit
- **2.5b Vault's own certificate, host trust and the renewal.** The renewal
  (`maintain.py`) issues Vault's certificate from `host-svc` and sends Vault `SIGHUP` (a reload keeps it
  unsealed; a restart would not), then puts the CA in the host trust store. It issues a
  host certificate only when it is missing or under 10 days remain: 30-day certificates
  outlive the build window, so there is no timer: the platform phase runs it every time,
  so every `up` and `update` does.
  Until 2.5e it authenticates with the root token; afterwards with `lab-bootstrap`.
  Exit: `curl https://vault.lab.test:8200/v1/sys/health` succeeds **without** `-k`;
  `openssl s_client` shows the issuer `lab.test CA`; `http://vault.lab.test:8200` fails
  (P3).

  ⤷ **Needs** 2.5a · **Recalls** `vault.addr`, `vault.pki.roles` · **Produces**
  `maintain.py`, `/var/lib/lab/certs/` · **Records** `path.lab-ca` (host trust-store
  file), `path.certs`, `cmd.maintain` · **Check** Exit; P3
- **2.5c KV and Transit.** KV v2 at `kv/` with the `bootstrap` / `pipeline` split (§6);
  Transit at `transit/`. Seed the SSH keypair at `kv/lab/pipeline/ssh`.
  Exit: `vault kv get kv/lab/pipeline/ssh` returns the public key; a Transit round trip
  on a throwaway key works and the key is deleted after.

  ⤷ **Needs** 2.4b · **Recalls** `vault.addr` · **Produces** KV/Transit setup in
  `platform.py` · **Records** `vault.mount.kv`, `vault.mount.transit`, `vault.kv.ssh` ·
  **Check** Exit
- **2.5f Separate roots: `pki_mesh` and `pki_app`** (§6 "Three roots"; the mesh root
  was decided 2026-11-05, §15). Same guarded code as 2.5a (tune to 10 years first; the CA
  generated only when `config/issuers` has no default):
  - `pki_mesh/`, root `lab mesh root`, **no roles**: its only use is
    `root/sign-intermediate` for the istiod CA (8.3a)
  - `pki_app/`, root `lab app root`, two roles, 30 days each, no IP, URI, wildcard or
    localhost SANs: `backend-gw` (`api.backend.lab.test` only, server auth only) and
    `frontend-client` (`frontend.app.lab.test` only, client auth only)
  - neither root goes into any trust store: mesh workloads get `pki_mesh` as
    `root-cert.pem` (8.3a); the backend gateway and fe-1's frontend get `pki_app` as a
    file (8.7d, 8.7g)
  Exit: both CAs are 10-year and a re-run adds no second issuer; `pki_mesh` lists no
  roles; `pki_app/issue/frontend-client` refuses `api.backend.lab.test` and an IP SAN,
  and its certificate's extended key usage is client auth only; neither root is in
  `/etc/ssl/certs`.

  ⤷ **Needs** 2.4b · **Recalls** `vault.addr`, `path.vault-init`, `decision.mesh-root` ·
  **Produces** the two mounts in `platform.py` · **Records** `vault.mount.pki_mesh`,
  `vault.mount.pki_app`, `vault.pki_app.roles` · **Check** Exit
- **2.5d Policies.** Policies `lab-bootstrap` and `lab-pipeline`, from `lab/policies/`.
  `lab-bootstrap` is the operator's automation identity, so it is broad by
  necessity. It still enumerates paths instead of using `*`: `kv/lab/*`, `kv/app/*`;
  `transit/keys/*` and `transit/encrypt|decrypt|rewrap/*`; `pki/issue/*`,
  `pki/sign/*`, `pki_app/sign/*`, `pki_mesh/root/sign-intermediate`, and
  `sys/mounts/{pki,pki_mesh,pki_app}/tune`; `sys/auth/k3s` (with `sudo`) and
  `auth/k3s/*`; `sys/auth/userpass` (with `sudo`) and `auth/userpass/users/operator`
  (3.5c); `auth/approle/role/*`; the named policies under `sys/policies/acl/*`;
  `sys/storage/raft/snapshot`; `sys/mounts/k3s-creds` and `k3s-creds/creds/*` (8.2c;
  `kv/lab/*` already covers the break-glass kubeconfig, and `kv/app/*` the Alloy write
  credential that the platform phase creates and renders, 2.7b).
  The **bodies** of the workload policies `api`, `vso-db` and `vso-monitoring` (read
  `kv/data/app/alloy-write` only) and of the console policy
  `operator-ui` are written here,
  by bootstrap (the root token now, `lab-bootstrap` from 2.5e on), from `lab/policies/` (a change to them is a bootstrap-side
  change, applied by `up` or `update` (the platform phase or the renewal), never by a
  pipeline job).
  `lab-pipeline` is narrower, so the pipeline can configure what it deploys but
  cannot widen any policy, and cannot mint a certificate for a control-plane name:
    - no write to `sys/policies/*` at all
    - Kubernetes auth only at `sys/auth/k3s` (with `sudo`), `auth/k3s/config`, and roles
      `auth/k3s/role/api`, `auth/k3s/role/vso-db` and `auth/k3s/role/vso-monitoring`, with `allowed_parameters` so each
      role's `token_policies` can only be the policy of the same name, and
      `denied_parameters` on the legacy `policies` alias
    - `transit/keys/customers` and `transit/keys/verify-*`, and the Transit
      encrypt/decrypt/rewrap paths for them
    - PKI: `pki/sign/app-edge` (never `host-svc`; it sets
      `allow_ip_sans=false`); `pki_app/sign/backend-gw` and
      `pki_app/sign/frontend-client` (sign only: keys are generated where they are
      used); never `pki/root/sign-intermediate`; `pki_mesh/root/sign-intermediate` with
      `allowed_parameters` listing every parameter the `mesh` job sends, each with its only
      allowed value: `csr` (any), `common_name=["istiod CA"]`,
      `permitted_dns_domains=["cluster.local"]`, `max_path_length=["0"]`,
      `ttl=["8760h"]` (ACL parameters match exact values, not ranges), plus
      `permitted_ip_ranges`/`permitted_uri_domains` pinned empty if the pinned Vault
      version accepts them; if it does not, an IP-SAN-capable sub-CA is an accepted gap,
      named in §15 (the istiod CA, 8.3a). No `"*"` key: `"*" = []` would
      also admit `use_csr_values=true`, which takes the subject from the CSR and bypasses
      the `common_name` pin. Vault ignores parameters it does not know without an error,
      so whether a constraint took effect is read from the issued certificate
      (`openssl x509 -text`), never inferred from the write succeeding
    - `kv/lab/pipeline/*`, `kv/app/*`; never `kv/lab/bootstrap/*`
    - the k3s identities (8.2c): `sys/mounts/k3s-creds` (create, read, update: the one
      mount it may enable), `k3s-creds/config`, `k3s-creds/roles/{lab-ci,lab-dbops,lab-operator}`
      and `k3s-creds/creds/{lab-ci,lab-dbops,lab-operator}`; on
      `kv/data/lab/breakglass/k3s-admin` **write only** (`create`, `update`: it deposits
      the kubeconfig after each k3s install and can never read or list it)
    - `sys/storage/raft/snapshot`
    - never `auth/approle/*`, `sys/mounts/*`, or any other policy name
  Exit: a token holding only policy `lab-pipeline` (made with the root token) is denied
  `pki/issue/host-svc`, `pki/root/sign-intermediate`, `kv/lab/bootstrap/cloudstack`
  and a read of `kv/lab/breakglass/k3s-admin`, and gets 403 from `pki_mesh/root/sign-intermediate` with `common_name="Evil CA"` or
  with `use_csr_values=true`; a CA it gets signed with the allowed values shows the name
  constraints in `openssl x509 -text` and chains to `lab mesh root`, not `lab.test CA`.

  ⤷ **Needs** 2.5a, 2.5c, 2.5f · **Recalls** `vault.mount.*`, `vault.pki.roles`,
  `vault.pki_app.roles`, `decision.mesh-root` · **Produces** `lab/policies/*.hcl` ·
  **Records**
  `vault.policy.*` (files), `vault.sign-intermediate` (path and pinned parameters, read
  by 8.3a); whether the IP/URI constraints were accepted · **Check** Exit
- **2.5e Bootstrap AppRole and root revocation.** AppRole `lab-bootstrap` (policy
  `lab-bootstrap`) written to `/var/lib/lab/approle.json`; every `up` and `update`
  re-issues its secret_id when under 7 days remain (§6). Then **revoke the root
  token.**
  Exit: the platform phase reads `kv/lab/pipeline/ssh` via AppRole; a manual AppRole
  login with `approle.json` (the runbook's Vault shell, 14.4) gives a working token;
  the root token is rejected.

  ⤷ **Needs** 2.5b, 2.5d · **Recalls** `path.vault-init`, `vault.kv.ssh` · **Produces**
  AppRole login in `lib/vault.py` · **Records**
  `vault.approle.lab-bootstrap` (file), `vault.root-token` (revoked, date) · **Check**
  Exit
- **2.6 Gateway (Traefik).** Pinned by digest, in the `lab_edge` and `lab_backend` networks,
  publishing **only** 443 (and 80 for `images/`, added in 2.7). Static config: the HTTPS
  entrypoint, a file provider reading `/var/lib/lab/traefik/dynamic.yml`, the access log
  to a file. `dynamic.yml` holds one router per hostname (`gitea`, `minio`,
  `minio-console`, `cloudstack`; 2.7b adds `grafana` and the `prometheus` and `loki`
  write paths with their middlewares) and **one** `host-svc` certificate carrying every
  gateway name in `gw.hosts` (no IP SAN); the renewal re-issues it when that set
  changes. Backends are plain HTTP: the platform containers by name on `lab_backend`
  (aardvark-dns), CloudStack at `10.250.0.1:8080` (the host's fixed `cloudbr1` address,
  reached through `lab_edge`'s gateway, so no extra host entry). Body size
  unlimited and read timeouts of 10 minutes on the `gitea` and `minio` routers (registry
  layers and golden images are large). The certificate is written by the renewal,
  which restarts Traefik when it issues a new one (Vault, DNS, Squid and SSH do not
  depend on the gateway).
  Exit: `curl https://gitea.lab.test/` reaches a placeholder backend (a pinned
  `traefik/whoami` container on `lab_backend`, removed in 2.8) with no `-k`;
  `openssl s_client -servername minio.lab.test` shows the gateway certificate, issued
  by `lab.test CA`, with every gateway name in its SANs; from a `LAN_CIDR` source
  (`cmd.netns-test`) 443 times out.

  ⤷ **Needs** 2.5e, 2.1b · **Recalls** `podman.networks`, `cmd.maintain`, `path.certs` ·
  **Produces** `platform/traefik/`, `dynamic.yml` · **Records** `gw.hosts` · **Check**
  Exit; P1
- **2.7 MinIO.** Behind the gateway (`https://minio.lab.test`, path-style; console at
  `minio-console.lab.test`); buckets `images`, `tfstate` and `loki` (Loki's store,
  2.7b; `tempo` too with §15's tracing option); one user and policy per
  bucket, credentials in Vault. `images` allows anonymous **read**: images hold no
  secrets (4.1b enforces that). For the SSVM, which copies templates by URL and does
  not trust `lab.test CA`, the gateway gets a second entrypoint, `:80`, whose only
  router passes `GET /images/*` to MinIO (§5, §6). The MinIO image is pinned by digest
  and, the first time it is pulled, saved with `podman save` to `/var/lib/lab/images/`
  (kept by `destroy`), and every later 2.7 `podman load`s it from there: the community
  edition's upstream image distribution has changed (§11), so a rebuild must not depend
  on pulling it again **[verify that `podman load` of the archive satisfies the
  digest-pinned `Image=` with `Pull=never`, so the unit starts with no pull]**.
  Exit: `mc` round-trips an object in each bucket with its own user, and is denied on
  the other bucket; from a system-VM-range address (`cmd.netns-test`),
  `http://HOST_IP/images/<test object>` answers and `http://HOST_IP/tfstate/` does not.

  ⤷ **Needs** 2.6 · **Recalls** `gw.hosts`, `vault.mount.kv`, `cmd.netns-test` ·
  **Produces** `platform/minio/`, MinIO setup in `platform.py`, `lib/minio.py`, the `:80`
  images route · **Records** `minio.url`, `minio.users` (KV path per user),
  `minio.images-http` (the `:80` URL form); `path.images-archive` · **Check** Exit
- **2.7b Telemetry stores and Grafana** (R6, R7; decided 2026-11-09, §15
  "Observability"). Three Compose services on `lab_backend` (internal, no published
  ports), images pinned by digest, each with a health check:
  - `prometheus`: `--web.enable-remote-write-receiver`,
    `--storage.tsdb.retention.time=7d`, `--storage.tsdb.retention.size=2GB`, volume
    `prometheus-data`. `rule_files`: the kubernetes-mixin and node-mixin **recording**
    rules (the mixin dashboards depend on them; no alert rules, no Alertmanager),
    rendered once with jsonnet at pinned commits, the node-mixin with
    `nodeExporterSelector: 'job="node-exporter"'` so both use the job labels Alloy sets
    (8.8a), and committed with their SHA-256. It scrapes only itself, `loki:3100` and
    `grafana:3000`.
  - `loki`: single binary (`-target=all`), `auth_enabled: false` (one tenant; the
    gateway guards it), schema v13 TSDB, `allow_structured_metadata: true` (Alloy sends
    structured metadata); chunks and index in MinIO bucket `loki` (`http://minio:9000`,
    path-style, its own user, 2.7); WAL, index cache and compactor on volume `loki-data`;
    `limits_config.retention_period: 168h`, `retention_stream: [{selector:
    '{job="k3s-audit"}', period: 720h}]`; `compactor.retention_enabled: true`,
    `delete_request_store: s3`.
  - `grafana` (OSS): admin from `/var/lib/lab/platform/grafana.env` (rendered from
    `kv/lab/bootstrap/grafana-admin`, created once, rule 18); anonymous access, sign-up,
    reporting, update checks and plugin preinstall off **[verify the key at the pin]**;
    `root_url=https://grafana.lab.test/`; SQLite on volume `grafana-data`; provisioned
    datasources with fixed uids `prometheus` (`http://prometheus:9090`) and `loki`
    (`http://loki:3100`); a dashboard provider reading `/var/lib/lab/grafana/dashboards`
    (read-only bind, `foldersFromFilesStructure: true`, `allowUiUpdates: false`, 30 s),
    a directory created here root-owned and handed to `lab-runner` (`0755`) by 2.10,
    which creates that user; the `monitoring` job fills it (8.8b),
    so dashboards stay CI-delivered (R5) while services, datasources and credentials
    stay with bootstrap. Through Grafana's API with the admin, the platform phase creates a
    Viewer service account `lab-verify` and stores its token at
    `kv/lab/pipeline/grafana-verify`: `verify` and the `monitoring` job read Prometheus
    and Loki only through `https://grafana.lab.test/api/datasources/proxy/uid/<uid>/…`
    **[verify that Viewer may use it at the pin]**, since neither has another read path.
  - **Gateway** (`dynamic.yml`; the gateway certificate's SANs gain `grafana`,
    `prometheus` and `loki`, so the renewal re-issues it): router `grafana` →
    `grafana:3000`; `prometheus-write`: `Host(prometheus.lab.test) &&
    Path(/api/v1/write) && Method(POST)` → `prometheus:9090`; `loki-push`:
    `Host(loki.lab.test) && Path(/loki/api/v1/push) && Method(POST)` → `loki:3100`.
    Nothing else on those two names is routed (404): the query APIs are reachable only
    from Grafana on `lab_backend`. Both write routers chain, in this order, `be1-only`
    (`ipAllowList.sourceRange: [10.250.0.112/32]`; netavark's DNAT keeps an outside
    source, as 2.1c proves and 2.2's forward rules rely on) and `alloy-auth` (basicAuth, `usersFile`
    `/var/lib/lab/traefik/alloy.htpasswd`, bcrypt, `0600`, `removeHeader: true`), so
    only be-1 may try a password.
  - **Write credential** (`decision.telemetry-auth`): `kv/app/alloy-write`
    `{username: alloy-v<N>, password: 32 random bytes}`, created once (rule 18); the
    platform phase renders its bcrypt hash into the users file, and VSO syncs it to be-1
    (8.8a). Rotation: a new KV version with the next username; the users file keeps the
    current and the previous entry until VSO has re-synced (remote write and Loki push
    drop a batch refused with a 4xx), then drops the old one. Chosen over a client
    certificate: Traefik's `clientAuth` cannot filter by subject without a plugin, so
    any `lab.test CA` client certificate would pass, and doing it safely needs a fourth
    root, a VSO PKI secret with rotation and per-SNI TLS options: too much for a
    write-only path from one VM. mTLS from a separate root is the upgrade path.
  Exit: on the host, `https://grafana.lab.test/login` loads without `-k` and both
  datasources report healthy; from the host, a POST to either write path gets 403;
  from a namespace test address `10.250.0.112` (`cmd.netns-test`; only while be-1 does
  not exist, since the address would clash; afterwards O5 probes from be-1), no credentials get
  401 and the correct ones reach the backend (its own status, never 401 or 403), while
  `10.250.0.111` gets 403; a GET of `/api/v1/query` or `/loki/api/v1/query_range` on
  those names gets 404; a re-run changes nothing.

  ⤷ **Needs** 2.7, 2.6, 2.5c · **Recalls** `gw.hosts`, `minio.url`, `minio.users`,
  `vault.mount.kv`, `podman.networks`, `cmd.maintain`, `cmd.netns-test`,
  `decision.observability`, `decision.telemetry-auth` · **Produces**
  `platform/{prometheus,loki,grafana}/`, the write routers and middlewares in
  `dynamic.yml`, the users-file renderer and Grafana setup in `platform.py` ·
  **Records** `mon.backends` (URLs, retention, datasource uids, users file, dashboards
  directory), `vault.kv.alloy-write`, `vault.kv.grafana-verify`, `gw.hosts` · **Check**
  Exit; O5 (write path)
- **2.8 Gitea and registry.** Behind the gateway (`https://gitea.lab.test`); SQLite
  database inside the Gitea volume (one user, no database network hop); admin in
  Vault; on `lab_backend` and `lab_egress` (at `172.30.3.11`, 2.1b). Users: `operator`
  (write to `lab/lab`),
  `lab-ci` (a bot: `write:package` on org `lab`, its token in `kv/lab/pipeline/gitea-ci`)
  and `lab-flux` (a bot: Read on `lab/lab` only, token scoped `read:repository` in
  `kv/lab/pipeline/gitea-flux`, for Flux, 8.1b).
  Public org `lab` for the container registry; private repository `lab/lab`, the
  origin the pipeline builds from; a push mirror of `main` to GitHub if the operator
  gives a token at the prompt (§6). `main` is seeded and protected in 3.5a. The 2.6
  placeholder backend is removed.
  Exit: `podman push` then `podman pull` of `gitea.lab.test/lab/hello:test` from the
  host succeed with no `insecure` entry in `registries.conf`; the Gitea web UI loads on the host at
  `https://gitea.lab.test`; the `lab-flux` token can clone `lab/lab` and its push is
  refused.

  ⤷ **Needs** 2.6 · **Recalls** `gw.hosts`, `vault.mount.kv` · **Produces**
  `platform/gitea/`, Gitea setup in `platform.py` · **Records** `gitea.url`,
  `gitea.repo`, `gitea.users` (KV paths), `git.remote.gitea`, `gitea.mirror` (on/off) ·
  **Check** Exit
- **2.9 Squid egress proxy.** `platform/squid/allowlist.txt` (Ubuntu archive and
  security mirrors, the container registries k3s, Flux, Istio, CloudNativePG, the Vault
  Secrets Operator, the k8s-monitoring chart's images (Alloy, the Alloy Operator, its
  config-reloader, kube-rbac-proxy, the hook's kubectl image, kube-state-metrics,
  node-exporter) and Caddy pull from, GitHub release downloads); clients
  allowed: `VMNET_CIDR` and the host itself (`10.250.0.1`, `127.0.0.1`: the Packer
  build VM's user-mode traffic, 4.1a; Squid runs with host networking, 2.1b, so it sees
  these real addresses); deny everything else; access log to a file, rotated daily.
  Exit: through the proxy, an allow-listed URL returns 200 and `example.com` returns
  403, which shows in the log.

  ⤷ **Needs** 2.2, 2.3a · **Recalls** `fw.host`, `cmd.netns-test` · **Produces**
  `platform/squid/` · **Records** `proxy.url`, `proxy.log`; `proxy.allowlist` · **Check**
  Exit
- **2.10 Runner.** One `act_runner`, registered to repository `lab/lab` only, as a
  systemd service (`lab-runner.service`; job logs in Gitea, the runner's own log in
  `journalctl -u lab-runner`) under a dedicated non-root user `lab-runner` with a
  **fixed UID/GID** (`runner.uid` in `config/lab.toml`, default 1990, so files kept in
  `/var/lib/lab/` across `destroy`/`up` keep their owner) in the `kvm` group only.
  This step also creates AppRole `lab-pipeline` (policy `lab-pipeline`) and writes its
  role_id and secret_id to `/var/lib/lab/runner/`. The runner has **one label,
  `host`** (in act_runner's config, `labels: ["host:host"]`, which runs jobs directly
  on the host instead of in a container): every job (`pr.yml`, `deliver.yml`,
  `schedules.yml`) runs directly on the host as `lab-runner`. Capacity **one job at a
  time**, so build memory never stacks and two jobs never share Terraform state.
  Workflows use only `run:` steps that call `git` and `python3 -B -m lab.<module>` (no
  JavaScript actions), so the host needs no Node.js.
  `lab-runner` owns `/var/lib/lab/backups/`, the CoreDNS zone file that `setup`
  updates and Grafana's dashboards directory that the `monitoring` job fills (2.7b). It builds container images with
  **rootless** Podman (`podman build`; no daemon, no socket, nothing root-owned) and golden
  images with Packer on `/dev/kvm`, and reaches everything else over the network with
  the `lab-pipeline` AppRole. Rootless needs:
  - a fixed 65536-ID range from `config/lab.toml` in `/etc/subuid` and `/etc/subgid`
    (`useradd --system` writes none); preflight checks it overlaps no existing range
  - `uidmap`, `slirp4netns` and `dbus-user-session` installed explicitly (Podman only
    recommends them; the last gives the user's systemd the cgroup delegation rootless
    Podman expects)
  - `loginctl enable-linger lab-runner`, so `/run/user/<uid>` exists for the service
    (`XDG_RUNTIME_DIR` set in `lab-runner.service`)
  - Ubuntu 24.04 restricts unprivileged user namespaces
    (`kernel.apparmor_restrict_unprivileged_userns=1`); rootless builds rely on the
    `podman`, `crun` and `buildah` AppArmor profiles Ubuntu ships, and the lab never
    switches that sysctl off **[verify `podman info` and a `podman build` as
    `lab-runner` from `lab-runner.service` at 4.9]**
  `host` jobs need no container engine, so act_runner gets no `DOCKER_HOST`, and
  `lab-runner` cannot open rootful Podman's socket (`root:root 0660`; checked in the
  Exit) **[verify act_runner at its pin starts with no container engine when its
  only label is `host`]**.
  **Accepted risk:** a pull request can edit its own workflow, so PR code runs with
  the same host access as `main`: `lab-runner`'s rights (the pipeline AppRole, `/dev/kvm`,
  the paths it owns), but not root, since there is no `docker` group. That is
  acceptable for a single-operator lab where every PR is the operator's own; §15 names
  what an enterprise does instead.
  Exit: the runner shows Online in Gitea (the workflow tests are in 3.5a, once `main`
  exists); `lab-platform.service` is active and every Phase 2 container healthy (`podman ps`
  shows each `healthy`);
  `id lab-runner` lists no `docker` group, `lab-runner` gets permission denied on
  `/run/podman/podman.sock`, and `podman info` as `lab-runner` reports
  rootless with its own ID range.

  ⤷ **Needs** 2.7, 2.7b, 2.8, 2.9 · **Recalls** `gitea.repo`, `vault.policy.*`, `dns.zones`,
  `mon.backends` ·
  **Produces** `lab-runner.service`, act_runner config, `/var/lib/lab/runner/` ·
  **Records** `runner.user` (UID/GID, sub-ID range), `runner.label`, `vault.approle.lab-pipeline`
  (path), `runner.owned-paths` · **Check** Exit

### Phase 3 — CloudStack (part of the platform, run by bootstrap)

Where to look when it goes wrong, from the first step: the management server log
(`/var/log/cloudstack/management/management-server.log`), the KVM agent log
(`/var/log/cloudstack/agent/agent.log`), failed async jobs (`cmk list asyncjobs`),
and system VM state (`cmk list systemvms`). What broke and how it was fixed goes into
the registry as `gotcha.*` keys (§17.1) as it happens.

Every Phase 3 call is adopt-before-create: it looks the object up by name and creates
it only on a definite NotFound (rule 18), so a re-run of `up` converges instead of
duplicating or skipping. The calls are hand-written `cmk`. Provider
`cloudstack/cloudstack` 0.7.0 (2026-09-21) also has resources for zone, physical
network, traffic type, pod, cluster, host, storage, IP ranges, offerings, roles,
accounts and global configuration, so 3.1c–3.3a could be declared in Terraform
instead; only the untagged mgmt network would still need `cmk` (its `vlan` is an
integer). That is an alternative, not the build: the `cmk` calls keep the admin keys
out of any Terraform state **[verify] those resources against 4.22.1.1 before
switching**.

- **3.1a Install.** CloudStack **4.22.1.1** (LTS, end of life 2027-12-01; Ubuntu
  24.04, Java 17), all-in-one, installed by a short Ansible role
  (`ansible/roles/cloudstack/`, run against the host by `provision.py`):
  - the `download.cloudstack.org` noble `4.22` repository, its key fetched and checked
    against the fingerprint in `config/versions.toml` (a `signed-by` keyring), and an apt pin
    on the exact version, so an upgrade never moves the schema underneath. First,
    `apt-get update` must succeed and `apt-cache policy cloudstack-management` must
    offer the pinned version; otherwise stop, naming the repository (its noble 4.22
    index was broken for months, which is why the previous build stayed on 4.21)
  - `cloudstack-management`, `cloudstack-agent` (configured when 3.1c adds the host),
    MySQL (bound to `127.0.0.1`, with the `my.cnf` settings the 4.22 install guide
    lists) and the NFS server (`/export/primary` and `/export/secondary` exported to
    `HOST_IP` and the §5 pod range only, never `*`)
  - the netplan file that creates `cloudbr0` and moves the LAN NIC and `HOST_IP` onto
    it (1.1 backed up `/etc/netplan`), applied inside a `netplan try` window that is
    confirmed only once `LAN_GATEWAY` answers
  - `cloudstack-setup-databases` (only as the database guard below allows), then
    `cloudstack-setup-management` while the `cloudstack-management` unit is not yet
    enabled

  None of the upstream `get.cloudstack.cloud` script's insecure defaults are carried
  over. No libvirt `auth_tcp="none"`: libvirt's TCP listener stays off, since one host
  never migrates VMs (**[verify]** what the agent setup writes to `libvirtd.conf` at
  4.22.1.1). AppArmor stays enforcing for libvirt; a denial is fixed with a local
  profile rule for the named path, never by disabling the profile **[verify]**. No
  `ufw allow from any`: the host firewall is 2.2's. No `admin`/`password` and no
  `cloud:cloud`: the `cloud` database password and the database encryption keys
  (`-m`, `-k`, which default to `password`) are generated per install into Vault
  `kv/lab/bootstrap/cloudstack`, written there before the databases are deployed.

  **The database guard.** The previous build's installer decided from a tracker file
  that recorded presence, not value, and re-marked its database step done whenever a
  `cloud` database existed, so a re-run never rebuilt or updated the database. Here no
  file decides: 3.1a asks MySQL directly whether `cloud` exists, with a query that
  tells "absent" apart from an error (rule 18).
  - absent: `cloudstack-setup-databases` deploys `cloud` and `cloud_usage`
  - present: nothing is deployed or changed, and the password and keys are read back
    from Vault, never regenerated (new keys cannot decrypt the existing database); if
    Vault lacks them or `db.properties` disagrees with them, 3.1a refuses. The newest
    `cloud.version` row must equal the pinned version (**[verify]** how a patch
    release records itself there); otherwise 3.1a stops before the management server
    starts, naming both versions (an older schema loops on 503, rule 2). A `cloud`
    database with no version row, or without `cloud_usage` beside it, is a
    half-finished deploy and is refused the same way. Every refusal says the way out
    is `destroy` then `up`
  - a deliberate rebuild is `destroy` (which drops `cloud` and `cloud_usage`, §14) and
    then `up`; there is no flag for it

  Readiness means `/client/api` on 8080 returns 200, not an open port; agent
  `TimeoutStartSec` above the readiness wait. Then, before anything else talks to it:
  - change the default `admin` password (generated into Vault
    `kv/lab/bootstrap/cloudstack`), and generate the admin's API key pair into the
    same path; every later admin call uses those keys
  - destroy and undefine libvirt's `default` network (`virbr0` runs dnsmasq on port
    53, which collides with CoreDNS); V-checks confirm it stays gone
  - NFS: pin `statd` and `lockd` ports in `/etc/nfs.conf` (§5), so the firewall can
    allow them
  - the KVM agent's `host.reserved.mem.mb` (§5)
  Exit: `/client/api` returns 200 through `https://cloudstack.lab.test` (the gateway
  route from 2.6 now has a backend); `cmk` logs in with the admin API keys; the old
  default password is rejected; `virsh net-list --all` shows no `default`; `HOST_IP`
  is on `cloudbr0` and the Phase 2 services still answer on it; a second run changes
  nothing (Ansible reports no changes, no database is deployed); with the newest
  `cloud.version` row changed by hand (and changed back afterwards), 3.1a refuses,
  naming both versions.

  ⤷ **Needs** 2.6, 2.10 · **Recalls** `gw.hosts`, `fw.host`, `net.host`,
  `vault.mount.kv`, `path.toolchain` · **Produces** `provision.py` (install),
  `ansible/roles/cloudstack/`, `lib/cloudstack.py` · **Records** `cs.api`,
  `cs.version`, `cs.repo`, `vault.kv.cs-admin`, `cs.nfs-ports`; the `cloudbr0` netplan
  file · **Check** Exit
- **3.1b Bridge netfilter** (before the zone, so no system VM ever starts with its
  bridged traffic filtered). **Off**, so bridged VM traffic never meets the host's
  forward chains (the lab's has policy drop, 2.2). Podman's netavark does not load `br_netfilter` (2.1c), but anything
  that does would switch bridge filtering on silently, and a sysctl.d file alone is
  applied only at boot. So the lab uses systemd's documented pair: a udev rule that runs
  `systemd-sysctl --prefix=/net/bridge` whenever `br_netfilter` loads, and a sysctl.d
  file setting the three `net.bridge.bridge-nf-call-*` values to 0.
  Exit: after `modprobe br_netfilter`, `sysctl net.bridge.bridge-nf-call-iptables` is 0;
  after a reboot (the module is then not loaded, so the key does not exist), `modprobe
  br_netfilter` again and it is still 0; the module is unloaded afterwards.

  ⤷ **Needs** 2.1b · **Recalls** `path.baseline` · **Produces** the udev rule and the
  sysctl.d file · **Records** `path.bridge-nf` · **Check** Exit
- **3.1c Zone, networks and host.** Advanced zone with the §5 ranges, built in
  CloudStack's order: zone → physical networks → pod → cluster → host (storage and
  enabling follow in 3.1d). Physical network 1 on `cloudbr0` (management, public,
  guest; tag `vpc`); physical network 2 on `cloudbr1` from 2.1a (guest; tag `vmnet`,
  for the mgmt shared network). With guest traffic on two physical networks, CloudStack
  places networks by tag, so every network offering in 3.3a carries the matching tag.
  `cloudbr0` has carried `HOST_IP` since 3.1a. `cloud0` is the link-local bridge the
  KVM agent creates for talking to system VMs. The host is added by key, not password:
  the management server's public key (`/var/lib/cloudstack/management/.ssh/id_rsa.pub`)
  goes into root's `authorized_keys` with `from="<HOST_IP>"`, and `addHost` is called
  with no password **[verify at 4.22.1.1]**. Ubuntu's default `PermitRootLogin
  prohibit-password` admits a key, and `from=` keeps that key usable from the host only.
  Exit: `cmk list hosts` shows the KVM host Up in a Disabled Advanced zone with both
  physical networks and their tags; host services from Phase 2 still reachable on
  `HOST_IP`.

  ⤷ **Needs** 3.1a, 3.1b · **Recalls** `net.host`, `net.vmnet`, `cs.api` · **Produces**
  zone build in `provision.py` · **Records** `cs.zone`, `cs.physnet.vpc`,
  `cs.physnet.vmnet`; the host's id · **Check** Exit
- **3.1d Storage, system VMs, enable.** Primary storage: NFS export `/export/primary`
  on the host; secondary storage: `/export/secondary`. Adding the first secondary
  storage registers the system VM template for the pinned version by itself (since
  4.16). 3.1d waits until that template is Ready, and seeds it with the package's
  `cloud-install-sys-tmplt` only if it is still missing when the wait ends; both happen
  before the zone is enabled, so the SSVM (secondary storage VM: copies templates) and
  CPVM (console proxy VM: the UI's VM console) can start. Also before enabling, the
  global setting `secstorage.allowed.internal.sites = HOST_IP/32`, so the SSVM starts
  allowed to download templates from the host's private address (4.3).
  **Platform-health gate** (H2, in `lib/cloudstack.py`): `/client/api` returns 200;
  the host is `Up`; the SSVM and CPVM exist and are `Running`; and every system VM
  and router that `cmk list systemvms` and `cmk list routers listall=true` call
  `Running` has a running libvirt domain of the same instance name in
  `virsh --readonly list` (the read-only socket needs no `libvirt` group
  **[verify]**). Bootstrap runs it with the admin keys; jobs and `verify` with the
  read-only `health` account's (3.2a). CloudStack's database is a claim, not a fact:
  after a host reboot it kept reporting dead VMs `Running`, because nothing reconciled
  it. The gate stops at
  the first failure, host first, and names it. It runs at this Exit and first in every
  job that calls CloudStack (`golden-image`, `setup`).
  Exit: `cmk list zones` shows an Enabled Advanced zone; SSVM and CPVM Running; H2
  passes; host services from Phase 2 still reachable on `HOST_IP`.

  ⤷ **Needs** 3.1c · **Recalls** `cs.zone`, `cs.nfs-ports`, `fw.host` · **Produces**
  storage + enable in `provision.py`, the health gate in `lib/cloudstack.py` ·
  **Records** `cs.storage`, `cs.systemvm-template` (registered by itself or seeded),
  `cs.ssvm-allowed-sites`, `cs.health` · **Check** Exit; H2
- **3.2a `cmk` and the scoped accounts.** Account `iac` in domain `lab` with a role
  allowing only the APIs Terraform and the pipeline jobs call, by their real names:
  - VPC and networks: `createVPC`, `updateVPC`, `deleteVPC`, `createNetwork`,
    `updateNetwork`, `deleteNetwork`, `createNetworkACLList`, `deleteNetworkACLList`,
    `createNetworkACL`, `updateNetworkACLItem`, `deleteNetworkACL`,
    `replaceNetworkACLList`
  - VMs: `deployVirtualMachine`, `updateVirtualMachine`,
    `changeServiceForVirtualMachine`, `destroyVirtualMachine` (with expunge),
    `start`/`stopVirtualMachine`, `addNicToVirtualMachine`,
    `removeNicFromVirtualMachine`, `registerSSHKeyPair`, `deleteSSHKeyPair`
  - ingress: `associateIpAddress`, `disassociateIpAddress`, `createPortForwardingRule`,
    `deletePortForwardingRule`
  - `createTags`, `deleteTags`, `queryAsyncJobResult`, and the `list*` calls for each
    of those plus zones, offerings, templates and accounts

  Global setting `allow.user.expunge.recover.vm = true`, and Terraform
  destroys with `expunge = true`, so a replaced VM's fixed `.10` address is free
  immediately. A second account, `publisher`, has a role with only
  `registerTemplate`, `deleteTemplate`, `listTemplates` and
  `updateTemplatePermissions`. A third account, `health`, has an Admin-type role with
  only `listHosts`, `listSystemVms` and `listRouters`, for the H2 gate in jobs and
  `verify` (**[verify]** that a custom Admin-type role can be cut down this far). All
  three API key pairs are in `kv/lab/pipeline/`.
  Exit: `cmk` with the `iac` keys lists zones and is denied `cmk list hosts`
  (admin-only); the `publisher` keys are denied `createVPC`; the `health` keys list
  hosts and are denied `createVPC` and `listAccounts`; a re-run creates nothing.

  ⤷ **Needs** 3.1d · **Recalls** `cs.api`, `vault.kv.cs-admin` · **Produces** accounts
  and roles in `provision.py` · **Records** `cs.account.iac`, `cs.account.publisher`,
  `cs.account.health`, `vault.kv.iac`, `vault.kv.publisher`, `vault.kv.health` ·
  **Check** Exit; N5
- **3.3a Offerings and the mgmt network.** Compute offerings matching §5 sizes; a
  redundant VPC offering whose UserData provider is **ConfigDrive** (userdata served
  as an attached ISO instead of from the router; a tier offering with ConfigDrive is
  only accepted under such a VPC offering); the VPC tier offering with ConfigDrive; a
  shared offering with DHCP for the mgmt network. The mgmt shared network is created
  with `cmk` on physical network 2 (`vlan=untagged`, `10.250.0.0/24`, gateway
  `10.250.0.1`, range `.100–.199`, `routerip=10.250.0.100`), because the Terraform
  provider cannot create an untagged shared network. `routerip` pins the network's
  virtual router outside the VMs' fixed `.110–.112` from the start (**[verify]** that
  it may sit inside the range). It is scoped to domain `lab` so `iac` can attach to
  it. Jobs look it up by name, like every other CloudStack object.
  Exit: `cmk list` shows each offering and the mgmt network; a re-run creates nothing.

  ⤷ **Needs** 3.2a · **Recalls** `cs.physnet.vmnet`, `cs.physnet.vpc`, `net.vmnet` ·
  **Produces** offerings + mgmt network in `provision.py` · **Records** `cs.offering.*`
  (names), `cs.network.mgmt` (name, id), `net.mgmt.router` · **Check** Exit
- **3.3b Spike: a mgmt NIC on a VPC VM** (the go/no-go for the CloudStack design, so
  it runs in the session 3.3a closes, before 3.5a–3.5c; §11). As `iac`, with a
  throwaway template (the upstream Ubuntu 24.04 cloud image, pinned by URL and
  checksum, registered by the admin and shared with `iac`): a VM in a test VPC tier
  accepts a second NIC on the mgmt network at a fixed address (`.199`), gets it, is
  destroyed and re-created at the same tier address and the same mgmt address, takes a
  port-forward on its VPC's public IP, and is then deleted with the template.
  If the hot-added NIC is refused, the spike tries the named fallback before failing:
  **deploy-time multi-network**, `deployVirtualMachine` with `networkids` (the tier and
  the mgmt network) and `iptonetworklist` (both fixed addresses), so both NICs exist
  at create. The 4.22 docs document a VM on a VPC tier plus shared networks
  (**[verify]** that the tier becomes the default NIC). The re-create and the
  port-forward are repeated the same way.
  Exit: every part above happened as `iac`, by hot-add or by the fallback; the mgmt
  network's router came up at `10.250.0.100`; nothing from the spike is left in
  `cmk list`.

  ⤷ **Needs** 3.3a, 3.2a · **Recalls** `cs.account.iac`, `cs.offering.*`,
  `cs.network.mgmt` · **Produces** nothing kept · **Records**
  `spike.mgmt-nic` (hot-add, fallback or fail; what was learned); only if both fail,
  `decision.mgmt-design` is opened and Phase 5 waits · **Check** Exit
- **3.5a Seed, workflows and branch protection.** The platform phase seeds `lab/lab`
  **once**, by pushing the current repository to the still-empty Gitea repo. The seed
  already contains `.gitea/workflows/`:
  - `pr.yml`, whose jobs grow with the repo: the no-Secrets-in-git rule always;
    `terraform plan -lock=false` + policy once `terraform/` exists; `trivy config` once
    there are Dockerfiles and manifests; kubeconform once there are manifests. There
    are no unit tests: each step's Exit, run by hand, and the pipeline are the tests
  - `deliver.yml` (triggers: push to `main`, `workflow_dispatch`), with every phase
    job, each running `python3 -B -m lab.<module>`; a phase not written yet runs its
    0.2a stub and passes
  - `schedules.yml`

  The seed commit carries `[skip ci]`, so the push itself starts no run. Then it
  protects `main`: no direct pushes (admin included), merge only from a pull
  request whose `pr.yml` status check passed, **0 required approvals** (one operator:
  Gitea does not count an author's approval of their own PR, so a required review would
  deadlock). After that, bootstrap never pushes again.
  Exit: a test branch pushed to `gitea` with a PR runs `pr.yml` (its job log prints
  `id`: `lab-runner`), and the PR can be merged only after it passes; a direct
  `git push gitea main` is rejected.

  ⤷ **Needs** 2.10 · **Recalls** `gitea.repo`, `git.remote.gitea`, `runner.label` ·
  **Produces** `.gitea/workflows/{pr,deliver,schedules}.yml`, seed +
  protection in `platform.py` · **Records** `ci.workflows`, `gitea.protection`,
  `cmd.pr-flow` (branch → push → PR → merge) · **Check** Exit
- **3.5b Hand-off: dispatch and follow.** Bootstrap dispatches `deliver.yml`
  through the Gitea API; `bootstrap.sh up` (and `update`) then follows the run and
  exits with its result; after a green run, `up` goes on to its local stage (9.3a–9.4).
  From here, `deliver.yml` runs one job per phase, in order:
  `golden-image` → `setup` → `base` → `tunnel` → `cluster` → `mesh` → `app` →
  `monitoring` → `verify`. Every job converges on every run (§2), so re-running
  the pipeline is safe, and each job checks the host's available memory against the
  §5 reserve before it starts (a job, not `up`, is what runs on the host).
  Exit: the first `deliver` run is triggered and visible in Gitea; `up` streams its job
  status; its jobs ran as `lab-runner` (the job log prints `id`).

  ⤷ **Needs** 3.5a, 3.3b · **Recalls** `ci.workflows`, `gitea.url`,
  `vault.approle.lab-pipeline`, `host.memory` · **Produces** dispatch + follow in
  `__main__.py`/`platform.py` · **Records** `ci.dispatch`; how `up` follows the run · **Check** Exit
- **3.5c Platform consoles** (R7; run by the platform phase). Read-only logins, each
  generated once into Vault (rule 18), for the five host consoles in §5:
  - Vault: `auth/userpass`, user `operator`, policy `operator-ui` (read and list on
    `sys/mounts`, `sys/auth`, `sys/policies/acl/*`, `kv/metadata/*`, `transit/keys/*`,
    the PKI roles and CA certificates; no `kv/data/*`, no encrypt or decrypt), token TTL
    8 h
  - MinIO: user `operator` with the built-in `readonly` policy
  - CloudStack: account `operator` with the built-in *Read-Only Admin* role
  - Gitea: the existing `operator` (2.8)
  - Grafana: user `operator`, role *Viewer*, created through Grafana's API with the
    admin (2.7b), password at `kv/lab/bootstrap/grafana-operator`
  - no command prints them: reading a login from Vault is a manual procedure in the
    runbook (14.4)
  Exit: from the host, each of the five URLs returns its login page with `curl --fail`
  and no `-k`, and each login, read from Vault with the `lab-bootstrap` AppRole, works
  (the Vault one is denied `kv/data/app/db`, the CloudStack one is denied `createVPC`,
  the Grafana one gets 403 saving a dashboard); from a `LAN_CIDR` source
  (`cmd.netns-test`) 443 and 8200 time out.

  ⤷ **Needs** 3.2a, 2.7, 2.7b, 2.8, 2.5e · **Recalls** `vault.addr`, `gw.hosts`, `minio.url`,
  `mon.backends`, `gitea.users`, `cs.api`, `vault.kv.cs-admin`, `vault.approle.lab-bootstrap`,
  `cmd.netns-test` · **Produces** `consoles.py` (run by the platform phase), the four
  logins · **Records** `console.urls`, `vault.kv.grafana-operator` · **Check**
  Exit; C1 (five consoles)

### Phase 4 — Golden image

- **4.1a Build through the proxy.** Packer `qemu` on user-mode networking. The build VM
  reaches the internet only through Squid, like every other VM: the autoinstall seed sets
  `proxy: http://10.250.0.1:3128` (reachable from the guest because user-mode traffic
  leaves from the host itself, which Squid's ACL allows), so the image is built
  against the same allow-list it will run with, and a package outside it fails the
  build. Ubuntu 24.04 autoinstall → qcow2.
  Where to look when it hangs: Packer's `-on-error=ask` keeps the build VM, and its
  serial console is logged to `builds/<version>/serial.log` (`-serial file:`), which
  shows where autoinstall stopped.
  Exit: `packer validate`; a build finishes and its package downloads show in Squid's
  log from `10.250.0.1`/`127.0.0.1`; a package outside the allow-list fails the build.

  ⤷ **Needs** 2.9, 1.3, 3.5b · **Recalls** `proxy.url`, `proxy.log`, `path.toolchain` ·
  **Produces** `packer/` template + autoinstall seed, `image.py` (build) · **Records**
  `img.packer`, `path.builds`, `img.iso-pin` · **Check** Exit
- **4.1b Image contents.** The image carries:
  - cloud-init, qemu-guest-agent, openssh-server, python3, chrony, nftables,
    wireguard-tools, podman (fe-1's container runtime), `lab.test CA` in the trust
    store
  - kernel argument `net.ifnames=0`, so NICs are `eth0`/`eth1` in attach order
    (netplan and nftables name them)
  - a netplan file that brings `eth1` up with DHCP, `use-routes: false`,
    `use-dns: false`, so it configures on hotplug, and sets `use-dns: false` on `eth0`
    too, so the VPC router never becomes a resolver (k3s's CoreDNS would otherwise
    forward `lab.test` queries to it). This DHCP file is only the fallback: the fixed
    mgmt address (§5) is written by 5.4a's userdata into a static netplan file for
    `eth1` that overrides it, so nothing depends on a lease (6.1b blocks DHCP on eth1)

  Never bake identity: the build **fails** if SSH host keys exist or `/etc/machine-id`
  is not empty. Whether the image applies ConfigDrive userdata is proven by 5.4a's Exit
  on a real VM.
  Exit: the build's last provisioner lists the packages above as installed and the CA
  in the trust store; a planted SSH host key fails the build.

  ⤷ **Needs** 4.1a, 2.5b · **Recalls** `img.packer`, `path.lab-ca` · **Produces**
  provisioners and netplan file in `packer/` · **Records** `img.eth1-fallback` (file
  name, so 5.4a's static file sorts after it), `img.contents` · **Check** Exit
- **4.3 Publish and register.** Version = SHA-256 over the `packer/` directory and the
  ISO pin in `config/versions.toml`. Upload to `images/<version>/` with its SHA-256; skip build
  and upload when that version already exists. As `publisher`, register it with
  `registerTemplate` from `http://HOST_IP/images/<version>/…` (the `:80` route, 2.7)
  with the checksum (the job first runs the H2 platform-health gate, 3.1d): the SSVM
  copies it into secondary storage and CloudStack verifies
  the checksum, so the plain-HTTP fetch cannot swap the image unnoticed. Grant `iac`
  launch permission (`updateTemplatePermissions accounts=iac`); wait for it to be ready
  (a refused URL shows in the template's status: check `cs.ssvm-allowed-sites`).
  **Publishing never changes running VMs:** the version VMs use is pinned in
  `config/lab.toml` (`golden_image`), and moving it is a pull request. The seed ships
  `golden_image = ""`, which `setup` accepts **only while the state holds no VMs** (it
  then uses the newest published version and prints it). After the first `deliver`,
  the operator pins that version by pull request; from then on an empty value fails
  `setup`.
  Exit: `cmk list templates` shows the version ready; an unchanged re-run builds
  nothing; the `golden-image` job passes in `deliver`.

  ⤷ **Needs** 4.1b, 3.2a, 2.7 · **Recalls** `minio.url`, `minio.users`,
  `minio.images-http`, `cs.account.publisher`, `vault.kv.publisher`,
  `cs.ssvm-allowed-sites`, `cs.health`, `vault.kv.health` · **Produces** publish + register in `image.py`, the
  `golden-image` job · **Records** `img.template`, `cfg.golden-image`; `img.version` ·
  **Check** Exit

### Phase 5 — Terraform: VPC, tiers, VMs

- **5.1 Provider and remote state.** Pinned `cloudstack/cloudstack` provider (0.7.0) and
  `ansible/ansible` provider (for the inventory resources, rule 8), lock file
  committed; provider `api_url = https://cloudstack.lab.test/client/api` (through the
  gateway). S3 backend on MinIO: `endpoints.s3 = https://minio.lab.test`,
  `use_path_style`, `use_lockfile`, a dummy `region`, and the flags a non-AWS S3 needs
  (`skip_credentials_validation`, `skip_region_validation`,
  `skip_requesting_account_id`, `skip_metadata_api_check`, `skip_s3_checksum`). `iac`
  keys and MinIO credentials are injected from Vault as environment variables at run
  time; data lookups for zone, offerings, template, mgmt network id.
  `pr.yml` plans with `-lock=false`: PR jobs only read state, and must never block a
  `deliver` run (the runner runs one job at a time, so they cannot overlap anyway).
  Exit: `terraform init` + `validate` against the MinIO backend; `terraform state list`
  is empty (the state object is first written by the first gated apply, 5.3b).

  ⤷ **Needs** 4.3, 3.3a · **Recalls** `cs.api`, `vault.kv.iac`, `minio.users`,
  `cs.offering.*`, `cs.network.mgmt`, `img.template` · **Produces** `terraform/`
  provider + backend + data, `lib/terraform.py` · **Records** `tf.backend` (bucket,
  key), `tf.env` (how credentials arrive) · **Check** Exit
- **5.2 Network.** VPC `10.0.0.0/16` on the redundant offering; tiers from §5; one ACL
  list per tier, **default deny in both directions**. The only allow rules, each
  written as a matching egress rule on one side and ingress rule on the other:
  - LAN → tier-frontend: TCP 443 from `LAN_CIDR` to `10.0.1.10` (the only
    public-facing rule)
  - fe-1 ↔ tun-1: UDP 51820 between `10.0.1.10` and `10.0.2.10`
  - be-1 ↔ tun-1: UDP 51821 between `10.0.3.10` and `10.0.2.10`
  - nothing at all between tier-frontend and tier-backend
  - **no internet egress for any tier**

  `parallelism=1` for ACL rules. Steps 5.2 and 5.3a–5.3b merge in **one** pull request:
  `setup` applies only when `policy/` exists, and plans without applying before
  that, so no network is ever applied ungated.
  Exit: plan shows the VPC, tiers and ACLs; nothing applied yet.

  ⤷ **Needs** 5.1 · **Recalls** `tf.backend`, `net.host` (`LAN_CIDR`) · **Produces**
  `terraform/vpc.tf`, `tiers.tf`, `acls.tf` · **Records** `net.vpc` (CIDR, tiers),
  `tf.acls` · **Check** Exit
- **5.3a Policy rules.** Conftest rules (OPA's Rego language) over
  `terraform plan -json`:
  - no ingress from `0.0.0.0/0`
  - every tier ends in deny-all, both directions
  - no inter-tier allow except the two WireGuard flows to tun-1
  - no rule of any kind between tier-frontend and tier-backend
  - written with the resources they cover (5.4a, 5.4b): every VM's default NIC is on a
    VPC tier, and it has exactly one mgmt NIC; the only public port-forward is
    tier-frontend 443 → fe-1; the ingress public IP is never replaced or destroyed
    (`teardown` destroys it without the gate: §14 runs `terraform destroy` directly)
  Exit: `conftest test` passes the real plan; fixture plans opening `0.0.0.0/0:22`, and
  allowing tier-frontend → tier-backend on any port, are rejected.

  ⤷ **Needs** 5.2 · **Recalls** `net.vpc`, `tf.acls` · **Produces** `policy/*.rego`,
  `policy/fixtures/` · **Records** `policy.dir`, `policy.fixtures` · **Check** Exit
- **5.3b The gated apply.** The plan JSON carries no credentials, so the `setup` job
  (`python3 -B -m lab.setup`) separately checks, before planning, that the API key in use
  resolves to account `iac` (`listAccounts`), after the H2 platform-health gate (3.1d).
  It runs **plan → policy → apply**, and apply is unreachable
  if the policy fails. This is the first apply: the network goes in here.
  Exit: the real plan passes and is applied by the `setup` job; with a fixture rule
  added, the policy fails and nothing is applied; with admin keys, `setup` refuses
  before planning.

  ⤷ **Needs** 5.3a · **Recalls** `policy.dir`, `cs.account.iac`, `tf.env`, `cs.health`, `vault.kv.health` · **Produces**
  `setup.py` (plan → policy → apply), the `setup` job · **Records** — ·
  **Check** Exit; N5
- **5.4a Compute.** Lab SSH public key from Vault. Each VM's **default NIC
  (eth0) is its tier**: default route, ConfigDrive userdata. The **mgmt NIC (eth1)** is
  attached with `cloudstack_nic` at its fixed address from §5 (`ip_address`), and the
  userdata writes that address into a static netplan file for `eth1` (§5), which
  overrides the image's DHCP fallback (4.1b). Policy rules for the NICs (5.3a) go in
  with them.
  **If 3.3b took the fallback** (**[verify]**): `cloudstack_instance` takes one
  `network_id`, so the `setup` job deploys the three VMs itself, between applying the
  network and the ingress, with `deployVirtualMachine` carrying both networks and both
  fixed addresses (adopted by name on a re-run; expunged and re-deployed when the
  template or offering changes). Terraform keeps the VPC, tiers, ACLs, public IP,
  port-forward (the VM found through a data source) and the `ansible_host` resources;
  `cloudstack_nic` goes, and 5.3a's NIC rules become checks the `setup` job runs on its
  deploy parameters.
  Exit: apply; all VMs Running and reachable over SSH from the host on their mgmt NIC
  at the fixed address; `networkctl status eth1` shows the static address (so the
  ConfigDrive userdata applied);
  **fe-1 cannot reach be-1's tier address `10.0.3.10`** on any port (N1 holds before
  the tunnel exists).

  ⤷ **Needs** 5.3b, 3.3b · **Recalls** `vault.kv.ssh`, `img.eth1-fallback`,
  `cs.network.mgmt`, `spike.mgmt-nic`, `cfg.golden-image` · **Produces**
  `terraform/compute.tf`, userdata template, NIC rules · **Records** `vm.<name>` (tier
  and mgmt addresses), `ssh.access` (user, key source) · **Check** Exit; N1
- **5.4b Ingress, inventory and DNS.** A VPC public IP with port-forward 443 →
  `fe-1:443`, and its policy rules (5.3a).
  Ansible's inventory: Terraform declares an `ansible_host` resource per VM (mgmt
  address, groups `frontend`, `hub`, `backend`), and Ansible reads
  them through the `cloud.terraform.terraform_provider` inventory plugin with absolute
  paths (rule 8), so every job sees the same hosts without passing files between
  jobs. The `setup` job writes `app.lab.test` (public IP) and `k3s.lab.test`
  (`10.250.0.112`) into CoreDNS.
  Exit: `ansible-inventory --graph` lists the groups from state; `dig app.lab.test`
  answers the public IP; a fixture plan replacing the public IP is rejected.

  ⤷ **Needs** 5.4a, 2.3a · **Recalls** `dns.add-record`, `dns.zones`, `vm.<name>` ·
  **Produces** `terraform/ingress.tf`, `outputs.tf`, inventory file, DNS writer ·
  **Records** `net.public-ip`, `ansible.inventory` (file, plugin) · **Check** Exit

### Phase 6 — Base configuration and the tunnel

- **6.1a `base` role: DNS, time and proxy (all VMs).**
  - DNS and NTP from `10.250.0.1`.
  - Proxy environment for apt, the shell, containerd (be-1) and Podman (fe-1):
    `http_proxy` **and** `https_proxy` = `http://proxy.lab.test:3128`, with `no_proxy`
    covering `lab.test`, `VMNET_CIDR`, `LAN_CIDR`, the VPC, the overlay `10.99.0.0/16`,
    the pod and service CIDRs, `.svc` and `.cluster.local`.
  - `unattended-upgrades` disabled: VMs are immutable; patching = a new image (Phase 4)
    and replacing the VM.

  Exit: from fe-1, `apt-get update` works through the proxy; a direct `curl` to the
  internet fails; `curl https://vault.lab.test:8200` succeeds without `-k`; a second run
  reports `changed=0`.

  ⤷ **Needs** 5.4b, 2.3b · **Recalls** `ansible.inventory`, `ssh.access`, `proxy.url`,
  `ntp.server`, `net.vpc` · **Produces** `ansible/roles/base/` (DNS, time, proxy),
  `base.py`, the `base` job · **Records** `vm.no-proxy` (the list, one place),
  `ansible.dropins` (file names per role) · **Check** Exit; N3
- **6.1b VM firewall.** nftables, the lab's rules in their own table `inet lab` at
  priority `filter - 1` (so k3s's and flannel's iptables rules on be-1 are untouched),
  default drop both ways on every interface the role names:
    - **eth1 (mgmt):** in from `10.250.0.1`: SSH; on be-1 also the k3s API (6443, for
      Vault's token reviews, the jobs and the break-glass kubeconfig).
      Out to `10.250.0.1` only (eth1 is static,
      §5, so no DHCP is needed). No default route via eth1
    - **eth0 (tier):** only the step 5.2 flows for this VM (fe-1: TCP 443 in, UDP 51820
      to tun-1; tun-1: UDP 51820/51821 from the spokes; be-1: UDP 51821 to tun-1). Host
      firewalls repeat the ACLs, so one misconfigured
      layer is not enough to open a path
    - **forward (be-1 only),** after `established,related`:
      - k3s ServiceLB exposes ports by DNAT (hostPort), so those packets never reach
        the input chain. Accept `ct status dnat iifname "wg1" ip saddr 10.99.0.2 ct
        original proto-dst 8000`; **drop every other DNAT'd packet**, which also
        closes the Istio gateway's status port 15021 on every node address
      - pod traffic masqueraded out eth1, allowed only to `10.250.0.1` on 53, 123, 443
        (gateway: registry pulls, Flux's git and chart fetches, Alloy's remote write and
        Loki push) and 8200 (the api, VSO)
    - node-exporter (8.8d) listens on `10.0.3.10:9100` in the host network namespace:
      eth0's default drop refuses it from outside, and pods reach it through `cni0`

  Exit: `curl` from one VM to another VM's mgmt address times out; VM →
  `10.250.0.1:8200` still succeeds; 6.1a's Exit still passes; `nft list table inet lab`
  on each VM shows only its role's rules (N4); once 8.8d runs, `10.250.0.112:9100` and
  `10.0.3.10:9100` time out from the host.

  ⤷ **Needs** 6.1a · **Recalls** `net.vpc`, `vm.<name>`, `ansible.dropins` · **Produces**
  the nftables template in `base` · **Records** `fw.vm` (table, file, per-VM rule
  summary) · **Check** Exit; N4
- **6.2a WireGuard keys and tunnels.** Three plays, in order: (1) on
  all three VMs, generate a key if none exists (the private key never leaves the VM)
  and publish the public key to Vault `kv/lab/pipeline/wg/<vm>`; (2) configure the hub
  with both spokes' keys; (3) configure each spoke with the hub's key. The underlay is each VM's **tier** address; the overlay addresses
  are the only `AllowedIPs`, so no Endpoint ever falls inside its own `AllowedIPs`
  (rule 9).

  | VM | Interface | Address | Listens | Peer | Peer Endpoint | Peer `AllowedIPs` |
  |---|---|---|---|---|---|---|
  | fe-1 | `wg0` | `10.99.0.2/24` | — | tun-1 | `10.0.2.10:51820` | `10.99.0.1/32`, `10.99.1.0/24` |
  | tun-1 | `wg0` | `10.99.0.1/24` | 51820 | fe-1 | (learned) | `10.99.0.2/32` |
  | tun-1 | `wg1` | `10.99.1.1/24` | 51821 | be-1 | (learned) | `10.99.1.2/32` |
  | be-1 | `wg1` | `10.99.1.2/24` | — | tun-1 | `10.0.2.10:51821` | `10.99.1.1/32`, `10.99.0.0/24` |

  - The spokes dial the hub (`PersistentKeepalive=25`), so the hub needs no Endpoint
    for them and spoke replacement never touches the hub's config beyond the key.
  - `wg-quick@wg0` / `wg-quick@wg1` enabled, restart on failure; `wg-quick` installs
    the routes for `AllowedIPs`.

  Where to look when a handshake never happens, layer by layer: `wg show` (latest
  handshake, transfer counters), the VPC ACL (UDP 51820/51821 both directions, 5.2),
  each VM's `nft list table inet lab` counters on eth0, then whether the published
  keys in Vault match `wg show <if> public-key` on each side.
  Exit: `wg show` on tun-1 has a recent handshake with both spokes; tun-1 reaches
  `10.99.0.2` and `10.99.1.2`; fe-1 cannot yet reach `10.99.1.2` (the hub does not
  forward until 6.2b).

  ⤷ **Needs** 6.1b · **Recalls** `vm.<name>`, `fw.vm`, `vault.mount.kv` · **Produces**
  `ansible/roles/wireguard_hub/`, `wireguard_spoke/`, `tunnel.py`, the `tunnel` job ·
  **Records** `wg.keys` (KV path), `net.overlay` · **Check** Exit
- **6.2b The hub's policy and the tunnel proofs.**
  - **tun-1 is the policy point.** `ip_forward=1` (be-1 has it too, for k3s, but its
    forward chain admits nothing from `wg1` except the DNAT'd 8000, 6.1b). Its
    `inet lab` forward chain: accept `iif wg0 oif wg1 ip saddr 10.99.0.2 ip daddr
    10.99.1.2 tcp dport 8000`; accept `established,related`; **log and drop everything
    else** (prefix `lab-hub-drop`). No NAT: be-1 sees the frontend's real overlay address.
  - On be-1, `wg1` input accepts only TCP 8000 from `10.99.0.2` (used by this step's
    test listener; once k3s runs, the real port 8000 arrives through forward, 6.1b).
    On fe-1, `wg0` accepts only `established,related`. fe-1's packets to `10.99.1.2`
    route via `wg0`, so the kernel picks `10.99.0.2` as their source, which is what
    tun-1 and be-1 match on.

  Exit: a test listener on
  be-1 (`systemd-run` a one-line HTTP server on `10.99.1.2:8000`, rule 10) answers fe-1;
  from fe-1, `10.99.1.2:22` times out and tun-1's log shows `lab-hub-drop`; with
  `wg0` or `wg1` down, `10.99.1.2:8000` is unreachable from fe-1 (N2).

  ⤷ **Needs** 6.2a · **Recalls** `net.overlay`, `fw.vm` · **Produces** hub forward
  chain and spoke input rules in the WireGuard roles · **Records** `wg.hub-log`
  (prefix, where it lands), `cmd.test-listener` · **Check** Exit; N2, N6

### Phase 8 — Application: database, encryption service, api, frontend, monitoring

Everything in k3s comes from `clusters/backend/` through Flux (8.1b). A step that "adds"
a manifest adds it to that tree in its pull request; the job then only writes the step's
run-time objects (§6) and waits (`cmd.flux-wait`).

From 8.2c on, every job talks to k3s as `lab-ci` (or `lab-dbops` for the database
pod), never as cluster-admin. An Exit that needs more (a throwaway pod as `sa/api`,
`istioctl` port-forwards, `kubectl auth can-i --as`, a hand edit Flux should revert) is
run by the learner with the break-glass kubeconfig (runbook), and the API audit log
(8.2d) records it.

- **8.1 k3s on be-1** (`k3s` role).
  - Pinned version, fetched through the proxy.
  - Flags:
    - `--disable=traefik`: the Istio Gateway is the only ingress
    - `--secrets-encryption`
    - `--node-ip=10.0.3.10`
    - `--tls-san` = `10.250.0.112` and `k3s.lab.test`
    - `--write-kubeconfig-mode=600`
  - Default flannel CNI.
  - containerd proxy and `no_proxy` from 6.1a; `registries.yaml` trusts
    `gitea.lab.test` (through the system trust store, which has `lab.test CA`).
  - Kubeconfig, pointed at `https://k3s.lab.test:6443`, stored in Vault
    `kv/lab/pipeline/k3s`: the build's scaffold, cluster-admin, used by the jobs only
    until 8.2c replaces it with scoped identities and moves it to break-glass.

  Exit: from the host, `kubectl get nodes` with the kubeconfig from Vault (`cmd.kubeconfig`)
  shows the node Ready; `k3s secrets-encrypt status`
  shows enabled and a throwaway Secret's value is absent from
  `/var/lib/rancher/k3s/server/db/state.db` (S2); a throwaway pod with `lab.test CA` mounted from a throwaway
  ConfigMap resolves `vault.lab.test` and gets 200 from `/v1/sys/health`.

  ⤷ **Needs** 6.1b · **Recalls** `vm.be-1`, `vm.no-proxy`, `fw.vm`, `gitea.url` ·
  **Produces** `ansible/roles/k3s/`, `cluster.py`, `lib/kube.py`, the `cluster` job ·
  **Records** `k8s.api`, `k8s.version`, `vault.kv.kubeconfig`, `cmd.kubeconfig` (temp
  file recipe, rule 21) · **Check** Exit; S2
- **8.1b Flux and the GitOps tree.** (Flux: controllers that make the cluster match a
  git revision: a `GitRepository` fetches it, a `Kustomization` applies a path of it and
  prunes what was removed, a `HelmRelease` installs a chart.)
  - `clusters/backend/flux-system/gotk-components.yaml`, generated by the pinned
    `flux install --export --components=source-controller,kustomize-controller,helm-controller`
    and committed (a Flux upgrade is a pull request). The `cluster` job applies it
    server-side; `flux bootstrap` is not used, because it pushes to `main`, which is
    protected (3.5a).
  - (From 8.2c, the first install below, before Flux exists, runs on be-1 through the
    `k3s` role with the node's own admin config; later runs only refresh the two Secrets,
    as `lab-ci`.)
  - The `cluster` job writes, on stdin, Secret `flux-system/gitea-auth` (`username`
    `lab-flux`, `password` = the token from `kv/lab/pipeline/gitea-flux`, `ca.crt` =
    `lab.test CA`) and Secret `flux-system/lab-ca` (`ca.crt`), then applies
    `gotk-sync.yaml`: GitRepository `lab` (`https://gitea.lab.test/lab/lab.git`, branch
    `main`, every minute) and the root Kustomization (path `./clusters/backend`,
    `prune: true`). From then on Flux manages its own sync objects from git.
  - Path: source-controller → be-1's eth1 → `10.250.0.1:443` → the gateway → Gitea, the
    flow 6.1b already allows; `no_proxy` covers `lab.test`, so Squid is not involved; TLS
    is verified against `lab.test CA`.
  - `kustomizations.yaml` starts with `platform` (namespaces `vault-auth`,
    `istio-system`, `cnpg-system`, `vso`, `db`, `app`, `ingress`, `monitoring`, `node-agents` with their PSA and ambient
    labels, §7; `monitoring` is ambient and PSA `restricted` if Alloy, kube-state-metrics
    and the Alloy Operator render compliant, `baseline` otherwise; `node-agents` is
    ambient, PSA `privileged` enforced and `restricted` warned, because node-exporter
    and alloy-audit need host access, 8.8d); later steps add their Kustomization and its `dependsOn`.

  Exit: `flux get sources git` shows `lab` Ready at `main`'s HEAD; Kustomization
  `platform` is Ready and the namespaces carry their labels; a label removed by hand
  comes back after `flux reconcile kustomization platform`; with a wrong `ca.crt` in
  `gitea-auth` the GitRepository fails with `x509: certificate signed by unknown
  authority` (TLS is verified, never skipped).

  ⤷ **Needs** 8.1, 2.8 · **Recalls** `cmd.kubeconfig`, `gitea.url`, `gitea.users`,
  `path.lab-ca`, `code.versions` · **Produces** `clusters/backend/{kustomization.yaml,
  flux-system/,kustomizations.yaml,platform/}`, Flux install in `cluster.py`,
  `lib/flux.py` · **Records** `flux.source` (GitRepository, URL, auth Secret),
  `flux.kustomizations` (names, `dependsOn`, gates), `cmd.flux-wait` (reconcile, then
  wait for Ready at the merged revision) · **Check** Exit
- **8.1c Chart mirror.** Flux never fetches a chart from the internet. The `cluster` job
  pulls each pinned chart with `helm pull` on the host (Istio `base`, `istiod`, `cni`,
  `ztunnel`; `cloudnative-pg`; `vault-secrets-operator`; `k8s-monitoring`, whose
  subcharts are inside its archive),
  checks its SHA-256 against `config/versions.toml`, and pushes it to
  `oci://gitea.lab.test/lab/charts` with the `lab-ci` credential; a version already
  there is skipped. `platform/sources.yaml` declares HelmRepository `lab-charts`
  (`type: oci`, `certSecretRef: lab-ca`; org `lab` is public, so no pull credential).
  Exit: `helm show chart oci://gitea.lab.test/lab/charts/istiod --version <pin>` works
  from the host; `lab-charts` is Ready; a re-run pushes nothing; a wrong SHA-256 pin
  stops the run before the push.

  ⤷ **Needs** 8.1b · **Recalls** `flux.source`, `gitea.users`, `code.versions` ·
  **Produces** chart mirror in `cluster.py`, `lib/helm.py`, `platform/sources.yaml` ·
  **Records** `flux.charts` (OCI URL, pinned versions) · **Check** Exit
- **8.2a Vault's Kubernetes auth.** On the host Vault:
    - Kubernetes auth at `auth/k3s`, pointed at `https://k3s.lab.test:6443` with the
      k3s CA (the same name the kubeconfig uses).
    - Reviewer: ServiceAccount `vault-auth` in namespace `vault-auth`, with
      `system:auth-delegator` and a long-lived token Secret, all in
      `platform/vault-auth.yaml` (Kubernetes fills the token in; git holds no value).
      The `cluster` job waits for `platform`, then reads the token into `auth/k3s/config`
      (from 8.2c the `k3s` role reads it on be-1, so no job identity can read Secrets in
      `vault-auth`).
  Exit: `kubectl auth can-i create tokenreviews --as=system:serviceaccount:vault-auth:vault-auth`
  says yes; `vault read auth/k3s/config` shows the k3s CA and host.

  ⤷ **Needs** 8.1b, 2.5d · **Recalls** `k8s.api`, `cmd.kubeconfig`, `cmd.flux-wait`,
  `vault.approle.lab-pipeline`, `vault.policy.*` · **Produces**
  `platform/vault-auth.yaml`, auth setup in `cluster.py` · **Records** `vault.auth.k3s`,
  `k8s.sa.vault-auth` · **Check** Exit
- **8.2c Least-privilege k3s identities** (rule 25: the mesh guards the network, RBAC
  guards the API). Until now every job held cluster-admin, which walks past every
  `AuthorizationPolicy`: `pods/exec` gives `psql` as `postgres` over the socket;
  `pods/portforward` has the kubelet dial `localhost` inside the pod's network namespace,
  so ztunnel never sees it; it reads every Secret, edits an `AuthorizationPolicy` or
  `PeerAuthentication`, and can create a pod with `serviceAccountName: api` that borrows
  the api's SPIFFE identity. Flux's controllers already do every apply, so nothing else
  needs to write manifests.
  - `platform/access/` (applied by Flux): namespace `lab-access` with ServiceAccounts
    `lab-ci`, `lab-dbops`, `lab-operator` and `vault-token-issuer` (a long-lived token
    Secret, like `vault-auth`); namespaces `probe` (ambient) and `probe-plain` (not), PSA
    `restricted`, each with ServiceAccount `probe`, for `verify`'s negative probes (Z1,
    Z2, O3). A pod can only use a ServiceAccount of its own namespace, so nothing created
    there can be `sa/api`.
  - Roles, no wildcards, derived from what the jobs still do (§6's run-time objects, the
    waits, `verify`'s probes and `pg_dump`):

    | Identity | Grants | Used by |
    |---|---|---|
    | `lab-ci` | ClusterRole `view` (it has no Secrets, exec or port-forward) and `lab-flux-read` (get, list, watch on GitRepositories, Kustomizations, HelmRepositories, HelmReleases, and CNPG `clusters`, since `view` may not aggregate CRDs); `get`, `update`, `patch` by `resourceNames` on the Secrets it owns: `flux-system/{gitea-auth,lab-ca}`, `istio-system/cacerts`, `ingress/backend-tls`, `db/vault-ca`, `app/vault-ca`, `monitoring/vault-ca`, and ConfigMap `flux-system/app-images`; `create` on Secrets or ConfigMaps in those namespaces only (RBAC cannot limit `create` by name); `create` on `pods/portforward` in `istio-system` only (`istioctl`'s ztunnel views); in `probe` and `probe-plain`: pods `create`, `delete`, `get`, `list`, `watch` and `pods/log` `get` | every `deliver` job and `verify` |
    | `lab-dbops` | `view`; in `db`: `get` and `create` on `pods/exec` with `resourceNames: [postgres-1]` (WebSocket exec is authorized as `get` by older API servers, `create` by newer); `get`, `delete` on CNPG `clusters` named `postgres` | `backup`, `restore-drill`, the canary cleanup of the DR drill in `up`'s local stage; E1, E3, S3 and S4's settings half in `verify` |
    | `lab-operator` | `view` and `lab-flux-read` | read-only hand checks by the operator at a terminal |
    | `vault-token-issuer` | in `lab-access`: `create` on `serviceaccounts/token`, `resourceNames: [lab-ci, lab-dbops, lab-operator]` | Vault only |

    No identity may patch a Flux object: a Kustomization's `spec.patches` would let its
    writer have kustomize-controller (cluster-admin) apply anything. So `cmd.flux-wait`
    stops requesting a reconcile and only waits for Flux's own poll (`main`, every minute).
  - **How tokens are issued: Vault's Kubernetes secrets engine** at `k3s-creds/` (the k3s
    CA, `https://k3s.lab.test:6443`, the issuer's JWT), one role per ServiceAccount
    (existing-ServiceAccount mode, `allowed_kubernetes_namespaces=["lab-access"]`, the
    §6 TTLs). `kubeconfig(identity)` in `lib/kube.py` asks `k3s-creds/creds/<identity>`
    for a token, writes the `0600` temp kubeconfig (rule 21), and asks again when under 5
    minutes remain. Chosen over a long-lived token in KV: nothing at rest to rotate or
    leak, every issue is a Vault audit line, and the cap on what can be minted lives in
    k3s's RBAC (the issuer's `resourceNames`), not in a Vault role the pipeline can edit.
  - **The bootstrap that needs cluster-admin moves onto be-1:** when Flux is absent, the
    `k3s` role applies `gotk-components.yaml`, `gotk-sync.yaml` and the two Flux Secrets
    (on stdin, `no_log`) with `k3s kubectl`, waits for `platform`, and reads the reviewer
    and issuer token Secrets for Vault. A fresh `up` never needs an admin credential off
    the node.
  - **Break-glass:** the `cluster` job deposits the node's admin kubeconfig (server
    rewritten to `k3s.lab.test`) at `kv/lab/breakglass/k3s-admin` (write-only, and only
    when the `k3s` role installed or reinstalled k3s, so a rebuilt be-1 never leaves a
    stale one), then deletes `kv/lab/pipeline/k3s`. Only `lab-bootstrap` (local, root)
    reads it, for `teardown`'s k3s rows (§14 0–3) and hand checks; a hand check writes
    it to a `0600` temp file and deletes it after use (runbook).

  Exit: `kubectl auth can-i` with each identity's token: `lab-operator` may `list pods
  -A` but not `get secrets -n db`, `create pods --subresource=exec -n db`, `create pods
  --subresource=portforward -n db`, `create pods -n app` or `patch
  authorizationpolicies -n app`; `lab-ci` may `update secret/cacerts -n istio-system` but
  not `get secret/app-db -n db`, exec or port-forward in `db` or `app`, `create pods -n
  app`, `patch kustomizations -n flux-system` or `create rolebindings -n app`;
  `lab-dbops` may exec into `pods/postgres-1` in `db` and nowhere else (K1); a
  `lab-pipeline` token is denied a read of `kv/lab/breakglass/k3s-admin`, and
  `kv/lab/pipeline/k3s` is gone; the `cluster` job re-runs green; a `lab-ci` token is
  refused (401) once its TTL has passed.

  ⤷ **Needs** 8.2a · **Recalls** `k8s.api`, `vault.kv.kubeconfig`, `cmd.kubeconfig`,
  `cmd.flux-wait`, `flux.kustomizations`, `vault.auth.k3s`, `k8s.sa.vault-auth`,
  `vault.policy.*`, `vm.be-1` · **Produces** `clusters/backend/platform/access/`, the
  on-node Flux bootstrap in `ansible/roles/k3s/`, `k3s-creds` setup in `cluster.py`,
  `kubeconfig(identity)` in `lib/kube.py`, the break-glass deposit in the `cluster` job ·
  **Records** `k8s.access` (identities, Roles, who may request each, TTLs),
  `vault.kv.k3s-admin`, `cmd.kubeconfig` (now per identity), `cmd.flux-wait` (wait
  only); the
  `k3s-creds` role names · **Check** Exit; K1
- **8.2d The k3s API audit log.** RBAC decides who may; the audit log shows who did. The
  `k3s` role installs `ansible/roles/k3s/files/audit-policy.yaml` as
  `/etc/rancher/k3s/audit-policy.yaml` (root `0600`) and adds to k3s's config
  (`kube-apiserver-arg`): `audit-policy-file=/etc/rancher/k3s/audit-policy.yaml`,
  `audit-log-path=/var/log/kubernetes/audit/audit.log` (directory root `0700`),
  `audit-log-maxage=7`, `audit-log-maxbackup=5`, `audit-log-maxsize=50` (MB, so at most
  300 MB on be-1); k3s restarts once. The policy, first match wins,
  `omitStages: [RequestReceived]`:
  1. `None`: every non-resource URL (health, version, discovery, `/metrics`), `leases`
     and `events`.
  2. `Metadata`: `pods/exec`, `pods/attach`, `pods/portforward` (who, which pod, when,
     the response code; a refused attempt is logged too).
  3. `Metadata`: every request on `secrets`, never `Request` or `RequestResponse`, which
     would copy Secret values into the log.
  4. `Metadata`: `create`, `update`, `patch`, `delete` on `authorizationpolicies` and
     `peerauthentications` (`security.istio.io`) and on `roles`, `rolebindings`,
     `clusterroles`, `clusterrolebindings`.
  5. `Request`: `create` on `pods` in `app` and `db`, so `spec.serviceAccountName` and
     the creator are visible (a pod borrowing `sa/api` stands out next to the ReplicaSet
     and CNPG controllers; pod specs carry no secret values, S1); `Metadata`: `create`
     on `serviceaccounts/token` in `app` and `db`.
  6. `None`: everything else, the read-only system traffic included.

  The log stays on be-1 as the record A1 reads; `verify` reads it over SSH and parses the
  JSON lines. node-agents' alloy-audit ships a copy to Loki (8.8d, §15). The policy is
  unchanged by that: Alloy's `pods/log` reads fall under rule 6, its `/metrics` scrapes
  under rule 1.
  Exit: as `lab-ci`, `kubectl exec` into a CoreDNS pod is refused; with the break-glass
  kubeconfig (runbook),
  a `kubectl port-forward` to it works; both appear in the audit log with
  `user.username` (`system:serviceaccount:lab-access:lab-ci`, `system:admin`),
  `objectRef.subresource` and the response code (A1); no `secrets` event carries a
  `requestObject` or `responseObject`.

  ⤷ **Needs** 8.2c · **Recalls** `k8s.access`, `vault.kv.k3s-admin`, `cmd.kubeconfig`,
  `vm.be-1` · **Produces** `ansible/roles/k3s/files/audit-policy.yaml`, the audit flags in
  the `k3s` role, the audit-log reader in `lib/kube.py` · **Records** `k8s.audit` (policy
  file, log path, rotation, reader) · **Check** Exit; A1
- **8.3a The istiod CA from Vault.** (Ambient mode: no sidecars; a per-node proxy,
  **ztunnel**, carries every meshed pod's traffic as mTLS over **HBONE**, an HTTP
  CONNECT tunnel on port 15008, with each workload's **SPIFFE** identity
  `spiffe://cluster.local/ns/<ns>/sa/<sa>` in its certificate.) The CA chains to the
  separate `pki_mesh` root (§6, decided 2026-11-05).
  1. The `mesh` job generates the istiod CA key and CSR in memory.
  2. Vault signs it via `pki_mesh/root/sign-intermediate` (CA:TRUE, path length 0,
     `permitted_dns_domains=cluster.local`, 1-year TTL).
  3. The `mesh` job writes Secret `istio-system/cacerts` (`ca-cert.pem`, `ca-key.pem`,
     `root-cert.pem` = `lab mesh root`, `cert-chain.pem`) **before** istiod starts.
     istiod reads it only at startup (then watches the files): if it is missing at
     install, istiod silently creates its own self-signed root in Secret
     `istio-ca-secret`, unconnected to Vault. The order is enforced by Flux, not by
     timing: Kustomization `gate-mesh` health-checks Secret `cacerts`, and `mesh` (the
     Istio HelmReleases, 8.3b) `dependsOn` it.

  Exit: `cacerts` holds all four keys; `openssl x509 -text` on `ca-cert.pem` shows
  CA:TRUE, pathlen 0, the `cluster.local` name constraint and a 1-year expiry;
  `openssl verify` chains it to `lab mesh root` and fails against `lab.test CA`;
  `gate-mesh` turns Ready once the Secret exists; a re-run with a valid CA does not
  re-sign.

  ⤷ **Needs** 8.1b, 2.5d, 8.2d · **Recalls** `decision.mesh-root`, `vault.sign-intermediate`,
  `cmd.kubeconfig`, `flux.kustomizations` · **Produces** `mesh.py` (CA signing),
  `clusters/backend/gates/mesh/`, Kustomizations `gate-mesh` and `mesh` · **Records**
  `mesh.ca` (CN, root it chains to, expiry date) · **Check** Exit
- **8.3b Install Istio ambient through Flux.**
  Where to look when it fails: `flux get helmreleases -A`, `kubectl -n istio-system logs
  ds/istio-cni-node` (CNI path mistakes show here first) and `ds/ztunnel`, and
  `istioctl ztunnel-config workloads` (a pod missing from the list was never captured).
  4. Gateway API CRDs (pinned) in `platform/`; HelmReleases in `mesh/` from
     `lab-charts`, chained with `dependsOn`: `base` → `istiod` (`profile: ambient`) →
     `cni` (`profile: ambient`) → `ztunnel`, all with `global.platform: k3s`, which sets
     k3s's CNI paths (`/var/lib/rancher/k3s/agent/etc/cni/net.d`, and the bin directory
     the precursor saw it choose, `/var/lib/rancher/k3s/data/cni`). A wrong path leaves
     pods bypassing ztunnel. `istioctl` stays for diagnostics only; pass it
     `--kubeconfig` (rule 21).

  Exit: every HelmRelease in `istio-system` is Ready at its pinned version; a smoke
  namespace labelled `istio.io/dataplane-mode=ambient` shows `HBONE` for its pods in
  `istioctl ztunnel-config workloads`; their certificate chains to `lab mesh root`;
  istiod's log shows it loaded the plugged-in CA from `/etc/cacerts` and no Secret
  `istio-system/istio-ca-secret` exists.

  ⤷ **Needs** 8.3a, 8.1c · **Recalls** `mesh.ca`, `flux.charts`, `cmd.flux-wait`,
  `cmd.kubeconfig` · **Produces** `clusters/backend/mesh/` HelmReleases, the `mesh` job ·
  **Records** `mesh.istio` (chart versions, CNI paths actually used), `cmd.istioctl` ·
  **Check** Exit; P2
- **8.3c STRICT mTLS and the capture point.** Required (R2, §6): no pod-to-pod hop in
  k3s may be plaintext.
  5. Mesh-wide `PeerAuthentication` STRICT (`mesh/peerauthentication.yaml`). It is
     enforced by the **receiving** ztunnel: an out-of-mesh client is reset (curl exit
     56), but mesh → out-of-mesh traffic leaves as plain TCP, so anything a meshed pod
     calls outside the mesh (the api → Vault) carries its own TLS.

  Exit: a client in an unlabelled namespace is refused; `tcpdump` on the
  server pod's host-side veth (its index is `cat /sys/class/net/eth0/iflink` inside
  the pod; match it in `ip -o link` on be-1) shows only TCP 15008 while the client
  sends plaintext (this settles T1's capture point on a single node). The smoke
  namespaces are deleted after.

  ⤷ **Needs** 8.3b · **Recalls** `cmd.istioctl`, `cmd.kubeconfig` · **Produces**
  `clusters/backend/mesh/peerauthentication.yaml` · **Records** `spike.t1-capture`
  (interface and filter that worked) · **Check** Exit; Z2 (smoke), T1 (method)
- **8.4a The database: CloudNativePG.** (CNPG: an operator that runs PostgreSQL from a
  `Cluster` resource: it creates the pods, PVCs, Services `postgres-rw`/`-ro`, its own
  TLS, and the database and roles the spec declares.)
  - Kustomization `operators` (`dependsOn: platform`): HelmRelease `cloudnative-pg` in
    namespace `cnpg-system` (not in the mesh). `apps` `dependsOn` `operators`, `mesh`
    and `gate-app`.
  - `apps/db/cluster.yaml`: `Cluster` `postgres` in ns `db` (ambient, PSA
    `restricted`), PostgreSQL 16 image pinned by digest, 1 instance, `local-path`
    storage 2 Gi, small requests, `enableSuperuserAccess: false` (no superuser password
    exists; nothing needs one: §6). CNPG gives the pod ServiceAccount `postgres` and label
    `cnpg.io/cluster: postgres`, so the mesh identity stays
    `cluster.local/ns/db/sa/postgres`.
  - `bootstrap.initdb`: database `app`, owner `app_owner` (no login: `managed.roles`
    sets `login: false`, so CNPG's generated `postgres-app` Secret opens nothing);
    `postInitApplicationSQL`, run once at init as `postgres`: table
    `customers(id serial primary key, name text not null, card_number text not null)`
    owned by `postgres`; `CREATE ROLE app NOLOGIN`; `GRANT SELECT, INSERT ON customers`
    and `USAGE ON SEQUENCE customers_id_seq` to `app`; `REVOKE ALL ON DATABASE app FROM
    PUBLIC; GRANT CONNECT ON DATABASE app TO app`. The role gets its login and password
    in 8.4b.
  - `pg_hba`: CNPG writes fixed rules first (`local all all peer map=local`, which maps
    only the OS user `postgres`, then `hostssl … streaming_replica … cert` and the
    pooler's `cert` rule), then `spec.postgresql.pg_hba`, then its default last line
    `host all all all scram-sha-256`. None is `trust`, unlike the official image's
    loopback rules (rule 24), so a `kubectl port-forward` (which arrives from `127.0.0.1`
    inside the pod) already needs a password; the lab still pins it explicitly,
    in order: `host all postgres all reject`, `hostssl app app all scram-sha-256`, `host
    all all all reject` (the last one shadows CNPG's default line). So `postgres` cannot
    log in over any network path, port-forward included, and `app` only over TLS with its
    password. CNPG's own server TLS stays on (defence in depth inside the mesh's mTLS; the
    api uses `sslmode=require`, §15).
  - The operator (outside the mesh) polls each instance's status port 8000, which STRICT
    would reset: a `PeerAuthentication` selecting `cnpg.io/cluster: postgres` sets port
    8000 alone to PERMISSIVE (CNPG serves it over its own TLS); 5432 stays STRICT.
  - Scrape annotations for 8.8b's discovery: the `Cluster` sets
    `inheritedMetadata.annotations` `prometheus.io/scrape: "true"`, `prometheus.io/port:
    "9187"` (the instance exporter; it stays STRICT), and the CNPG HelmRelease sets
    `podAnnotations` with port `8080` (the operator's metrics).
  - Deleting the `Cluster` deletes its PVC and the database; only 9.2 and `teardown`
    (also run by `destroy`) do,
    each after a fresh backup (§11).

  Exit: `kubectl get cluster -n db postgres` reports a healthy cluster; pod
  `postgres-1` is `HBONE` in `istioctl ztunnel-config workloads`; inside it,
  `psql -d app -c '\dp customers'` (as `postgres` over the local socket) shows only
  `app=ar`; no Secret `postgres-superuser` exists; a root pod in ns `db` is rejected by
  admission; `SELECT … FROM pg_hba_file_rules` shows the three pinned lines and no
  `trust`; with the break-glass kubeconfig (runbook), `kubectl port-forward
  pod/postgres-1 15432:5432` then
  `psql "host=127.0.0.1 port=15432 user=postgres sslmode=require"` is rejected by
  `pg_hba`, and `user=app` with a wrong password fails authentication (S4).

  ⤷ **Needs** 8.3c, 8.1c · **Recalls** `cmd.kubeconfig`, `cmd.flux-wait`, `vault.kv.k3s-admin`,
  `flux.kustomizations`, `flux.charts`, `code.versions` · **Produces**
  `clusters/backend/operators/` (CNPG), `apps/db/cluster.yaml`,
  `mesh/db-status-port.yaml`, `gates/app/`, `app.py` (waits), the `app` job ·
  **Records** `db.cluster` (name, Services, SA, label, PVC, the pinned `pg_hba` lines),
  `db.schema`, `k8s.ns.app-db` · **Check** Exit; S4
- **8.4b The `app` password: Vault → VSO → CNPG.** (VSO, the Vault Secrets Operator:
  logs in to Vault and keeps a Kubernetes Secret equal to a Vault path.)
  - The `app` job generates the `app` password **once** into `kv/app/db` (fields
    `username`, `password`, `host`, `dbname`), never printed: only a definite NotFound
    creates it, any other Vault error stops the run (rule 18).
  - HelmRelease `vault-secrets-operator` in `operators/` (ns `vso`, not in the mesh).
  - In `apps/db/`: ServiceAccount `vso-db`; `VaultConnection` (`https://vault.lab.test:8200`,
    CA from Secret `db/vault-ca`, a run-time object in `gate-app`); `VaultAuth`
    (Kubernetes method, mount `k3s`, role `vso-db`, audience `vault`); and
    `VaultStaticSecret` `app-db`: `kv/app/db` → Secret `db/app-db` of type
    `kubernetes.io/basic-auth`, refreshed every minute.
  - Vault: `auth/k3s/role/vso-db` bound to `sa/vso-db` in ns `db`, token TTL 1 h,
    policy `vso-db` (body from 2.5d): read `kv/data/app/db`, nothing else.
  - The `Cluster` gains `managed.roles`: `app`, `login: true`, `passwordSecret: app-db`.
  - Auto-heal (rule 23): a new `kv/app/db` version re-syncs `db/app-db`, and CNPG
    re-sets the role's password; the api re-reads `kv/app/db` on an authentication
    failure (8.7b).

  Exit: Secret `db/app-db` exists with the KV values; from a throwaway pod running as
  `sa/api` in `ns app`, `psql "host=postgres-rw.db.svc dbname=app user=app
  sslmode=require"` (the password on stdin from Vault, never stored; a non-loopback
  connection, rule 24) can `INSERT` but
  not `DELETE`, `UPDATE` or `CREATE TABLE` (S3); writing a new `kv/app/db` version
  makes the old password fail and the new one work within 2 minutes; a second run keeps
  the same `kv/app/db` version; a `vso-db` token is denied `kv/data/lab/pipeline/ssh`.

  ⤷ **Needs** 8.4a, 8.2a · **Recalls** `db.cluster`, `vault.mount.kv`, `vault.auth.k3s`,
  `vault.policy.*` · **Produces** `operators/` (VSO), `apps/db/vso.yaml`, KV and Vault
  role setup in `app.py` · **Records** `vault.kv.app-db`, `db.role.app`, `vso.auth`
  (VaultAuth, role, SA) · **Check** Exit; S3
- **8.4c Only the api reaches Postgres.**
  `AuthorizationPolicy` on the pods labelled `cnpg.io/cluster: postgres`: allow
  `cluster.local/ns/app/sa/api` on 5432, and the pod CIDR `10.42.0.0/16` on port 8000
  only (the CNPG operator, which has no mesh identity).
  Exit: the 8.4b `sa/api` pod still connects; the same pod with another ServiceAccount
  is refused and ztunnel logs the deny; the `Cluster` stays healthy (the operator still
  reaches port 8000).

  ⤷ **Needs** 8.4b · **Recalls** `k8s.ns.app-db`, `db.cluster` · **Produces**
  `apps/policies/postgres-allow.yaml` · **Records** `mesh.authz` (policies so far) ·
  **Check** Exit; Z1 (in-cluster half)
- **8.5 Vault for the api.**
  - Transit key `customers` (`aes256-gcm96`).
  - Policy `api` (its body written by bootstrap, 2.5d): exactly
    `transit/encrypt/customers`, `transit/decrypt/customers` and `kv/data/app/db`.
  - `auth/k3s/role/api`, bound to `sa/api` in `ns app`, token TTL 1h, with an
    `audience` (`vault`); the api logs in with a projected ServiceAccount token for that
    audience, so a token minted for anything else (the default API audience) is refused.
  - Secret `app/vault-ca` (the public CA, written by the `app` job; `gate-app`).

  Exit: from a pod running as `sa/api`, logging in through `auth/k3s/role/api` gives
  a token that round-trips an encrypt/decrypt, and is denied
  `kv/data/lab/pipeline/ssh` and `transit/keys/customers/rotate`.

  ⤷ **Needs** 8.2a, 8.4b · **Recalls** `vault.auth.k3s`, `vault.policy.*`,
  `path.lab-ca` · **Produces** Vault setup in `app.py`, the `vault-ca` objects ·
  **Records** `vault.transit.customers`, `vault.role.api` (audience, TTL) · **Check** Exit
- **8.6a Image build and scan gate.** `app/api` and `app/frontend` start as minimal
  apps (`/healthz` only; 8.7b–8.7e fill them in, and every merge rebuilds them), each:
  - base image pinned by digest
  - `pip install --require-hashes` at **build** time
  - non-root user, read-only root filesystem compatible
  - Trivy gate: fixable HIGH/CRITICAL fail (`--ignore-unfixed`), waivers with expiry
    in `app/trivyignore`
  - tagged with the git SHA

  Built by the `app` pipeline job on the runner with `lab-runner`'s rootless Podman; the
  gate scans a `podman save` archive (`trivy image --input`), so no Podman socket is opened.
  Exit: both images build and pass the gate; an expired waiver fails it; the
  containers run read-only as non-root and answer `/healthz`.

  ⤷ **Needs** 2.8, 3.5b · **Recalls** `runner.user`, `code.versions` · **Produces**
  `app/api/`, `app/frontend/` (Dockerfile, hash-pinned requirements, minimal app),
  `app/trivyignore`, build in `app.py` · **Records** `img.app` (Dockerfiles, ignore file)
  · **Check** Exit
- **8.6b Push by digest.** Pushed to `gitea.lab.test/lab/` only if the scan gate passes,
  and **deployed by digest**: the `app` job writes the digests the push returned into
  ConfigMap `flux-system/app-images` (`API_IMAGE`, `FRONTEND_IMAGE`), a run-time object
  in `gate-app`.
  Exit: both images in the registry, pushed by the `lab-ci` credential; the scan gate
  passed; `app-images` holds both digests.

  ⤷ **Needs** 8.6a · **Recalls** `gitea.users`, `img.app` · **Produces** push in
  `app.py` · **Records** `img.app.digests` (ConfigMap, keys) · **Check** Exit
- **8.7a The api in k3s: plumbing.** **api** in k3s (Flask, `sa/api`, port 8000), first
  with the minimal image: Deployment and Service in `apps/app/`, the image
  `${API_IMAGE}`, which Flux substitutes from `app-images` (`postBuild.substituteFrom`).
  Probes; resource requests and limits; no secret values in any Deployment; every
  workload its own ServiceAccount (rule 22).
  Exit: the api pod is Ready and `HBONE` and runs the digest in `app-images`; `/healthz`
  answers from a meshed pod; the Deployment has no secret env or mounts (S1).

  ⤷ **Needs** 8.6b, 8.5, 8.4c · **Recalls** `img.app.digests`, `k8s.ns.app-db`,
  `vault.role.api`, `cmd.flux-wait` · **Produces** `apps/app/` (Deployment, Service) ·
  **Records** `k8s.app.api` · **Check** Exit; S1
- **8.7b The api talks to Vault.**
    - logs in to Vault with its ServiceAccount token, and logs in again when the
      token nears its 1-hour expiry or a call returns 403
    - reads `kv/app/db` at startup, and again once on a database authentication
      failure (the password was rotated, 8.4b)
    - Transit encrypt and decrypt helpers for `card_number`
    - `VAULT_CACERT` is its only TLS setting for Vault; Postgres at `postgres-rw.db.svc`
      with `sslmode=require`
  Exit: the api logs a successful login at startup; `/healthz` reports Vault and the
  database reachable; revoking its token makes the next call log in again.

  ⤷ **Needs** 8.7a · **Recalls** `vault.role.api`, `vault.kv.app-db`,
  `vault.transit.customers`, `db.cluster` · **Produces** `app/api/` Vault client ·
  **Records** `api.vault-client` (module, functions) · **Check** Exit
- **8.7c The api's customer endpoints.**
    - `/healthz`, `GET /customers`, `POST /customers`
    - encrypts `card_number` via Transit before inserting
    - decrypts on read and returns only `**** ` + the last 4 digits
    - one database connection per request, parameterized SQL
  Exit: from a meshed pod, a POST then a GET shows `**** 4242`; `psql` in the postgres
  pod shows `vault:v<n>:…` (E1).

  ⤷ **Needs** 8.7b · **Recalls** `api.vault-client`, `db.schema` · **Produces**
  `app/api/` endpoints · **Records** `api.endpoints` · **Check** Exit; E1
- **8.7d The backend gateway with mutual TLS.**
  - **Backend gateway** (`apps/ingress/`): namespace `ingress`, **not** labelled ambient
    (it receives the frontend's TLS from ServiceLB, not HBONE, which STRICT would reset
    if ztunnel captured it; it still speaks HBONE to the api), PSA `baseline` because
    Istio's auto-deployed gateway pod does not meet `restricted`; a Gateway API
    `Gateway` named `backend` (class `istio`) with one **HTTPS** listener on 8000 for
    `api.backend.lab.test`, `tls.mode: Terminate` with Secret `ingress/backend-tls`, and
    **client certificates required** from the `pki_app` root (Gateway API frontend
    validation, or Istio's listener option `gateway.istio.io/tls-terminate-mode: MUTUAL`
    reading `ca.crt` from the Secret: whichever the pinned Istio supports); an
    `HTTPRoute` to `api.app:8000`. ServiceLB exposes 8000 (and the status port 15021) on
    every node address by DNAT; be-1's forward chain admits only 8000, only on `wg1`,
    only from `10.99.0.2` (6.1b).
  - **Server certificate:** the `app` job generates the key in memory, has the CSR
    signed through `pki_app/sign/backend-gw`, and writes Secret `ingress/backend-tls`
    (`tls.crt`, `tls.key`, `ca.crt` = `lab app root`) on stdin (`gate-app`); it
    re-issues only when the certificate is missing or has under 10 days left.

  Exit: from fe-1, `openssl s_client -connect 10.99.1.2:8000 -servername
  api.backend.lab.test -CAfile <lab app root>` verifies the server certificate, and
  the handshake fails without a client certificate (P5, server half); tun-1's forward
  counter for the 8000 rule went up; from fe-1, be-1's tier and mgmt addresses on 8000
  and 15021 time out; `istioctl ztunnel-config workloads` lists the gateway pod as TCP
  and the api and postgres pods as HBONE.

  ⤷ **Needs** 8.7c, 6.2b · **Recalls** `net.overlay`, `fw.vm`, `vault.pki_app.roles`,
  `cmd.flux-wait` · **Produces** `apps/ingress/`, backend-tls issuance in `app.py` ·
  **Records** `k8s.gateway` (namespace, Gateway, SA, TLS Secret, SNI name, how mutual
  TLS is set) · **Check** Exit; P5 (server half)
- **8.7g The frontend's client certificate: end-to-end mTLS.** fe-1 generates its
  client key and a CSR for `frontend.app.lab.test` (the `frontend` role, created here);
  the `app` job signs the CSR through `pki_app/sign/frontend-client` and installs the
  certificate and `lab app root` in `/etc/frontend/tls/` (key `0600`, owned by the
  frontend container's UID). Re-signed only when missing or under 10 days left.

  Exit: from fe-1, `curl --cert … --key … --cacert <lab app root> --resolve
  api.backend.lab.test:8000:10.99.1.2 https://api.backend.lab.test:8000/healthz`
  answers (N2, real backend); the same with a throwaway certificate signed by
  `lab.test CA` (`pki/sign/app-edge`) fails the handshake (P5); during a request,
  `tcpdump -i wg0 -nn -X 'tcp port 8000'` on tun-1 shows TLS records only, no `HTTP/1.1`
  (T3).

  ⤷ **Needs** 8.7d · **Recalls** `k8s.gateway`, `vault.pki_app.roles`,
  `ansible.inventory`, `net.overlay` · **Produces** `ansible/roles/frontend/` (client
  key and CSR), CSR signing in `app.py` · **Records** `fe.client-cert` (paths, SAN,
  owner, re-sign rule) · **Check** Exit; N2 (real backend), P5, T3
- **8.7h Default deny and the ALLOW policies.**
  - Mesh-wide `AuthorizationPolicy` `allow-nothing` in `istio-system` (the root
    namespace, empty spec, `mesh/allow-nothing.yaml`): every meshed workload, and the
    gateway, refuse any caller an ALLOW does not name.
  - ALLOWs in `apps/policies/`: api ← `cluster.local/ns/ingress/sa/backend-istio` on
    8000; postgres (8.4c); the backend gateway ← any source (its client-certificate
    check and be-1's forward chain are its gate).

  Exit: 8.7g's `curl` from fe-1 still answers; a meshed pod in a fresh ambient
  namespace is refused by the api and by postgres, and ztunnel logs both denies; the
  8.4b `sa/api` test pod still reaches postgres (Z1).

  ⤷ **Needs** 8.7g · **Recalls** `mesh.authz`, `k8s.gateway`, `fe.client-cert` ·
  **Produces** `mesh/allow-nothing.yaml`, `apps/policies/{api-allow,gateway-allow}.yaml` ·
  **Records** `mesh.authz` · **Check** Exit; Z1 (default deny)
- **8.7e The frontend on fe-1** (`frontend` Ansible role, Podman quadlets: systemd units
  generated from `.container` files, run as system units by root's Podman). Both
  containers use **`Network=host`**: no Podman port publishing, so no DNAT and no
  forward rules on fe-1, `127.0.0.1` means the host's loopback in both, and the
  frontend's calls to `10.99.1.2` leave through `wg0`:
    - `frontend.container`: the frontend image by digest, read-only root, non-root
      (`User=`), listening on `127.0.0.1:8080` only;
      `API_URL=https://api.backend.lab.test:8000` with
      `PodmanArgs=--add-host=api.backend.lab.test:10.99.1.2` (`AddHost=` came after
      quadlet 4.9.3 **[verify]**); `/etc/frontend/tls` mounted read-only;
      its `ssl.SSLContext` trusts `lab app root` only (never the system store) and
      presents the client certificate; HTML list and add form, no database driver, no
      Vault access
    - `caddy.container`: Caddy (pinned digest) listening on `:443`, `reverse_proxy
      127.0.0.1:8080`, TLS from `/etc/caddy/tls/` (a self-signed placeholder until 8.7f)
  Exit: on fe-1, `curl http://127.0.0.1:8080/` lists customers and the add form creates
  one; `ss -ltn` shows 8080 on loopback only.

  ⤷ **Needs** 8.7h, 8.6b · **Recalls** `img.app.digests`, `vm.no-proxy`,
  `ansible.inventory`, `fe.client-cert` · **Produces** `ansible/roles/frontend/`
  (quadlets), `app/frontend/` (HTML, Caddyfile, quadlets) · **Records** `fe.units`
  (quadlet files, image pins) · **Check** Exit
- **8.7f Edge TLS for `app.lab.test`.** fe-1 generates its key and a CSR for
  `app.lab.test`; the `app` job signs the CSR through `pki/sign/app-edge`, installs the
  certificate, then runs `podman exec caddy caddy reload --force --config
  /etc/caddy/Caddyfile` (without `--force` Caddy ignores a reload whose Caddyfile is
  unchanged). An `app` run re-signs only when the certificate is missing, is the
  placeholder, or has under 10 days left.

  Exit: from a LAN machine (DNS `HOST_IP`, trusting `lab.test CA`),
  `curl https://app.lab.test/` succeeds without `-k`. Adding a customer shows
  `**** 4242`, and `psql` in the postgres pod shows `vault:v<n>:…`; a second `app` run
  does not re-sign.

  ⤷ **Needs** 8.7e, 5.4b · **Recalls** `fe.units`, `net.public-ip`, `vault.pki.roles` ·
  **Produces** CSR/sign/reload in `app.py` · **Records** —; key path and expiry ·
  **Check** Exit; E1 end to end
- **8.8a k8s-monitoring through Flux** (decided 2026-11-09, `decision.observability`).
  HelmRelease `k8s-monitoring` (from `lab-charts`, pinned with SHA-256; `install` and
  `upgrade` `crds: CreateReplace` for the Alloy CRD) in `monitoring/`, namespace
  `monitoring`; Kustomization `monitoring` `dependsOn` `mesh`, `operators` (VSO) and
  `gate-monitoring`. One Alloy, `sa/alloy` (`fullnameOverride: alloy`, preset
  `deployment`: one replica, no clustering, so one node sends no duplicate logs or
  events), does all scraping and pod-log collection and sends to the host over eth1:443.
  Values:
  - `destinations` (a map in 4.x): `prometheus`
    (`https://prometheus.lab.test/api/v1/write`) and `loki`
    (`https://loki.lab.test/loki/api/v1/push`), each `auth.type: basic` from the
    existing Secret `monitoring/alloy-write` (`secret.create: false`) and `tls.caFile:
    /etc/lab-ca/ca.crt`, where Secret `monitoring/vault-ca` is mounted
    (`controller.volumes.extra`, `alloy.mounts.extra`): with an external Secret the
    chart reads every `tls.*` value from that Secret, so an inline CA would be ignored
  - `global.scrapeInterval: 30s` (keeps O3's 2-minute window); `cluster.name:
    lab-backend`
  - `clusterMetrics`: kubelet, cAdvisor, kubelet resource and probes,
    kube-state-metrics, and the API server (`jobLabel: kube-apiserver`, with
    `metricsTuning.excludeMetrics` for the `*_size(s)_bytes_bucket` and
    `apiserver_watch_*` series). On k3s the API server, kubelet, controller-manager,
    scheduler and kube-proxy share one registry, so the API server job carries the
    embedded components' series and kine's `etcd_*`; the kubelet job keeps its default
    allow list, which drops the copies. `kubeControllerManager`, `kubeScheduler` and
    `kubeProxy` off, and no k3s bind-address flags (kube-proxy's listener would be plain
    HTTP without auth); no etcd (kine/SQLite). The job labels `kubelet`, `cadvisor`,
    `kube-state-metrics`, `kube-apiserver` match the kubernetes-mixin defaults
  - `telemetryServices.kube-state-metrics.deploy: true`, `collectors` = the default list
    minus `secrets`, `configmaps` and `certificatesigningrequests` (otherwise its
    ServiceAccount may list every Secret; the mixin uses none of them)
  - `podLogsViaKubernetesApi` (every pod's log streamed through the API server: no
    hostPath, no DaemonSet; ztunnel's access and deny lines included) and
    `clusterEvents`; `prometheusOperatorObjects`, `applicationObservability`,
    `selfReporting` and `nodeLogs` off; `hostMetrics` and `lokiLogsReceiver` come in 8.8d
  - **RBAC, least privilege.** `alloy-operator: {ownNamespaceOnly: true, rbac:
    {createClusterRoles: false}, podSecurityContext: {seccompProfile: {type:
    RuntimeDefault}}}`: by default its ClusterRole may write Secrets, workloads and RBAC
    in every namespace, with `bind` and `escalate`. The collector sets `alloy.rbac.create:
    false`: its default rules read every Secret and ConfigMap, `istio-system/cacerts`
    included. Instead, plain manifests in `monitoring/`: a read-only ClusterRole on
    pods, `pods/log`, namespaces, nodes, `nodes/metrics`, services, endpointslices,
    events and the nonResourceURL `/metrics` (no Secrets, no ConfigMaps, no
    `nodes/proxy`), bound to `sa/alloy`; a Role in `monitoring` with `get` on Secrets,
    `resourceNames: [alloy-write]` (`remote.kubernetes.secret` polls it by name)
  - Alloy's container: requests 512 Mi, limit 1 Gi, an `ephemeral-storage` limit; UID 473
    (`alloy`; the image runs as root by default), `runAsNonRoot`, no privilege
    escalation, `readOnlyRootFilesystem`, all capabilities dropped, seccomp
    `RuntimeDefault`; an `emptyDir` at `/tmp/alloy` (the chart's `storagePath`: WAL and
    positions; without it the read-only root stops Alloy starting)
  - every image pinned by digest, the hook's `ghcr.io/grafana/helm-chart-toolbox-kubectl`
    included (the chart default is a tag)
  - VSO objects: ServiceAccount `vso-monitoring`, `VaultConnection` (CA from
    `monitoring/vault-ca`), `VaultAuth` (mount `k3s`, role `vso-monitoring`, audience
    `vault`), `VaultStaticSecret` `kv/app/alloy-write` → Secret `monitoring/alloy-write`
  - ALLOW kube-state-metrics ← `cluster.local/ns/monitoring/sa/alloy` on 8080
    (`monitoring/policies/ksm-allow.yaml`). Nothing else calls into `monitoring`: the
    Alloy Operator has no webhook and Alloy runs without clustering
  The `monitoring` job writes `monitoring/vault-ca` on stdin (`gate-monitoring`
  health-checks it) and Vault role `auth/k3s/role/vso-monitoring` (bound to
  `sa/vso-monitoring` in ns `monitoring`, policy `vso-monitoring`, token TTL 1 h). Before
  the first merge, `helm template` with these values shows the rendered ServiceAccount
  and pod labels (the ALLOW selectors use them) and no chart ClusterRole.
  Exit: the HelmRelease is Ready at its pinned version; in host Prometheus (through
  Grafana's datasource proxy), `up` is 1 for the kubelet, cAdvisor, resource, probes,
  API server and kube-state-metrics jobs; Loki holds pod logs from every namespace that
  runs pods, and Kubernetes events; `kubectl auth can-i get secrets -n istio-system
  --as=system:serviceaccount:monitoring:alloy`, and `list secrets -A` as
  kube-state-metrics' ServiceAccount, say `no`; the requests of everything on be-1 sum
  within §5's 4.5 GB (`kubectl describe node`).

  ⤷ **Needs** 8.7h, 8.1c, 2.7b · **Recalls** `flux.charts`, `flux.kustomizations`,
  `cmd.flux-wait`, `mesh.authz`, `vault.auth.k3s`, `vault.policy.*`, `vso.auth`,
  `mon.backends`, `vault.kv.alloy-write`, `vault.kv.grafana-verify`,
  `decision.observability` · **Produces** `monitoring/` (HelmRelease, RBAC, VSO objects,
  policies), `gates/monitoring/`, `monitoring.py`, the `monitoring` job · **Records**
  `mon.collector` (release, values file, SA, pod labels, job labels, requests),
  `mesh.authz` · **Check** Exit; K1 (Alloy, kube-state-metrics), O4 (pod logs, events)
- **8.8b Mesh, platform and api metrics, three dashboards.**
  - `annotationAutodiscovery` with keys `prometheus.io/{scrape,port,path,scheme}`,
    `services.enabled: false` (pods only, so the CNPG Services' inherited annotations
    scrape nothing twice) and `bearerToken.enabled: false` (the default sends Alloy's
    token to every annotated pod over plain HTTP). It finds istiod (15014), ztunnel
    (15020), istio-cni (15014), the backend gateway's Envoy (15020,
    `/stats/prometheus`, from Istio's gateway template **[verify at the pinned
    Istio]**), Flux's controllers (8080; Flux's `allow-scraping` NetworkPolicy admits
    it), the CNPG operator (8080) and the Postgres exporter (9187) from 8.4a's
    annotations, and the api.
  - `clusterMetrics.kubeDNS.enabled: true`: CoreDNS by endpointslice (port name
    `metrics`, 9153), so its pod IP is scraped directly, never a ClusterIP behind
    kube-proxy's DNAT (6.1b).
  - VSO (`:8443`, kube-rbac-proxy, self-signed) through the collector's `extraConfig`:
    `discovery.kubernetes` role `endpointslice` in ns `vso`, port `https`, Alloy's
    ServiceAccount token, `insecure_skip_verify`, forwarding to
    `prometheus.remote_write.prometheus.receiver`; and `prometheus.exporter.self` for
    Alloy's own metrics (no network hop).
  - The api serves Prometheus metrics on a second port, 9090 (`prometheus-client`,
    hash-pinned: requests by route and status, latency), with pod annotations
    `prometheus.io/scrape: "true"` and `prometheus.io/port: "9090"`; the api's ALLOW
    gains `cluster.local/ns/monitoring/sa/alloy` on port 9090 only, and the postgres
    ALLOW gains it on 9187 (that port stays STRICT).
  - First find the ztunnel metric that counts a denied connection: read ztunnel's
    metrics before and after the Z1 probe (a pod with another ServiceAccount →
    postgres) and record it; nothing assumes its name.
  - Dashboards as files in `observability/dashboards/`, which the `monitoring` job
    syncs into `/var/lib/lab/grafana/dashboards/` (2.7b): `kubernetes/`, the
    kubernetes-mixin and node-mixin dashboards rendered with 2.7b's rules (SHA-256 in
    `config/versions.toml`), without the scheduler, controller-manager and kube-proxy ones (k3s
    has no such jobs); `lab/`, three: **Mesh traffic and denials** (connections and
    bytes by source and destination SPIFFE principal; denied connections), **api**
    (request rate, errors, latency, the pod's memory) and **Logs** (Loki panels:
    ztunnel denies, `{job="k3s-audit"}` exec and port-forward events, Kubernetes
    events), so the Viewer login sees logs without Explore, which Viewer cannot use.
  Exit: every annotation, CoreDNS and VSO target is `up` (O1); `count by (job,
  instance) (up) > 1` is empty; every mixin panel showing "No data" is listed and
  either its metric is added to `includeMetrics` or its absence is explained; after a
  POST from fe-1 through the gateway, the mesh dashboard shows `ns/app/sa/api` →
  `ns/db/sa/postgres` (O2); the Z1 probe appears on the denials panel within 2 minutes
  (O3).

  ⤷ **Needs** 8.8a, 8.7g · **Recalls** `mon.collector`, `mon.backends`,
  `api.endpoints`, `mesh.authz`, `fe.client-cert`, `db.cluster` · **Produces**
  `/metrics` and annotations in `app/api/` and `apps/app/`, the discovery values,
  `observability/dashboards/`, the dashboard sync in `monitoring.py` · **Records**
  `mon.targets`, `mon.dashboards`, `mesh.authz`, `spike.denial-metric` · **Check** Exit;
  O1–O3
- **8.8d Node metrics and the API audit log.** The only two pieces that need host
  access, in namespace `node-agents` (8.1b), so `monitoring` holds no hostPath pod.
  Neither holds a credential, and Flux is their only applier.
  - **node-exporter**, the chart's: `telemetryServices.node-exporter` with `deploy:
    true`, `namespaceOverride: node-agents`, `service.listenOnAllInterfaces: false` (it
    binds the node's InternalIP `10.0.3.10` only), `kubeRBACProxy.enabled: true` (9100
    is HTTPS and every scrape needs a token allowed `/metrics`), and pod label
    `istio.io/dataplane-mode: none` (its pod IP is the node IP, which ztunnel must never
    treat as a workload). `hostMetrics.linuxHosts`: `scheme: https`, `bearerTokenFile:
    /var/run/secrets/kubernetes.io/serviceaccount/token`, `jobLabel: node-exporter`,
    `metricsTuning.useDefaultAllowList: false` (the default list lacks `node_load*`,
    `node_disk_*` and `node_vmstat_*`, which the mixins need; one node is about 1–2k
    series). It runs with hostNetwork, hostPID and read-only hostPath `/`, `/proc` and
    `/sys`, as nobody. Accepted: it is the only source of be-1's disk, filesystem, load
    and network metrics, and the likely real outage is a full disk (the audit log up to
    300 MB, 8.2d; the Postgres PVC; images), which cAdvisor cannot show and for which
    `local-path` volumes report no `kubelet_volume_stats_*`.
  - **alloy-audit**, plain manifests in `monitoring/node-agents/` (the chart renders
    every collector into its own namespace): a DaemonSet on the same pinned Alloy image,
    ServiceAccount `alloy-audit` with `automountServiceAccountToken: false` (its mesh
    identity comes through ztunnel; it never calls the API); `runAsUser: 0`,
    `privileged: false`, no privilege escalation, all capabilities dropped,
    `readOnlyRootFilesystem`, seccomp `RuntimeDefault`; one `hostPath`
    `/var/log/kubernetes/audit` (type `Directory`) mounted **read-only**; an `emptyDir`
    for its positions, passed as `--storage.path`, with an `ephemeral-storage` limit;
    its HTTP server on `127.0.0.1:12345`. Config: `local.file_match` on `audit.log`
    labelled `job="k3s-audit"` → `loki.source.file` (`tail_from_end = true`) →
    `loki.write` to `http://alloy.monitoring.svc:3500/loki/api/v1/push`. UID 0 is
    unavoidable: k3s writes the files `0600` under a root `0700` directory, so only
    their owner can read them without `CAP_DAC_READ_SEARCH`.
  - `lokiLogsReceiver: {enabled: true, port: 3500}` on the main Alloy; ALLOW Alloy ←
    `cluster.local/ns/node-agents/sa/alloy-audit` on 3500
    (`monitoring/policies/alloy-allow.yaml`, selecting the pod labels in
    `mon.collector`).
  Exit: `node_filesystem_avail_bytes` and `node_load1` for be-1 are in host Prometheus;
  an A1-style event (a `kubectl exec` into a CoreDNS pod refused as `lab-ci`, 8.2d)
  appears in Loki `{job="k3s-audit"}` within 2 minutes; `istioctl ztunnel-config
  workloads` does not list node-exporter; on be-1, `curl -k
  https://10.0.3.10:9100/metrics` without a token gets 401; from the host,
  `10.250.0.112:9100` and `10.0.3.10:9100` time out (N4).

  ⤷ **Needs** 8.8a, 8.2d · **Recalls** `mon.collector`, `mon.backends`, `k8s.audit`,
  `mesh.authz`, `fw.vm`, `cmd.istioctl`, `vault.kv.k3s-admin` · **Produces** the
  node-exporter and receiver values, `monitoring/node-agents/`,
  `monitoring/policies/alloy-allow.yaml` · **Records** `mon.targets`, `mon.logs`
  (streams, labels, retention), `mesh.authz` · **Check** Exit; O4 (audit half)

### Phase 9 — Backup, restore, DR and crypto-shredding

- **9.1a Backup: the Vault snapshot and the database.** The `backup` job
  (`python3 -B -m lab.backup`; `schedules.yml` nightly, or dispatch):
  - `vault operator raft snapshot save`
  - `pg_dump -Fc -d app` as `postgres` over the instance's local socket (`kubectl exec
    postgres-1 -c postgres` as `lab-dbops`, the one identity allowed to exec, and only
    there, 8.2c; no superuser password exists, §6). CNPG's native backup to MinIO is not
    used (§15)
  - both to `/var/lib/lab/backups/<timestamp>/` (survives `teardown` and `destroy`; the
    newest 14 kept)

  A Raft snapshot is encrypted by Vault's barrier and is useless without the unseal
  key. The unseal key is **not** in the backup; offline custody of it is an operator
  duty, stated in the runbook (14.4).
  Exit: both files exist with non-zero sizes; `vault operator raft snapshot inspect`
  reads the snapshot; `pg_restore --list` reads the dump.

  ⤷ **Needs** 8.7c · **Recalls** `runner.owned-paths`, `cmd.kubeconfig`, `k8s.access` · **Produces**
  `backup.py`, the `backup` job · **Records** `backup.dir`, `cmd.backup` · **Check** Exit
- **9.2 Restore drill** (the `restore-drill` job, on dispatch). Take a fresh backup (so
  the dump matches the key's current `min_decryption_version`),
  delete the `Cluster` `postgres` as `lab-dbops` (CNPG removes its pod and PVC: the data
  is gone), and wait for Flux's next reconcile of `apps` (no job identity may patch a
  Flux object, 8.2c): Flux re-creates the `Cluster` from git, CNPG
  re-runs `initdb` (empty schema, the grants) and re-sets role `app` from `db/app-db`
  (the same `kv/app/db` password); then `pg_restore --clean --if-exists`; the api reads
  the old rows and decrypts them (B1).
  Exit: B1 passes; the row count after the restore equals the count in the backup.

  ⤷ **Needs** 9.1a · **Recalls** `cmd.backup`, `db.cluster`, `vault.kv.app-db` ·
  **Produces** the `restore-drill` job · **Records** `cmd.restore-drill` · **Check** Exit; B1
- **9.3a Vault DR drill: a scratch Vault from the snapshot** (the DR drill in `up`'s
  local stage, **local, as root**, after the pipeline is green: it needs the unseal key,
  which the runner can never read). Proves the crown jewels actually restore (R3). Scratch containers on an internal Podman network (no
  published ports, nothing else attached): a scratch Vault and a scratch Postgres. The
  scratch Vault has a TLS-disabled listener on its own loopback only and is driven with
  `podman exec`, so no certificate is involved.
  1. Before taking the backup, the drill inserts a **canary row** through the api,
     with a known card number, so there is a full plaintext to compare against (the
     api only ever returns the last four digits).
  2. Take a fresh backup (9.1a).
  3. Scratch Vault: `operator init` (1 share), unseal with the **scratch** key, log in
     with the scratch root token, mount a writable directory at the live audit
     device's file path (an unseal fails if a configured audit device cannot be
     opened), then `raft snapshot restore -force` the new snapshot.
  4. The scratch Vault now holds the live data: unseal it with the **live** unseal key
     from `vault-init.json`, and log in with the `lab-bootstrap` AppRole (the live root
     token was revoked in 2.5e, so it does not exist in the snapshot either).
  Exit: the scratch Vault is unsealed with the live key and lists the live Transit keys;
  the live Vault's `sys/health` is unchanged throughout.

  ⤷ **Needs** 9.1a · **Recalls** `path.vault-init`, `vault.approle.lab-bootstrap`,
  `vault.audit`, `backup.dir` · **Produces** the DR drill in `up`'s local stage (Vault
  half) · **Records**
  `dr.scratch` (network and container names), `dr.canary` (how it is found and removed)
  · **Check** Exit
- **9.3b Vault DR drill: the canary decrypts.**
  5. Restore the dump into the scratch Postgres (`--no-owner --no-privileges`: its
     roles are not the cluster's); decrypt the canary row's
     `card_number` through the scratch Vault: it equals the known card number (B3).
  Exit: B3 passes; the live Vault's `sys/health` is unchanged throughout.

  ⤷ **Needs** 9.3a · **Recalls** `dr.scratch`, `dr.canary`, `db.schema` · **Produces**
  the DR drill in `up`'s local stage (database half) · **Records** — · **Check** Exit; B3
- **9.4 Crypto-shredding** (same scratch pair, continuing 9.3b). In the scratch Vault,
  allow deletion of `customers` and delete it, still as `lab-bootstrap`. Decrypting
  the canary row now fails; every `card_number` in the scratch Postgres is unreadable
  ciphertext, and names are still readable (B2). The live key is never touched; the
  drill deletes the canary row from the live database at the end.
  Exit: B2 passes; the scratch containers and network are removed.

  This is the point to make: the database backup is safe to lose; the Vault snapshot
  plus the unseal key are the crown jewels. A corollary: rewrapping the real `customers`
  key and then raising its `min_decryption_version` (E3's operation, which `verify` runs
  only on a scratch key) makes every **older** dump undecryptable, so whoever does it
  takes a backup right after.

  ⤷ **Needs** 9.3b · **Recalls** `dr.scratch`, `dr.canary` · **Produces** the shred and
  cleanup in the DR drill in `up`'s local stage · **Records** — · **Check** Exit; B2

### Phase 10 — Pipeline gates and schedules

The runner (2.10) and the delivery pipeline (3.5) exist from bootstrap; this phase
hardens how changes get in and adds what runs on a timer. 10.2 and 10.3a run `verify`,
so they come after 12.1c.

- **10.1 `pr.yml`, on every pull request** (on the one host runner, with the
  pipeline identity: step 2.10's accepted risk): `terraform plan -lock=false` → policy
  gate → `trivy config` on the Dockerfiles and
  manifests → kubeconform over `kustomize build` of every Kustomization path in
  `clusters/backend/` (with the Flux, Gateway API, Istio, CNPG and VSO CRD schemas
  pinned in the repo) → the **no-Secrets-in-git** rule: any `Secret` with `data` or
  `stringData` under `clusters/` fails. Container images are built and scanned in `deliver`'s `app` job, after
  merge. The plan output and the scan summary are posted to the PR. `main` requires
  this check to pass (0 approvals, 3.5a) before merge.
  Exit: a PR that opens `0.0.0.0/0`, or adds a Secret with data under `clusters/`, fails
  the gate and cannot merge (G1).

  ⤷ **Needs** 5.3b, 8.6a, 8.1b · **Recalls** `ci.workflows`, `policy.fixtures`,
  `cmd.pr-flow`, `flux.kustomizations` · **Produces** `.gitea/workflows/pr.yml` · **Records** `ci.pr-gates` ·
  **Check** Exit; G1
- **10.2 `deliver.yml`, on every merge to `main`** (and on dispatch): the job chain
  in 3.5b. Jobs that change running services print what they changed. A failed job
  stops the chain.
  Exit: merging a change to the frontend's template makes the `app` job rebuild both
  images (a new git SHA), update `app-images` (Flux rolls the api to the new digest) and
  redeploy the frontend; every other job reports no changes (Terraform "No changes",
  Ansible `changed=0`, no Flux object changed); a merged manifest change is applied by
  Flux before the `app` job, which only waits for it; `verify` passes at the end (G2).

  ⤷ **Needs** 8.7f, 12.1f · **Recalls** `ci.dispatch`, `cmd.pr-flow`, `img.app.digests` ·
  **Produces** `.gitea/workflows/deliver.yml` (change reporting) · **Records**
  `ci.deliver` · **Check** Exit; G2
- **10.3a `schedules.yml`: nightly backup and verify.** Nightly `backup` (9.1a) and
  `verify`.
  Exit: the nightly runs appear in Gitea with their results; a backup lands in
  `/var/lib/lab/backups/` (G3).

  ⤷ **Needs** 9.1a, 12.1c · **Recalls** `cmd.backup`, `ci.workflows` · **Produces**
  `.gitea/workflows/schedules.yml` · **Records** —; the schedule times · **Check** Exit; G3

### Phase 12 — Verification

- **12.1 `verify`.** Every check in §12 except B1 (run by the `restore-drill` job), B2–B3
  (the DR drill in `up`'s local stage), G1–G3 (proven by the pipeline's own history) and
  V1–V5 (true only after `destroy` and its reboot; checked when `destroy` runs again,
  13.2), each implemented once in `lab/verify.py` with a
  pass/fail line and the evidence. Non-zero exit on any failure. E2/E3 run against a
  scratch Transit key that is deleted afterwards, so `verify` changes nothing. Built in
  four steps; each check reuses the commands of the Exit that first proved it.
  - **12.1a Framework and network checks:** the check runner (pass/fail line,
    evidence, exit code), N1–N6 and H2.
    Exit: N1–N6 and H2 pass; breaking one (e.g. `wg0` down) fails `verify` naming it.

    ⤷ **Needs** 8.7f · **Recalls** `net.overlay`, `wg.hub-log`, `vm.<name>`,
    `cs.account.iac`, `cs.health`, `vault.kv.health` · **Produces** `verify.py` · **Records** `verify.checks`
    (module, IDs done) · **Check** Exit; N1–N6, H2
  - **12.1b Data, secrets, mesh and API-access checks:** E1–E3 (scratch key), S1–S4,
    the required mTLS checks T1, T2, Z1, Z2, P2, and K1 (access half: the `lab-access`
    identities and `lab-pipeline`), A1. They run as `lab-ci`, with
    `lab-dbops` for the database pod (E1, S3 through `SET ROLE app` over the socket, S4's
    `pg_hba_file_rules` half); the negative probes run in `probe` and `probe-plain`, and
    the positive path is the api itself (E1), so `verify` never creates a `sa/api` pod.
    Exit: they pass; T1 uses the capture point 8.3c settled; `vault list transit/keys`
    is unchanged afterwards; a temporary RoleBinding granting `lab-operator` exec in `db`
    fails K1 naming it, and the A1 events of this run are in the audit log.

    ⤷ **Needs** 12.1a · **Recalls** `verify.checks`, `vault.transit.customers`,
    `k8s.app.api`, `spike.t1-capture`, `mesh.authz`, `mesh.ca`, `k8s.access`,
    `k8s.audit`, `db.cluster` · **Produces** checks in `verify.py` · **Records**
    `verify.checks` · **Check** Exit; E1–E3, S1–S4, T1, T2, Z1, Z2, P2, K1 (access half), A1
  - **12.1c TLS checks and the `verify` job:** P1, P3, the P4 sweep over §5's fixed
    port lists (§6), P5 and T3; then the `verify` job in `deliver` (`python3 -B -m
    lab.verify`).
    Exit: they pass; a temporary plain-HTTP listener on a §5 port fails P4; `verify`
    green twice in a row.

    ⤷ **Needs** 12.1b · **Recalls** `verify.checks`, `fw.host`, `fw.vm`, `gw.hosts`,
    `k8s.gateway`, `fe.client-cert` · **Produces** checks in `verify.py`, the `verify`
    job · **Records** `verify.checks` · **Check** Exit; P1, P3, P4, P5, T3
  - **12.1f Observability, consoles and GitOps checks:** O1–O5, C1, G4 and K1's
    monitoring half (Alloy's and kube-state-metrics' ServiceAccounts). They read
    Prometheus and Loki through Grafana's datasource proxy with the verify token.
    Exit: they pass; with Kustomization `apps` suspended and an AuthorizationPolicy
    edited by hand (both with the break-glass kubeconfig, runbook), G4 fails naming it
    (then `apps` is resumed and Flux restores it).

    ⤷ **Needs** 12.1c, 8.8b, 8.8d, 3.5c · **Recalls** `verify.checks`, `mon.targets`,
    `mon.dashboards`, `mon.backends`, `mon.logs`, `vault.kv.grafana-verify`,
    `spike.denial-metric`, `console.urls`, `flux.kustomizations`,
    `img.app.digests` · **Produces** checks in `verify.py` · **Records** `verify.checks` ·
    **Check** Exit; O1–O5, C1, G4, K1 (monitoring half)
The evidence (§13) is a green `deliver` run ending in `verify`, plus `up`'s local-stage
output (B2, B3). Proofs that only the old walkthrough showed are dropped: E2 and E3 on
the real `customers` key (`verify` proves both on a scratch key) and the break-glass
port-forward in A1 and O4 (`verify` still proves A1 with the `lab-dbops` exec and the
refused `lab-ci` port-forward). S4's port-forward half was proven once by 8.4a, and
G4's hand edit by 12.1f.

### Phase 13 — Teardown and revert

- **13.1 `teardown` and `destroy`** run §14 in order. Each row tolerates "already
  gone". No row reads state that an earlier row deleted. Helpers return success on
  "not found". Each phase's `down()` was written with the phase; this step composes
  them and proves them once, on the full build, as the final `destroy`.
  - **13.1a `teardown` and `destroy` orchestration:** `teardown` runs §14's tenant rows
    (the VPC, tiers and VMs, so the k3s cluster goes with be-1, and the state and Vault
    entries that belong only to them) and keeps the host platform. `destroy` runs
    teardown's rows, then the platform rows to 9, each phase's `down()` with the state
    it reads, then the host restore (13.1b). It needs the whole lab built and the
    evidence captured first (14.4).
    `destroy` asks first (§8); its prompt code lives in `teardown.py`.
    Exit: answering anything but `destroy`, or piping stdin, changes nothing; on the
    built lab, `teardown` completes and a second `teardown` reports every
    row already gone; the next `up` rebuilds only the tenant side (its log shows each
    platform phase's `check()` passing); then `destroy` completes rows −1 to 9 and a
    second run reports every row already gone.

    ⤷ **Needs** 12.1f, 14.4, 10.1, 10.2, 10.3a, 9.2 · **Recalls** `runner.user`,
    `tf.backend`, `vault.kv.cs-admin`, `vault.kv.k3s-admin` · **Produces** `teardown.py` · **Records** — ·
    **Check** Exit
  - **13.1b Host restore:** `destroy`'s rows 9a–12: users and groups, packages by
    difference, lab files and the backed-up shared files, the netplan
    restore inside one `netplan try` window, `state/`, the reboot.
    Exit: after the reboot the host reaches `LAN_GATEWAY` on `HOST_IP` and no lab bridge
    exists.

    ⤷ **Needs** 13.1a · **Recalls** `path.netplan-orig`, `path.baseline`, `net.host` ·
    **Produces** host restore in `teardown.py` · **Records** — · **Check** Exit; V2
- **13.2 Revert check in `destroy`.** Run again after the reboot, `destroy` finds nothing
  left, compares the host against `/var/backups/lab/baseline.json` (V1–V5) and writes a
  pass/fail report. Green, it deletes `/var/backups/lab/`, so the next `up` takes a
  fresh baseline; red, it keeps it for the next look.
  Exit: green; every row reports already gone; `/var/backups/lab/` is gone.

  ⤷ **Needs** 13.1b · **Recalls** `path.baseline` · **Produces**
  `revert.py`, the V1–V5 report · **Records** — · **Check** Exit; V1–V5

### Phase 14 — Documentation

- **14.4 Runbook and evidence.** `docs/runbook.md`: short manual procedures for reading
  a console login from Vault (3.5c), a Vault shell with the `lab-bootstrap` AppRole, the
  break-glass k3s kubeconfig in a `0600` temp file deleted after use, and keeping the
  unseal key offline (9.1a); then links to one green `deliver` run ending in `verify`
  and one `up` local-stage output (B2, B3). Once the final `destroy` runs (13.1a), those
  two are the evidence for R1–R3 and R5–R7 (§13).

  ⤷ **Needs** 12.1f, 9.4 · **Recalls** `console.urls`, `vault.approle.lab-bootstrap`,
  `vault.kv.k3s-admin`, `path.vault-init` · **Produces** `docs/runbook.md` ·
  **Records** — · **Check** each procedure run once by hand; both links open

---

## 10. Rules learned the hard way (build them in)

1. **Preflight apt.** One broken apt source makes `apt-get update` exit non-zero and
   kills an install partway through. Fail first and name the source. Always re-fetch
   signing keys (they rotate) and check them against the pinned fingerprint.
2. **Old CloudStack databases are poison.** An existing `cloud` DB with an older
   schema makes the management server loop on 503 forever. Preflight refuses one the
   lab did not make; 3.1a never deploys over an existing one, checks its schema
   version against the pin by asking MySQL (never a tracker file), and refuses a
   mismatch; `destroy` drops it.
3. **Gate on health, with timeouts longer than the gates.** Readiness = HTTP 200 from
   the API, not an open port. Systemd start timeouts must exceed the wait budget.
   First boot of the management server takes minutes. And a control plane reports its
   database, not reality: after a host reboot CloudStack kept dead VMs `Running`, so
   the health gate compares its view with `virsh` (H2, 3.1d).
4. **Teardown is the code most likely to be wrong.** It must not depend on state it
   already deleted, must succeed on "not found", and must keep the reboot out of
   reach of an earlier failure.
5. **Refuse leftovers instead of tolerating them:** systemd drop-ins, extra bridges,
   third-party apt sources, containers.
6. **Terraform's CloudStack provider cannot create an untagged shared network.** Make
   the mgmt network with `cmk` and pass its id in.
7. **ConfigDrive userdata is served by the network of the VM's default NIC**, and
   Terraform's `network_id` is that default NIC (eth0); extra NICs come later via
   `cloudstack_nic`. So the default NIC is the tier, and the VPC tier offering must use
   ConfigDrive.
8. **Ansible's Terraform inventory:** `ansible_host` / `ansible_group` resources are
   read by `cloud.terraform.terraform_provider` (not `terraform_state`), with absolute
   paths.
9. **A WireGuard Endpoint must never fall inside its own AllowedIPs.** Route only
   overlay addresses through the tunnel and keep the underlay (here, the tier
   addresses) out of `AllowedIPs`; a peer that routed the whole backend subnet while
   its endpoint sat in that subnet would loop.
10. **Long-running helpers on a VM run as transient systemd units** (`systemd-run`),
    never as processes left behind by an SSH session. Connection refused vs timeout
    tells "no listener" apart from "firewall dropped it".
11. **`no_proxy` is where proxied clusters break.** Pod, service and VPC CIDRs, `.svc`,
    `.cluster.local`, `lab.test`, `VMNET_CIDR` and `LAN_CIDR` must all bypass the
    proxy, or pods send cluster traffic to Squid. Set `https_proxy` as well as
    `http_proxy`: containerd and HTTPS apt sources use it.
12. **Check container entrypoints before overriding commands.** Some images set the
    entrypoint to the tool itself (`mc`), so `sh -c` needs `--entrypoint`.
13. **The container runtime shares the firewall.** Published ports are DNAT'd past the
    input chain (filter them in a forward chain that runs before netavark's, matching
    `ct status dnat`: 2.2). Netavark only adds ACCEPT rules and turns `ip_forward` on, so
    the lab's forward chain must be the default deny, and it sets `route_localnet` on
    bridges with published ports, so drop outside traffic to `127.0.0.0/8` (2.1c). A
    loaded `br_netfilter` silently drops bridged VM traffic: keep bridge netfilter off
    whenever the module loads (3.1b). Never load `/etc/nftables.conf`: it starts with
    `flush ruleset`.
14. **Keep VM management off the LAN.** A mgmt network on the LAN subnet gives VMs a
    second route to LAN clients (replies leave by the wrong NIC) and lets the LAN's
    DHCP server answer them. A host-only bridge removes both problems.
15. **libvirt brings a network you did not ask for.** Its `default` network (`virbr0`,
    dnsmasq on port 53) collides with CoreDNS; remove it right after install.
16. **Ubuntu's chrony and timesyncd conflict at the package level.** Installing one
    removes the other, so a revert has to reinstall, not just re-enable.

*Rules 17–22 come from the k3s precursor lab (issue_197), which built Phase 8's
cluster first.*

17. **Secrets travel on stdin, never in argv or env.** Arguments show in `ps` and
    `/proc/<pid>/cmdline` and end up in error messages: never `kubectl create secret
    --from-literal`; use `kubectl apply -f -`, `vault write … key=-`, and a token read
    from stdin (`sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"'`).
    Env vars are readable through `kubectl exec` and `/proc/<pid>/environ`; prefer files
    (`*_FILE`). A Secret placeholder in a manifest template is quoted (`"${PASSWORD}"`), so
    YAML keeps the value a string.
18. **Create-once values: only NotFound means "create".** Anything read once and kept
    (Vault's init file, `kv/app/db`, the Grafana admin password, the CA on a PKI mount)
    is checked with a call that tells NotFound apart from every other error; any other
    error stops the run. A check that falls through to "create" on a timeout or a 403
    silently replaces a live secret.
19. **A changed config file restarts nothing by itself.** A ConfigMap change does not
    roll its pods: put the file's SHA-256 in a pod-template annotation
    (`checksum/config`). A bind-mounted config does not restart its container (Compose
    recreates a service only when its own definition changes), and a changed network
    definition is never applied to an existing network: restart the services whose
    config files changed, and recreate a changed network. Any byte rolls it, comments included (accepted).
20. **Wait on the right thing.** `kubectl wait --for=condition=Available` exists only for
    Deployments; StatefulSets and DaemonSets need `kubectl rollout status`. A pod that
    never appears is explained in its controller's events (the ReplicaSet for a
    Deployment), and events expire after about an hour. A webhook's Deployment being
    Available does not mean the webhook answers: retry the first applies.
21. **Name the kubeconfig every time.** `sudo` drops `KUBECONFIG`, so clients fall back
    to `localhost:8080` and fail; `istioctl` does not find k3s's kubeconfig at all. Pass
    `--kubeconfig` or assign `KUBECONFIG` in-process (assign, never `setdefault`: an
    inherited value from `sudo -E` could point at another cluster).
22. **Mesh identity is only as fine as ServiceAccounts.** Workloads sharing a
    ServiceAccount (e.g. `default`) share a certificate, and no `AuthorizationPolicy`
    can tell them apart: every workload gets its own ServiceAccount, and a pod that never
    calls the API sets `automountServiceAccountToken: false`.
23. **Auto-heal by default.** Every step converges to the desired state: when the state is
    known and the repair is safe and simple, repair it and log a warning instead of
    stopping with a manual command. Prefer controllers that heal on their own: Flux
    reverts a hand edit in k3s; a new `kv/app/db` version is re-synced by VSO into
    `db/app-db` and CNPG re-sets the `app` role's password, and the api re-reads the KV
    on its next authentication failure. Stop only on an error that isn't a definite NotFound, or when the repair
    would destroy data or keys (Vault initialized but its init file gone).
24. **Prove a database password from another address.** The official postgres image
    trusts the Unix socket **and** TCP from `127.0.0.1`/`::1`, so `psql -h 127.0.0.1`
    inside the pod succeeds with a wrong password (seen in issue_197); only a connection
    from a non-loopback address (another pod over the Service, or `-h "$(hostname -i)"`)
    meets `scram-sha-256`. CNPG's local socket is peer-authenticated for `postgres`
    only; the lab still proves the `app` password from the `sa/api` pod over the Service
    (8.4b).
25. **The mesh guards the network; RBAC guards the API.** Whoever may `exec`,
    `port-forward`, read Secrets, edit an `AuthorizationPolicy` or create a pod with a
    workload's ServiceAccount is already inside the mesh's protections: a port-forward
    reaches the pod from its own loopback, past ztunnel. Give humans and CI least
    privilege (namespaced Roles, `resourceNames`, short-lived tokens, nothing that can
    patch a Flux object), keep cluster-admin break-glass, and audit both (8.2c, 8.2d).
26. **Name everything the lab writes, so `destroy` can find it without a list.** A file
    the lab creates outside a package lives in a lab-owned directory (`/etc/lab/`,
    `/opt/lab/`, `/var/lib/lab/`) or carries `lab` in its name inside a system
    directory: `/etc/systemd/system/lab-*`, `/etc/sysctl.d/*-lab.conf`,
    `/etc/udev/rules.d/*-lab.rules`, `/etc/apt/sources.list.d/lab-*`,
    `/etc/apt/keyrings/lab-*`, `/etc/systemd/resolved.conf.d/lab.conf`,
    `/etc/logrotate.d/lab-*`, `/etc/containers/containers.conf.d/lab.conf`,
    `/etc/ssh/sshd_config.d/*-lab.conf`,
    `/usr/local/share/ca-certificates/lab-*.crt`. Prefer a drop-in to editing a shared
    file; a shared file that must be edited (root's `authorized_keys`, `/etc/hosts`) is
    backed up by 1.1 and restored by `destroy` (row 9c). A step that adds a new kind of
    file adds its pattern here.

---

## 11. Risks

| Risk | Where | Mitigation |
|---|---|---|
| Advanced-zone bring-up is the most fragile step | 3.1c–3.1d | health-based gates, resumable `up`, generous timeouts; every call adopts before it creates |
| The CloudStack noble apt index breaks (the 4.22 one did, for months) | 3.1a | 3.1a checks that the index resolves and offers the pinned version before installing anything, and names the repository if not; the exact-version pin means a repaired index never moves the version |
| CloudStack's database disagrees with the hypervisor (dead VMs still `Running` after a host reboot) | 3.1d, 4.3, 5.3b | the H2 platform-health gate compares `cmk` with `virsh` at 3.1d's Exit and first in every job that calls CloudStack, and names the first failure, host first |
| `HOST_IP` moves to `cloudbr0` mid-build | 3.1a, 3.1c | services bind `0.0.0.0`; `HOST_IP` is static (1.2a); the 3.1a, 3.1c and 3.1d Exits re-check Phase 2 reachability |
| The host is a VM | all | check nested KVM and foreign-MAC acceptance by hand before the build (§5); `timeouts.nested_factor` stretches every wait; if the outer hypervisor will not pass foreign MACs, system VMs and VPC routers never get LAN connectivity |
| The SSVM cannot fetch the golden image from the host | 3.1d, 4.3 | CloudStack refuses private-address URLs unless `secstorage.allowed.internal.sites` lists `HOST_IP` (set before the SSVM starts); the template's status in `cmk list templates` names the failure; the checksum guards the plain-HTTP fetch |
| mgmt NIC added after boot (`cloudstack_nic`) | 4.1b, 5.4a | the image's netplan and the userdata's static file both match eth1, so it configures on hotplug; 5.4a Exit fails fast if eth1 has no address |
| A shared-network NIC on a VM inside a VPC may be refused by CloudStack | 3.3b, 5.4a | proven by the 3.3b spike, run as soon as 3.3a closes, before Terraform depends on it. The cheap fallback is deploy-time multi-network (`deployVirtualMachine` with `networkids` and `iptonetworklist`, documented in 4.22), done by the `setup` job because `cloudstack_instance` takes one network (5.4a) **[verify]**. Only if that fails too, stop before Phase 5; the candidate redesign is then a VPC **private gateway** onto `cloudbr1`, so the host reaches the tiers through the VPC router under ACLs instead of through a second NIC |
| Same-node HBONE capture point for T1 | 8.3c, T1 | settled in 8.3c's smoke test before the application depends on it |
| Istio ambient on k3s (CNI paths) | 8.3b | k3s-specific install values; smoke namespace before any workload; fallback is sidecar mode |
| Flux applies a manifest before its run-time Secret exists | 8.1b, 8.3a, 8.4a, 8.8a | a gate Kustomization per job health-checks the job's objects and dependents `dependsOn` it; P2 also asserts no `istio-ca-secret` (istiod never started without `cacerts`) |
| Gateway API mutual TLS in the pinned Istio | 8.7d | the Exit proves a certless client is refused; if neither frontend validation nor the `tls-terminate-mode` option works, Istio's own `Gateway` resource with `mode: MUTUAL` replaces the listener |
| The default deny cuts off a needed flow | 8.7h, 8.8a, 8.8b, 8.8d | every flow has a named ALLOW and a test; the gateway gets an explicit allow; ztunnel's deny log names the flow |
| CNPG in an ambient STRICT mesh | 8.4a, 8.4c | the operator is outside the mesh and polls port 8000: that port alone is PERMISSIVE and allowed only from the pod CIDR; 5432 stays STRICT and api-only. Fallback: mesh `cnpg-system` too, with its webhook port excluded |
| Telemetry to the host | 2.7b, 8.8a, 8.8b, 8.8d | Alloy buffers in its WAL, an `emptyDir` with an `ephemeral-storage` limit, so an outage longer than the WAL, or the host and the pod restarting together, leaves a gap (accepted); every meshed target needs an ALLOW, so O1 names each job |
| The Alloy Operator and Alloy's default RBAC | 8.8a | by default the operator may write Secrets, workloads and RBAC everywhere (with `bind` and `escalate`), and Alloy and kube-state-metrics may read every Secret, the mesh CA key included; the operator is confined to `monitoring` without ClusterRoles, Alloy's ClusterRole is a read-only Flux manifest with no Secrets or ConfigMaps, kube-state-metrics drops its `secrets` and `configmaps` collectors; K1 proves Alloy cannot read `istio-system` Secrets |
| Privileged `node-agents` | 8.8d | node-exporter (hostNetwork, hostPID, read-only host paths) and alloy-audit (UID 0, no capabilities, one read-only directory) are the only host-access pods: own namespace, no credential, no token in alloy-audit, node-exporter bound to `10.0.3.10` behind kube-rbac-proxy and dropped on eth0 (6.1b), Flux their only applier |
| Pod logs hold whatever pods print | 8.8a | Loki is as sensitive as pod stdout; the api logs no card data (S1); Grafana's console login is a Viewer; gitleaks-style `secretFilter` is available but off to save memory |
| The Alloy write credential leaks | 2.7b | it only appends metrics and logs, and only from `10.250.0.112` (the allowlist runs before the password check); rotated by a new KV version with versioned usernames, so no batch is refused during the switch |
| istiod `cacerts` key names | 8.3a | write all four Istio file names; Exit checks the workload chain, not just the Secret |
| Egress allow-list too tight | 2.9, 4.1a, 6.1a, 8.x | denials are logged by Squid; grow the list from the log, never by opening the ACL |
| Host memory (32 GB ceiling) | all | §5 budget with a 4 GB reserve, measured per phase; `up` refuses a phase that would breach the reserve; §5 cut order if it overruns |
| Vault sealed after a host reboot | everything | pipeline jobs fail fast with "Vault sealed"; the operator runs `sudo ./bootstrap.sh up` (or `update`), which unseals first (the runner cannot read the unseal key, by design); production answer is KMS auto-unseal |
| Losing the unseal key or Vault snapshot | 9 | that is total loss of encrypted data, by design; the runbook (14.4) makes offline custody of both an explicit operator duty |
| MinIO community edition distribution | 2.7 | upstream changed how community images and binaries ship; the image is pinned by digest and kept as a `podman save` archive in `/var/lib/lab/images/`, which `destroy` keeps (2.7). If it can no longer be pulled at all, Garage or SeaweedFS (both S3-compatible, both work as a Terraform S3 backend) replace it behind the same `minio.lab.test` name |
| Vault audit device unwritable | 2.4a | daily rotation with `SIGHUP`, disk-usage warning logged by `up` and `update` |
| The gateway is a single point of failure for every web service | 2.6 | Vault, CoreDNS, Squid and SSH never depend on it, so unseal, DNS and break-glass access survive a gateway outage; `up` and `update` name it first when it is down |
| ServiceLB exposes the backend gateway on every node address | 8.7d | be-1's nftables admit 8000 only on `wg1` from `10.99.0.2`; P4 and Z1 test the tier and mgmt addresses too |
| PR code runs on the host with the pipeline identity | 2.10 | accepted for one operator (§15); `main` is protected, so nothing reaches `deliver` without a merge; with no `docker` group and rootless builds, it runs with `lab-runner`'s rights, not root's |
| Podman comes from Ubuntu's universe component, paired with an older netavark (4.9.3 with 1.4.0) | 2.1b, 2.1c, 2.2 | security fixes come from the community or Ubuntu Pro, not a vendor repo; versions are pinned (`config/versions.toml`) and logged by `up`; no container port faces the LAN except through the firewall. Netavark features after 1.4 (the nftables driver, `isolate=strict`) are absent, so 2.1c proves the driver, the DNAT path and DNS before 2.2 depends on them. If it fails: Podman 5.x with netavark ≥ 1.10 (nftables driver) from a pinned third-party repository (2.1c names it); Docker is the last resort |
| aardvark-dns and CoreDNS both want port 53 | 2.1b, 2.3a | aardvark-dns moves to `dns_bind_port` 1053; the lab's own nat rule redirects containers' TCP and UDP port 53 queries to it on every network, since netavark 1.4 does it for UDP only and never on internal networks (2.1c, 2.2) |
| A mesh CA forging names other clients trust | 2.5f, 8.3a | decided 2026-11-05: the istiod CA is under its own root, `pki_mesh`, which no host or VM trusts (§6); P2 proves the chain ends there and not at `lab.test CA` |
| One compromised ztunnel impersonates every workload on its node | 8.3b | ambient keeps keys out of pods but in ztunnel; with one node that is every identity (§6). Accepted for the lab; production spreads workloads over hardened nodes |
| Deleting the CNPG `Cluster` (or its PVC) erases the database | 8.4a, 9.2, 14 | `local-path` reclaims with `Delete`; only 9.2 (after a fresh backup), `teardown` and `destroy` delete it; production uses a `Retain` StorageClass and CNPG's own backups |
| A k3s credential walks past the mesh: exec, port-forward, Secret reads, policy edits, a pod borrowing `sa/api` | 8.2c, 8.2d, 8.4a | split by role: Flux applies, `lab-ci` writes only its named run-time objects, `lab-dbops` may exec into `postgres-1` only, people get `view`; cluster-admin only through the break-glass kubeconfig (runbook); `pg_hba` rejects `postgres` from every address; K1, A1 and S4 prove it. Admission policy against borrowed identities is not built (§15) |
| `lab-dbops` can run `psql` as `postgres` in `postgres-1` | 8.2c, 9.1a | `pg_dump` needs it; one pod by name, 15-minute tokens, every exec in the audit log (A1); `card_number` is Transit ciphertext, so the database alone reveals no card |
| `lab-ci` may `create` any Secret in the namespaces where it owns one | 8.2c | RBAC cannot limit `create` by name; it still cannot read or change any other Secret, and Flux never applies what it creates |
| Root on be-1 is cluster-admin, and `lab-pipeline` holds the lab SSH key | 8.1, 8.2c | the node's `k3s.yaml` and client certificates are there; accepted like 2.10's runner risk. RBAC governs API credentials, not SSH; `k3s kubectl` on the node still goes through the API server, so A1 records it as `system:admin` |
| The API audit log fills be-1's disk | 8.2d | rotated at 50 MB, 5 backups, 7 days; secrets at `Metadata` only; read traffic dropped |
| Bootstrap runs as root from the operator's user-writable checkout | 0–3, `up`, `update`, `teardown`, `destroy` | the user could change code (or plant a symlink at `state/`) that root then runs or writes through; accepted for one operator who already has sudo (the precursor skipped the same fix). Production installs the tool root-owned (`/opt/lab`) and keeps its state there, and root never runs a user-writable binary |

---

## 12. Verification catalog

Every check is first proven by a step in §17.4. The mTLS checks (T1–T3, Z1, Z2, P2, P5)
are required, like the rest. After that, the `verify` job (12.1) runs every check except
B1–B3, G1–G3 and V1–V5: B1 runs in the `restore-drill` job, B3 and B2 in the DR drill in
`up`'s local stage (it needs the unseal key), G1–G3 are the pipeline's own history, and
V1–V5 run in `destroy` after its reboot.

| ID | Check | How |
|---|---|---|
| **N1** | frontend and backend tiers are isolated | fe-1 → `10.0.3.10` (be-1's tier address) on any port times out, with and without the tunnel up; the ACL has no rule between the two tiers |
| **N2** | the tunnel is the only path | fe-1 → `10.99.1.2:8000` (mTLS with the frontend's client certificate) succeeds and tun-1's forward counter rises; with `wg0` (fe-1) or `wg1` (tun-1) down it times out; `ip route get 10.99.1.2` on fe-1 shows `dev wg0` |
| **N3** | no internet from tiers | direct `curl https://example.com` fails; through the proxy → 403 and logged |
| **N4** | mgmt NIC reaches only the host | VM → another VM's mgmt address times out; VM → `10.250.0.1:8200` succeeds; from the host, be-1's `10.250.0.112:9100` and `10.0.3.10:9100` (node-exporter) time out |
| **N5** | Terraform runs least-privilege | `iac` key denied an admin-only API call |
| **N6** | the hub forwards one flow only | fe-1 → `10.99.1.2:22` and `:5432` time out and tun-1 logs `lab-hub-drop` |
| **H2** | CloudStack platform healthy | `/client/api` returns 200; the KVM host is `Up`; SSVM and CPVM are `Running`; every system VM and router `cmk` lists as `Running` has a running domain of the same instance name in `virsh --readonly list` |
| **E1** | field-level encryption | `psql` shows `vault:v<n>:…` (any key version); API returns `**** 4242` |
| **E2** | key rotation | rotate → new ciphertext carries the new version (`vault:v2:…` on first run); the older ciphertext still decrypts (`verify`: on a scratch Transit key) |
| **E3** | rewrap + retire | rewrap to the latest version; set `min_decryption_version` to it; a ciphertext saved before the rotation fails to decrypt (`verify`: on a scratch Transit key) |
| **T1** | mTLS on the wire | `tcpdump` on be-1 during a request: api ↔ postgres only on TCP 15008, no SQL text |
| **T2** | workload identity | ztunnel log shows `spiffe://cluster.local/ns/app/sa/api` → `ns/db/sa/postgres` |
| **T3** | tun-1 sees only ciphertext | during a POST through the UI, `tcpdump -i wg0 -nn -X 'tcp port 8000'` (and `-i wg1`) on tun-1 shows TLS records only (content types 22/23): no `HTTP/1.1`, no `/customers`, no card digits |
| **Z1** | identity authorization | the frontend cannot reach Postgres: from fe-1 the hub drops it (N6); in the cluster, a pod with any ServiceAccount other than `sa/api` is refused by postgres's `AuthorizationPolicy`, a meshed pod no ALLOW names is refused by the api too (mesh-wide `allow-nothing`), and ztunnel logs each deny |
| **Z2** | STRICT mTLS | a pod in an unlabelled namespace cannot reach `api.app:8000` (reset by ztunnel: curl exit 56) |
| **P1** | edge PKI | the gateway certificate chains to `lab.test CA` and carries every gateway name |
| **P2** | mesh PKI | a workload certificate chains through the istiod CA to `lab mesh root` (`pki_mesh`) and does **not** verify against `lab.test CA`; no Secret `istio-system/istio-ca-secret` exists (istiod did not fall back to its own root) |
| **P3** | Vault speaks only TLS | `http://vault.lab.test:8200` fails; `https://` succeeds |
| **P4** | TLS to every entry point | on the host, fe-1 and be-1, every TCP port in §5's tables completes a verified TLS handshake or is a named §6 exception (be-1's node-exporter 9100: HTTPS behind kube-rbac-proxy, on-node only); no gateway backend port answers from a VM |
| **P5** | frontend ↔ api mutual TLS | the backend gateway's certificate chains to `lab app root` with SAN `api.backend.lab.test`; from fe-1 a client with no certificate, or with one from `lab.test CA`, fails the handshake; the frontend's certificate succeeds |
| **S1** | no secrets in manifests | the api Deployment has no secret env or mounts; the password is at `kv/app/db`, and its only Kubernetes copy is VSO's `db/app-db`; no `Secret` with data exists under `clusters/` |
| **S2** | Secrets encrypted at rest | `k3s secrets-encrypt status` = Enabled; a known Secret value does not appear in `/var/lib/rancher/k3s/server/db/state.db` |
| **S3** | least-privilege database role | role `app` can `SELECT` and `INSERT` on `customers` and is refused `DELETE`, `UPDATE` and `CREATE TABLE` (8.4b: from the `sa/api` pod over the Service; `verify`: `SET ROLE app` over the socket as `lab-dbops`, rolled back); no superuser password exists (`enableSuperuserAccess: false`) |
| **S4** | no passwordless path into Postgres | `pg_hba_file_rules` holds no `trust` and the three pinned lines (`verify`, as `lab-dbops`); through a `kubectl port-forward` to 5432 (8.4a's Exit, with the break-glass kubeconfig (runbook), the only identity allowed to port-forward there), `user=postgres` is rejected by `pg_hba` and `user=app` with a wrong password fails |
| **K1** | the k3s API is least privilege | `kubectl auth can-i` with each identity's own token: `lab-operator` and `lab-ci` get `no` for exec, attach and port-forward in `db` and `app`, `get secrets` in `db`, `create pods` in `app` and `db`, `patch` on `authorizationpolicies`, `peerauthentications` and Flux Kustomizations, and `create rolebindings`; `lab-dbops` gets `yes` only for exec into `postgres-1`; Alloy's ServiceAccount gets `no` for `get secrets -n istio-system` and kube-state-metrics' for `list secrets -A`; `lab-pipeline` cannot read `kv/lab/breakglass/k3s-admin` |
| **A1** | API access is audited | the audit log on be-1 holds, with `user.username` and the response code, this run's `lab-dbops` exec into `postgres-1` and a refused `lab-ci` port-forward to it; no `secrets` event carries a request or response body |
| **B1** | restore drill | the api reads and decrypts restored rows |
| **B2** | crypto-shredding | in a Vault restored from the snapshot, deleting the Transit key makes every restored `card_number` undecryptable while names stay readable |
| **B3** | Vault disaster recovery | a scratch Vault restored from the newest snapshot and unsealed with the kept key decrypts the drill's canary row to its known card number |
| **G1–G3** | pipeline | a PR opening `0.0.0.0/0` or adding a Secret with data under `clusters/` fails and cannot merge; a merge rebuilds, redeploys and verifies; nightly backup and verify run on schedule |
| **G4** | GitOps in sync | every Flux Kustomization and HelmRelease (HelmRelease `k8s-monitoring` included) is Ready at `main`'s HEAD; the running api digest equals `flux-system/app-images`; a hand-edited AuthorizationPolicy is restored by Flux (12.1f's Exit) |
| **O1** | metrics collected | in host Prometheus (through Grafana's datasource proxy), every job in `mon.targets` is `up`: kubelet, cAdvisor, kubelet resource and probes, API server, kube-state-metrics, node-exporter, istiod, ztunnel, istio-cni, the backend gateway, CoreDNS, Flux's controllers, the CNPG operator, the Postgres exporter, VSO, the api and Alloy itself; no `(job, instance)` pair appears twice |
| **O2** | mesh traffic visible | after a POST, the *Mesh traffic and denials* dashboard in Grafana on the host shows connections `ns/app/sa/api` → `ns/db/sa/postgres` |
| **O3** | denials visible | the Z1 probe shows on the denials panel in Grafana on the host within 2 minutes (the metric recorded in `spike.denial-metric`) |
| **O4** | logs collected | Loki holds recent lines from every namespace that runs pods, and within 2 minutes this run's ztunnel deny line for the Z1 probe, a Kubernetes event and the A1 audit events (`{job="k3s-audit"}`); the *Logs* dashboard shows them to the Viewer login |
| **O5** | the write paths admit only be-1's Alloy | from the host, and from fe-1, a POST to `prometheus.lab.test/api/v1/write` or `loki.lab.test/loki/api/v1/push` gets 403; from be-1 without credentials, 401; a GET of either name's query API gets 404; from a `LAN_CIDR` source nothing answers |
| **C1** | consoles | on the host, each of the five §5 console URLs (Grafana's `https://grafana.lab.test/`, Viewer) returns its login page over TLS verified against `lab.test CA` (no `-k`) and its login, read from Vault (runbook), works (3.5c's Exit; `verify` checks the pages, since the runner never reads `kv/lab/bootstrap/*`); from a `LAN_CIDR` source none answers |
| **V1** | packages and sources | no package in the `PACKAGES` table is installed; `systemd-timesyncd` is back; no apt source or key named by rule 26 |
| **V2** | network | `/etc/netplan` byte-identical to `netplan.orig/`; no lab bridges (`cloudbr0`, `cloudbr1`, `cloud0`, `virbr0`, `podman*`); `/etc/resolv.conf` links where the baseline says; no `inet lab` table; the host reaches `LAN_GATEWAY` on `HOST_IP` |
| **V3** | services | no `lab-*` units, no containers, no resolved drop-in named by rule 26 |
| **V4** | identity and trust | users, groups and group memberships equal the baseline's; no `lab-*` certificate in the trust store |
| **V5** | lab files | nothing rule 26 names is left; root's `authorized_keys` and `/etc/hosts` equal their copies in `files.orig/`. `/var/lib/lab/` and `/var/backups/lab/` are expected and excluded (the latter is deleted after a green report, 13.2). Not checked (accepted 2026-11-10): an edit to a file outside rule 26's names that stays installed; take a fresh snapshot if in doubt |

---

## 13. Evidence

Two outputs prove the build. The runbook (14.4) links one of each.

1. **A green `deliver.yml` run on `main` ending in the `verify` job.** Every §12 check
   except B1–B3, G1–G3 and V1–V5 passes, each with its evidence line. G1–G3 are the
   pipeline's own history: a refused PR, the merge run, the nightly `schedules.yml`
   runs. B1 is the `restore-drill` job.
2. **`up`'s local-stage output.** The Vault DR drill (B3, then B2), run as root because
   it needs the unseal key the runner can never read, then the `verify` job's pass/fail
   summary.

The final `destroy`, run again after its reboot, writes the V1–V5 report (R4). What was
deliberately **not** built, and why, is in §15; a human-readable walkthrough is one of
those options.

---

## 14. Teardown order (`teardown`, `destroy`)

Each line runs that phase's `down()`. The state each step reads is listed so that no
step depends on something already deleted. Every row tolerates "already gone".

- `teardown` runs rows −1 to 6: the tenant side (the VPC, tiers and VMs, so the k3s
  cluster goes with be-1) and the Vault and `state/` entries that belong only to it. The
  host platform and the golden image template stay, so the next `up` is quick.
- `destroy` first asks for confirmation (§8: the operator types `destroy`), then runs
  every row: teardown's (no-ops if `teardown` already ran), then the rows marked
  *destroy only*, ending with a reboot. Data is not spared: CloudStack's databases and
  MySQL's data directory go even if they hold data.
- Packages are undone by the one `PACKAGES` table (row 9b); files by rule 26's names;
  users by difference (row 9a).

| # | Step | Reads | Removes |
|---|---|---|---|
| −1 | pipeline | Gitea | disables `schedules.yml` and cancels running runs, so no job races the teardown; *destroy only:* stops the runner service |
| 0 | `monitoring` | the break-glass kubeconfig (`kv/lab/breakglass/k3s-admin`, read by `lab-bootstrap`; rows 0–3 are its one routine use, since `flux uninstall` and suspending Flux need cluster-admin) | **suspends Flux's root Kustomization first**, so nothing deleted below comes back; then Kustomizations `monitoring` and `gate-monitoring`, deleted with pruning (Flux uninstalls k8s-monitoring, whose Alloy Operator pre-delete hook removes the Alloy instances first, and the `node-agents` objects); Secret `monitoring/vault-ca`; Vault `auth/k3s/role/vso-monitoring` (`kv/app/alloy-write` goes with row 1's `kv/app/*`) |
| 1 | `app` | break-glass kubeconfig, inventory | the CNPG `Cluster` first, waiting until CNPG has removed its pod and PVC (its finalizer needs the operator still running); then Kustomizations `apps` and `gate-app` with pruning (VSO objects, api, `backend` gateway, ALLOWs), then `operators` (CNPG and VSO, after everything carrying their finalizers is gone); the run-time objects (§6); Vault `auth/k3s/role/{api,vso-db}`, `kv/app/*`, `transit/keys/customers` (deletion allowed first) |
| 2 | `mesh` | break-glass kubeconfig | Kustomizations `mesh` and `gate-mesh` with pruning (Flux uninstalls the Istio HelmReleases), Secret `cacerts` |
| 3 | `cluster` | break-glass kubeconfig | the root Kustomization, `platform` (Gateway API CRDs, namespaces, `access/`), `flux uninstall`; Vault `auth/k3s` and the `k3s-creds/` mount; then deletes `kv/lab/breakglass/k3s-admin` (read last, by this row) and `kv/lab/pipeline/gitea-flux` |
| 5 | `tunnel`, `base` | inventory | nothing to undo on VMs that are about to be destroyed; WireGuard public keys in Vault (`kv/lab/pipeline/wg/*`) |
| 6 | `setup` | Vault (`iac`, the `tfstate` MinIO user) | `terraform destroy` (run directly, not through the policy gate, which forbids destroying the public IP); then the state object; the `app.lab.test` and `k3s.lab.test` records |
| 7 | `image` (*destroy only*) | Vault (admin) | the CloudStack template; MinIO `images/*` |
| 8 | `provision` (*destroy only*) | — | CloudStack: services, system VMs, `cloud` and `cloud_usage` DBs, then **purges** `/var/lib/mysql` (an old `cloud` DB left there would poison a reinstall, rule 2), `/etc/cloudstack/` (the generated `key` file outlives a package purge), NFS exports and `/export/*`, `/etc/nfs.conf` pins, the management server's key line in root's `authorized_keys` (the file itself if the baseline had none), the bridge-netfilter udev rule and sysctl file, drop-ins, the CloudStack apt repository, key and version pin, `cmk` |
| 9 | `platform` (*destroy only*) | — | unregisters the runner, removes its service; as `lab-runner`, `podman system reset --force` (its rootless images, owned by sub-UIDs); `loginctl disable-linger lab-runner`; `lab-runner`'s work directory; `docker-compose down --volumes` (gateway, Prometheus, Loki and Grafana included), then disables and removes `lab-platform.service` and runs `daemon-reload`, and disables `podman.socket`; removes any containers, the three networks and the volumes left (theirs included; Loki's bucket goes with MinIO's); the `/etc/containers/containers.conf.d/` lab file and `/var/lib/containers`; any netavark chains left in the `ip filter` and `ip nat` tables (V2) **[verify what netavark 1.4 leaves after its last network is removed]**; `lab-nftables.service`, the `inet lab` table and `/etc/lab/`; if `decision.podman-fw` chose the fallback, its apt repository and key (2.1c; V1); the systemd-resolved drop-in and the original `/etc/resolv.conf` link; the Vault and Squid logrotate rules; `/opt/lab/`; `/var/lib/lab/platform`, `/var/lib/lab/certs`, `/var/lib/lab/traefik` (dynamic routes, the users file) and `/var/lib/lab/grafana`; the lab CA from the host trust store |
| 9a | users (*destroy only*) | baseline | `userdel`/`groupdel` every user and group the baseline does not have (`lab-runner` with its `/etc/subuid` and `/etc/subgid` lines, `cloud`, `mysql`, `libvirt-qemu`, `libvirt`, and memberships added to `kvm`), with their home directories: package purges leave them behind |
| 9b | packages (*destroy only*) | preflight's `PACKAGES` | **only what the lab installed** (decided 2026-11-10: a package someone else installs while the lab runs is not the lab's to remove): preflight's `down()` purges exactly the `PACKAGES` table (every step's entry) (CloudStack, MySQL, libvirt, NFS, Podman and its helpers, chrony, `qemu-*`, `dnsutils`, …); then one `apt-get autoremove --purge` takes the dependencies apt pulled in (apt marked them automatic); a package the lab removed is reinstalled (`systemd-timesyncd`, which chrony replaced, rule 16); then the lab's apt sources and keys by rule 26's names |
| 9c | lab files and shared files (*destroy only*) | `/var/backups/lab/files.orig/` | everything rule 26 names that is still there; then the backed-up shared files (root's `authorized_keys`, `/etc/hosts`) are copied back |
| 10 | host (*destroy only*) | `/var/backups/lab/netplan.orig/` | restores the original netplan files, then inside one `netplan try` window deletes `cloud0`, `cloudbr0` and `cloudbr1` (networkd does not release a NIC from a bridge on its own) and applies the restored config; the automation confirms (SIGUSR1) only after it reaches `LAN_GATEWAY` again, otherwise it auto-reverts |
| 11 | `state/` (*destroy only*) | — | copies `bootstrap.log` to `/var/backups/lab/destroy-<timestamp>.log`, then deletes `state/` |
| 12 | reboot (*destroy only*) | — | — then run `destroy` again: it finds nothing left and runs the revert checks V1–V5, writing the pass/fail report (13.2) |

`/var/lib/lab/` (unseal key, backups, `archive/`) is **kept**, and the next `up`
archives rather than overwrites it (2.4b). No command removes it: the operator deletes
it by hand once the unseal key and snapshots are no longer needed.

---

## 15. Decisions and alternatives not built

| Decision | Chosen | Not built, and why |
|---|---|---|
| IaC engine | Terraform | OpenTofu: drop-in and openly licensed; a one-line swap via `TF_BIN` |
| Secrets/KMS | Vault | OpenBao: its advantage (free namespaces) is unused by a single tenant |
| PKI | three roots in Vault (`lab.test CA`, `pki_mesh`, `pki_app`), one trust domain each, + the istiod sub-CA | two-tier root/intermediate: without an offline root it adds shape, not safety |
| Mesh trust root | **decided 2026-11-05: a separate root `pki_mesh`** that signs only the istiod CA (built in the precursor, issue_197 A1), so host trust and mesh trust never overlap. Chosen by the security-first rule (§2): it costs one mount and P2 chaining to it | the istiod sub-CA under `lab.test CA`, DNS-constrained to `cluster.local`: one root fewer, but it could still mint any `*.svc.cluster.local` certificate, and IP SANs if the IP constraint is unavailable, that every host client accepts (§6) |
| k3s Secrets at rest | `--secrets-encryption` (key on the node); RBAC limits who reads Secrets (8.2c) | a KMS provider plugin, so the key is off the node: the production answer; here it protects `state.db` copies, not the node (§6) |
| k3s API access | **built:** scoped ServiceAccounts with namespaced Roles, tokens issued per command by Vault's Kubernetes secrets engine, people read-only (`view`), cluster-admin as an audited break-glass kubeconfig in Vault, the API audit log, `pg_hba` without `trust` (8.2c, 8.2d, 8.4a) | admission policy (a `ValidatingAdmissionPolicy` or Kyverno rule) refusing pods in `app`/`db` that use `sa/api` unless created by its Deployment, and refusing exec into `db`: the stronger guard against a borrowed identity, but one more policy layer to debug with the mesh; OIDC logins for people and just-in-time admin (Teleport, an access broker) instead of a static break-glass certificate; rotating k3s's client CA to retire the admin certificate: all production answers, out of scope |
| API audit log destination | on be-1, rotated (7 days, A1's record, read by `verify` over SSH), plus a copy in Loki (30 days) through node-agents' alloy-audit (8.8d) | a SIEM with alerts on exec, port-forward and `system:admin`: needs alert routing nobody would receive in the build window |
| Database | CloudNativePG `Cluster`, 1 instance, schema and grants in `postInitApplicationSQL`, no superuser | a hand-written StatefulSet with schema code in the `app` job (the earlier plan): more to write and get wrong (create-once superuser Secret, password re-sets) for no extra lesson; 3 instances with failover: memory |
| Schema changes | `postInitApplicationSQL`, which runs only at `initdb` | a migration tool (a Job running Alembic, Flyway or Atlas on each release): needed once the schema changes after the first deploy; out of scope |
| Database backup | `pg_dump` through `kubectl exec`, kept with the Vault snapshot (9.1a) | CNPG's native backups to MinIO (Barman Cloud plugin, WAL archiving, point-in-time restore): the production answer, but it adds a plugin, a bucket with credentials and a CNPG restore path, and the scratch DR drill (9.3) would need a CNPG cluster instead of a plain container; `pg_dump` proves B1–B3 as well |
| Database TLS inside the mesh | the mesh's mTLS, plus CNPG's server TLS with `sslmode=require` | `sslmode=verify-full` against CNPG's CA: CNPG's CA lives in ns `db`, so the api would need a copy kept in sync; the mesh already authenticates postgres by SPIFFE ID |
| Secrets into k3s | Vault Secrets Operator for the one Secret CNPG needs; the api reads Vault directly | External Secrets Operator: equivalent, but VSO is Vault's own and speaks its Kubernetes auth natively; the api through a synced Secret: one more copy of the password, and it already logs in to Vault for Transit |
| Database storage | k3s `local-path` (reclaim `Delete`) | a `Retain` StorageClass or CSI volumes with snapshots: production databases; here the data is restorable from 9.1a's backups |
| VPN topology | one VPC, three tiers, WireGuard hub (tun-1) between frontend and backend | two VPCs joined by a site-to-site tunnel between their public IPs: the shape of two real sites, but a second router pair for no extra lesson here. CloudStack's built-in VPC site-to-site IPsec VPN: the managed-gateway answer, but known to be fragile and debugged inside system VMs. Tailscale/Headscale: for many ephemeral nodes with tag ACLs |
| Mesh | Istio ambient | Linkerd: simpler install, but sidecars per pod and edge-only open-source releases |
| CNI | k3s flannel | Cilium: its flow visibility is covered by ztunnel's deny logs for meshed traffic |
| Cluster ingress | one Istio Gateway, `backend` (mutual TLS, reachable only from the tunnel) | k3s's Traefik (disabled), NGINX Gateway Fabric: a second controller outside the mesh's identity model; a separate operator gateway: not needed since Grafana moved to the host (2026-11-09) |
| GitOps | Flux CD, installed from committed `flux install --export` output, pulling `main` from Gitea with a read-only token; charts mirrored into Gitea's OCI registry | Argo CD: a UI and an app-of-apps model, heavier for one cluster; `flux bootstrap`: pushes to `main`, which is protected; jobs running `kubectl apply`: no drift repair and no single source of truth |
| Image delivery to k3s | digests in ConfigMap `app-images`, written by the `app` job, substituted by Flux | Flux image automation committing the digest to git: auditable in history, but it needs an identity allowed past `main`'s protection |
| Mesh authorization | mesh-wide `allow-nothing`, one ALLOW per flow | ALLOW policies only on the sensitive workloads: anything unlisted would be open to every meshed pod |
| Web front door | Caddy on fe-1, Vault-signed certificate, key generated on the VM | a managed load balancer with TLS offload: what a cloud would give; one VM needs no balancer |
| DB credentials | static, in Vault KV, synced by VSO to CNPG's managed role | Vault database engine: short-lived users per pod; costs refresh logic in the api and a Vault → Postgres path through STRICT mTLS |
| App delivery | images built, scanned, pinned | code in ConfigMaps + pip at start: unpinned, unscanned, needs internet from the tier |
| Directory login | not built | a Samba AD DC on its own tier, VMs joined with realmd/SSSD: AD users log in, `sudo` by AD group, one disable revokes access everywhere. Adds a VM, an ACL set and a join role; R1–R7 do not need it |
| Observability | **decided 2026-11-09 (Option B):** k8s-monitoring (Grafana Alloy) in k3s by Flux, collecting metrics from everything in the cluster, in and out of the mesh, plus pod logs, events and the API audit log; it writes to Prometheus (7 days, 2 GB cap) and Loki (7 days, the audit log 30 days) on the host, behind the gateway with basic auth from be-1 only (`decision.telemetry-auth`: a client certificate from a separate root is the upgrade path); Grafana a fifth host console, Viewer login, the mixin and three lab dashboards; Alertmanager off | in-cluster kube-prometheus-stack (the earlier design): a second gateway and a mgmt-NIC listener on be-1, metrics lost on a restart, no logs; alerts on tunnel handshakes, hub drops, mesh denials and unexpected Vault decrypts: alert routing nobody would receive in the build window; Mimir and long retention: the production answer for many clusters |
| Telemetry: traces (OpenTelemetry) | **highly recommended option, not in the core build** (added 2026-11-09; slot after 8.8d): OpenTelemetry auto-instrumentation in the api (Flask, `psycopg`, and `requests`, which carries `hvac`'s Vault calls; packages pinned with `--require-hashes` like the rest), exporting OTLP/HTTP to Alloy's receiver `alloy.monitoring:4318` (`applicationObservability` on; ALLOW Alloy ← `sa/api` on 4318; Alloy's ClusterRole gains `replicasets`); Alloy forwards it through an `otlp` destination to Tempo on the host through the gateway (`tempo.lab.test`, one more SAN, `Path(/v1/traces)`, the same allowlist and basic auth), Tempo's data in a MinIO bucket `tempo`, Tempo added to Grafana. About a day of work, ~0.4 GB on the host and ~0.1 GB more for Alloy; no firewall or waypoint change, since pod egress to `10.250.0.1:443` is already allowed. Proof: one `POST /customers` shows the api, Vault-login, Transit and Postgres spans in one trace | frontend and gateway spans for an end-to-end trace from fe-1 (fe-1 → host OTLP is a new mgmt flow); Istio waypoints for per-hop L7 spans (an Envoy per namespace: memory on be-1) |
| Longevity and hardening | 30-day host certificates, no renewal timer; nothing that only matters after the build window | renewal timers and hot-reload checks, CRLs and revocation, istiod CA rotation, CIS hardening and an image scan/SBOM, `tfstate` versioning, Gitea and state backups, teardown and reboot drills, ADRs and a full runbook (beyond 14.4's few procedures): worth having for a long-lived estate, not for a 3-week build proven by a green pipeline run and `up`'s local stage (§13) |
| Frontend → api encryption | **built:** mutual TLS from the frontend to the backend gateway, end to end inside the WireGuard tunnels (`pki_app`, both keys generated where used), so tun-1 forwards ciphertext only | server-auth TLS only: simpler, but anything that reached the overlay could call the api; the client certificate reuses fe-1's CSR flow (8.7f). TLS straight to the api pod: the gateway would pass it through and the api would carry TLS code the mesh already provides |
| Third-party image mirror | **option, not in the core build** (added 2026-11-09; slot after 8.1c): the `cluster` job copies each pinned public image (Istio, CloudNativePG, the Vault Secrets Operator, the k8s-monitoring images, Caddy) by digest from its registry to `gitea.lab.test/lab/mirror/` with `skopeo copy`, on the host, after a Trivy scan, the way 8.1c mirrors charts; a digest already there is skipped. be-1's `registries.yaml` and fe-1's `registries.conf` point `docker.io`, `quay.io`, `ghcr.io` and `registry.k8s.io` at that mirror (**[verify]** k3s's `rewrite` and Podman's `location` with a path prefix at the pinned versions), and the registries leave Squid's allow-list, so VMs fetch only apt packages and the k3s binary through Squid. About one M session and a few GB in Gitea; no new service and no firewall change, since VMs already reach the gateway. Proof: with the registries off the allow-list, a rebuilt be-1 starts every pod and Squid's log shows no registry request | Harbor or Nexus as a pull-through cache: the enterprise answer, but ~2 GB on the host and another console; Zot with on-demand sync: lighter, still one more service; air-gap bundles carried in by hand: the answer for networks with no egress at all |
| Egress control | proxy allow-list | ACL allow-list by CIDR: registries and mirrors sit behind CDNs, so CIDR lists rot |
| Console exposure | host only, each tool's own login, read-only identities everywhere | consoles on the LAN behind SSO (OIDC from a directory): the enterprise answer; needs the directory (above) |
| Grafana access | a host console behind the gateway, on the one gateway certificate, Viewer login | on be-1 behind its own Istio gateway on the mgmt NIC (the earlier design): a second gateway, a DNAT rule and a `pki/sign/grafana` role; `kubectl port-forward`: plain HTTP on the host's loopback and a helper process to keep alive |
| CI runner | one runner on the host as `lab-runner` (in `kvm` only; images built with rootless Podman), one label, every job; `main` protected by a required `pr.yml` check with 0 approvals | separate untrusted runners for pull requests (no host access, no deploy credentials), a deploy runner only `main` can reach, a remote BuildKit service, and a required second reviewer: the enterprise answer once more than one person pushes. With one operator, every PR is the operator's own code, so a PR running with host access and the pipeline identity is an accepted, stated risk |
| Control-plane runtime | **decided 2026-11-09: Podman over Docker; 2026-11-10: Compose over quadlets.** Rootful Podman from the Ubuntu 24.04 archive, the host services in one `compose.yaml` run by a pinned `docker-compose` v2 against Podman's socket, started by `lab-platform.service` after the firewall; TLS at a gateway, Vault direct; rootless Podman for the runner's image builds | Docker Compose (the earlier design): a root daemon, a third-party apt repo and key, and the `docker` group, which made the runner root-equivalent; Docker also set FORWARD to drop and loaded `br_netfilter`, which the lab had to undo (§10 rule 13). Podman has no daemon and the runner needs no privileged group. Quadlets (one systemd unit per container, the native way on a Podman production host) were the first choice; Compose replaced them because the operator already knows it, one file shows the whole control plane, and Podman 4.9's quadlets lack `AddHost=` and `Notify=healthy`. Compose's costs: rootful Podman's API socket is on (root-only), services are not separate systemd units (`podman logs`, `docker-compose restart`), and the firewall dependency is on the whole stack. Its costs: netavark adds no forward filtering, so the lab's table is the default deny (2.2), and aardvark-dns moves off port 53 (2.1c). If the 2.1c spike fails, the named fallback is Podman 5.x with netavark ≥ 1.10 (nftables driver) from a pinned third-party apt repository, today OBS `home:alvistack` **[verify]**, removed by `destroy`; returning to Docker is the last resort. A host k3s cluster with a mesh: the mesh's CA would be Vault running inside it, CloudStack and `/dev/kvm` builds cannot move in, and k3s needs bridge netfilter on, which breaks bridged VM traffic (§10 rule 13). Enterprises keep foundation services (DNS, PKI, SCM, artifact store) outside the platforms they bootstrap |
| Supply-chain admission | images scanned and pinned by digest; Pod Security Admission `restricted` | cosign signing at push with a Kyverno/policy-controller verify rule at admission: the production answer for "only our images run"; here digest pinning in reviewed manifests gives the same guarantee for a single registry and operator |
| Gateway certificates | one certificate for every gateway name, issued by the renewal that `up`, `update` and the platform phase run, Traefik restarted on re-issue | per-hostname certificates hot-reloaded on renewal, or ACME from Vault's PKI (Traefik as an ACME client): the common enterprise pattern; renewal machinery a 3-week build never exercises |
| Golden-image transport | SSVM copy over plain HTTP from the gateway's `images/` route, checksum verified | direct-download templates over HTTPS with `lab.test CA` uploaded to the KVM host: TLS on that hop, but an extra trust upload and an admin-only registration path |
| Behind the gateway | plain HTTP on an internal Podman network and loopback | re-encrypting to every backend: needed when the network behind the gateway is shared or untrusted; here it never leaves the host |
| SSH host trust | per-job `known_hosts` with `accept-new` | Vault's SSH CA signing host and user certificates, so host keys are verified and no static key exists: the production answer, out of scope |
| istiod CA name constraints | DNS constrained to `cluster.local`; IP/URI constraints only if the pinned Vault accepts them (2.5d) | an offline-root PKI where the intermediate is constrained by the signing ceremony itself: out of scope; the pipeline identity that could request it already runs with host access (2.10) |
| Management network isolation | in-guest nftables on a shared host-only bridge | private VLANs or per-VM L2 isolation, so a VM's root cannot reach another VM's mgmt NIC: needs Open vSwitch PVLAN support in CloudStack |
| Privileged access | SSH to the host as Ubuntu ships it, from `LAN_CIDR` only (2.2); CloudStack adds the KVM host as root with a key limited by `from=` to the host's own address (3.1c) | key-only SSH hardening (the option below); AD logins (above), Teleport/Boundary with an SSH CA and session recording: the production answer, out of scope |
| Host SSH hardening | **option, not in the core build** (moved out of 2.2 on 2026-11-10; about one M session, folds into 2.2): config key `OPERATOR_LOGIN`, which preflight requires to be a local non-root user with a usable key in the file `sshd -T -C user=<login>` names (owned by the user, not group- or world-writable); a drop-in `/etc/ssh/sshd_config.d/00-lab.conf` (sorts before cloud-init's `50-cloud-init.conf`; sshd keeps the first value) with `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`, `AllowUsers <OPERATOR_LOGIN> root@<HOST_IP>` (the second for 3.1c; `user@host` avoids a `Match` block), `X11Forwarding no`, `AllowAgentForwarding no`, `PermitTunnel no`, `AllowStreamLocalForwarding no`, `AllowTcpForwarding local` (`ssh -D`, `-L`, `-J` work; `-R` does not); a per-source nftables meter on new tcp 22 connections (`limit rate over 10/minute burst 10 packets`); lockout guards: the key check re-runs, `install -d -m 0755 /run/sshd` then `sshd -t` (a failure removes the file), then `systemctl try-reload-or-restart ssh`, the applying session kept open. Check H1: `ssh -o PreferredAuthentications=none` as `OPERATOR_LOGIN`, root and an unknown user lists only `publickey`; root and a temporary keyed user from the LAN are refused. `destroy` removes the drop-in (rule 26 names it) and reloads. Further tightenings: refuse stray `AllowUsers`/`AllowGroups`/`Match` lines elsewhere in the sshd config (sshd adds up `AllowUsers` from every file); a timed undo (`systemd-run --on-active=5min` removes the drop-in unless confirmed from a new session) | the core build keeps Ubuntu's SSH defaults to stay on the core functions; the risk accepted is password logins from `LAN_CIDR` if the host allows them |
| Linting | **option, not in the core build** (moved out of the scaffold step on 2026-11-10; about one M session): a `lint` job in `pr.yml` running ruff, mypy, shellcheck (`bootstrap.sh`), yamllint, ansible-lint and tflint, each only over the file types that exist so far, failing when files of a type exist but its linter is missing; ruff, mypy, yamllint and ansible-lint hash-pinned in a dev requirements file this option adds, shellcheck and tflint pinned in `config/versions.toml` | not needed for the core functions; `terraform plan` + policy, `trivy config`, kubeconform and the no-Secrets rule still gate every PR (10.1) |
| Unit tests | **option, not in the core build** (removed 2026-11-10): pytest over `lab/` in a `tests/` tree, with a `pyproject.toml`, hash-pinned dev tools in `requirements-dev.txt` and a repo `.venv/`, run as a `pr.yml` job | testing happens as the lab is built: each step's Exit is run by hand on the CLI, and every change runs through the Gitea pipeline (`pr.yml`'s gates, then `verify`); most units would only mock CloudStack, Vault and k3s |
| `status` command | **option, not in the core build** (removed 2026-11-10): a read-only `status` command printing each phase's `check()` result, the pinned versions, Vault's seal state, the gateway, the Vault audit disk usage and host memory against the §5 budget | the core build keeps four commands; `up` and `update` log each phase's state as they converge, and a version is one `/opt/lab/bin/<tool> version` away |
| Examiner walkthrough (`demo`) | **option, not in the core build** (removed 2026-11-10; about two M sessions): a `demo` command running a 14-minute walkthrough (shape, tiers and tunnel, application, encryption, zero trust, trust chain, backup, operations) as re-runnable proofs with human-readable output, reusing the `verify` checks; E2/E3 on the real `customers` key with every row rewrapped first; the break-glass port-forward shown in S4 and A1; a hand edit Flux reverts; kept as `docs/walkthrough.md` with real output | the evidence already exists without it: a green `deliver.yml` run ending in `verify`, and `up`'s local stage for B2/B3 (§13); a walkthrough re-states it for a human audience |
| Egress tightening | **option, not in the core build** (added 2026-11-09; folds into 2.2, minutes of work): Gitea's public egress in rule 4 also excludes `100.64.0.0/10` (carrier-grade NAT) and `169.254.0.0/16` (link-local, where cloud metadata services listen), so a compromised Gitea cannot reach a provider's metadata endpoint or a CGNAT neighbour; the 2.2 Exit adds `169.254.169.254:443` timing out from Gitea's address | not needed for the core functions |
| Defence in depth inside k3s | mesh identity (AuthorizationPolicy) only | Kubernetes NetworkPolicies as an L3 layer under the mesh: worth it with many teams; its interplay with ambient's HBONE port needs care, out of scope |
| Git provenance | protected `main`, read-only Flux token | Flux verifying signed commits: needs every merge signed by a key Flux trusts, Gitea's merge commits included |

---

## 16. Glossary

| Term | Meaning here |
|---|---|
| aardvark-dns | Podman's DNS server for named networks: answers container names on each network's gateway address and forwards other names to the host's resolver (here CoreDNS at `127.0.0.1`); on port 1053 here, so CoreDNS keeps 53 |
| ACL list | a CloudStack VPC tier's firewall: ordered allow/deny rules, ingress and egress |
| `allow-nothing` | an `AuthorizationPolicy` with an empty spec in Istio's root namespace: every meshed workload denies callers no ALLOW names |
| Alloy | Grafana Alloy: a telemetry collector that scrapes metrics, reads logs and forwards both (here by remote write to Prometheus and push to Loki on the host) |
| Alloy Operator | the controller k8s-monitoring 4.x uses to run Alloy from an `Alloy` custom resource; here confined to `monitoring`, with no ClusterRoles of its own |
| AppRole | a Vault login for machines: a `role_id` (like a username) plus a `secret_id` (like a password, with a TTL) |
| break-glass | an emergency credential kept out of daily use: here the k3s cluster-admin kubeconfig, read only by `teardown`/`destroy` (§14 rows 0–3) and by hand through the runbook's procedure (a `0600` temp file deleted after use), every read audited |
| CPVM / SSVM | CloudStack system VMs: the console proxy (browser VM consoles) and the secondary-storage VM (copies templates) |
| CNPG | CloudNativePG: an operator that runs PostgreSQL from a `Cluster` resource (pods, PVCs, Services, TLS, declared roles) |
| `cmk` | CloudMonkey, CloudStack's CLI |
| ConfigDrive | userdata delivered to a VM as an attached ISO (label `config-2`) instead of from the virtual router |
| Flux | GitOps controllers: a `GitRepository` fetches a git revision, a Flux `Kustomization` applies one path of it (pruning what was removed, in `dependsOn` order), a `HelmRelease` installs a chart |
| gate (Kustomization) | an empty Flux Kustomization whose health checks wait for a job's run-time Secrets; what needs them `dependsOn` it |
| `fib saddr type local` | nftables match: the packet's source address is one of the host's own |
| HBONE | Istio ambient's tunnel: mTLS HTTP CONNECT on port 15008 between ztunnels |
| hub (tun-1) | the tunnel tier's VM; terminates both WireGuard tunnels and forwards one allowed flow |
| k8s-monitoring | Grafana's Helm chart that deploys Alloy, the Alloy Operator, kube-state-metrics and node-exporter and writes Alloy's configuration from feature switches |
| kubernetes-mixin | the community's recording rules and dashboards for Kubernetes (with the node-mixin for node-exporter), rendered from jsonnet |
| local stage (`up`) | what `up` runs as root on the host once the pipeline is green: the Vault DR drill (B3, B2), which needs the unseal key the runner can never read, then the `verify` job's pass/fail summary |
| Loki | Grafana's log store: indexes labels only, keeps chunks in object storage (here MinIO) |
| meter (nftables) | a rule that adds each source to a dynamic set with its own rate limit, so one noisy address is limited without affecting others; used by the SSH-hardening option (§15) |
| `min_decryption_version` | Transit key setting: ciphertext older than this key version can no longer be decrypted |
| netavark | Podman's network tool: creates bridges and veths and writes the NAT and published-port rules (with its iptables driver at 1.4, through iptables-nft) |
| `netplan try` / SIGUSR1 | apply a network change that reverts itself unless confirmed; SIGUSR1 is the confirmation |
| mutual TLS (mTLS) | TLS in which the client also presents a certificate the server verifies; here frontend ↔ backend gateway (`pki_app`), and every meshed hop (HBONE) |
| `node-agents` | the namespace holding the only host-access pods (node-exporter, alloy-audit), PSA `privileged`, kept apart from `monitoring` |
| PSA | Pod Security Admission: per-namespace labels that reject pods breaking a security profile |
| RBAC | Kubernetes role-based access control: `Role`/`ClusterRole` list verbs on resources (optionally by name), bindings give them to users or ServiceAccounts; it guards the API, as the mesh guards the network (rule 25) |
| quadlet | Podman's systemd integration: a `.container`, `.network` or `.volume` file in `/etc/containers/systemd/` becomes a systemd service at `daemon-reload`; here fe-1's frontend (the host uses Compose) |
| Compose | one YAML file declaring containers, networks and volumes, applied with `docker-compose up`; here run against rootful Podman's API socket for the host's control plane |
| Raft | Vault's built-in replicated storage; a snapshot is a full, barrier-encrypted copy |
| Rego / Conftest | OPA's policy language, and the CLI that runs it against files such as a plan JSON |
| remote write | Prometheus's push protocol: a client (Alloy) POSTs samples to `/api/v1/write` on a Prometheus started with `--web.enable-remote-write-receiver` |
| rootless Podman | containers run by an unprivileged user in a user namespace mapped onto its `/etc/subuid` range: root in the container is a subordinate UID on the host; here `lab-runner`'s image builds |
| ServiceLB | k3s's built-in LoadBalancer: exposes a Service's port on the node's own addresses |
| SPIFFE ID | a workload identity, `spiffe://cluster.local/ns/<ns>/sa/<sa>`, carried in its mesh certificate |
| Transit | Vault's encryption-as-a-service engine: data is encrypted and decrypted by Vault; keys never leave it |
| VSO | Vault Secrets Operator: logs in to Vault (here with Kubernetes auth) and keeps a Kubernetes Secret equal to a Vault path (`VaultStaticSecret`) |
| ztunnel | Istio ambient's per-node proxy that carries meshed pods' traffic |

---

## 17. Build tracking: steps, handoffs and the registry

The build spans 91 sessions, and each starts cold. Two records outside the repo carry what a session needs from earlier ones, in a private repo `~/lab-tracker`
(created when the build starts; the learner commits it, Claude never does):

- **beads** (`bd`): one issue per step (§17.4), with the Needs as dependencies. It answers
  *what is next*, *what is half done* and *what did step X conclude*.
- **`registry.md`**: the durable facts later steps read, by key. It answers *what is the
  value, location or decision for X*, however many phases back it was made.

Neither is a diary: the narrative goes in the learning log (STUDY-PLAN §7.1), and the
past is in git history. The precursor's single RESUME block and "Notes carried forward"
mixed status, narrative, facts and corrections in one growing file, so old names stayed
next to new ones; here status lives in beads, facts in the registry (overwritten in
place), and the story in the log.

### 17.1 The registry

`~/lab-tracker/registry.md`, one section per group of prefixes, in this order:

| Section | Prefixes | Holds | Example keys |
|---|---|---|---|
| Network | `net.` | addresses, CIDRs and ports as built | `net.host`, `net.vpc`, `net.public-ip` |
| Host | `host.`, `path.` | host facts, file paths | `host.memory`, `path.vault-init`, `path.bridge-nf` |
| Control plane | `podman.`, `fw.`, `dns.`, `ntp.`, `gw.`, `minio.`, `gitea.`, `git.`, `proxy.`, `runner.` | how each service is reached and configured | `gw.hosts`, `runner.user` |
| Vault | `vault.` | mounts, roles, policies, AppRoles, KV paths | `vault.mount.pki`, `vault.kv.app-db` |
| CloudStack | `cs.` | object names and ids | `cs.network.mgmt`, `cs.account.iac` |
| Image and Terraform | `img.`, `cfg.`, `tf.`, `policy.` | image versions, state location, gate files | `img.template`, `tf.backend` |
| VMs | `vm.`, `ssh.`, `ansible.`, `wg.` | per-VM addresses, access, roles, tunnel | `vm.be-1`, `wg.keys` |
| Cluster and app | `k8s.`, `flux.`, `mesh.`, `db.`, `vso.`, `api.`, `fe.`, `mon.` | cluster objects, GitOps, mesh CA, app pieces, monitoring | `flux.kustomizations`, `mesh.ca`, `db.cluster` |
| Operations | `ci.`, `backup.`, `dr.`, `verify.`, `console.` | pipeline, drills, checks, consoles | `ci.dispatch`, `dr.canary`, `console.urls` |
| Code map | `code.`, `cmd.` | where a helper lives; the exact command for a recurring task | `code.config`, `cmd.kubeconfig` |
| Decisions | `decision.` | a choice made during the build, and the alternative | `decision.mesh-root`, `decision.observability`, `decision.runtime` |
| Spikes | `spike.` | results that gate later steps | `spike.netavark-fw`, `spike.mgmt-nic`, `spike.t1-capture` |
| Gotchas | `gotcha.` | a trap found while building that a later step will meet again (not already a §10 rule) | `gotcha.sudo-kubeconfig` |
| Deviations | `deviation.` | where the build differs from this plan, until the plan is edited | `deviation.8.3b-cni-bin` |

**Keys:** lowercase, dots for hierarchy (`<area>.<object>[.<attr>]`), hyphens inside
words. A contract may name a family: `vault.policy.*`, `vm.<name>`.

**Entries:** one line each, `` `key` = value — source · step, date ``:

```
- `vault.kv.app-db` = `kv/app/db`, field `password`, create-once — lab/app.py · 8.4b, 2027-01-12
- `decision.mesh-root` = `pki_mesh` (separate root for the istiod CA) — §15 "Mesh trust root", decided 2026-11-05
- `decision.observability` = Option B: Alloy (k8s-monitoring) in k3s → Prometheus, Loki, Grafana on the host — §15 "Observability", decided 2026-11-09
- `gotcha.sudo-kubeconfig` = sudo drops KUBECONFIG → localhost:8080; pass --kubeconfig (rule 21) · 8.1, 2027-01-05
```

**Rules:**

- A key exists only if a later step's Recalls names it, or it is a decision, spike,
  gotcha or deviation. Anything else goes in the bead's closing note.
- Short values are written in; anything longer points at the repo file. Where the repo
  is the source of truth (`config/lab.toml`, `config/versions.toml`, a manifest), the entry names
  file and key, and the source wins any disagreement.
- Overwrite in place: never two values for one key, never "superseded" lines. A renamed
  object has its key updated in the same session.
- Never a secret value: its path only (§6).
- `decision.*` is written when the learner decides, in any session. `OPEN` means a step
  that recalls it stops and asks. The registry starts with `decision.mesh-root =
  pki_mesh` (decided 2026-11-05), `decision.observability = Option B` and
  `decision.telemetry-auth` = Traefik basic auth from be-1 only, credential in Vault KV
  synced by VSO (§15 "Observability", 2.7b), and `decision.runtime` = Podman, host services
  by Compose (§15 "Control-plane runtime"), all three decided 2026-11-09 (Compose
  2026-11-10); no
  decision is open.
- The registry describes one lab on one host; a rebuild elsewhere rewrites its `net.*`
  and `host.*` keys on the way through. Prune keys no open step recalls once it passes
  about 300 lines.

### 17.2 Beads

- **Import:** one bead per row of §17.4, titled `<ID> <title>` (`2.4b Init and unseal`),
  labels `phase-<n>` and `size-S` or `size-M`; one dependency per Needs entry (`bd dep add`).
  The body points at the step (`PLAN-enterprise.md §9, 2.4b`) instead of copying it.
- **Blockers as beads:** an open decision or a failed spike becomes its own bead, blocking
  the steps that need it: a 3.3b spike whose fallback also failed opens "Decide the mgmt design", which blocks
  5.4a. None is open at the start.
- **Work in progress:** while a step spans sessions, its notes hold one WIP block,
  replaced each session, ≤ 6 lines: where it stopped, the next action, what the learner
  owes (predictions, a `sudo` run), uncommitted files.
- **Closing note** (the close reason), ≤ 5 lines: what was built (files, objects); the
  Check evidence (command → result, §12 IDs); registry keys written; deviations; anything
  left open (new work becomes a new bead). Steps list extras after the `;` in Records.

### 17.3 Session protocol

**Start** (Claude, before teaching):

1. `bd ready` and `bd list --status in_progress`. Take the in-progress step, else the
   first ready step in §17.4 order. Confirm it with the learner.
2. `bd show <ID>`: the WIP block, if any.
3. Read the step in §9 and only the sections it cites.
4. Read the registry keys in its Recalls, the `decision.*` keys it names, and the
   `deviation.*` keys for its phase. A missing key: find the step that records it
   (search this plan for the key under Records), read that step's closing note, fill the
   key and say so. An `OPEN` decision: stop and ask.
5. Read the closing notes of its Needs (`bd show`). Anything further back comes through
   the registry, never by reading old history.
6. Continue with the study loop (STUDY-PLAN §3): due cards, then the cold attempt.

**End** (in the study loop's last phase, before the log entry):

1. Check passed: write the Records keys, close the bead with its closing note, and name
   the next step `bd ready` shows.
2. Check not passed: replace the bead's WIP block; the step stays in progress.
3. Any decision, gotcha or deviation found: its registry key now; a deviation also gets a
   one-line plan-edit proposal for the learner.
4. The learner commits `~/lab-tracker` and the lab repo.

### 17.4 Step index

90 steps, all required: 19 S (60 min), 71 M (105 min), 143.25 h in the full study
loop. Import one bead per row.

| ID | Title | Needs | Phase | Size |
|---|---|---|---|---|
| 0.1 | Shim and package | — | 0 | M |
| 0.2a | Command map and phase interface | 0.1 | 0 | M |
| 1.1 | Baseline and netplan backup | 0.2a | 1 | M |
| 1.2a | Preflight checks | 1.1 | 1 | M |
| 1.3 | Toolchain | 1.2a | 1 | M |
| 2.1a | Host-only bridge | 1.2a | 2 | S |
| 2.1b | Podman and Compose | 2.1a, 1.3 | 2 | M |
| 2.1c | Spike: netavark's firewall driver and rule order | 2.1b | 2 | S |
| 2.2 | Host firewall | 2.1c | 2 | M |
| 2.3a | CoreDNS | 2.2 | 2 | M |
| 2.3b | NTP | 2.2 | 2 | S |
| 2.4a | Vault server | 2.3a | 2 | M |
| 2.4b | Init and unseal | 2.4a | 2 | M |
| 2.5a | PKI: the CA and its roles | 2.4b | 2 | M |
| 2.5b | Vault's own certificate, host trust and renewal | 2.5a | 2 | S |
| 2.5c | KV and Transit | 2.4b | 2 | S |
| 2.5f | Separate roots: `pki_mesh` and `pki_app` | 2.4b | 2 | S |
| 2.5d | Policies | 2.5a, 2.5c, 2.5f | 2 | M |
| 2.5e | Bootstrap AppRole and root revocation | 2.5b, 2.5d | 2 | S |
| 2.6 | Gateway (Traefik) | 2.5e, 2.1b | 2 | M |
| 2.7 | MinIO | 2.6 | 2 | M |
| 2.7b | Telemetry stores and Grafana | 2.7, 2.6, 2.5c | 2 | M |
| 2.8 | Gitea and registry | 2.6 | 2 | M |
| 2.9 | Squid egress proxy | 2.2, 2.3a | 2 | S |
| 2.10 | Runner | 2.7, 2.7b, 2.8, 2.9 | 2 | M |
| 3.1a | Install | 2.6, 2.10 | 3 | M |
| 3.1b | Bridge netfilter | 2.1b | 3 | S |
| 3.1c | Zone, networks and host | 3.1a, 3.1b | 3 | M |
| 3.1d | Storage, system VMs, enable | 3.1c | 3 | M |
| 3.2a | `cmk` and the scoped accounts | 3.1d | 3 | M |
| 3.3a | Offerings and the mgmt network | 3.2a | 3 | M |
| 3.3b | Spike: a mgmt NIC on a VPC VM | 3.3a, 3.2a | 3 | M |
| 3.5a | Seed, workflows and branch protection | 2.10 | 3 | M |
| 3.5b | Hand-off: dispatch and follow | 3.5a, 3.3b | 3 | M |
| 3.5c | Platform consoles | 3.2a, 2.7, 2.7b, 2.8, 2.5e | 3 | M |
| 4.1a | Build through the proxy | 2.9, 1.3, 3.5b | 4 | M |
| 4.1b | Image contents | 4.1a, 2.5b | 4 | S |
| 4.3 | Publish and register | 4.1b, 3.2a, 2.7 | 4 | M |
| 5.1 | Provider and remote state | 4.3, 3.3a | 5 | M |
| 5.2 | Network | 5.1 | 5 | M |
| 5.3a | Policy rules | 5.2 | 5 | M |
| 5.3b | The gated apply | 5.3a | 5 | M |
| 5.4a | Compute | 5.3b, 3.3b | 5 | M |
| 5.4b | Ingress, inventory and DNS | 5.4a, 2.3a | 5 | M |
| 6.1a | `base` role: DNS, time and proxy | 5.4b, 2.3b | 6 | M |
| 6.1b | VM firewall | 6.1a | 6 | M |
| 6.2a | WireGuard keys and tunnels | 6.1b | 6 | M |
| 6.2b | The hub's policy and the tunnel proofs | 6.2a | 6 | M |
| 8.1 | k3s on be-1 | 6.1b | 8 | M |
| 8.1b | Flux and the GitOps tree | 8.1, 2.8 | 8 | M |
| 8.1c | Chart mirror | 8.1b | 8 | S |
| 8.2a | Vault's Kubernetes auth | 8.1b, 2.5d | 8 | M |
| 8.2c | Least-privilege k3s identities | 8.2a | 8 | M |
| 8.2d | The k3s API audit log | 8.2c | 8 | S |
| 8.3a | The istiod CA from Vault | 8.1b, 2.5d, 8.2d | 8 | M |
| 8.3b | Install Istio ambient through Flux | 8.3a, 8.1c | 8 | M |
| 8.3c | STRICT mTLS and the capture point | 8.3b | 8 | M |
| 8.4a | The database: CloudNativePG | 8.3c, 8.1c | 8 | M |
| 8.4b | The `app` password: Vault → VSO → CNPG | 8.4a, 8.2a | 8 | M |
| 8.4c | Only the api reaches Postgres | 8.4b | 8 | S |
| 8.5 | Vault for the api | 8.2a, 8.4b | 8 | M |
| 8.6a | Image build and scan gate | 2.8, 3.5b | 8 | M |
| 8.6b | Push by digest | 8.6a | 8 | S |
| 8.7a | The api in k3s: plumbing | 8.6b, 8.5, 8.4c | 8 | M |
| 8.7b | The api talks to Vault | 8.7a | 8 | M |
| 8.7c | The api's customer endpoints | 8.7b | 8 | M |
| 8.7d | The backend gateway with mutual TLS | 8.7c, 6.2b | 8 | M |
| 8.7g | The frontend's client certificate: end-to-end mTLS | 8.7d | 8 | M |
| 8.7h | Default deny and the ALLOW policies | 8.7g | 8 | M |
| 8.7e | The frontend on fe-1 | 8.7h, 8.6b | 8 | M |
| 8.7f | Edge TLS for `app.lab.test` | 8.7e, 5.4b | 8 | M |
| 8.8a | k8s-monitoring through Flux | 8.7h, 8.1c, 2.7b | 8 | M |
| 8.8b | Mesh, platform and api metrics, three dashboards | 8.8a, 8.7g | 8 | M |
| 8.8d | Node metrics and the API audit log | 8.8a, 8.2d | 8 | M |
| 9.1a | Backup: the Vault snapshot and the database | 8.7c | 9 | M |
| 9.2 | Restore drill | 9.1a | 9 | M |
| 9.3a | DR drill: scratch Vault from the snapshot | 9.1a | 9 | M |
| 9.3b | DR drill: the canary decrypts | 9.3a | 9 | S |
| 9.4 | Crypto-shredding | 9.3b | 9 | S |
| 10.1 | `pr.yml` gates | 5.3b, 8.6a, 8.1b | 10 | M |
| 10.2 | `deliver.yml` change flow | 8.7f, 12.1f | 10 | S |
| 10.3a | `schedules.yml`: nightly backup and verify | 9.1a, 12.1c | 10 | S |
| 12.1a | `verify`: framework and network checks | 8.7f | 12 | M |
| 12.1b | `verify`: data, secrets, mesh and API access | 12.1a | 12 | M |
| 12.1c | `verify`: TLS and the `verify` job | 12.1b | 12 | M |
| 12.1f | `verify`: observability, consoles and GitOps | 12.1c, 8.8b, 8.8d, 3.5c | 12 | M |
| 13.1a | `teardown` and `destroy` orchestration | 12.1f, 14.4, 10.1, 10.2, 10.3a, 9.2 | 13 | M |
| 13.1b | Host restore | 13.1a | 13 | M |
| 13.2 | Revert check in `destroy` | 13.1b | 13 | M |
| 14.4 | Runbook and evidence | 12.1f, 9.4 | 14 | S |

### 17.5 Old → new step numbers

Steps not listed kept their number. A bare old number now names the whole group.
**Removed** numbers stay unused; what they built is summarised in §15.
On 2026-11-10, 0.2c (dev tools and unit tests), 12.2 and 12.3 (`demo`) were removed:
each step's Exit, run by hand, and the Gitea pipeline are the tests, and the evidence is a
green `deliver.yml` run plus `up`'s local stage (§13).

| Old | New |
|---|---|
| 0.2 | 0.2a; 0.2b folded into 1.3, 0.2c removed (2026-11-10) |
| 1.2 | 1.2a; 1.2b removed (nested-host checks: by hand, §5) |
| 2.1, 2.3, 2.4 | 2.1a–2.1b, 2.3a–2.3b, 2.4a–2.4b; new 2.1c (spike: netavark's firewall driver) |
| 2.5 | 2.5a–2.5e; new 2.5f (separate roots `pki_mesh`, `pki_app`) |
| 2.7 | 2.7 kept; new 2.7b (telemetry stores and Grafana on the host) |
| 3.1c | 3.1c, 3.1d |
| 3.2 | 3.2a; 3.2b removed |
| 3.3, 3.5 | 3.3a–3.3b, 3.5a–3.5b; new 3.5c (platform consoles) |
| 3.4 | removed (the template is copied by the SSVM, 4.3) |
| 4.1 | 4.1a, 4.1b |
| 4.2 (4.2a, 4.2b) | removed |
| 5.3, 5.4, 6.1, 6.2 | 5.3a–5.3b, 5.4a–5.4b, 6.1a–6.1b, 6.2a–6.2b |
| Phase 7 (7.1–7.4) | removed (§15 "Directory login") |
| 8.1 | 8.1 kept; new 8.1b (Flux), 8.1c (chart mirror) |
| 8.2 | 8.2a; 8.2b removed; new 8.2c (least-privilege k3s identities, break-glass admin), 8.2d (API audit log) |
| 8.3 | 8.3a–8.3c; 8.3d removed |
| 8.4 | 8.4a–8.4c (8.4a now CNPG, 8.4b now VSO; the hand-written StatefulSet and schema code are gone) |
| 8.7 | 8.7a–8.7f; new 8.7g (client certificate), 8.7h (default deny) |
| — | new 8.8a, 8.8b, 8.8d (k8s-monitoring, metrics and dashboards, node metrics and the audit log); 8.8c removed (the Grafana console moved to 2.7b and 3.5c, 2026-11-09) |
| 8.6 | 8.6a, 8.6b; 8.6c removed |
| 9.1 | 9.1a; 9.1b removed |
| 9.3 | 9.3a, 9.3b |
| 10.3 | 10.3a; 10.3b removed |
| Phase 11 (11.1a–11.2) | removed; a smaller monitoring stack returned as 8.8a, 8.8b, 8.8d and 2.7b |
| 12.1 | 12.1a; 12.1b (was 12.1b + 12.1c); 12.1c (was 12.1d + the job from 12.1e); 12.1d, 12.1e removed; new 12.1f (observability, consoles, GitOps); 12.2, 12.3 (`demo`) added, then removed 2026-11-10 |
| 13.1 | 13.1a, 13.1b; 13.1c–13.1e removed |
| 14.1, 14.2 (14.2a, 14.2b), 14.3, 14.5 | removed; 14.4 kept (now "Runbook and evidence", 2026-11-10) |
