# SingleClusterIaCLab — Build Plan

One Ubuntu 24.04 host becomes a small, enterprise-shaped private cloud, built and
torn down by one command:

- **IaaS:** Apache CloudStack on KVM, provisioned by Terraform from a hardened golden image.
- **Network:** a VPC with isolated tiers, default-deny ACLs, no direct internet from any
  tier, and a WireGuard site-to-site VPN as the only path between two of them.
- **Application platform:** k3s running a three-tier application (HTML frontend → API →
  PostgreSQL) in an Istio ambient mesh, with Vault as the encryption service and the CA.
- **Control plane:** Vault, CoreDNS, MinIO, Gitea and an egress proxy on the host, driving
  everything with secrets issued at run time.

`sudo ./bootstrap.sh up` bootstraps the host, the control plane, CloudStack and a
CI runner, then hands over to the **delivery pipeline**, which builds everything
else; `up` follows the pipeline until it finishes. `sudo ./bootstrap.sh demo` proves
every requirement. `sudo ./bootstrap.sh down` removes it and restores the host, and
`sudo ./bootstrap.sh revert-check` (after the reboot) proves the host matches its
original baseline.

This document is complete on its own: everything needed to build the lab is here.

---

## 1. Requirements and how each is proven

| ID | Requirement | Built in | Proven by (check IDs, §12) |
|---|---|---|---|
| **R1** | Construct a VPC and implement a VPN to provide access | Phases 5, 6 | N1–N5 |
| **R2** | Deploy a database and an encryption service for a cloud application | Phases 2, 8 | E1–E3, T1–T2, Z1–Z2, P1–P3, S1–S2 |
| **R3** | Back up and restore the encrypted data; show key loss destroys it | Phase 9 | B1–B2 |
| **R4** | Reversible infrastructure: teardown restores the host exactly | Phase 13 | V1–V5 |
| **R5** | Pipeline-driven: after bootstrap, every build and change is a CI run with gates | Phases 2.9, 3.5, 10 | G1–G3 |
| X1 | Directory login: AD users, AD-group sudo, central revocation | Phase 7 **[ext]** | D1–D4 |
| X3 | Observability of tunnel, mesh denials and Vault access | Phase 11 **[ext]** | O1–O3 |

**Tags.** Everything untagged is **core**: required for R1–R5. **[ext]** marks
enterprise extensions built on a working core. `up --core` builds the core
only; `up` builds everything.

---

## 2. Principles

- **Bash at the door, Python inside.** `bootstrap.sh` checks for Python ≥ 3.12 and
  runs `PYTHONPATH=src exec python3 -B -m lab "$@"`, nothing more. Every phase,
  check, demo and teardown is Python in `src/lab/`, type-checked with mypy. External
  tools (`cmk`, `terraform`, `ansible-playbook`, `packer`, `kubectl`, `vault`,
  `istioctl`, `mc`, `docker`) are called through thin wrappers, never
  re-implemented. The only shell in the repo is the vendored upstream CloudStack
  installer, which is third-party.
- **Bootstrap by hand, everything else by pipeline.** `bootstrap.sh` builds only what
  must exist before CI can run: the host, the control plane, CloudStack and the
  runner (Phases 1–3). From Phase 4 on, every phase is a job in the delivery
  pipeline, and each job runs the same `python3 -m lab <command>` a person would.
  Running a pipeline phase by hand needs `--break-glass`, which is logged and runs
  the phase as `lab-runner` (never as root, so it leaves no root-owned files behind
  for later jobs). Only
  bootstrap, `demo`, `down`, `revert-check` and unsealing Vault after a reboot run
  locally, because CI cannot exist before them or would not survive them.
- **Every phase owns its teardown.** Each phase module exports `up()`, `down()` and
  `check()`. `down` composes the `down()`s in reverse build order, so a phase can't
  be built without the code to remove it.
- **Always converge; skip only expensive builds.** Every job runs its idempotent
  converge on every run (`terraform plan/apply`, Ansible, `kubectl apply`), so a
  merged change always reaches the lab and an unchanged lab produces no changes.
  Only costly builds are skipped, and only by content: the golden image by its input
  hash, the container images by git SHA. `check()` compares **desired with actual**
  (versions, image tags, plan diff), not just health. The local tracker only helps
  bootstrap resume; it is never proof that something is done.
- **Least privilege.** Terraform uses a scoped CloudStack account. Each workload and
  the pipeline gets its own Vault identity and policy. The Vault root token is
  revoked after bootstrap. The CloudStack global admin is used only where nothing
  less works: installing CloudStack (bootstrap) and `down`. Terraform runs as `iac`;
  the golden image is registered by a separate account, `publisher` (3.2).
- **Secrets are issued at run time**, with the exceptions in §6, each named and
  protected.
- **Pinned and immutable.** Every version, image digest, provider and chart is
  pinned in `src/lab/versions.py`. Images are built, scanned and published once, then
  never patched in place. Nothing installs software at container start.
- **Gates before change.** Lint runs from the first commit. Terraform cannot apply
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
| Private CA + certificate automation | Vault PKI (`lab.test CA`); cert-manager in the cluster; `lab maintain` on the host |
| Remote Terraform state + locking | MinIO S3 backend, lockfile |
| Golden-image factory | Packer + CIS-style hardening + Trivy + SBOM → versioned in MinIO |
| Container registry | Gitea registry; images scanned before push |
| Policy-as-code | Conftest/OPA on `terraform plan -json`, before every apply |
| Network segmentation | VPC tiers, default-deny ACLs both directions |
| Egress control | No tier has internet; an allow-listing forward proxy (Squid) on the host |
| Site-to-site VPN | WireGuard, subnet-routed, systemd-managed |
| Managed Kubernetes | k3s, Secrets encrypted at rest |
| Zero-trust service traffic | Istio ambient: STRICT mTLS, SPIFFE identities, `AuthorizationPolicy` |
| Managed database | PostgreSQL 16 StatefulSet; app credentials in Vault, not in manifests |
| API front door | Istio Gateway (Gateway API), TLS with a Vault-issued certificate |
| Backup / DR | Vault Raft snapshot + `pg_dump`, with a restore drill |
| Directory **[ext]** | Samba AD DC; members joined with realmd/SSSD |
| CI/CD | Gitea Actions with one self-hosted runner; every change after bootstrap is a pipeline run |
| Observability **[ext]** | Prometheus, Grafana, Loki, Alloy |

---

## 4. Architecture

```
 LAN (LAN_CIDR)  ── browser / operator
   │
 ┌─┴─────────────────────────────── host: Ubuntu 24.04, KVM ───────────────────────────────┐
 │ cloudbr0 = HOST_IP (LAN)              cloudbr1 = VMNET_HOST_IP 10.250.0.1 (host-only)    │
 │ control plane (Docker):  CoreDNS · Vault · MinIO · Gitea(+registry) · Squid · runner     │
 │                          [Prometheus · Grafana · Loki]                                   │
 │ CloudStack: management + MySQL + NFS + KVM agent      Packer/qemu (image builds)         │
 │                                                                                          │
 │  mgmt shared network (untagged, on cloudbr1 10.250.0.0/24): every VM's mgmt NIC         │
 │  ════════════════════════════════════════════════════════════════════════════════════   │
 │   │ vm-a      │ vm-b          │ app-1                    │ dc [ext]                      │
 │  ┌┴───────────┴───────────────┴──────────────────────────┴───────────────────────────┐  │
 │  │ VPC 10.0.0.0/16   (virtual router: ACLs, source NAT, port-forward)                 │  │
 │  │  tier-a 10.0.1.0/24   tier-b 10.0.2.0/24   tier-app 10.0.3.0/24   tier-svc 10.0.10.0/24│
 │  │   vm-a .10  ✗──────────✗ vm-b .10           app-1 .10 (k3s)        dc .10            │  │
 │  │     └─ wg0 10.99.0.1 ══ WireGuard (underlay: mgmt network) ══ wg0 10.99.0.2         │  │
 │  └────────────────────────────────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
   VPC public IP :443 ──port-forward──▶ app-1:443 (Istio Gateway)
```

**Three planes, kept apart:**

- **Data plane:** the VPC tiers. Inter-tier traffic is denied by ACL, except the AD
  ports into tier-svc **[ext]**. The tiers have **no egress to the internet**. tier-a
  and tier-b reach each other only through the WireGuard tunnel, routed by subnet.
- **Management plane:** each VM's **mgmt NIC** (its second NIC) on the shared mgmt
  network, which lives on a **host-only bridge** (`cloudbr1`, no physical port). The
  LAN cannot reach it and its DHCP cannot answer on it. A per-VM nftables policy lets
  the mgmt NIC talk **only to the host at `10.250.0.1`** (SSH from it; DNS, NTP, proxy,
  Vault, registry and Kubernetes API traffic to and from it) and to the WireGuard peer
  on UDP 51820. The mgmt NIC carries no default route; the default route is the tier
  NIC, so replies to LAN clients always leave through the VPC router they came in by.
- **Control plane:** the host's containers. Every VM reaches the internet only
  through Squid on `10.250.0.1:3128`, against a domain allow-list.

**Application platform on app-1:**

```
 user ──HTTPS :443 (public IP → app-1)──▶ Istio Gateway ──mTLS──▶ frontend (ns app)
                                                                    │ mTLS
                                                                    ▼
                                          Vault ◀──HTTPS── api (ns app) ──mTLS──▶ postgres (ns db)
                                         (host)                     card_number = vault:v1:…
```

- Every pod-to-pod hop is mTLS through ztunnel. Applications speak plain HTTP/TCP.
- **Vault stays outside the cluster and the mesh.** It is the mesh's root of trust;
  if the mesh depended on Vault and Vault on the mesh, neither could recover alone.
- The frontend has no database driver and no Vault access, and the mesh's policies
  forbid it from reaching Postgres.

---

## 5. Address, VM, port and DNS plan (single source of truth)

All environment-specific values live in `config/lab.toml` (committed, non-secret).
Preflight validates them. The values below are the defaults and examples.

**Host and management network**

| Item | Value |
|---|---|
| `LAN_CIDR` | host LAN, e.g. `192.168.50.0/24` |
| `HOST_IP` | host LAN address, moved onto `cloudbr0` by CloudStack, e.g. `192.168.50.10` |
| `LAN_GATEWAY` / upstream DNS | from the LAN |
| CloudStack pod (system VM) range | on the LAN, e.g. `.180–.189` |
| CloudStack public range (VPC source NAT and public IPs) | on the LAN, e.g. `.190–.209` |
| `VMNET_CIDR` (mgmt shared network) | `10.250.0.0/24` on host-only bridge `cloudbr1`; router DHCP `.100–.199`; guests ignore its gateway and DNS |
| `VMNET_HOST_IP` | `10.250.0.1`, the host's address on `cloudbr1`: every VM reaches the control plane here |
| Docker address pool | `172.30.0.0/16` (pinned; must not overlap any range here) |

**VPC `10.0.0.0/16`**

| Tier | CIDR | VM | Size | Role |
|---|---|---|---|---|
| tier-a | `10.0.1.0/24` | `vm-a` `.10` | 1 vCPU · 1 GB · 10 GB | VPN site A |
| tier-b | `10.0.2.0/24` | `vm-b` `.10` | 1 vCPU · 1 GB · 10 GB | VPN site B |
| tier-app | `10.0.3.0/24` | `app-1` `.10` | 4 vCPU · 4 GB · 40 GB | k3s, mesh, database, app |
| tier-svc **[ext]** | `10.0.10.0/24` | `dc` `.10` | 1 vCPU · 2 GB · 20 GB | Samba AD DC |
| WireGuard overlay | `10.99.0.0/24` | vm-a `.1`, vm-b `.2` | | tunnel addresses |
| k3s pods / services | `10.42.0.0/16` / `10.43.0.0/16` | | | inside app-1 only |

**Host ports.** All services listen on `0.0.0.0`, so they keep working when
CloudStack moves `HOST_IP` onto `cloudbr0`. The host firewall is default-drop on
input, accepts `established,related`, and allows each port only from the sources
listed. "VMs" means `VMNET_CIDR`; "containers" means the Docker pool.

| Service | Port | Allowed from | Name → address |
|---|---|---|---|
| SSH | 22 | LAN | `host.lab.test` → `HOST_IP` |
| CoreDNS | 53 tcp/udp | LAN, VMs, containers | — |
| chrony (NTP server) | 123/udp | VMs | — |
| Vault | 8200 | VMs, containers, host | `vault.lab.test` → `10.250.0.1` |
| MinIO API / console | 9000 / 9001 | VMs, containers, host; KVM host (template download) | `minio.lab.test` → `10.250.0.1` |
| Gitea web + registry | 3000 | VMs, containers, host; LAN (web UI) | `gitea.lab.test` → `10.250.0.1` |
| Squid | 3128 | VMs | `proxy.lab.test` → `10.250.0.1` |
| CloudStack UI/API · agent · cluster | 8080 · 8250 · 9090 | LAN (UI), system-VM range (agent), host (Terraform, `cmk`, runner jobs), containers (PR-job `terraform plan`) | `cloudstack.lab.test` → `HOST_IP` |
| NFS (rpcbind, mountd pinned, nfsd) | 111 · 20048 · 2049 | system-VM range | — |
| Grafana · Prometheus · Loki **[ext]** | 3001 · 9095 · 3100 | LAN (Grafana), VMs (Loki push) | `grafana.lab.test` → `HOST_IP` |

Other names: `app.lab.test` → the VPC public IP; `k3s.lab.test` → app-1's mgmt
address. Both are written by `lab setup` (5.4). Every control-plane certificate
carries both its name and `10.250.0.1` as SANs.

**DNS.** CoreDNS on the host is authoritative for `lab.test` and for the reverse
zones of `VMNET_CIDR` and `10.0.0.0/16`, and forwards everything else upstream. Every
VM resolves through the host. Pods resolve through k3s's CoreDNS, which forwards to
the node's resolver. **[ext]** `ad.lab.test` is served by the DC itself; members send
just that domain to `10.0.10.10` (systemd-resolved domain routing). The host cannot
reach VPC addresses, so it does not forward AD names.

**Host capacity: 32 GB RAM is the ceiling, not a target.** The lab must fit
under it with a reserve, at its peak, with no memory overcommit (CloudStack
`mem.overprovisioning.factor = 1.0`, no swap counted). Figures are estimates until
measured; each phase's Exit records the measured steady-state RSS in
`docs/capacity.md`, and `up` refuses to start a phase if the host's available memory
would drop below the **4 GB reserve**.

| Consumer | Core | + [ext] |
|---|---|---|
| Host OS + page-cache floor | 2.0 GB | |
| CloudStack management (JVM) + MySQL + KVM agent | 3.0 GB | |
| System VMs: SSVM, CPVM, redundant VPC router pair, mgmt-network router | 2.5 GB | |
| Control plane: CoreDNS, Vault, MinIO, Gitea, Squid | 1.5 GB | |
| vm-a + vm-b (1 GB each) + app-1 (4 GB) + KVM overhead | 7.0 GB | |
| dc (2 GB) + KVM overhead | | 2.3 GB |
| Gitea runner (idle host service) | 0.2 GB | |
| Prometheus + Grafana + Loki + Alloy | | 2.5 GB |
| **Steady state** | **16.2 GB** | **21.0 GB** |
| Peak transient, one job at a time: golden-image build (Packer VM) | +2.0 GB | +2.0 GB |
| *(container build + scan, +1.5 GB, never overlaps it: the runner runs one job at a time)* | | |
| **Peak** | **18.2 GB** | **23.0 GB** |
| **Headroom under 32 GB** (must stay ≥ 4 GB reserve) | **13.8 GB** | **9.0 GB** |

**What app-1's 4 GB holds** (requests in the manifests must sum to ≤ 3 GB): k3s
server ~0.6, istiod ~0.3, ztunnel + istio-cni ~0.15, Istio gateway ~0.1,
cert-manager ~0.2, Postgres ~0.3, api + frontend ~0.25.

**If measurements overrun, cut in this order:** observability first (it can run
only for the `demo`), then the redundant VPC router (a single router saves
~0.25 GB but loses the HA story), then the directory (dc, 2.3 GB). Core never
shrinks below the table.

**Host:** 8 cores · **32 GB RAM (ceiling)** · 250 GB disk · `/dev/kvm`.

---

## 6. Secrets and the trust bootstrap

**Rule:** a secret is created in Vault or by its consumer, read at run time, and
never written to the repo. The bootstrap secrets below are the only secrets that
exist outside Vault, and each one is listed with its location and protection.

| Secret | Lives in | Protection / rotation |
|---|---|---|
| Vault unseal key + initial root token | `/var/lib/lab/vault-init.json` (outside the repo) | root `0600`. The root token is **revoked** at the end of Phase 2; regenerate it with `vault operator generate-root` when needed. The unseal key is the one thing to back up offline. |
| Runner registration and pipeline AppRole (`lab-pipeline`) role_id + secret_id | `/var/lib/lab/runner/` | owned by `lab-runner`, `0600`; secret_id TTL 30 days, re-issued by the daily root `lab maintain` timer (as `lab-bootstrap`) when under 7 days remain; never stored in Gitea or the repo; unreadable from PR jobs, which run in containers (10.1) |
| PR-job credentials: `iac` API key and a **read-only** `tfstate` MinIO user | Gitea repository Actions secrets | needed only for `terraform plan` in `pr.yml`; `iac` is already scoped (3.2) |
| Bootstrap AppRole (`lab-bootstrap`) role_id + secret_id | `/var/lib/lab/approle.json` | root `0600`; secret_id TTL 30 days. Every `lab` run re-issues it when under 7 days remain (it authenticates with the current one). If it ever expires, recovery is `vault operator generate-root` with the unseal key (runbook) |
| Lab SSH private key (Ansible → VMs) | Vault KV; written to a per-job `0600` temp directory with its own `known_hosts` (`StrictHostKeyChecking=accept-new`, so replaced VMs do not break SSH) | deleted when the job ends |
| Tool credentials (`cmk` API keys, `mc` aliases, registry login) | per-job temp configs only: `cmk` with a temp config file, `mc` through `MC_HOST_*` variables, Docker through a temp `DOCKER_CONFIG` | nothing credential-bearing persists in `lab-runner`'s home between jobs |
| k3s kubeconfig (cluster-admin) | Vault `kv/lab/k3s` | jobs and local commands read it into a `0600` temp file for the duration of the command; deleted from Vault by `down` |
| WireGuard private keys | generated **on** each VM; never leave it | public keys published to Vault KV |
| AD machine keytabs **[ext]** | `/etc/krb5.keytab` on each member | created by the join, never baked into an image |
| Postgres superuser password | k8s Secret in `ns db` | k3s Secrets encryption at rest is on |
| k3s node token and Secrets-encryption key | `/var/lib/rancher/k3s/server/` on app-1 | root-only. The encryption key sits on the same node, so encryption at rest protects datastore copies and backups, not a compromised node |
| istiod signing CA key | k8s Secret `istio-system/cacerts` | encrypted at rest; rotated by `lab mesh --rotate-ca` |
| Vault token-reviewer JWT | k8s Secret for SA `vault-auth`, and Vault's `auth/k3s/config` | encrypted at rest; rotated by re-running `lab cluster` |
| CloudStack DB and MySQL passwords | `/etc/cloudstack/management/db.properties`, MySQL | root-only; generated by the installer; removed in teardown |
| Control-plane start-up credentials (MinIO root, Gitea admin) and host TLS keys | `/var/lib/lab/platform/*.env`, `/var/lib/lab/certs/` | root `0600`, rendered from Vault by `lab platform`; never in the repo |

**Everything else lives only in Vault** (the start-up credentials above are rendered
copies of Vault entries, refreshed by `lab platform`): CloudStack admin and `iac` API keys, MinIO root
and per-bucket users, Gitea admin and runner tokens, the Postgres `app` password,
and AD passwords **[ext]**.

**Trust bootstrap order (the chicken-and-egg, broken explicitly):**

1. Vault starts with a **self-signed bootstrap certificate**, valid for one day.
2. `init` → unseal → enable PKI → generate the **single self-signed CA**
   `lab.test CA` (10 years; key never leaves Vault).
3. Vault issues its **own** listener certificate from that CA and reloads with
   `SIGHUP`. The bootstrap certificate is gone.
4. The CA is installed into the host trust store. It is baked into the golden image,
   so every VM trusts it from first boot.
5. Every other service certificate comes from Vault: host services via `lab maintain`
   (30-day TTL, renewed under 10 days by the daily `lab maintain` timer), cluster workloads via
   cert-manager.

**Why a single CA tier:** a two-tier PKI exists so the root can be kept
**offline**. Both tiers inside one Vault would have the shape without that
property. The one sub-CA in this lab belongs to istiod (Phase 8.3), because Istio
must hold a signing key of its own.

---

## 7. Repository layout

```
bootstrap.sh                 shim: ensure Python ≥ 3.12, exec python3 -B -m lab "$@"
pyproject.toml               ruff + mypy + pytest config (no packaging)
config/lab.toml              environment values (§5), non-secret
src/lab/
  __main__.py                argparse command map (§8)
  versions.py                every pin: CloudStack, Terraform provider, k3s, Istio,
                             cert-manager, Gateway API, images (by digest), Python deps
  lib/                       log, tracker, system (run/capture/require_root), config,
                             netplan, cloudstack (cmk), terraform, ansible, packer,
                             kube, vault, minio, docker — thin wrappers only
  preflight.py toolchain.py platform.py provision.py image.py setup.py base.py tunnel.py
  directory.py cluster.py mesh.py app.py observe.py backup.py verify.py demo.py
  status.py teardown.py revert.py maintain.py
  vendor/cloudstack-install.sh   the vendored upstream installer (third-party shell)
platform/                    compose project + config: coredns/, vault/, minio/, gitea/,
                             squid/ (allowlist.txt), observability/ [ext]
packer/                      qemu template, autoinstall seed, hardening, scan
terraform/                   provider + backend, vpc, tiers, acls, compute, ingress, outputs
policy/                      Conftest/OPA rules over the plan JSON
ansible/                     roles: base, wireguard, k3s, samba_dc [ext], ad_member [ext]
k8s/                         raw manifests: issuers, mesh, db, app, gateway, policies
app/                         api/ and frontend/ (Flask), each with Dockerfile and
                             requirements.txt (hash-pinned)
tests/                       pytest for src/lab; verify/demo helpers
.gitea/workflows/            pr.yml (gates on every PR), deliver.yml (Phases 4–11 on
                             main), schedules.yml (nightly backup and verify, weekly
                             golden-image rebuild)
docs/                        adr/, runbook.md, capacity.md, walkthrough.md
state/                       local run state (gitignored): bootstrap log, tracker. Pipeline
                             jobs keep **no** local state between jobs (§9 intro)
```

---

## 8. Commands and build order

Every command is `python3 -m lab <command>`, whether a person runs it through
`bootstrap.sh` or the runner runs it as a pipeline job. The tables are in **build
order**.

**Bootstrap: local, through `bootstrap.sh`** (CI cannot exist before these)

| # | Command | Phase | Core | Needs |
|---|---|---|---|---|
| 1 | `preflight` | 1 | ✓ | — |
| 2 | `platform` | 2, 3 | ✓ | preflight. Runs Phase 2 (control plane, runner), then Phase 3 (CloudStack), then the 3.5 hand-off |

**Delivery pipeline: `deliver.yml` jobs on the runner** (one job per phase)

| # | Job | Phase | Core | Needs |
|---|---|---|---|---|
| 3 | `golden-image` | 4 | ✓ | platform. Skipped when the input hash is already published |
| 4 | `setup` | 5 | ✓ | golden-image; runs **plan → policy → apply** |
| 5 | `base` | 6.1 | ✓ | setup |
| 6 | `tunnel` | 6.2 | ✓ | base |
| 7 | `directory` | 7 | [ext] | base |
| 8 | `cluster` | 8.1–8.2 | ✓ | base |
| 9 | `mesh` | 8.3 | ✓ | cluster |
| 10 | `app` | 8.4–8.7 | ✓ | mesh; builds, scans and pushes the container images, then deploys |
| 11 | `observe` | 11 | [ext] | app (and `tunnel` for the WireGuard exporter) |
| 12 | `verify` | 12 | ✓ | everything built; non-zero on any failure |

**Other commands**

| Command | Where | Runs |
|---|---|---|
| `up [--core]` | local | `preflight` → `platform` → dispatches `deliver.yml` and follows it. `--core` skips [ext] jobs. Each step resumes at the first phase whose `check()` fails. |
| `backup` / `restore-drill` | pipeline (`schedules.yml` nightly / dispatch) | Phase 9 (`restore-drill` takes a fresh backup first) |
| `lint` | pipeline (`pr.yml`) and local | ruff, mypy, pytest, shellcheck (`bootstrap.sh`), yamllint, ansible-lint, tflint, `trivy config`, kubeconform |
| `demo` | local | the examiner walkthrough (§13): proofs with human-readable output, re-runnable |
| `status` | local and pipeline | read-only inventory: what exists, what `check()` says |
| `maintain` | local, daily root systemd timer | renews host service certificates and the runner's `lab-pipeline` secret_id |
| `unseal` | local | after a host reboot, before the pipeline can read secrets |
| `down` | local | §14 order. Ends with a reboot (it removes the runner, so it cannot run in CI) |
| `revert-check` | local | after the reboot: asserts the host baseline (V1–V5) |

---

## 9. Phases and steps

Each step fits one focused session and ends with an **Exit** you can run. Phases
0–3 run locally through `bootstrap.sh`. **From Phase 4 on, each phase is a job in
`deliver.yml`, and its Exit is checked on the pipeline run.** Jobs share nothing on
disk: Terraform state is in MinIO, the inventory comes from it, the kubeconfig and
every secret come from Vault, and "is this phase done?" is answered by `check()`. While developing a
phase, run it by hand with `--break-glass`, then prove it from the pipeline.

### Phase 0 — Scaffolding

- **0.1 Shim and package.** `bootstrap.sh`; `src/lab/__init__.py`; `lib/log.py`
  (`[+]/[!]/[x]` to the console, timestamped `state/bootstrap.log`); `lib/tracker.py`
  (atomic JSON writes via temp file + `os.replace`); `.gitignore` (`/state/`,
  `__pycache__/`, `.mypy_cache/`, `.ruff_cache/`, `*.tfstate*`, `.terraform/`,
  `/builds/`).
  Exit: `shellcheck bootstrap.sh` clean; `PYTHONPATH=src python3 -c 'import lab.lib.log'`.
- **0.2 Command map, config, helpers.** `__main__.py` with every §8 command as a
  logged stub; the phase interface (`up/down/check`); `lib/system.py`; `lib/config.py`
  (load and validate `config/lab.toml`); `versions.py`; `pyproject.toml`.
  Exit: `./bootstrap.sh --help` lists every command; `sudo ./bootstrap.sh up` logs each
  stub; `./bootstrap.sh lint` clean. **Lint stays green from here on.**

### Phase 1 — Host preflight and reversibility

- **1.1 Baseline and netplan backup.** Record the revert baseline in
  `/var/backups/lab/baseline.json` (package list, `/etc/netplan` hashes, bridges,
  listening ports, apt sources, the `/etc/resolv.conf` link, enabled systemd units,
  nftables ruleset, trust-store contents). One-time copy of `/etc/netplan` to
  `/var/backups/lab/netplan.orig/`, outside the repo and outside `state/`.
  Exit: both exist; a re-run changes neither.
- **1.2 Preflight.** Ubuntu 24.04; `/dev/kvm`; CPU and disk against §5; `MemTotal`
  ≥ 30 GiB (a 32 GB host reports about 31 GiB) with the §5 peak + 4 GB reserve fitting (warn above 32 GB: the budget is the
  ceiling, not the hardware); strict
  `apt-get update` (fail naming any broken source); config values valid and
  non-overlapping; **refuse** leftovers (existing `cloud` DB, `cloudbr0`,
  `cloudstack-*` packages, lab containers) with a message naming each one.
  Exit: passes on a fresh host; deliberately fails on a host with a planted
  `cloudbr0`.

- **1.3 Toolchain.** Pinned CLIs into `/opt/lab/bin`, each verified against a
  SHA-256 in `versions.py`: terraform, packer, ansible (venv), conftest, trivy,
  syft, cmk, kubectl, istioctl, vault, mc, tflint, kubeconform.
  Exit: `lab status` prints every tool and its version; a corrupted download is
  rejected.

### Phase 2 — Control plane

- **2.1 Host-only bridge, Docker and the compose project.** First the host-only
  bridge `cloudbr1` with `10.250.0.1/24` (a lab netplan file, no physical port,
  `ignore-carrier: true`: a bridge with no ports has no carrier, and networkd would
  otherwise not configure the address until a VM attaches),
  because every control-plane name resolves to that address. Then Docker Engine
  (pinned), address pool `172.30.0.0/16`, `daemon.json` with `"dns": ["10.250.0.1"]`
  (Docker drops loopback resolvers, so containers would otherwise miss `lab.test`).
  One compose project in `platform/`, each service with a health check, each started
  by its own step below.
  Host firewall: the lab's own nftables table `inet lab`, so Docker's and libvirt's
  iptables-nft rules are never edited:
  - input chain, default drop: `iif lo` and `fib saddr type local` accepted first (the
    host talking to itself: resolved → CoreDNS, KVM agent → 8250, NFS, MySQL), then
    `established,related`, then each §5 port from its listed sources. Rules match
    addresses, never interface names, because 3.1 moves `HOST_IP` onto `cloudbr0`.
  - forward chain at priority `filter - 1`, drop-only: published container ports are
    DNAT'd past input, so they are matched here by `ct status dnat` and
    `ct original proto-dst`, and dropped unless the source is listed for that port.
    Containers' own outbound traffic (Vault → k3s API, Squid → internet, Prometheus
    scrapes) is never dropped.
  Exit: `cloudbr1` is up with `10.250.0.1`; Docker runs; from a network namespace with
  a foreign source address a test container's published port is refused; from
  `VMNET_CIDR` and from the Docker pool it answers.
- **2.2 CoreDNS and NTP.** Forward and reverse zones from §5; upstream forwarding.
  systemd-resolved: `DNSStubListener=no` (its 127.0.0.53:53 would block CoreDNS
  binding port 53), `DNS=127.0.0.1`, and `/etc/resolv.conf` re-linked to
  `/run/systemd/resolve/resolv.conf` (the default stub file would point at nothing).
  chrony replaces systemd-timesyncd and serves time to `VMNET_CIDR`
  (`allow 10.250.0.0/24`). The original resolv.conf link and timesyncd state are in
  the baseline.
  Exit: `dig vault.lab.test` and a PTR lookup answer; external names resolve from the
  host; `chronyc tracking` is synchronised.
- **2.3 Vault: server, init, unseal.** Integrated **Raft** storage (snapshots in
  Phase 9); TLS listener on the bootstrap certificate (regenerated if it expired
  before 2.4 completed); audit device to a file;
  `operator init` (1 share for the lab; production uses 5/3 or KMS auto-unseal) to
  `/var/lib/lab/vault-init.json`; unseal. After a host reboot, `bootstrap.sh unseal`
  (local, root) does it again; pipeline jobs only detect a sealed Vault and stop.
  Exit: `vault status` unsealed; restart the container, run `lab platform`, and it is
  unsealed with data intact.
- **2.4 Vault PKI and trust.** Enable `pki/` and tune its `max_lease_ttl` to 10 years
  **before** generating the CA (the default 32 days would cap the CA and everything
  under it); `lab.test CA`; roles `host-svc` (host
  service names, 30 days) and `k3s-svc` (`svc.cluster.local` + the app hostname, 7
  days); Vault re-issues its own certificate and reloads; CA into the host trust
  store; `lab maintain` + daily systemd timer.
  Exit: `curl https://vault.lab.test:8200/v1/sys/health` succeeds **without** `-k`;
  `openssl s_client` shows the issuer is `lab.test CA`.
- **2.5 Vault identities and KV.** KV v2 at `kv/`; Transit at `transit/`; policies
  `lab-bootstrap`, `lab-pipeline`, `iac`; AppRole `lab-bootstrap` written to
  `/var/lib/lab/approle.json`; seed CloudStack admin and SSH keypair paths. **Revoke
  the root token.**
  `lab-bootstrap` is the operator's automation identity, so it is broad by necessity.
  It still enumerates paths instead of using `*`: the lab's KV paths;
  `transit/keys/*` and `transit/encrypt|decrypt|rewrap/*`; `pki/sign/*`,
  `pki/root/sign-intermediate`, `pki/revoke`, `sys/mounts/pki/tune`; `sys/auth/k3s`
  (with `sudo`) and `auth/k3s/*`; `auth/approle/role/*`; the named policies under
  `sys/policies/acl/*`; `sys/storage/raft/snapshot`.
  `lab-pipeline` is narrower, so the pipeline can configure what it deploys but
  cannot grant itself more:
  - policies only by name: `sys/policies/acl/api` and `sys/policies/acl/cert-manager`
  - Kubernetes auth only at `sys/auth/k3s` (with `sudo`) and roles `auth/k3s/role/api`
    and `auth/k3s/role/cert-manager`, with `allowed_parameters` so a role's
    `token_policies` can only be its own policy
  - `transit/keys/customers` and `transit/keys/verify-*`, and the Transit
    encrypt/decrypt/rewrap paths for them
  - `pki/sign/*`, `pki/root/sign-intermediate`, `pki/revoke`
  - the lab's KV paths
  - `sys/storage/raft/snapshot`
  - never `auth/approle/*`, `sys/mounts/*`, or any other policy name
  Exit: `lab` reads `kv/lab/ssh` via AppRole; the root token is rejected.
- **2.6 MinIO.** TLS from Vault; buckets `images`, `tfstate` and `backups`; one user and
  policy per bucket, credentials in Vault. `images` allows anonymous **read**: images
  hold no secrets (4.1 enforces that), and CloudStack fetches templates by URL.
  Exit: `mc` round-trips an object in each bucket with its own user, and is denied on
  the other bucket.
- **2.7 Gitea and registry.** TLS from Vault; admin in Vault; public org `lab` for
  the container registry; repository `lab/lab`, the origin the pipeline builds from.
  Its `main` branch is protected in 3.5, after the one-time seed.
  Exit: `docker push` then `docker pull` of `gitea.lab.test:3000/lab/hello:test` from the
  host succeed with no insecure-registry setting.
- **2.8 Squid egress proxy.** `platform/squid/allowlist.txt` (Ubuntu archive and
  security mirrors, the container registries k3s/Istio/cert-manager/Postgres pull
  from, GitHub release downloads); deny everything else; access log to a file.
  Exit: through the proxy, an allow-listed URL returns 200 and `example.com` returns
  403, which shows in the log; `docker compose ps` shows every Phase 2 service
  healthy.
- **2.9 Runner.** One `act_runner`, registered to repository `lab/lab` only, as a
  systemd service under a dedicated non-root user `lab-runner` in the `docker` and
  `kvm` groups. It has two labels:
  - `host`: jobs run directly on the host. Only `deliver.yml` and `schedules.yml`
    use it, and only on `main`.
  - `pr`: jobs run in a throwaway container with no host mounts. Only `pr.yml` uses
    it, so code from a pull request never sees `/var/lib/lab` or the pipeline
    identity.

  Workflows use only `run:` steps that call `git` and `python3 -m lab` (no
  JavaScript actions), so the host needs no Node.js. The `pr` label's job image,
  `lab/ci-job`, carries the pinned toolchain from `versions.py` and `lab.test CA`;
  bootstrap builds it with the host's Docker and pushes it to the registry.
  `lab-runner` owns `/var/lib/lab/backups/` and `/var/lib/lab/observe/`. That user can build
  container images with the host's Docker (BuildKit is built in) and golden images
  with Packer on `/dev/kvm`, and reaches everything else over the network with the
  `lab-pipeline` AppRole. Capacity **one job at a time** across both labels, so build
  memory never stacks.
  `lab-runner` owns the CoreDNS zone file that `setup` updates.
  Membership in `docker` is root-equivalent. That is accepted for an internal,
  single-operator lab, and §15 says what an enterprise would do instead.
  Exit: the runner shows Online in Gitea; a test workflow on `main` runs
  `python3 -m lab status` as `lab-runner` and passes; a pull-request job cannot read
  `/var/lib/lab/runner/`; a pull request cannot trigger `deliver.yml`.

### Phase 3 — CloudStack (part of the platform, run by bootstrap)

- **3.1 Install.** Vendored installer, all-in-one (management, MySQL,
  NFS, KVM agent). Advanced zone with the §5 ranges: physical network 1 on `cloudbr0`
  (management, public, guest; tag `vpc`), physical network 2 on `cloudbr1` from 2.1
  (guest; tag `vmnet`, for the mgmt shared network). With guest traffic on two
  physical networks, CloudStack places networks by tag, so every network offering in
  3.3 carries the matching tag. `cloudbr0` takes `HOST_IP`. Bridge netfilter **off**, persisted in
  a sysctl.d file applied after Docker starts (Docker re-enables `br_netfilter`, and
  its FORWARD-drop policy would then drop bridged VM traffic). Agent
  `TimeoutStartSec` above the readiness wait. Readiness means `/client/api` returns
  200, not an open port.
  Exit: `cmk list zones` shows an Enabled Advanced zone; SSVM and CPVM Running; host
  services from Phase 2 still reachable on `HOST_IP`; after a reboot,
  `sysctl net.bridge.bridge-nf-call-iptables` is still 0.
- **3.2 `cmk` and the scoped identity.** `cmk` (pinned); account `iac` in domain
  `lab` with a role allowing only the APIs Terraform and `lab` call, by their real
  names:
  - VPC and networks: `createVPC`, `deleteVPC`, `createNetwork`, `deleteNetwork`,
    `createNetworkACLList`, `createNetworkACL`, `deleteNetworkACL`,
    `replaceNetworkACLList`
  - VMs: `deployVirtualMachine`, `destroyVirtualMachine` (with expunge),
    `start`/`stopVirtualMachine`, `addNicToVirtualMachine`,
    `removeNicFromVirtualMachine`, `registerSSHKeyPair`, `deleteSSHKeyPair`
  - ingress: `associateIpAddress`, `disassociateIpAddress`, `createPortForwardingRule`,
    `deletePortForwardingRule`
  - `createTags`, `deleteTags`, `queryAsyncJobResult`, and the `list*` calls for each
    of those plus zones, offerings, templates and accounts

  Global setting `allow.user.expunge.recover.vm = true`, and Terraform destroys with
  `expunge = true`, so a replaced VM's fixed `.10` address is free immediately.
  A second account, `publisher`, has a role with only `registerTemplate`,
  `deleteTemplate`, `listTemplates` and `updateTemplatePermissions`. API keys for both
  are in Vault.
  Exit: as `iac`, a scratch Terraform config creates and destroys a VPC, a tier, a VM
  with a second NIC and a port-forward, then re-creates the VM at the same address;
  `cmk list hosts` (admin-only) is denied.
- **3.3 Offerings and the mgmt network.** Compute offerings matching §5 sizes; a
  redundant VPC offering whose UserData provider is **ConfigDrive** (a tier offering
  with ConfigDrive is only accepted under such a VPC offering); the VPC tier offering
  with ConfigDrive; a shared offering with DHCP for the mgmt network. The mgmt shared
  network is created with `cmk` on physical network 2 (`vlan=untagged`, `10.250.0.0/24`,
  gateway `10.250.0.1`, range `.100–.199`), because the Terraform provider cannot
  create an untagged shared network. It is scoped to domain `lab` so `iac` can attach
  to it. Jobs look it up by name, like every other CloudStack object.
  Exit: `cmk list` shows each offering and the mgmt network; **spike:** a test VM in a
  test VPC tier accepts a second NIC on the mgmt network (`addNicToVirtualMachine`),
  gets a `10.250.0.x` address, and is deleted; a re-run creates nothing.
- **3.4 Template trust.** Install `lab.test CA` on the KVM host for direct-download
  templates (`uploadTemplateDirectDownloadCertificate`).
  Exit: the certificate is listed for the host.
- **3.5 Hand-off to the pipeline.** `lab platform` seeds `lab/lab` **once**, by
  pushing the repository while it is still empty, then protects `main`: changes only
  by a merged pull request whose `pr.yml` passed. After that, bootstrap never pushes
  again; it dispatches `deliver.yml` (with `core: true` for `up --core`) through
  the Gitea API; `bootstrap.sh up` then follows the run and exits with its result.
  From here, `deliver.yml` runs one job per phase, in order:
  `golden-image` → `setup` → `base` → `tunnel` → `cluster` → `mesh` → `app` →
  `verify`. The [ext] jobs hang off the chain instead of sitting in it: `directory`
  needs only `base`, `observe` needs `app`, and `verify` runs with
  `if: !cancelled()`, so skipping or failing an [ext] job never blocks the core. Every
  job converges on every run (§2), so re-running the pipeline is safe.
  Exit: the first `deliver` run is triggered and visible in Gitea; `up` streams its
  job status; a direct `git push` to `main` is rejected.

### Phase 4 — Golden image

- **4.1 Build.** Packer `qemu`: Ubuntu 24.04 autoinstall → qcow2 with cloud-init,
  qemu-guest-agent, openssh-server, python3, chrony, nftables, `lab.test CA` in the
  trust store; kernel argument `net.ifnames=0` so NICs are `eth0`/`eth1` in attach
  order (netplan, nftables and Samba all name them); a netplan file that brings `eth1`
  up with DHCP, `use-routes: false`, `use-dns: false`, so it configures on hotplug,
  and sets `use-dns: false` on `eth0` too, so the VPC router never becomes a resolver
  (k3s's CoreDNS would otherwise forward `lab.test` queries to it); [ext] directory packages (sssd, realmd, adcli, krb5-user,
  samba-common-bin). Never bake identity: the build **fails** if a keytab, SSSD
  config or SSH host keys exist, or `/etc/machine-id` is not empty.
  Exit: `packer validate`; a booted test VM gets userdata from a ConfigDrive and shows
  `eth0`.
- **4.2 Harden, scan, SBOM.** CIS-style hardening role; Trivy fails the build on
  HIGH/CRITICAL; Syft SBOM saved next to the image.
  Exit: the scan gate passes; the SBOM exists.
- **4.3 Publish and register.** Version = hash of the inputs plus a **patch epoch**
  (the ISO week for scheduled builds, so the weekly build does pick up OS updates);
  upload to `images/<version>/` with its SBOM and SHA-256; skip build and upload when
  that version already exists. As `publisher`, register it as a **direct-download**
  template over HTTPS with the checksum and grant `iac` launch permission
  (`updateTemplatePermissions accounts=iac`); wait for it to be ready.
  **Publishing never changes running VMs:** the version VMs use is pinned in
  `config/lab.toml` (`golden_image`), and moving it is a reviewed pull request.
  Exit: `cmk list templates` shows the version ready; an unchanged re-run builds
  nothing.

### Phase 5 — Terraform: VPC, tiers, VMs

- **5.1 Provider and remote state.** Pinned `cloudstack/cloudstack` provider, lock
  file committed; S3 backend on MinIO (`use_path_style`, `use_lockfile`); `iac` keys
  and MinIO credentials injected from Vault as environment variables at run time;
  data lookups for zone, offerings, template, mgmt network id.
  Exit: `terraform init` + `validate`; the state object appears in `tfstate`.
- **5.2 Network.** VPC `10.0.0.0/16` on the redundant offering; tiers from §5; one
  ACL list per tier, **default deny in both directions**. Allow rules:
  - nothing between tier-a, tier-b and tier-app
  - tier-app ingress TCP 443 from `LAN_CIDR` (the only public-facing rule)
  - [ext] tier-a, tier-b and tier-app → tier-svc on the AD ports only, as matching
    egress rules on the member tiers and ingress rules on tier-svc
  - **no internet egress for any tier**

  `parallelism=1` for ACL rules.
  Exit: plan shows the VPC, tiers and ACLs; nothing applied yet.
- **5.3 Policy gate.** Conftest rules over `terraform plan -json`:
  - no ingress from `0.0.0.0/0`
  - the only public port-forward is tier-app 443
  - every tier ends in deny-all, both directions
  - no inter-tier allow except the AD ports
  - every VM's default NIC is on a VPC tier, and it has exactly one mgmt NIC
  - the ingress public IP is never replaced or destroyed outside `down` (its DNS
    record depends on it)

  The plan JSON carries no credentials, so `lab setup` separately checks, before
  planning, that the API key in use resolves to account `iac` (`listAccounts`).

  `lab setup` runs **plan → policy → apply**, and apply is unreachable if the policy
  fails.
  Exit: the real plan passes; a fixture plan opening `0.0.0.0/0:22` is rejected and
  nothing is applied.
- **5.4 Compute and ingress.** Lab SSH public key from Vault. Each VM's **default NIC
  (eth0) is its tier**: default route, ConfigDrive userdata. The **mgmt NIC (eth1)** is
  attached with `cloudstack_nic`; the image's netplan brings eth1 up with DHCP while
  ignoring its routes and DNS. A VPC public IP with port-forward 443 → `app-1:443`.
  Ansible reads the inventory straight from the Terraform state through the
  `cloud.terraform` inventory plugin with absolute paths, so every job sees the same
  hosts without passing files between jobs. `lab setup` writes
  `app.lab.test` (public IP) and `k3s.lab.test` (app-1's mgmt address) into CoreDNS.
  Exit: apply; all VMs Running and reachable over SSH from the host on their mgmt NIC; **vm-a
  cannot ping vm-b's tier address** (N1 holds before the VPN exists).

### Phase 6 — Base configuration and the VPN

- **6.1 `base` role (all VMs).**
  - DNS and NTP from `10.250.0.1`.
  - Proxy environment for apt, the shell and containerd: `http_proxy` **and**
    `https_proxy` = `http://proxy.lab.test:3128`, with `no_proxy` covering `lab.test`,
    `VMNET_CIDR`, `LAN_CIDR`, the VPC, the pod and service CIDRs, `.svc` and
    `.cluster.local`.
  - nftables on the mgmt NIC (eth1), default drop both ways:
    - in from `10.250.0.1`: SSH; on app-1 also the k3s API (6443, for Vault's token
      reviews and `lab`); **[ext]** node exporter (9100) and WireGuard exporter (9586)
    - in from the VPN peer's mgmt address: UDP 51820
    - out to `10.250.0.1` only, plus UDP 51820 to the VPN peer, plus DHCP (UDP 67/68)
      to the mgmt network's router and broadcast, so eth1's lease renews
    - forward (app-1 only, pod traffic masqueraded out eth1): allowed only to
      `10.250.0.1` on 53, 123, 8200, 3000 and 3100; the lab's rules live in their own
      table, `inet lab`, at priority `filter - 1`, so k3s's and flannel's iptables
      rules are untouched
    - no default route via eth1
  - `base` and `ad_member` / `samba_dc` **[ext]** own separate drop-in files. On `dc`
    and on hosts in the `ad_members` group, `base` skips its chrony source and its
    resolver settings (the DC resolves through itself; members route `ad.lab.test`
    to it), so re-running `base` cannot undo a join.
  - `unattended-upgrades` disabled: VMs are immutable; patching = a new image (Phase 4)
    and replacing the VM.

  Exit: from vm-a, `apt-get update` works through the proxy; a direct `curl` to the
  internet fails; `curl` to another VM's mgmt NIC fails; `curl` to
  `https://vault.lab.test:8200` succeeds (N3, N4).
- **6.2 `wireguard` role.** Keys generated on each VM (private never leaves; public
  key to Vault). `wg0` with `AllowedIPs` = the peer **tier subnet** + its overlay /32.
  Endpoint = the peer's **mgmt** address, so the underlay is never inside
  `AllowedIPs`. `ip_forward=1`. `PersistentKeepalive=25`. `wg-quick@wg0` enabled,
  restart on failure; `wg-quick` installs the routes for `AllowedIPs`, so the peer
  tier subnet goes via `wg0`.
  Exit: `wg show` has a recent handshake on both sides; vm-a reaches `10.0.2.10`
  over `wg0`; with `wg0` down, it does not (N2).

### Phase 7 — Directory login **[ext]**

Goal: a user who exists only in AD logs in to a tier VM with their AD password,
gets `sudo` only through an AD group, and loses access the moment they are disabled.

- **7.1 DC VM.** `features.directory = true` in `config/lab.toml` feeds Terraform's
  `enable_directory`, so every `setup` run plans the same estate;
  `up --core` skips the directory *configuration* but never changes Terraform inputs,
  so it cannot destroy a DC that exists. Terraform then adds tier-svc and `dc` (the
  AD-port rules from step 5.2 come with it); `lab directory` then applies the `base` role to
  `dc`. ACL allows only TCP 53, 88, 389, 445, 464, 636, 3268, 3269 and UDP 53, 88,
  123, 389, 464 from the member tiers.
  Exit: `dc` Running; from vm-a, port 22 on `10.0.10.10` times out (the AD ports are
  tested in 7.2, once something listens on them).
- **7.2 Provision the domain** (`samba_dc` role).
  - Install `samba-ad-dc` and `krb5-user` through the proxy.
  - Realm `AD.LAB.TEST` (a subdomain: the DC must own its zone, and `lab.test`
    belongs to CoreDNS; members query the DC directly for it, §5).
  - Internal DNS, forwarding non-AD names to `10.250.0.1`; mask `smbd`, `nmbd`,
    `winbind`; the DC resolves through itself.
  - Bind Samba to the **tier NIC only** (`interfaces = eth0 lo`, `bind interfaces
    only = yes`), so it registers only `10.0.10.10` in DNS, never the mgmt address.
  - Reverse zone; `OU=LabServers`.
  - A delegated `joiner` account limited to creating computers in that OU.
  - Groups `lab-users` and `lab-admins`; users `alice` (admins), `bob` (users),
    `carol` (neither).
  - All passwords generated into Vault.

  Exit: from vm-a, `host -t SRV _ldap._tcp.ad.lab.test 10.0.10.10` answers with
  `10.0.10.10`; ports 88 and 389 connect; `kinit administrator` works on dc.
- **7.3 Join members** (`ad_member` role).
  - FQDN hostnames; chrony from dc; systemd-resolved sends `~ad.lab.test` and the
    tier-svc reverse zone to `10.0.10.10`.
  - `realm join --user=joiner --computer-ou=OU=LabServers`, with the password on
    stdin from Vault.
  - SSSD: short names, `/home/%u`, `cache_credentials=False` on app-1.
  - `realm deny --all`, then `realm permit -g lab-users lab-admins`.
  - mkhomedir; `%lab-admins` in sudoers; sshd password auth for directory users.

  Exit: `realm list` shows the domain; `id alice` resolves with no local account.
- **7.4 Checks** (D1–D4) and **teardown slice:** `realm leave` on every member before
  the VMs are destroyed; delete the `kv/ad/*` paths.

### Phase 8 — Application platform: database + encryption service

- **8.1 k3s on app-1** (`k3s` role).
  - Pinned version, fetched through the proxy.
  - Flags:
    - `--disable=traefik`: the Istio Gateway is the only ingress
    - `--secrets-encryption`
    - `--node-ip=10.0.3.10`
    - `--tls-san` = app-1's mgmt IP and `k3s.lab.test`
    - `--write-kubeconfig-mode=600`
  - Default flannel CNI.
  - containerd proxy and `no_proxy` from 6.1; `registries.yaml` trusts
    `gitea.lab.test`.
  - Kubeconfig, pointed at `k3s.lab.test`, stored in Vault `kv/lab/k3s`.

  Exit: from the host, `lab status` shows the node Ready; `k3s secrets-encrypt status`
  shows enabled (S2); a pod resolves `vault.lab.test` and gets 200 from
  `/v1/sys/health` using the CA bundle.
- **8.2 Vault as the cluster's CA.**
  - Host Vault:
    - Kubernetes auth at `auth/k3s`, pointed at `https://<app-1 mgmt IP>:6443` with
      the k3s CA.
    - Reviewer: ServiceAccount `vault-auth` with `system:auth-delegator` and a
      long-lived token Secret.
    - Policy `cert-manager` = `pki/sign/k3s-svc` only, attached through
      `auth/k3s/role/cert-manager`, bound to the issuer's ServiceAccount and
      namespace, with the audience cert-manager's token request uses.
  - In k3s: cert-manager (pinned static manifest) and a `ClusterIssuer vault`
    (server `https://vault.lab.test:8200`, `caBundle`, Kubernetes auth via a
    ServiceAccount token request, with RBAC letting cert-manager request tokens for
    that ServiceAccount only).

  Exit: a throwaway `Certificate` reaches Ready and verifies against `lab.test CA`
  with `openssl verify`.
- **8.3 Istio ambient with Vault's CA.**
  1. `lab mesh` generates the istiod CA key and CSR in memory.
  2. Vault signs it via `pki/root/sign-intermediate` (CA:TRUE, path length 0, 1-year
     TTL).
  3. `lab mesh` writes Secret `istio-system/cacerts` (`ca-cert.pem`, `ca-key.pem`,
     `root-cert.pem`, `cert-chain.pem`) **before** istiod starts.
  4. Gateway API CRDs (pinned); `istioctl install --set profile=ambient` (pinned,
     k3s values).
  5. Mesh-wide `PeerAuthentication` STRICT.

  `lab mesh --rotate-ca` repeats the signing and restarts the istiod, ztunnel and
  workload rollouts in order.
  Exit: a smoke namespace labelled `istio.io/dataplane-mode=ambient` shows `HBONE` for
  its pods in `istioctl ztunnel-config workloads`; their certificate chains to
  `lab.test CA`; a client in an unlabelled namespace is refused; `tcpdump` on the
  server pod's veth shows only TCP 15008 while the client sends plaintext (this
  settles T1's capture point on a single node).
- **8.4 Database.**
  - Namespace `db` (ambient), ServiceAccount `postgres`.
  - PostgreSQL 16 (pinned digest) StatefulSet with a `local-path` PVC; superuser
    password generated into a Secret.
  - Schema `customers(id serial primary key, name text not null, card_number text not
    null)`; role `app` with `SELECT, INSERT` on the table and `USAGE` on its sequence,
    nothing else.
  - The `app` password generated once and written to Vault `kv/app/db`, never printed.
  - `AuthorizationPolicy` on postgres: allow only `cluster.local/ns/app/sa/api`.

  Exit: from a pod running as `sa/api` in `ns app`, `psql` as `app` connects; the same
  pod with another ServiceAccount is refused.
- **8.5 Vault for the api.**
  - Transit key `customers` (`aes256-gcm96`).
  - Policy `api`: exactly `transit/encrypt/customers`, `transit/decrypt/customers`
    and `kv/data/app/db`.
  - `auth/k3s/role/api`, bound to `sa/api` in `ns app`, token TTL 1h.
  - ConfigMap `vault-ca` in `ns app` (public CA).

  Exit: from a pod running as `sa/api`, logging in through `auth/k3s/role/api` gives
  a token that round-trips an encrypt/decrypt, and is denied `kv/data/lab/ssh` and
  `transit/keys/customers/rotate`.
- **8.6 Application images.** `app/api` and `app/frontend`, each:
  - base image pinned by digest
  - `pip install --require-hashes` at **build** time
  - non-root user, read-only root filesystem compatible
  - Trivy gate (HIGH/CRITICAL fail)
  - SBOM
  - tagged with the git SHA
  - pushed to `gitea.lab.test:3000/lab/`

  Built by the `app` pipeline job on the runner with the host's Docker; pushed only if
  the scan gate passes.
  Exit: both images in the registry with their SBOMs; the scan gate passed.
- **8.7 Deploy the application.**
  - **api** (Flask, `sa/api`):
    - `/healthz`, `GET /customers`, `POST /customers`
    - logs in to Vault with its ServiceAccount token, and logs in again when the
      token nears its 1-hour expiry or a call returns 403
    - reads `kv/app/db` once at startup
    - encrypts `card_number` via Transit before inserting
    - decrypts on read and returns only `**** ` + the last 4 digits
    - one database connection per request, parameterized SQL
    - `VAULT_CACERT` is its only TLS setting
  - **frontend** (Flask, `sa/frontend`): HTML list and add form; knows only `API_URL`.
  - **Gateway**: an explicit cert-manager `Certificate` for `app.lab.test` from
    `ClusterIssuer vault` (no reliance on cert-manager's Gateway shim), a Gateway API
    `Gateway` (class `istio`, HTTPS 443) referencing its Secret, and an `HTTPRoute` to
    the frontend.
    k3s's ServiceLB exposes the gateway's LoadBalancer Service on `app-1:443`, which
    is where the VPC port-forward lands.
  - **ALLOW policies**: frontend ← the gateway's ServiceAccount; api ← `sa/frontend`.
  - Probes; resource requests and limits; no secret values in any Deployment.

  Exit: from the host, `curl https://app.lab.test/` (resolving to the public IP)
  succeeds without `-k`. Adding a customer shows `**** 4242`, and `psql` in the
  postgres pod shows `vault:v1:…`.

### Phase 9 — Backup, restore, crypto-shredding

- **9.1 Backup.** `lab backup`:
  - `vault operator raft snapshot save`
  - `pg_dump` of `customers` (through `kubectl exec`)
  - both to `/var/lib/lab/backups/<timestamp>/` (survives `down`), mirrored to MinIO
    bucket `backups/`

  A Raft snapshot is encrypted by Vault's barrier and is useless without the unseal
  key. The unseal key is **not** in the backup; offline custody of it is an operator
  duty, stated in the runbook.
  Exit: both objects exist; sizes are non-zero; the Vault snapshot verifies.
- **9.2 Restore drill.** Take a fresh backup (so the dump matches the key's current
  `min_decryption_version`, whatever `demo` did to it), delete the `db` namespace and
  its PVC, redeploy (8.4 is
  idempotent: it reuses the `app` password already in `kv/app/db`), restore the dump;
  the api reads the old rows and decrypts them (B1).
- **9.3 Crypto-shredding.** Restore the same dump into a scratch Postgres next to a
  **scratch Vault** without the `customers` key: every `card_number` is unreadable
  ciphertext, and names are still readable (B2).

  This is the point to make: the database backup is safe to lose; the Vault snapshot
  plus the unseal key are the crown jewels.
  Exit: B1 and B2 pass; the scratch resources are removed.

### Phase 10 — Pipeline gates and schedules

The runner (2.9) and the delivery pipeline (3.5) exist from bootstrap; this phase
hardens how changes get in and adds what runs on a timer.

- **10.1 `pr.yml`, on every pull request** (the `pr` label: a container with no host
  access; it gets only the PR-job secrets in §6): `lint` → unit tests →
  `terraform plan` → policy gate → `trivy config` on the Dockerfiles and manifests.
  Container images are built and scanned in `deliver`'s `app` job, after merge.
  The plan output and the scan summary are posted to the PR. `main` requires this to
  pass and a review before merge.
  Exit: a PR that opens `0.0.0.0/0` fails the gate and cannot merge (G1).
- **10.2 `deliver.yml`, on every merge to `main`** (and on dispatch): the job chain
  in 3.5. Jobs that change running services print what they changed. A failed job
  stops the chain.
  Exit: merging a change to the frontend's template rebuilds and redeploys only the
  `app` job's images, and `verify` passes at the end (G2).
- **10.3 `schedules.yml`:** nightly `backup` (Phase 9) and `verify`; weekly
  `golden-image` build with a new patch epoch (4.3). A new golden image reaches VMs
  only when a pull request moves `golden_image` in `config/lab.toml`. Then `setup`
  replaces vm-a and vm-b (the `tunnel` job republishes their new WireGuard keys).
  **app-1 and dc are never replaced by a template change** (`ignore_changes` on their
  template): app-1 holds the database, the k3s CA and the cluster's Vault auth, so
  replacing it is a runbook procedure: backup → replace → `deliver` → restore
  (Phase 9).
  Exit: the nightly runs appear in Gitea with their results; a backup lands in
  `/var/lib/lab/backups/` (G3).

### Phase 11 — Observability **[ext]**

- **11.1** `lab observe`: Prometheus, Grafana and Loki on the host, as a **separate**
  compose project whose config and `.env` files live in `lab-runner`-owned
  `/var/lib/lab/observe/` (not in the job's work directory). node_exporter and a WireGuard
  exporter on the VMs, scraped over the mgmt NIC. Alloy on app-1 ships ztunnel logs and pod
  logs; Alloy on the host ships the Vault audit log and the Squid access log.
  Exit: Grafana dashboards for tunnel health, mesh denials and Vault access (O1).
- **11.2** Alerts in Grafana alerting (it evaluates Prometheus *and* Loki queries,
  so no separate Alertmanager or Loki ruler): WireGuard handshake older than 3 minutes
  (Prometheus); any ztunnel deny and any Vault `transit/decrypt` by an identity other
  than `api` (Loki).
  Exit: `wg-quick down wg0` on vm-a fires the tunnel alert (O2); a denied
  frontend → postgres connection fires the mesh alert (O3).

### Phase 12 — Verification

- **12.1 `verify`.** Every check in §12 except B1–B2 (destructive; run by
  `restore-drill`), G1–G3 (proven by the pipeline's own history) and V1–V5 (true only
  after `down`; run by `revert-check`), each implemented once in `src/lab/verify.py` with a pass/fail line
  and the evidence. Non-zero exit on any failure. [ext] checks are skipped, and
  reported as skipped, under `--core`. E2/E3 run against a scratch Transit key that is
  deleted afterwards, so `verify` changes nothing.
  Exit: `verify` green twice in a row; `vault list transit/keys` is unchanged.

### Phase 13 — Teardown and revert

- **13.1 `down`** runs §14 in order. Each step tolerates "already gone". Teardown
  never reads state that an earlier teardown step deleted. Helpers return success on
  "not found".
  Exit: completes from any partially built state (tested by cancelling the `deliver`
  run in Gitea after `setup` and after `mesh`).
- **13.2 `revert-check`** (after the reboot) compares against
  `/var/backups/lab/baseline.json` (V1–V5) and writes a pass/fail report.
  Exit: green.

### Phase 14 — Documentation

- **14.1** `README.md`: what the lab is, prerequisites (§5), `up` / `demo` / `down` /
  `revert-check`, and sample `demo` output.
- **14.2** `docs/adr/`: one record per decision in §15, with the alternatives rejected.
- **14.3** `docs/runbook.md`: zone won't enable, template stuck, Vault sealed after a
  reboot, tunnel down, cert renewal failed, mesh CA rotation, restore from backup,
  netplan restore failed.
- **14.4** `docs/walkthrough.md`: §13, with real output pasted in.

  Exit: someone new runs `up → demo → down → revert-check` from the docs alone.

---

## 10. Rules learned the hard way (build them in)

1. **Preflight apt.** One broken apt source makes `apt-get update` exit non-zero and
   kills the vendored installer partway through. Fail first and name the source.
   Always reinstall signing keys; they rotate.
2. **Old CloudStack databases are poison.** An existing `cloud` DB with an older
   schema makes the management server loop on 503 forever. Preflight refuses it;
   teardown drops it and deletes the installer's tracker.
3. **Gate on health, with timeouts longer than the gates.** Readiness = HTTP 200 from
   the API, not an open port. Systemd start timeouts must exceed the wait budget.
   First boot of the management server takes minutes.
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
9. **A WireGuard Endpoint must never fall inside its own AllowedIPs.** Run the
   underlay on a network the tunnel does not route (here, the mgmt network).
10. **Long-running helpers on a VM run as transient systemd units** (`systemd-run`),
    never as processes left behind by an SSH session. Connection refused vs timeout
    tells "no listener" apart from "firewall dropped it".
11. **`no_proxy` is where proxied clusters break.** Pod, service and VPC CIDRs, `.svc`,
    `.cluster.local`, `lab.test`, `VMNET_CIDR` and `LAN_CIDR` must all bypass the
    proxy, or pods send cluster traffic to Squid. Set `https_proxy` as well as
    `http_proxy`: containerd and HTTPS apt sources use it.
12. **Check container entrypoints before overriding commands.** Some images set the
    entrypoint to the tool itself (`mc`), so `sh -c` needs `--entrypoint`.
13. **Docker owns part of the firewall.** Published ports are DNAT'd past the input
    chain (filter them in `DOCKER-USER`), and Docker re-enables `br_netfilter`, which
    silently drops bridged VM traffic unless bridge netfilter is switched off again
    after Docker starts.
14. **Keep VM management off the LAN.** A mgmt network on the LAN subnet gives VMs a
    second route to LAN clients (replies leave by the wrong NIC) and lets the LAN's
    DHCP server answer them. A host-only bridge removes both problems.

---

## 11. Risks

| Risk | Where | Mitigation |
|---|---|---|
| Advanced-zone bring-up is the most fragile step | 3.1 | health-based gates, resumable `up`, generous timeouts |
| `HOST_IP` moves to `cloudbr0` mid-build | 3.1 | services bind `0.0.0.0`; 3.1 Exit re-checks Phase 2 reachability |
| Direct-download templates over HTTPS with a private CA | 3.4, 4.3 | if the KVM host certificate upload fails, serve `images/` from a read-only static HTTP container on the host and rely on the template checksum for integrity |
| mgmt NIC added after boot (`cloudstack_nic`) | 4.1, 5.4 | the image's netplan matches eth1 so it configures on hotplug; 5.4 Exit fails fast if eth1 has no address |
| A shared-network NIC on a VM inside a VPC may be refused by CloudStack | 3.3 | proven by the 3.3 spike before Terraform depends on it. There is no cheap fallback (deploying with both networks hits the same validation): if the spike fails, stop and redesign management access before Phase 5 |
| Golden-image direct download may need the root admin | 4.3 | proven on the first registration; if `publisher` is refused, registration becomes a bootstrap-time (local, admin) step and the pipeline only builds and uploads |
| Same-node HBONE capture point for T1 | 8.3, T1 | settled in 8.3's smoke test before the application depends on it |
| Istio ambient on k3s (CNI paths) | 8.3 | k3s-specific install values; smoke namespace before any workload; fallback is sidecar mode |
| istiod `cacerts` key names | 8.3 | write all four Istio file names; Exit checks the workload chain, not just the Secret |
| Egress allow-list too tight | 2.8, 6.1, 8.x | denials are logged by Squid; grow the list from the log, never by opening the ACL |
| Host memory (32 GB ceiling) | all | §5 budget with a 4 GB reserve, measured per phase; `up` refuses a phase that would breach the reserve; §5 cut order if it overruns |
| Vault sealed after a host reboot | everything | pipeline jobs fail fast with "Vault sealed"; the operator runs `bootstrap.sh unseal` (the runner cannot read the unseal key, by design); runbook entry; production answer is KMS auto-unseal |
| Losing the unseal key or Vault snapshot | 9 | that is total loss of encrypted data, by design; the runbook makes offline custody of both an explicit operator duty |

---

## 12. Verification catalog

| ID | Check | How |
|---|---|---|
| **N1** | tiers are isolated | vm-a → `10.0.2.10` on its tier NIC with `wg0` down: no route/timeout |
| **N2** | the VPN routes subnets | vm-a → vm-b's **tier** address `10.0.2.10` (not its overlay address) succeeds; `ip route get` shows `dev wg0` |
| **N3** | no internet from tiers | direct `curl https://example.com` fails; through the proxy → 403 and logged |
| **N4** | mgmt NIC reaches only the host | VM → another VM's mgmt NIC fails; VM → `10.250.0.1:8200` succeeds |
| **N5** | Terraform runs least-privilege | `iac` key denied an admin-only API call |
| **E1** | field-level encryption | `psql` shows `vault:v1:…`; API returns `**** 4242` |
| **E2** | key rotation | rotate → new ciphertext carries the new version (`vault:v2:…` on first run); the older ciphertext still decrypts (`verify`: scratch key; `demo`: the real key) |
| **E3** | rewrap + retire | rewrap to the latest version; set `min_decryption_version` to it; a ciphertext saved before the rotation fails to decrypt (`verify`: scratch key; `demo`: rewraps every row first, so it re-runs at any key version) |
| **T1** | mTLS on the wire | `tcpdump` on app-1 during a request: api ↔ postgres only on TCP 15008, no SQL text |
| **T2** | workload identity | ztunnel log shows `spiffe://cluster.local/ns/app/sa/api` → `ns/db/sa/postgres` |
| **Z1** | identity authorization | from the frontend pod, TCP to `postgres.db:5432` is refused; ztunnel logs the deny |
| **Z2** | STRICT mTLS | a pod in an unlabelled namespace cannot reach `api.app:8000` |
| **P1** | edge PKI | the gateway certificate chains to `lab.test CA` |
| **P2** | mesh PKI | a workload certificate chains through the istiod CA to `lab.test CA` |
| **P3** | Vault speaks only TLS | `http://vault.lab.test:8200` fails; `https://` succeeds |
| **S1** | no secrets in manifests | the api Deployment has no secret env or mounts; the password is at `kv/app/db` |
| **S2** | Secrets encrypted at rest | `k3s secrets-encrypt status` = Enabled |
| **B1** | restore drill | the api reads and decrypts restored rows |
| **B2** | crypto-shredding | restored rows without the Transit key are unreadable |
| **D1–D4** [ext] | directory | alice logs in and can `sudo`; bob logs in, no `sudo`; carol refused; disabling alice blocks her next login |
| **G1–G3** | pipeline | a PR opening `0.0.0.0/0` fails and cannot merge; a merge rebuilds, redeploys and verifies; nightly backup and verify run on schedule |
| **O1–O3** [ext] | observability | dashboards populated; tunnel alert fires; mesh-deny alert fires |
| **V1–V5** | revert | the package list equals the baseline's (no CloudStack, Docker, libvirt, MySQL, NFS or chrony additions); `/etc/netplan` byte-identical; no lab bridges (`cloudbr0`, `cloudbr1`, `cloud0`), containers, nftables rules, resolved drop-ins or timers, and `/etc/resolv.conf` links where it did; listening ports, enabled units, apt sources and trust-store contents match the baseline; host online. `/var/lib/lab/` and `/var/backups/lab/` are expected and excluded |

---

## 13. Examiner walkthrough (`demo`, about 10 minutes)

1. **Show the shape** (1 min): `lab status`, the architecture diagram in §4, and the
   last `deliver` run in Gitea: every phase is a pipeline job (G2).
2. **VPC isolation and VPN** (2 min): N1 → N2 → bring `wg0` down → N1 again → up.
   Then N3: the tiers have no internet, and here is the proxy denial in the log.
3. **The application** (1 min): open `https://app.lab.test` from a LAN machine that
   uses `HOST_IP` for DNS and trusts `lab.test CA`, and add a customer.
4. **Encryption service** (2 min): E1 (`psql` vs the UI), E2, E3. Point out that the
   API never holds key material.
5. **Zero trust inside the cluster** (2 min): T1 `tcpdump`, T2 the identities, Z1
   frontend → database refused, Z2.
6. **Trust chain** (1 min): P1/P2, `openssl` output ending at `lab.test CA`.
7. **Backup** (1 min): B2 — a stolen database dump is useless without Vault.
   Then name what *is* critical: the Vault snapshot and the unseal key.

Close with what was deliberately **not** built and why (§15).

---

## 14. Teardown order (`down`)

Each line runs that phase's `down()`. The state each step reads is listed so that no
step depends on something already deleted.

| # | Step | Reads | Removes |
|---|---|---|---|
| −1 | pipeline | Gitea | disables `schedules.yml`, cancels running runs, stops the runner service, so no job races the teardown |
| 0 | `backup` | Vault, kubeconfig | nothing — takes a final `lab backup` while the data and its key still exist (`--no-backup` skips it) |
| 0a | `observe` [ext] | inventory | exporters and Alloy on the VMs; the observability containers |
| 1 | `app` | kubeconfig (from Vault) | ns `app`, `db` (PVC); Vault `auth/k3s/role/api`, policy `api`, `kv/app/*`, `transit/keys/customers` (deletion allowed first) |
| 2 | `mesh` | kubeconfig | Istio (`istioctl uninstall --purge`), Gateway API CRDs; **revokes** the istiod CA certificate in Vault |
| 3 | `cluster` | kubeconfig | cert-manager; Vault `auth/k3s`, policy `cert-manager`; then deletes `kv/lab/k3s` |
| 4 | `directory` [ext] | inventory, AD secrets | `realm leave` on members; Vault `kv/ad/*` |
| 5 | `tunnel`, `base` | inventory | nothing to undo on VMs that are about to be destroyed; WireGuard public keys in Vault |
| 6 | `setup` | Vault (`iac`, MinIO keys) | `terraform destroy`; then the state object |
| 7 | `image` | Vault (admin) | the CloudStack template; MinIO `images/*` |
| 8 | `provision` | — | CloudStack: services, system VMs, `cloud` and `cloud_usage` DBs, installer tracker, packages, NFS exports, drop-ins, repo, `cmk` |
| 9 | `platform` | — | unregisters the runner, removes its service, `lab-runner` and its work directory; stops and removes the compose project, volumes, Docker, its apt repo and key, and `/etc/docker/`; the `inet lab` nftables table and its persisted file; the systemd-resolved drop-in and the original `/etc/resolv.conf` link; chrony removed and timesyncd re-enabled; the bridge-netfilter sysctl file; the `lab maintain` timer; `/opt/lab/bin`; `/var/lib/lab/platform` and `/var/lib/lab/certs`; the lab CA from the host trust store |
| 10 | host | `/var/backups/lab/netplan.orig/` | restores the original netplan files, then inside one `netplan try` window deletes `cloud0`, `cloudbr0` and `cloudbr1` (networkd does not release a NIC from a bridge on its own) and applies the restored config; the automation confirms (SIGUSR1) only after it reaches `LAN_GATEWAY` again, otherwise it auto-reverts |
| 11 | `state/` | — | copies `bootstrap.log` to `/var/backups/lab/down-<timestamp>.log`, then deletes `state/` |
| 12 | reboot | — | — then run `revert-check` |

`/var/lib/lab/` (unseal key, backups) is **kept** by default. `down --purge-secrets`
removes it after a confirmation prompt naming every file.

---

## 15. Decisions and alternatives not built

| Decision | Chosen | Not built, and why |
|---|---|---|
| IaC engine | Terraform | OpenTofu: drop-in and openly licensed; a one-line swap via `TF_BIN` |
| Secrets/KMS | Vault | OpenBao: its advantage (free namespaces) is unused by a single tenant |
| PKI | one CA in Vault + istiod sub-CA | two-tier root/intermediate: without an offline root it adds shape, not safety |
| VPN | WireGuard site-to-site | Tailscale/Headscale: better for many ephemeral nodes with tag ACLs; overkill for two sites |
| Mesh | Istio ambient | Linkerd: simpler install, but sidecars per pod and edge-only open-source releases |
| CNI | k3s flannel | Cilium: its flow visibility is covered by ztunnel's deny logs for meshed traffic |
| Ingress | Istio Gateway | Traefik (disabled), NGINX Gateway Fabric: a second controller outside the mesh's identity model |
| DB credentials | static, in Vault KV | Vault database engine: short-lived users per pod; costs refresh logic in the api and a Vault → Postgres path through STRICT mTLS |
| App delivery | images built, scanned, pinned | code in ConfigMaps + pip at start: unpinned, unscanned, needs internet from the tier |
| Directory [ext] | Samba AD DC | FreeIPA: needs a RHEL-family guest and a second image pipeline |
| Egress control | proxy allow-list | ACL allow-list by CIDR: registries and mirrors sit behind CDNs, so CIDR lists rot |
| CI runner | one runner as `lab-runner` (in `docker` and `kvm`): host label for `main`, container label for PRs | separate runner pools on separate machines with a remote BuildKit service: full isolation, needed when many people push; overkill for an internal, single-operator lab, where `docker` group membership for `main`-branch jobs (root-equivalent) is an accepted, stated risk |
| Privileged access | the host as bastion, AD logins [ext] | Teleport/Boundary with an SSH CA and session recording: the production answer, out of scope |
