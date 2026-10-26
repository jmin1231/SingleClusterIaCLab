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

`sudo ./bootstrap.sh up` builds it. `sudo ./bootstrap.sh demo` proves every
requirement. `sudo ./bootstrap.sh down` removes it and restores the host, and
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
| X1 | Directory login: AD users, AD-group sudo, central revocation | Phase 7 **[ext]** | D1–D4 |
| X2 | Pipeline-driven delivery with gates | Phase 10 **[ext]** | G1–G3 |
| X3 | Observability of tunnel, mesh denials and Vault access | Phase 11 **[ext]** | O1–O3 |

**Tags.** Everything untagged is **core**: required for R1–R4. **[ext]** marks
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
- **Every phase owns its teardown.** Each phase module exports `up()`, `down()` and
  `check()`. `down` composes the `down()`s in reverse build order, so a phase can't
  be built without the code to remove it.
- **Idempotent on health, not on flags.** A phase is skipped only when its `check()`
  passes against the real system (API returns 200, resource exists and is healthy).
  The tracker in `state/tracker.json` records progress for resuming; it is never
  proof that something is done.
- **Least privilege.** Terraform uses a scoped CloudStack account. Each workload and
  each pipeline gets its own Vault identity and policy. Nothing in automation uses
  the CloudStack global admin or the Vault root token after bootstrap.
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
| Private CA + certificate automation | Vault PKI (`lab.test CA`); cert-manager in the cluster; `lab certs` on the host |
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
| CI/CD **[ext]** | Gitea Actions runner, scoped Vault identity |
| Observability **[ext]** | Prometheus, Grafana, Loki, Alloy |

---

## 4. Architecture

```
 LAN (MGMT_CIDR)  ── browser / operator
   │
 ┌─┴─────────────────────────────── host: Ubuntu 24.04, KVM ───────────────────────────────┐
 │ cloudbr0 = HOST_IP                                                                       │
 │ control plane (Docker):  CoreDNS · Vault · MinIO · Gitea(+registry) · Squid · [runner]   │
 │                          [Prometheus · Grafana · Loki]                                   │
 │ CloudStack: management + MySQL + NFS + KVM agent      Packer/qemu (image builds)         │
 │                                                                                          │
 │  mgmt shared network (untagged, on cloudbr0): every VM's NIC0, host-only reachability    │
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
- **Management plane:** each VM's NIC0 on the shared mgmt network. A per-VM nftables
  policy lets NIC0 talk **only to the host** (SSH from it; DNS, NTP, proxy, Vault,
  registry and Kubernetes API traffic to and from it) and to the WireGuard peer on
  UDP 51820. NIC0 carries no default route.
- **Control plane:** the host's containers. Every VM reaches the internet only
  through Squid on `HOST_IP:3128`, against a domain allow-list.

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
| `MGMT_CIDR` | host LAN, e.g. `192.168.50.0/24` |
| `HOST_IP` | host address, moved onto `cloudbr0` by CloudStack, e.g. `192.168.50.10` |
| `LAN_GATEWAY` / upstream DNS | from the LAN |
| CloudStack pod (system VM) range | e.g. `.180–.189` |
| CloudStack public range (VPC source NAT and public IPs) | e.g. `.190–.209` |
| mgmt shared network (VM NIC0) | e.g. `.150–.179`, untagged on `cloudbr0`, no gateway handed to VMs |
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

**Host ports** (all services listen on `0.0.0.0`, so they keep working when
CloudStack moves `HOST_IP` onto `cloudbr0`; the host firewall restricts sources)

| Service | Port | Name |
|---|---|---|
| CoreDNS | 53 | — |
| Vault | 8200 | `vault.lab.test` |
| MinIO API / console | 9000 / 9001 | `minio.lab.test` |
| Gitea web + registry | 3000 | `gitea.lab.test` |
| Squid | 3128 | `proxy.lab.test` |
| CloudStack UI/API · agent · cluster | 8080 · 8250 · 9090 | `cloudstack.lab.test` |
| Grafana · Prometheus · Loki **[ext]** | 3001 · 9095 · 3100 | `grafana.lab.test` … |
| chrony (NTP for VMs) | 123/udp | — |

**DNS.** CoreDNS on the host is authoritative for `lab.test` and for the reverse
zones of `MGMT_CIDR` and `10.0.0.0/16`, and forwards everything else upstream. It
also forwards `ad.lab.test` to `dc` **[ext]**. Every VM resolves through the host.
Pods resolve through k3s's CoreDNS, which forwards to the node's resolver.

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
| System VMs: SSVM, CPVM, redundant VPC router pair | 2.5 GB | |
| Control plane: CoreDNS, Vault, MinIO, Gitea, Squid | 1.5 GB | |
| vm-a + vm-b (1 GB each) + app-1 (4 GB) + KVM overhead | 7.0 GB | |
| dc (2 GB) + KVM overhead | | 2.3 GB |
| Gitea runner + rootless BuildKit job | | 1.5 GB |
| Prometheus + Grafana + Loki + Alloy | | 2.5 GB |
| **Steady state** | **16.0 GB** | **22.3 GB** |
| Peak transient: Packer build (Phase 4, before any VM exists) | +2.0 GB | |
| Peak transient: image build + scan (8.6 / CI) | +1.5 GB | +1.5 GB |
| **Peak** | **17.5 GB** | **23.8 GB** |
| **Headroom under 32 GB** (must stay ≥ 4 GB reserve) | **14.5 GB** | **8.2 GB** |

**What app-1's 4 GB holds** (requests in the manifests must sum to ≤ 3 GB): k3s
server ~0.6, istiod ~0.3, ztunnel + istio-cni ~0.15, Istio gateway ~0.1,
cert-manager ~0.2, Postgres ~0.3, api + frontend ~0.25.

**If measurements overrun, cut in this order:** observability first (it can run
only for the `demo`), then the redundant VPC router (a single router saves
~0.25 GB but loses the HA story), then the CI runner (CD is [ext]). Core never
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
| Bootstrap AppRole (`lab-bootstrap`) role_id + secret_id | `/var/lib/lab/approle.json` | root `0600`; secret_id TTL 30 days, re-issued by `lab platform --rotate-approle` |
| Lab SSH private key (Ansible → VMs) | Vault KV; written to `state/ssh/id_ed25519` only for the duration of a run | `0600`, deleted at the end of each phase that uses it |
| k3s kubeconfig (cluster-admin) | `state/kubeconfig` | `0600`; deleted by `down`; re-fetched on demand |
| WireGuard private keys | generated **on** each VM; never leave it | public keys published to Vault KV |
| AD machine keytabs **[ext]** | `/etc/krb5.keytab` on each member | created by the join, never baked into an image |
| Postgres superuser password | k8s Secret in `ns db` | k3s Secrets encryption at rest is on |
| istiod signing CA key | k8s Secret `istio-system/cacerts` | encrypted at rest; rotated by `lab mesh --rotate-ca` |

**Everything else is in Vault:** CloudStack admin and `iac` API keys, MinIO root
and per-bucket users, Gitea admin and runner tokens, the Postgres `app` password,
AD passwords **[ext]**, and the CI AppRole **[ext]**.

**Trust bootstrap order (the chicken-and-egg, broken explicitly):**

1. Vault starts with a **self-signed bootstrap certificate**, valid for one day.
2. `init` → unseal → enable PKI → generate the **single self-signed CA**
   `lab.test CA` (10 years; key never leaves Vault).
3. Vault issues its **own** listener certificate from that CA and reloads with
   `SIGHUP`. The bootstrap certificate is gone.
4. The CA is installed into the host trust store. It is baked into the golden image,
   so every VM trusts it from first boot.
5. Every other service certificate comes from Vault: host services via `lab certs`
   (30-day TTL, daily systemd timer renews under 10 days), cluster workloads via
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
  preflight.py platform.py provision.py image.py setup.py base.py tunnel.py
  directory.py cluster.py mesh.py app.py backup.py verify.py demo.py
  status.py teardown.py revert.py certs.py
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
.gitea/workflows/            ci.yml, cd.yml [ext]
docs/                        adr/, runbook.md, capacity.md, walkthrough.md
state/                       run state (gitignored): tracker, log, kubeconfig, inventory
```

---

## 8. Commands and build order

Every command runs `python3 -m lab <command>`. The table is in **build order**.

| # | Command | Phase | Core | Needs |
|---|---|---|---|---|
| 1 | `preflight` | 1 | ✓ | — |
| 2 | `platform` | 2 | ✓ (runner, observability: [ext]) | preflight |
| 3 | `provision` | 3 | ✓ | platform (Vault holds the `iac` key) |
| 4 | `image` | 4 | ✓ | provision (template registration) |
| 5 | `setup` | 5 | ✓ | image; runs **plan → policy → apply** |
| 6 | `base` | 6.1 | ✓ | setup |
| 7 | `tunnel` | 6.2 | ✓ | base |
| 8 | `directory` | 7 | [ext] | base |
| 9 | `cluster` | 8.1–8.2 | ✓ | base |
| 10 | `mesh` | 8.3 | ✓ | cluster |
| 11 | `app` | 8.4–8.7 | ✓ | mesh |
| 12 | `verify` | 12 | ✓ | everything built; non-zero on any failure |

**Composite commands**

| Command | Runs |
|---|---|
| `up [--core]` | 1 → 12 in order. `--core` skips [ext] steps. Resumes at the first phase whose `check()` fails. |
| `demo` | the examiner walkthrough (§13): proofs with human-readable output, re-runnable |
| `backup` / `restore-drill` | Phase 9 |
| `lint` | ruff, mypy, pytest, shellcheck (`bootstrap.sh`), yamllint, ansible-lint, tflint, `trivy config`, kubeconform |
| `status` | read-only inventory: what exists, what `check()` says |
| `certs` | renew host service certificates (also run by a systemd timer) |
| `down` | §14 order. Ends with a reboot. |
| `revert-check` | after the reboot: asserts the host baseline (V1–V5) |

---

## 9. Phases and steps

Each step fits one focused session and ends with an **Exit** you can run.

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
  listening ports, apt sources). One-time copy of `/etc/netplan` to
  `/var/backups/lab/netplan.orig/`, outside the repo and outside `state/`.
  Exit: both exist; a re-run changes neither.
- **1.2 Preflight.** Ubuntu 24.04; `/dev/kvm`; CPU and disk against §5; RAM ≥ 31 GiB
  usable with the §5 peak + 4 GB reserve fitting (warn above 32 GB: the budget is the
  ceiling, not the hardware); strict
  `apt-get update` (fail naming any broken source); config values valid and
  non-overlapping; **refuse** leftovers (existing `cloud` DB, `cloudbr0`,
  `cloudstack-*` packages, lab containers) with a message naming each one.
  Exit: passes on a fresh host; deliberately fails on a host with a planted
  `cloudbr0`.

### Phase 2 — Control plane

- **2.1 Docker and the compose project.** Docker Engine (pinned), address pool
  `172.30.0.0/16`, one compose project in `platform/` with health checks on every
  service. Host nftables: control-plane ports accept only from `MGMT_CIDR` and the
  Docker pool.
  Exit: `docker compose ps` all healthy; a port is refused from outside `MGMT_CIDR`
  (tested from a network namespace with a foreign address).
- **2.2 CoreDNS.** Forward and reverse zones from §5; upstream forwarding; host
  resolver uses it for `lab.test` (systemd-resolved drop-in).
  Exit: `dig vault.lab.test @HOST_IP` and a PTR lookup both answer; external names
  resolve.
- **2.3 Vault: server, init, unseal.** Integrated **Raft** storage (snapshots in
  Phase 9); TLS listener on the bootstrap certificate; audit device to a file;
  `operator init` (1 share for the lab; production uses 5/3 or KMS auto-unseal) to
  `/var/lib/lab/vault-init.json`; unseal; `lab` re-unseals on every run if sealed.
  Exit: `vault status` unsealed; restart the container, run `lab platform`, and it is
  unsealed with data intact.
- **2.4 Vault PKI and trust.** `pki/` with `lab.test CA`; roles `host-svc` (host
  service names, 30 days) and `k3s-svc` (`svc.cluster.local` + the app hostname, 7
  days); Vault re-issues its own certificate and reloads; CA into the host trust
  store; `lab certs` + systemd timer.
  Exit: `curl https://vault.lab.test:8200/v1/sys/health` succeeds **without** `-k`;
  `openssl s_client` shows the issuer is `lab.test CA`.
- **2.5 Vault identities and KV.** KV v2 at `kv/`; Transit at `transit/`; policies
  `lab-bootstrap`, `iac`, `ci` **[ext]**; AppRole `lab-bootstrap` written to
  `/var/lib/lab/approle.json`; seed CloudStack admin and SSH keypair paths. **Revoke
  the root token.**
  Exit: `lab` reads `kv/lab/ssh` via AppRole; the root token is rejected.
- **2.6 MinIO.** TLS from Vault; buckets `images`, `tfstate` and `backups`; one user and
  policy per bucket, credentials in Vault.
  Exit: `mc` round-trips an object in each bucket with its own user, and is denied on
  the other bucket.
- **2.7 Gitea and registry.** TLS from Vault; admin in Vault; public org `lab` for
  the container registry; repo mirror.
  Exit: `docker push` then `docker pull` of `gitea.lab.test:3000/lab/hello:test` from the
  host succeed with no insecure-registry setting.
- **2.8 Squid egress proxy.** `platform/squid/allowlist.txt` (Ubuntu archive and
  security mirrors, the container registries k3s/Istio/cert-manager/Postgres pull
  from, GitHub release downloads); deny everything else; access log to a file.
  Exit: through the proxy, an allow-listed URL returns 200 and `example.com` returns
  403, which shows in the log.

### Phase 3 — CloudStack

- **3.1 Install.** Vendored installer, all-in-one (management, MySQL, NFS, KVM
  agent). Advanced zone with the §5 ranges; `cloudbr0` takes `HOST_IP`. Disable
  bridge netfilter. Agent `TimeoutStartSec` above the readiness wait. Readiness means
  `/client/api` returns 200, not an open port.
  Exit: `cmk list zones` shows an Enabled Advanced zone; SSVM and CPVM Running; host
  services from Phase 2 still reachable on `HOST_IP`.
- **3.2 `cmk` and the scoped identity.** `cmk` (pinned); account `iac` in domain
  `lab` with a role limited to VPC, network, ACL, VM, template, keypair, public IP and
  port-forward APIs; API keys in Vault.
  Exit: as `iac`, `cmk create network` succeeds and `cmk list hosts` (admin-only) is
  denied.
- **3.3 Offerings and the mgmt network.** Compute offerings matching §5 sizes;
  redundant VPC offering; VPC tier offering with **ConfigDrive** userdata; a shared
  offering with ConfigDrive userdata; the mgmt shared network created with `cmk`
  (`vlan=untagged`, because the Terraform provider cannot create an untagged shared
  network); its id written to `state/`.
  Exit: `cmk list` shows each offering and the mgmt network; a re-run creates nothing.
- **3.4 Template trust.** Install `lab.test CA` on the KVM host for direct-download
  templates (`uploadTemplateDirectDownloadCertificate`).
  Exit: the certificate is listed for the host.

### Phase 4 — Golden image

- **4.1 Build.** Packer `qemu`: Ubuntu 24.04 autoinstall → qcow2 with cloud-init,
  qemu-guest-agent, openssh-server, python3, chrony, nftables, `lab.test CA` in the
  trust store; [ext] directory packages (sssd, realmd, adcli, krb5-user,
  samba-common-bin). Never bake identity: the build **fails** if a keytab, SSSD
  config, SSH host keys or machine-id exist.
  Exit: `packer validate`; a booted test VM gets userdata from a ConfigDrive.
- **4.2 Harden, scan, SBOM.** CIS-style hardening role; Trivy fails the build on
  HIGH/CRITICAL; Syft SBOM saved next to the image.
  Exit: the scan gate passes; the SBOM exists.
- **4.3 Publish and register.** Version = date + input content hash; upload to
  `images/<version>/` with its SBOM and SHA-256; skip build and upload when that hash
  already exists. Register as a **direct-download** template over HTTPS with the
  checksum; wait for it to be ready.
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
  - tier-app ingress TCP 443 from `MGMT_CIDR` (the only public-facing rule)
  - [ext] tier-a, tier-b and tier-app → tier-svc on the AD ports only
  - **no internet egress for any tier**

  `parallelism=1` for ACL rules.
  Exit: plan shows the VPC, tiers and ACLs; nothing applied yet.
- **5.3 Policy gate.** Conftest rules over `terraform plan -json`:
  - no ingress from `0.0.0.0/0`
  - the only public port-forward is tier-app 443
  - every tier ends in deny-all, both directions
  - no inter-tier allow except the AD ports
  - every VM has the mgmt NIC as NIC0
  - provider credentials are the `iac` account

  `lab setup` runs **plan → policy → apply**, and apply is unreachable if the policy
  fails.
  Exit: the real plan passes; a fixture plan opening `0.0.0.0/0:22` is rejected and
  nothing is applied.
- **5.4 Compute and ingress.** Lab SSH public key from Vault; VMs with NIC0 = mgmt,
  NIC1 = their tier (default route); ConfigDrive userdata; a VPC public IP with
  port-forward 443 → `app-1:443`; outputs → `state/inventory.json`, consumed by Ansible
  through the `cloud.terraform` inventory plugin with absolute paths; `app.lab.test`
  registered in CoreDNS pointing at the public IP.
  Exit: apply; all VMs Running and reachable over SSH from the host on NIC0; **vm-a
  cannot ping vm-b's tier address** (N1 holds before the VPN exists).

### Phase 6 — Base configuration and the VPN

- **6.1 `base` role (all VMs).**
  - DNS and NTP from the host.
  - Proxy environment for apt and containerd: `http_proxy` to the host, with
    `no_proxy` covering `lab.test`, `MGMT_CIDR`, the VPC, the pod and service CIDRs,
    and `.svc` and `.cluster.local`.
  - nftables on NIC0:
    - in: from `HOST_IP` only: SSH; on app-1 also the k3s API (6443, for Vault's
      token reviews and `lab`); node exporter **[ext]**
    - out: to `HOST_IP` only, plus UDP 51820 to the VPN peer
    - no default route via NIC0
  - Unattended security updates through the proxy.

  Exit: from vm-a, `apt-get update` works through the proxy; a direct `curl` to the
  internet fails; `curl` to another VM's NIC0 fails; `curl` to the host succeeds
  (N3, N4).
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

- **7.1 DC VM.** `dc` in tier-svc; ACL allows only 53, 88, 123, 389, 445, 464, 636,
  3268, 3269 from the member tiers.
  Exit: from vm-a, ports 88 and 389 on `10.0.10.10` connect; port 22 does not.
- **7.2 Provision the domain** (`samba_dc` role).
  - Realm `AD.LAB.TEST` (subdomain: the DC must own its zone; `lab.test` belongs to
    CoreDNS, which forwards `ad.lab.test` to the DC).
  - Internal DNS; mask `smbd`, `nmbd`, `winbind`; the DC resolves through itself.
  - Reverse zone; `OU=LabServers`.
  - A delegated `joiner` account limited to creating computers in that OU.
  - Groups `lab-users` and `lab-admins`; users `alice` (admins), `bob` (users),
    `carol` (neither).
  - All passwords generated into Vault.

  Exit: `host -t SRV _ldap._tcp.ad.lab.test HOST_IP` answers via forwarding;
  `kinit administrator` works on dc.
- **7.3 Join members** (`ad_member` role).
  - FQDN hostnames; chrony from dc.
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
  - Kubeconfig to `state/kubeconfig`, pointed at the mgmt IP.

  Exit: from the host, `lab status` shows the node Ready; `k3s secrets-encrypt status`
  shows enabled (S2); a pod resolves `vault.lab.test` and gets 200 from
  `/v1/sys/health` using the CA bundle.
- **8.2 Vault as the cluster's CA.**
  - Host Vault:
    - Kubernetes auth at `auth/k3s`, pointed at `https://<app-1 mgmt IP>:6443` with
      the k3s CA.
    - Reviewer: ServiceAccount `vault-auth` with `system:auth-delegator` and a
      long-lived token Secret.
    - Policy `cert-manager` = `pki/sign/k3s-svc` only.
  - In k3s: cert-manager (pinned static manifest) and a `ClusterIssuer vault`
    (server `https://vault.lab.test:8200`, `caBundle`, Kubernetes auth via a
    ServiceAccount token request).

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
  `lab.test CA`; a client in an unlabelled namespace is refused.
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

  Exit: an encrypt/decrypt by hand round-trips; an `api`-policy token is denied
  `kv/data/lab/ssh` and `transit/keys/customers/rotate`.
- **8.6 Application images.** `app/api` and `app/frontend`, each:
  - base image pinned by digest
  - `pip install --require-hashes` at **build** time
  - non-root user, read-only root filesystem compatible
  - Trivy gate (HIGH/CRITICAL fail)
  - SBOM
  - tagged with the git SHA
  - pushed to `gitea.lab.test:3000/lab/`

  Built by `lab app` on the host (core) or by CI **[ext]**.
  Exit: both images in the registry with their SBOMs; the scan gate passed.
- **8.7 Deploy the application.**
  - **api** (Flask, `sa/api`):
    - `/healthz`, `GET /customers`, `POST /customers`
    - logs in to Vault with its ServiceAccount token
    - reads `kv/app/db` once at startup
    - encrypts `card_number` via Transit before inserting
    - decrypts on read and returns only `**** ` + the last 4 digits
    - one database connection per request, parameterized SQL
    - `VAULT_CACERT` is its only TLS setting
  - **frontend** (Flask, `sa/frontend`): HTML list and add form; knows only `API_URL`.
  - **Gateway**: Gateway API `Gateway` (class `istio`, HTTPS 443, certificate from
    `ClusterIssuer vault` for `app.lab.test`) and an `HTTPRoute` to the frontend.
  - **ALLOW policies**: frontend ← the gateway's ServiceAccount; api ← `sa/frontend`.
  - Probes; resource requests and limits; no secret values in any Deployment.

  Exit: from the host, `curl https://app.lab.test/` (resolving to the public IP)
  succeeds without `-k`. Adding a customer shows `**** 4242`, and `psql` in the
  postgres pod shows `vault:v1:…`.

### Phase 9 — Backup, restore, crypto-shredding

- **9.1 Backup.** `lab backup`:
  - `vault operator raft snapshot save`
  - `pg_dump` of `customers` (through `kubectl exec`)
  - both to MinIO bucket `backups/<timestamp>/`, and the Vault snapshot also to
    `/var/lib/lab/backups/`

  The unseal key is **not** in the backup; it is stored offline (operator
  responsibility, stated in the runbook).
  Exit: both objects exist; sizes are non-zero; the Vault snapshot verifies.
- **9.2 Restore drill.** Delete the `db` namespace and its PVC, redeploy, restore the
  dump; the api reads the old rows and decrypts them (B1).
- **9.3 Crypto-shredding.** Restore the same dump into a scratch Postgres next to a
  **scratch Vault** without the `customers` key: every `card_number` is unreadable
  ciphertext, and names are still readable (B2).

  This is the point to make: the database backup is safe to lose; the Vault snapshot
  plus the unseal key are the crown jewels.
  Exit: B1 and B2 pass; the scratch resources are removed.

### Phase 10 — Gates and CI/CD **[ext]**

- **10.1 Runner.** `act_runner` on the host. Jobs run in containers with **no host
  Docker socket and no host network privileges**; image builds use rootless
  BuildKit. AppRole `ci` with read access to only what CI phases need.
  Exit: a trivial workflow runs green; a job trying to mount `/var/run/docker.sock`
  fails.
- **10.2 CI on every PR.** `lint` → unit tests → build, scan and push app images →
  `terraform plan` → policy gate. The plan output is posted to the PR.
  Exit: a PR that opens `0.0.0.0/0` fails the gate (G1).
- **10.3 CD (manual approval)** runs only the **cloud-level** commands, over the
  network as `ci`: `setup`, `base`, `tunnel`, `cluster`, `mesh`, `app`, `verify`.
  Host-level commands (`preflight`, `platform`, `provision`, `image`, `down`,
  `revert-check`) are **operator-only**, because they change or reboot the host the
  runner lives on.
  Exit: an approved merge re-applies and verifies (G2); the runner identity is denied
  `sys/` and `pki/root/*` in Vault (G3).

### Phase 11 — Observability **[ext]**

- **11.1** Prometheus, Grafana and Loki on the host. node_exporter and a WireGuard
  exporter on the VMs, scraped over NIC0. Alloy on app-1 ships ztunnel logs and pod
  logs; Alloy on the host ships the Vault audit log and the Squid access log.
  Exit: Grafana dashboards for tunnel health, mesh denials and Vault access (O1).
- **11.2** Alerts: WireGuard handshake older than 3 minutes; any ztunnel deny; any
  Vault `transit/decrypt` by an identity other than `api`.
  Exit: `wg-quick down wg0` on vm-a fires the tunnel alert (O2); a denied
  frontend → postgres connection fires the mesh alert (O3).

### Phase 12 — Verification

- **12.1 `verify`.** Every check in §12 except B1–B2 (destructive; run by
  `restore-drill`), each implemented once in `src/lab/verify.py` with a pass/fail line
  and the evidence. Non-zero exit on any failure. [ext] checks are skipped, and
  reported as skipped, under `--core`. E2/E3 run against a scratch Transit key that is
  deleted afterwards, so `verify` changes nothing.
  Exit: `verify` green twice in a row; `vault list transit/keys` is unchanged.

### Phase 13 — Teardown and revert

- **13.1 `down`** runs §14 in order. Each step tolerates "already gone". Teardown
  never reads state that an earlier teardown step deleted. Helpers return success on
  "not found".
  Exit: completes from any partially built state (tested by interrupting `up` after
  `setup` and after `mesh`).
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
7. **ConfigDrive userdata is served by the network of the VM's default NIC.** Shared
   networks default to router-served userdata, so use a shared offering with
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
    `.cluster.local`, `lab.test` and `MGMT_CIDR` must all bypass the proxy, or pods
    send cluster traffic to Squid.
12. **Check container entrypoints before overriding commands.** Some images set the
    entrypoint to the tool itself (`mc`), so `sh -c` needs `--entrypoint`.

---

## 11. Risks

| Risk | Where | Mitigation |
|---|---|---|
| Advanced-zone bring-up is the most fragile step | 3.1 | health-based gates, resumable `up`, generous timeouts |
| `HOST_IP` moves to `cloudbr0` mid-build | 3.1 | services bind `0.0.0.0`; 3.1 Exit re-checks Phase 2 reachability |
| Direct-download templates over HTTPS with a private CA | 3.4, 4.3 | if the KVM host certificate upload fails, serve the images bucket through a read-only presigned URL and rely on the template checksum for integrity |
| Istio ambient on k3s (CNI paths) | 8.3 | k3s-specific install values; smoke namespace before any workload; fallback is sidecar mode |
| istiod `cacerts` key names | 8.3 | write all four Istio file names; Exit checks the workload chain, not just the Secret |
| Egress allow-list too tight | 2.8, 6.1, 8.x | denials are logged by Squid; grow the list from the log, never by opening the ACL |
| Host memory (32 GB ceiling) | all | §5 budget with a 4 GB reserve, measured per phase; `up` refuses a phase that would breach the reserve; §5 cut order if it overruns |
| Vault sealed after a host reboot | everything | `lab` unseals on every run; runbook entry; production answer is KMS auto-unseal |
| Losing the unseal key or Vault snapshot | 9 | that is total loss of encrypted data, by design; the runbook makes offline custody of both an explicit operator duty |

---

## 12. Verification catalog

| ID | Check | How |
|---|---|---|
| **N1** | tiers are isolated | vm-a → `10.0.2.10` on its tier NIC with `wg0` down: no route/timeout |
| **N2** | the VPN routes subnets | vm-a → vm-b's **tier** address `10.0.2.10` (not its overlay address) succeeds; `ip route get` shows `dev wg0` |
| **N3** | no internet from tiers | direct `curl https://example.com` fails; through the proxy → 403 and logged |
| **N4** | mgmt NIC reaches only the host | VM → another VM's NIC0 fails; VM → `HOST_IP:8200` succeeds |
| **N5** | Terraform runs least-privilege | `iac` key denied an admin-only API call |
| **E1** | field-level encryption | `psql` shows `vault:v1:…`; API returns `**** 4242` |
| **E2** | key rotation | rotate → new ciphertext is `vault:v2:…`; v1 ciphertext still decrypts (`verify`: scratch key; `demo`: the real key) |
| **E3** | rewrap + retire | rewrap to v2; `min_decryption_version=2`; a saved v1 ciphertext fails to decrypt (`verify`: scratch key; `demo`: rewraps every row first) |
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
| **G1–G3** [ext] | gates | bad plan rejected; approved merge verifies; runner denied `sys/` |
| **O1–O3** [ext] | observability | dashboards populated; tunnel alert fires; mesh-deny alert fires |
| **V1–V5** | revert | no `cloudstack-*` packages; `/etc/netplan` byte-identical; no lab bridges or containers; listening ports match the baseline; host online |

---

## 13. Examiner walkthrough (`demo`, about 10 minutes)

1. **Show the shape** (1 min): `lab status`, then the architecture diagram in §4.
2. **VPC isolation and VPN** (2 min): N1 → N2 → bring `wg0` down → N1 again → up.
   Then N3: the tiers have no internet, and here is the proxy denial in the log.
3. **The application** (1 min): open `https://app.lab.test`, add a customer.
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
| 0 | `backup` | Vault, kubeconfig | nothing — takes a final `lab backup` while the data and its key still exist (`--no-backup` skips it) |
| 1 | `app` | `state/kubeconfig` | ns `app`, `db` (PVC); Vault `auth/k3s/role/api`, policy `api`, `kv/app/*`, `transit/keys/customers` (deletion allowed first) |
| 2 | `mesh` | kubeconfig | Istio (`istioctl uninstall --purge`), Gateway API CRDs; **revokes** the istiod CA certificate in Vault |
| 3 | `cluster` | kubeconfig | cert-manager; Vault `auth/k3s`, policy `cert-manager`; then deletes `state/kubeconfig` |
| 4 | `directory` [ext] | inventory, AD secrets | `realm leave` on members; Vault `kv/ad/*` |
| 5 | `tunnel`, `base` | inventory | nothing to undo on VMs that are about to be destroyed; WireGuard public keys in Vault |
| 6 | `setup` | Vault (`iac`, MinIO keys) | `terraform destroy`; then the state object; then `state/inventory.json` |
| 7 | `image` | Vault (admin) | the CloudStack template; MinIO `images/*` |
| 8 | `provision` | — | CloudStack: services, system VMs, `cloud` and `cloud_usage` DBs, installer tracker, packages, NFS exports, drop-ins, repo, `cmk` |
| 9 | `platform` | — | stops and removes the compose project, volumes, Docker; removes the lab CA from the trust store (the host trust store is part of the baseline) |
| 10 | host | `/var/backups/lab/netplan.orig/` | restores netplan (`netplan try` with auto-revert); removes `cloudbr0`/`cloud0` |
| 11 | `state/` | — | deleted last |
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
| Privileged access | the host as bastion, AD logins [ext] | Teleport/Boundary with an SSH CA and session recording: the production answer, out of scope |
