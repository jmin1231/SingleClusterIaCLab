# Lab build order

This is the working implementation plan for **writing the files that deploy the lab**:
Python modules, configuration, Terraform, Ansible roles, workflows, application code,
and Flux manifests. It starts from an empty repository, but records the implementation
already present so we can continue without rebuilding completed work.

Initial reconciliation: **2026-11-16**, against the working tree at `e027e15` plus
uncommitted changes to `terraform/compute.tf` and `.gitea/workflows/check.yml`.
No deployment or destructive operation was run to prepare this document.

Use this file for build order and progress. [PLAN-enterprise.md](PLAN-enterprise.md)
remains the detailed design/history reference; its old step numbers are cross-referenced
below, not reused. Its CloudStack sections, old directory layout, and contradictory
status claims are not instructions to build those things again.

## How we maintain this file

| Status | Meaning |
|---|---|
| `Implemented` | Relevant code exists and was inspected. This does not assert a successful fresh-host deployment. |
| `Partial` | Some code exists, but the step's stated outcome still needs implementation. |
| `Next` | Unfinished work on the current critical path. |
| `Planned` | Required later; implementation is absent or not yet wired in. |
| `Verified` | The acceptance check passed on the lab, with a dated evidence reference recorded here. |
| `Deferred` | Outside the current build; not a prerequisite for the active phases. |

Each step has a stable ID such as **B04.2**, files to create or extend, and an acceptance
check. Steps within a phase are ordered unless a dependency says otherwise. Future file
names are proposed locations, not claims that those files already exist.
These are implementation phases, not the runtime order of `platform_up()`; for
example, the VM firewall is loaded before any workflow can start VMs, even though
its implementation is described alongside Terraform in B04.

At the end of a working session:

1. Update the affected step's status and current note in place.
2. Record the tested commit, command or Gitea run, result, and any remaining gap.
3. Update **Next work** below. Split a large step into suffixed IDs rather than renumbering.
4. Add new scope to the appropriate phase; keep alternatives in the deferred section.

Do not append competing versions of a decision. Keep secrets out of this file: record
their paths and owners only. Existing external trackers can reference these IDs; using
this build plan does not require setting up another tracker.

## Current design: decisions to carry forward

| Area | Build this |
|---|---|
| Host | Ubuntu 24.04, x86_64, four cores, 16 GB RAM, roughly 250 GB disk, usable `/dev/kvm`; nested virtualization when the host is itself a VM. |
| Python | `bootstrap.sh` executes `python3 -B -m src`; standard-library bootstrap code under `src/host`, `src/lib`, and `src/services`. Keep the current layout. |
| Configuration | Shared values in `src/lib/config.py`; host pins in `src/host/config/config.py`; service-specific configuration beside its service. Do not introduce the old TOML loader merely to match the old plan. |
| Host services | Rootful Podman and Compose; one Compose file per service. Current networks include `lab-backend` and `lab-vault`. The code installs the home:alvistack Podman stack, not the old Ubuntu Podman 4.9 design. |
| Infrastructure | QEMU/KVM and `qemu:///system`; Terraform's pinned libvirt provider. Three simulated VPCs and a routed WAN. No CloudStack, system VMs, MySQL, NFS, or LAN bridge migration. |
| Firewall | Bootstrap loads `src/host/files/nftables-vmfw.nft` through `vmfw.py`. No VM-firewall `.service`. Its `/run/lab/vmfw.loaded` marker and rules disappear on reboot; VMs have `autostart = false`. |
| CI | Gitea with one host runner, user `lab-runner`, `libvirt` group, capacity one. The operator owns the infrastructure; keep the agreed administrative model. |
| Checkout | `actions/checkout@v4`, `persist-credentials: false`, host Node installed by `toolchain.py`. No npm installation or `builtin:checkout`. |
| Change flow | Local edits → `bootstrap.sh update` commits → converges host → pushes to Gitea `main`, or dispatches when unchanged → follows that run. No PR requirement, branch protection, or push to `origin`. |
| Workflow structure | `deploy.yml` calls reusable stage workflows. Tools run directly in workflows; add a small adjacent script only when needed. No generic Python pipeline framework. |
| State | Terraform local backend at `/var/lib/lab/tfstate/terraform.tfstate`, outside workspaces. Retain locking and deployment concurrency with `cancel-in-progress: false`. |
| Trust | cfssl creates host and application roots; Istio later creates its own mesh root. Vault holds secrets and provides Transit encryption; it is not the certificate issuer. |
| Guests | Stock dated Ubuntu cloud image; cloud-init handles initial identity/network/trust. Ansible handles packages and guest services. |
| Cluster | One k3s server on be-1, Flannel, Flux, Istio ambient, CNPG and VSO. Flux owns ongoing manifest reconciliation after its initial bootstrap. |
| Monitoring | Prometheus, Loki and Grafana on the host; cluster collection through Alloy later. Monitoring is built after the core delivery path. |

Current addressing, sourced from `terraform/compute.tf` and `network.tf`:

| VM | Private network/address | WAN address | Management address | vCPU / RAM / disk |
|---|---|---|---|---|
| fe-1 | `site-a`, `10.1.1.10/24` | `198.51.100.11/24` | `10.250.0.110/24` | 1 / 1024 MiB / 10 GiB |
| tun-1 | `site-hub`, `10.2.1.10/24` | `198.51.100.12/24` | `10.250.0.111/24` | 1 / 512 MiB / 10 GiB |
| be-1 | `site-c`, `10.3.1.10/24` | `198.51.100.13/24` | `10.250.0.112/24` | 2 / 4096 MiB / 40 GiB |

Private networks have no host address. `wan` has host address `198.51.100.1/24` and
no NAT for general internet access. `cloudbr1` has `10.250.0.1/24`. Guest NICs are
`eth0` private, `eth1` WAN, `eth2` management; only WAN has a default route. Fixed
MACs and host tap names live in Terraform, not in a second hand-maintained inventory.

Keep at least 2 GiB host memory available under the planned peak; measure actual usage.
The VMs request 5.5 GiB total before virtualization overhead. The old plan's capacity
estimates are not fresh measurements. Later be-1 manifests should budget requests to
at most 3 GiB within its 4 GiB allocation; reduce monitoring first if measurements fail.

## Where we are now

| Area | Evidence in the repository | Remaining work |
|---|---|---|
| Bootstrap and host | CLI/lock/logging; KVM check; live LAN discovery; bridge; chrony; Podman; libvirt; toolchain | Resource checks, baseline/ownership recording, and complete restoration are absent. |
| Foundation services | CoreDNS, cfssl PKI, Vault init/unseal/KV/Transit/bootstrap AppRole, Traefik | Host trust, console setup, broader host firewall, and configuration-change/reboot proofs. |
| Gitea and CI | Gitea admin/org/repo, runner registration/service, seed/update/dispatch/follow, three workflows | Live acceptance evidence; pipeline AppRole, registry/Flux users, and rootless build setup arrive with their consumers. |
| Terraform | Providers/lock, pool/image, networks, domains, seed templates, inventory resources, real apply workflow | Fresh-host state directory, cloud-init artifact persistence, live first/repeat/reboot apply, inventory consumer. |
| Guest configuration onward | Design only | No `ansible/`, `clusters/`, application, Squid, monitoring, or verify implementation exists in this tree. |
| Removal | Individual `down()` functions | `teardown` is a stub. `destroy` removes host services but does not yet destroy Terraform resources or prove baseline restoration. |

The latest review exercised Gitea run-following with mocks: discovery, success, missing
logs, HTTP/network errors, timeout, and interrupt handling. That is useful code evidence,
not proof of a live Gitea delivery. The old plan records earlier host-service and runner
smoke tests; preserve their provenance rather than marking the whole build verified.

## Next work

The current milestone is **B04: three VMs created through CI, followed by a no-change
run and a reboot recovery without unintended disk replacement**.

1. **B01.1–B01.2:** close fresh-host preflight/baseline gaps before claiming a reproducible
   clean build or testing full destruction. An already modified host cannot supply its
   original baseline retrospectively; use the original snapshot for that proof.
2. **B04.1:** provision runner-owned Terraform state storage; it is named in the plan
   but is not created by the current runner installer.
3. **B04.3:** resolve the temporary cloud-init ISO/replacement concern and validate the
   current seed-volume format. The working tree currently specifies `type = "iso"`.
4. **B04.4:** capture first apply, unchanged apply, failure-gate, and reboot evidence.
5. **B04.5–B04.6:** finish the inventory/DNS handoff and minimal tenant teardown.
6. Continue with **B05**, where controlled egress and Vault credentials make Ansible usable.

## Phase overview

| Phase | What we build |
|---|---|
| B00 | Python package, shell entry point, commands and shared helpers |
| B01 | Host checks, baseline, networking, runtimes and tool installers |
| B02 | DNS, PKI, Vault and HTTPS gateway |
| B03 | Gitea, runner and workflow handoff |
| B04 | Terraform VMs, persistent state, inventory and minimal removal |
| B05 | Host/guest firewall, Squid, pipeline credentials and Ansible base |
| B06 | WireGuard hub and spokes |
| B07 | Registry, k3s, Flux and scoped cluster identities |
| B08 | Istio ambient and transport/authorization policies |
| B09 | Application images, database, API and frontend |
| B10 | Metrics, logs, dashboards and operator consoles |
| B11 | Integrated verification and operator documentation |
| B12 | Complete cleanup and host restoration |
| B13 | Deferred backup, restore and key-loss drills |

## Phase B00 — Repository and command skeleton

**Outcome:** an importable Python bootstrap with a small, predictable command surface.
**Legacy reference:** Phase 0. **Dependency:** none.

### B00.1 — Package, shim and logging — Implemented

- **Files:** `bootstrap.sh`, `src/__init__.py`, package `__init__.py` files,
  `src/lib/log.py`, `.gitignore`.
- **Build:** root/Python checks in the shim; anchor paths to the checkout; console
  messages plus `state/bootstrap.log`; ignore runtime keys, Terraform state and caches.
- **Accept:** shell syntax and Python imports pass; invocation outside the repo works;
  `state/` is created on first use and runtime material is not tracked.

### B00.2 — Commands, lock and shared helpers — Implemented

- **Files:** `src/__main__.py`, `src/lib/config.py`, `src/lib/system.py`.
- **Build:** `up`, `update`, `teardown`, `destroy`; local command lock, exit codes,
  logging, and helpers shared by multiple modules. Wire real steps as they are built.
- **Accept:** help matches the CLI, a competing invocation is refused, exceptions return
  failure, Ctrl+C returns 130. Removal commands remain incomplete until B04.6/B12.

## Phase B01 — Host prerequisites and recoverable changes

**Outcome:** the host can run services and VMs, and its prior state can be restored.
**Legacy reference:** 1.1–1.3, 2.1a–2.1d, 2.3b. **Dependency:** B00.

### B01.1 — Preflight and capacity — Partial

- **Files:** extend `src/host/preflight.py`, `src/host/config/config.py`; create
  `docs/capacity.md` when measurements are collected.
- **Build:** retain the existing KVM check and live LAN discovery; add supported OS/CPU,
  RAM/disk checks, clear handling of ambiguous routes/addresses, relevant subnet overlap
  checks, and a fresh-host ownership contract. Check the 2 GiB reserve before costly
  work; reuse the same measurement in CI when builds arrive.
- **Accept:** unsuitable hosts fail before mutation with specific reasons; a four-core,
  16 GB host passes with measured headroom. Do not add the discarded CloudStack
  static/DHCP restrictions or foreign-MAC prerequisites to the new topology.

### B01.2 — Baseline and ownership — Planned

- **Files:** extend `preflight.py` and `src/lib/system.py`; a small
  `src/host/baseline.py` is appropriate if baseline logic needs its own module.
- **Build:** write-once backup of files and state the lab will change, outside the
  checkout; record original users/groups, relevant package/service state and network
  configuration. Each installer records its own additions for later removal.
- **Accept:** a repeated or interrupted bootstrap never overwrites the original
  baseline; restoration can distinguish pre-existing resources from lab additions.

### B01.3 — Management bridge and time — Implemented

- **Files:** `src/host/network.py`, `ntp.py`, `config/config.py`,
  `files/60-lab-cloudbr1.yaml`, `files/chrony-lab.conf`.
- **Build:** host-only `cloudbr1` and its dummy anchor, split DNS for `lab.test`, chrony
  serving management clients. Leave the physical LAN interface in its existing role.
- **Accept:** bridge address survives reboot, LAN connectivity remains intact, time
  synchronizes, repeat configuration is stable; removal restores the original time service.

### B01.4 — Container and virtualization runtimes — Implemented

- **Files:** `src/services/podman/` including its config/repository files;
  `src/host/kvm.py` and host package settings.
- **Build:** current Podman/Compose stack, rootful API socket, QEMU/libvirt socket.
  Keep networks and VM resources under Terraform ownership.
- **Accept:** Compose can start a disposable container; `virsh --connect qemu:///system
  list --all` works. Record actual Podman/netavark versions and firewall behavior before
  writing more host rules; do not copy assumptions about netavark 1.4.

### B01.5 — Tool installers — Partial

- **Files:** `src/host/toolchain.py`, `src/host/config/config.py`.
- **Build:** keep the existing Terraform, Ansible collection and Node installers;
  remove the obsolete first `ensure_node()` definition that the later definition shadows.
  Add tools only with the phase that consumes them; verify downloads where supported.
- **Accept:** exact configured versions execute as `lab-runner`, unchanged installs
  download nothing, corrupt archives fail, removal is ownership-aware. No npm dependency.

## Phase B02 — DNS, certificates, Vault and gateway

**Outcome:** trusted control-plane endpoints exist before CI depends on them.
**Legacy reference:** 2.3a, 2.4a–2.6. **Dependency:** B01 runtime/network steps.

### B02.1 — CoreDNS — Implemented

- **Files:** `src/services/coredns/dns.py`, `compose.yaml`, `conf/Corefile`.
- **Build:** local `lab.test` answers and external forwarding, using the existing
  split-DNS bridge configuration. The current implementation uses a hosts list, not
  the old zone-file/SOA-writer design.
- **Accept:** host and management clients resolve Gitea/Vault and external names without
  a forwarding loop. Verify config edits actually reload; add new names with consumers.

### B02.2 — cfssl roots and certificates — Implemented

- **Files:** `src/lib/pki.py`, `src/lib/config.py` (`CERTS`), `src/cfssl/*.json`.
- **Build:** `lab.test CA` and application root, server/client profiles, service leaves,
  private-key ownership, create-once behavior. Make certificates before Vault/Traefik.
- **Accept:** certificate/key pairs and chains are valid, keys have intended permissions,
  reruns preserve identities. Existing application leaves are not yet published to Vault;
  that handoff belongs to B09.4. Remove stale CloudStack SANs when refreshing this config.

### B02.3 — Vault server and recovery — Implemented

- **Files:** `src/services/vault/vault.py`, `vault.hcl`, `compose.yaml`.
- **Build:** Raft/TLS service; guarded initialization; durable recovery file;
  unseal after restart; explicit refusal when Vault and recovery material disagree.
- **Accept:** fresh setup, repeat setup and restart/unseal preserve data; sealed health
  does not deadlock initialization. Complete deletion must be confirmed before recovery
  keys are removed; audit this in B12, not merely by checking whether Podman is active.

### B02.4 — Vault engines and bootstrap identity — Implemented

- **Files:** `vault.py`, `policies/lab-bootstrap.hcl`, `policies/lab-pipeline.hcl`,
  `src/lib/config.py` (`APPROLES`).
- **Build:** KV v2, Transit, SSH keypair, bootstrap policy/AppRole and initial root-token
  revocation. Grow named policy grants with each actual consumer.
- **Accept:** bootstrap logs in after root revocation and existing SSH keys remain stable.
  **Current boundary:** the pipeline policy exists, but `APPROLES` currently contains
  only `lab-bootstrap`; do not assume runner credentials already exist.

### B02.5 — Traefik and configuration updates — Implemented

- **Files:** `src/services/traefik/traefik.py`, `compose.yaml`, `dynamic/tls.yml`,
  `dynamic/gitea.yml`; existing service modules where reloads are needed.
- **Build:** TLS on `10.250.0.1:443`, private service backends; Vault remains direct on
  `10.250.0.1:8200`. Keep per-service Compose files and current network names.
- **Accept:** verified HTTPS reaches the intended backend; LAN access to control-plane
  consoles is excluded. Exercise both a Compose edit and a bind-mounted config edit;
  `compose up` alone is not evidence that every service reloaded its config.

## Phase B03 — Gitea, runner and deployment handoff

**Outcome:** bootstrap launches and follows a gated pipeline built from Gitea's checkout.
**Legacy reference:** 2.8, 2.10, 3.5a–3.5b. **Dependency:** B02 and B01.5.

### B03.1 — Gitea service and repository — Implemented

- **Files:** `src/services/gitea/gitea.py`, `config/config.py`, `compose.yaml`;
  Traefik's Gitea route.
- **Build:** service health, admin credentials in Vault, public `lab` organization and
  private `lab/lab` repository; registration disabled. Keep `origin` untouched.
- **Accept:** UI/API work through verified TLS, credentials survive reruns, and setup
  adopts the existing org/repository. Registry and Flux identities are B07.1 work.

### B03.2 — Host runner — Implemented

- **Files:** `src/services/gitea/runner/runner.py`, `config/config.py`,
  `files/config.yaml`, `files/lab-runner.service`.
- **Build:** user, libvirt membership, checked runner download, instance registration,
  credential ownership, CA/public SSH key publication and systemd service. One `host`
  label, capacity one. Keep registration token off argv.
- **Accept:** service runs as `lab-runner`, checkout trusts Gitea, Node is found, and
  `virsh` works in an actual job. Terraform's directory ownership is completed in B04.1.

### B03.3 — Seed, update and run following — Implemented

- **Files:** `src/__main__.py`, Gitea module/config.
- **Build:** commit local edits before applying host code; seed once; initialized
  marker; update push-or-dispatch; SHA-filtered push discovery; exact dispatch ID;
  bounded run following; optional failed-job logs; correct failure/interrupt exits.
- **Accept:** first `up` starts a build, second `up` refuses rebuilding, unchanged
  `update` dispatches, changed `update` pushes, failures return nonzero. Test interrupted
  first setup too: if the repository is seeded but local fixes differ, recovery must
  deploy those fixes rather than silently dispatch the old revision.

### B03.4 — Reusable workflows and checks — Implemented

- **Files:** `.gitea/workflows/deploy.yml`, `check.yml`, `terraform.yml`.
- **Build:** parent push/dispatch triggers and concurrency; child `workflow_call` jobs;
  checkout with credentials not persisted; Terraform init without backend, formatting
  and validation before apply. The Terraform workflow now contains a real apply.
- **Accept:** malformed Terraform stops downstream jobs; a corrected commit proceeds;
  a second delivery does not overlap or cancel an active apply. Record the live run URL.

## Phase B04 — Terraform infrastructure and the first repeatable milestone

**Outcome:** CI creates exactly three VMs with stable identity, storage and isolation.
**Legacy reference:** 4.0, 5.1–5.4b. **Dependency:** B03.

### B04.1 — Persistent state and base storage — Partial / Next

- **Files:** `terraform/provider.tf`, `.terraform.lock.hcl`, `storage.tf`,
  `variables.tf`; extend runner setup/config.
- **Build:** retain provider/version pins and local backend; provision
  `/var/lib/lab/tfstate` as `lab-runner`, mode `0700`, before any job. Terraform owns
  the `lab` pool/base volume. Keep the dated image URL; record its independently checked
  checksum without claiming the provider verifies it on every download.
- **Accept:** a fresh runner can initialize and lock state outside its checkout;
  the pool/image survives job workspace cleanup. A competing apply cannot bypass locking.

### B04.2 — Networks and host-enforced VM isolation — Implemented

- **Files:** `terraform/network.tf`, `src/host/vmfw.py`,
  `src/host/files/nftables-vmfw.nft`, host config and bootstrap ordering.
- **Build:** three isolated site networks, routed WAN, fixed taps, bridge isolation,
  WAN restrictions, LAN HTTPS DNAT to fe-1. Python validates/loads only lab tables,
  then writes the boot-local marker. Preserve the current stateless bridge rules;
  the old plan's bridge conntrack description is not the implementation.
- **Accept:** syntax/load succeeds without flushing other tables; management peers and
  direct spoke-to-spoke traffic are blocked even without guest rules. Direct VM
  internet and WAN-to-host-service attempts fail; drops have observable counters.

### B04.3 — Disks, domains and cloud-init — Partial / Next

- **Files:** `terraform/compute.tf`, `cloud-init/*.yaml.tftpl`, `variables.tf`;
  runner/workflow configuration if persistent temporary storage is needed.
- **Build:** overlays, uploaded cloud-init seeds, fixed MAC/name/address mapping,
  user/public key and CA. Retain disabled autostart and intentional replacement when
  image or cloud-init content changes. Verify the current seed format against the pinned
  provider/libvirt before calling it complete.
- **Resolve:** the provider's local ISO is temporary, while replacement of its uploaded
  volume triggers disk replacement. Make artifact lifetime compatible with persistent
  Terraform state, for example a dedicated persistent runner-owned `TMPDIR`, and prove
  the result. Merely referring to the uploaded volume does not prove reboot safety.
- **Accept:** cloud-init finishes and SSH reaches all three management addresses;
  sizes, taps and routes match the table. An unchanged plan after reboot/workspace
  cleanup must not propose disk replacement. Deliberate seed changes affect only the
  intended VM; document that replacement loses that VM's local data.

### B04.4 — First apply, repeated apply and reboot — Implemented; live verification pending

- **Files:** `.gitea/workflows/terraform.yml`; bootstrap/runner integration as needed.
- **Build:** firewall marker and libvirt checks, locked initialization, automatic apply.
  Public key and CA files are the only Terraform inputs; no private-key Vault login
  belongs in this job.
- **Accept:** record first green apply, second no-change apply, refusal without the
  firewall marker, and reboot → `bootstrap.sh update` → recovered VMs without new
  disks. On an initialized lab, `up` is intentionally not the recovery command.

### B04.5 — Inventory and application DNS handoff — Partial

- **Files:** existing `terraform/inventory.tf`; create
  `ansible/inventory.terraform.yml`, `ansible/ansible.cfg`; extend CoreDNS config/rendering.
- **Build:** consume `ansible_host` resources through `cloud.terraform.terraform_provider`
  using absolute paths to the same Terraform project/backend. Add `app.lab.test` and
  `k3s.lab.test` records when their consumers are introduced.
- **Ownership:** proposed simplification for the current architecture: bootstrap owns
  CoreDNS records, using the detected host IP and fixed guest management IP. No pipeline
  writer into root-owned CoreDNS configuration is needed for these static addresses.
- **Accept:** `ansible-inventory --graph` lists frontend/hub/backend from state; names
  resolve from the required clients. LAN HTTPS reaches a temporary fe-1 listener;
  management-address HTTPS still reaches Traefik. Document the host-local app access path.

### B04.6 — Minimal tenant removal — Planned

- **Files:** implement `cmd_teardown()` in `src/__main__.py`; introduce
  `src/host/tenant.py` if orchestration needs separation.
- **Build:** stop new delivery from racing removal; use the existing runner identity,
  Terraform configuration and backend to destroy tenant resources while tools and state
  still exist. Make `destroy` perform this before deleting the runner or libvirt.
- **Accept:** Terraform removes VMs/networks/volumes; host services remain; repeat
  teardown is harmless. Define marker behavior explicitly: proposed behavior is to
  clear `state/initialized` only after successful tenant removal so `up` can rebuild.
  Current single-state Terraform also owns the base image/pool: preserving those needs
  an explicit state/layout decision, not a promise that ordinary `destroy` keeps them.

## Phase B05 — Controlled egress and Ansible base configuration

**Outcome:** jobs securely reach guests and install packages through the intended path.
**Legacy reference:** 2.2, 2.9, remaining 2.10, 6.1a–6.1b. **Dependency:** B04.

### B05.1 — Host firewall beyond the VM WAN — Planned

- **Files:** proposed `src/host/firewall.py`, `src/host/files/nftables-host.nft`;
  host config and `platform_up()`/`platform_down()`.
- **Build:** host input and management-routing policy, preserve operator SSH/DNS/time/
  Vault/gateway/proxy access, block management-to-LAN routing, handle published-container
  forwarding alongside current Podman/libvirt rules. Keep VM tables separately owned.
- **Accept:** positive and negative probes test both routed and bridged paths without
  breaking existing services. Record host-service reboot/restart behavior explicitly:
  the VM autostart guard alone does not protect independently restarting host containers.
  Keep Python loading as agreed; do not reintroduce the old VM-firewall unit.

### B05.2 — Squid — Planned

- **Files:** create `src/services/squid/squid.py`, `compose.yaml`, configuration and
  allowlist files; add DNS/bootstrap/removal wiring.
- **Build:** proxy on `10.250.0.1:3128`, management/host clients only, explicit domains,
  access logs and rotation. Add actual registry/download endpoints as consumers arrive.
- **Accept:** approved downloads succeed through Squid, an unapproved domain is denied
  and logged, and direct guest internet still fails. This precedes guest package installs.

### B05.3 — Pipeline AppRole and temporary SSH access — Planned

- **Files:** extend runner setup, Vault policies and AppRole configuration;
  `.gitea/workflows/ansible.yml`; an adjacent helper under `ansible/` only if necessary.
- **Build:** create `lab-pipeline` after the runner user exists; store credentials in
  runner-owned mode `0600` files. Jobs log in, fetch the SSH private key into a temporary
  directory, use per-job known_hosts, and clean up on success/failure. Keep unseal material
  and bootstrap credentials out of this identity.
- **Accept:** Ansible reaches each VM as `user`; pipeline authentication cannot read
  bootstrap secrets or rewrite policies; repeated setup preserves the SSH key. Prove
  credentials come from the runner path, not `vault.login()`'s root-only default.

### B05.4 — Common guest role — Planned

- **Files:** `ansible/playbooks/base.yml`, `roles/base/{tasks,handlers,templates}/`,
  group variables, `ansible.yml`; extend `deploy.yml` after Terraform.
- **Build:** wait for SSH/cloud-init; configure DNS, time, apt/runtime proxies and
  `no_proxy`; install guest-agent, nftables, WireGuard and required per-role packages.
  Keep unattended-upgrade behavior aligned with the pinned-image replacement model.
- **Accept:** packages install through Squid, Vault TLS verifies, no direct internet;
  second playbook run reports no unintended changes. A failed guest stops delivery.

### B05.5 — Guest firewall — Planned

- **Files:** role-specific nft templates/handlers under `ansible/roles/base/` and variables.
- **Build:** management host-only flows, WAN WireGuard/edge ports, future tunnel rules;
  be-1 forwarding must account for pod traffic and ServiceLB DNAT. Preserve k3s/runtime
  tables; persist guest rules with the guest's service management.
- **Accept:** management peers are blocked, required host services work, and permitted
  flows still work after reboot. Later cluster steps extend and retest these rules.

### B05.6 — Host SSH hardening — Planned

- **Files:** proposed `src/host/ssh.py`, managed sshd drop-in template, host configuration
  and baseline/removal wiring. **Additional dependency:** B01.2 and a verified operator key.
- **Build:** validate the operator login/key and effective sshd configuration before
  enabling key-only access and intended user/forwarding restrictions. Keep local console
  recovery available; omit the old CloudStack root-login exception. Validate before reload
  and provide rollback if a new connection fails.
- **Accept:** a new operator key-authenticated session works, password/unauthorized-user
  attempts fail, and removal restores the previous configuration. This returned to scope
  in the plan's November 14 decision despite its older optional-work entry.

## Phase B06 — WireGuard site-to-site path

**Outcome:** frontend reaches backend only through the hub's allowed tunnel flow.
**Legacy reference:** 6.2a–6.2b. **Dependency:** B05.

### B06.1 — Keys and tunnel configuration — Planned

- **Files:** `ansible/playbooks/tunnel.yml`, `roles/wireguard_hub/`,
  `roles/wireguard_spoke/`; extend the Ansible workflow.
- **Build:** generate private keys on guests and publish only public keys to Vault;
  configure hub after keys exist, then spokes. Use `wg0` frontend/hub and `wg1`
  backend/hub, `10.99.0.0/24` and `10.99.1.0/24`, UDP 51820/51821 on WAN.
  Keep endpoint/WAN/management ranges out of AllowedIPs; set spoke preferred source
  to its private VPC address. Use persistent systemd-managed tunnel configuration.
- **Accept:** both handshakes are current, reruns retain keys, and fe-1's route to
  `10.3.1.10` uses `wg0` with source `10.1.1.10`.

### B06.2 — Hub policy and isolation proofs — Planned

- **Files:** hub/spoke firewall templates and forwarding settings; network-check
  playbook under `ansible/playbooks/` for reuse by later verification.
- **Build:** allow fe-1 private IP → be-1 private IP TCP 8000 and replies; log/drop other
  transit; no tunnel NAT. Use a temporary listener before the application exists.
- **Accept:** allowed connection passes; SSH/Postgres through the hub fail; disabling
  either tunnel breaks the permitted connection with no WAN/management fallback.

## Phase B07 — Registry delivery, k3s, Flux and cluster identities

**Outcome:** a reproducible cluster that reconciles git and has explicit runtime identities.
**Legacy reference:** remaining 2.8/2.10, 8.1–8.2d. **Dependency:** B05;
build after B06 in the normal sequence, although cluster installation does not need the tunnel.

### B07.1 — Registry identities and image-build runtime — Planned

- **Files:** extend Gitea and runner modules, policies, DNS/trust configuration;
  add necessary tool pins/installers to `src/host/`.
- **Build:** registry publisher `lab-ci` and read-only repository user `lab-flux`,
  credentials in their planned Vault pipeline paths. Configure rootless Podman for the
  runner: subordinate IDs, runtime directory/service environment and required packages.
- **Accept:** runner builds/pushes a disposable image and pulls it by digest over TLS;
  Flux credentials clone the private repo but cannot push. No rootful Podman socket
  is needed for the image-build path.

### B07.2 — k3s installation and audit — Planned

- **Files:** `ansible/roles/k3s/`, `playbooks/cluster.yml`,
  `.gitea/workflows/cluster.yml`; audit policy/config templates; tool pins.
- **Build:** pinned k3s on be-1, Flannel on the private interface, node IP `10.3.1.10`,
  API SANs for management/name, Secrets encryption, bundled Traefik disabled,
  containerd proxy/CA configuration. Add bounded readiness and rotating API audit logs
  that record secret access metadata without secret bodies.
- **Accept:** node Ready; API TLS verifies; encrypted-at-rest check passes; pod DNS and
  approved egress work; guest firewall still blocks unintended node entry points.

### B07.3 — Initial Flux bootstrap and repository tree — Planned

- **Files:** `clusters/backend/{kustomization.yaml,kustomizations.yaml,flux-system/,platform/}`;
  k3s role bootstrap tasks; cluster workflow.
- **Build:** export pinned Flux controllers, initial source/root objects and TLS/auth
  Secrets on be-1 using its local admin configuration. Thereafter Flux owns manifests.
  Use `lab-flux` to read `main`; do not let bootstrap push generated commits.
- **Accept:** source and platform reconcile to the intended revision; a harmless hand
  edit is repaired; a wrong CA fails. Jobs wait for revision/readiness with a timeout.

### B07.4 — Chart publishing — Planned

- **Files:** cluster workflow; optional `clusters/publish-charts.py`; pinned chart
  inputs and `clusters/backend/platform/sources.yaml`.
- **Build:** fetch/check/publish required charts to Gitea OCI on the runner; configure
  Flux to consume the mirror with lab CA trust. Add charts when their phases need them.
- **Accept:** bad checksum stops publishing; an existing version is reused;
  Flux can fetch the intended chart version without external chart access.

### B07.5 — Vault/Kubernetes identities and runtime object contracts — Planned

- **Files:** `clusters/backend/platform/{access/,vault-auth.yaml}`;
  Vault policy files/configuration; k3s role and cluster workflow helpers.
- **Build:** Vault Kubernetes auth/reviewer and scoped `k3s-creds` token issuer;
  `lab-ci`, `lab-operator`, `lab-dbops` identities and probe namespaces. Deposit the
  node admin kubeconfig to the break-glass path with pipeline write-only access.
  Document which runtime Secrets/ConfigMaps jobs create and which VSO synchronizes.
- **Accept:** positive and negative RBAC checks match the plan; ordinary CI cannot
  read the break-glass credential or modify Flux policies. Initial admin work stays on
  the node; later jobs use scoped credentials. Confirm audit events for allowed/denied access.

## Phase B08 — Istio ambient and its policy boundary

**Outcome:** authenticated mesh transport and default-deny policy before application rollout.
**Legacy reference:** 8.3a–8.3c, 8.7h. **Dependency:** B07.

### B08.1 — Mesh installation — Planned

- **Files:** `clusters/backend/mesh/`, Gateway API CRDs under `platform/`,
  Flux Kustomization dependencies; extend cluster workflow readiness checks.
- **Build:** pinned base/istiod/CNI/ztunnel releases, k3s-specific CNI paths, Istio's
  separate built-in CA. Verify supported chart values when selecting pins.
- **Accept:** releases Ready, smoke workloads captured by HBONE, workload certificates
  chain to the mesh root and not the host CA. Record actual CNI paths and memory usage.

### B08.2 — STRICT transport, default deny and probes — Planned

- **Files:** mesh PeerAuthentication/AuthorizationPolicy manifests; probe playbooks or
  scripts beside their verification consumer.
- **Build:** STRICT for meshed workloads, mesh-wide allow-nothing, explicit ALLOWs as
  consumers arrive. Prove a same-node capture location before relying on packet evidence.
- **Accept:** non-mesh traffic is refused, unrelated mesh identities are refused, a
  named smoke flow passes, and capture shows HBONE. Do not claim every cluster component
  is meshed: ingress, operators and node agents have explicit exceptions below.

## Phase B09 — Database, API and frontend

**Outcome:** HTTPS UI → WireGuard-carried application mTLS → API → encrypted customer data.
**Legacy reference:** 8.4a–8.7h. **Dependency:** B06 and B08.

### B09.1 — Application images and scan gate — Planned

- **Files:** `app/api/`, `app/frontend/`, Dockerfiles, hash-pinned dependency files,
  `.gitea/workflows/app.yml`; scanner configuration and tool pins.
- **Build:** minimal health endpoints first, non-root/read-only-compatible containers,
  rootless build, scan before push, revision tags and deployed digests. Add a small
  helper beside `app/` only if workflow logic needs it.
- **Accept:** both images build/run/scan; a failing scan prevents publication/deployment;
  successful digests become the runtime `flux-system/app-images` ConfigMap.

### B09.2 — Database and VSO credential flow — Planned

- **Files:** `clusters/backend/operators/`, `apps/db/`, `gates/app/`,
  `apps/policies/`; `src/services/vault/policies/vso-db.hcl`; app workflow.
- **Build:** one-instance CNPG PostgreSQL 16, schema/grants, small local-path PVC;
  no superuser network login; only app SELECT/INSERT privileges. Create `kv/app/db`
  once, configure VSO to sync it, and let CNPG manage the login password.
  Gate dependent resources on required runtime objects; bootstrap writes policy bodies.
- **Accept:** database healthy, VSO/CNPG agree on the password, wrong passwords fail,
  app cannot update/delete/create tables. Keep 5432 STRICT/api-only; if CNPG status
  8000 needs its planned TLS exception, isolate and prove that exception.

### B09.3 — API with Vault Transit — Planned

- **Files:** API code, `clusters/backend/apps/app/`, API ALLOW policy,
  `src/services/vault/policies/api.hcl`; Vault role/key setup in app delivery.
- **Build:** projected-token Vault login/refresh, create-once `customers` Transit key,
  DB credential lookup/retry, parameterized SQL, `/healthz`, GET/POST `/customers`.
  Encrypt card numbers before inserts; return only masked last-four values.
- **Accept:** SQL stores `vault:v...` ciphertext, UI/API responses are masked, unrelated
  identities cannot access DB or Transit, and token/password refresh works without
  printing credentials or card data.

### B09.4 — Certificate handoff and backend gateway — Partial

- **Files:** extend bootstrap Vault publication for existing PKI leaves;
  `clusters/backend/apps/ingress/`, policies and runtime TLS Secret delivery.
- **Build:** publish `backend-gw`, `frontend-client`, `app-edge` leaf bundles in
  `kv/lab/pipeline/tls/*` without CA private keys. Configure backend listener 8000 with
  client authentication using the application root; ingress namespace outside ambient,
  gateway-to-API explicitly authorized. Validate mutual-TLS syntax at the selected pin.
- **Accept:** intended frontend certificate succeeds; missing/wrong-root certificates
  fail. Only tunnel-origin traffic reaches backend 8000; WAN/management and ServiceLB
  status-port bypasses are blocked. tun-1 sees TLS records, not HTTP or card data.

### B09.5 — Frontend and public TLS — Planned

- **Files:** frontend application/templates, Caddyfile/quadlets,
  `ansible/roles/frontend/`, frontend playbook and app workflow integration.
- **Build:** Caddy on fe-1:443 and frontend on loopback:8080; images by digest; frontend
  presents its client certificate and trusts only the application root for backend
  requests. It holds no Vault credential or database driver. Install edge TLS and
  reload Caddy when certificate content changes.
- **Accept:** LAN HTTPS through host DNAT serves the UI, add/list round-trip works,
  frontend loopback port is not exposed, and repeat delivery causes no unnecessary restart.

## Phase B10 — Observability and operator consoles

**Outcome:** measured infrastructure/application health and usable trusted consoles.
**Legacy reference:** 2.5b, 2.7b, 3.5c, 8.8a/b/d. **Dependency:** B09 for full monitoring;
host/VM metrics can be brought forward after B05 if a review needs them first.

### B10.1 — Host telemetry services — Planned

- **Files:** `src/services/{prometheus,loki,grafana}/` modules, Compose/config/provisioning;
  Traefik routes/middlewares, CoreDNS names, bootstrap wiring and Vault credentials.
- **Build:** bounded host storage/retention, Grafana datasources/admin, be-1-only
  authenticated telemetry write routes; query access through Grafana. No MinIO dependency.
- **Accept:** healthy datasources; unauthorized writes and direct query routes fail;
  approved writes work; memory/disk usage fits the budget. Include host/VM node metrics
  without creating a second duplicate exporter on be-1 when cluster monitoring arrives.

### B10.2 — Cluster metrics, logs and audit shipping — Planned

- **Files:** `clusters/backend/monitoring/`, `gates/monitoring/`,
  `monitoring/node-agents/`, VSO policy/role and monitoring workflow.
- **Build:** pinned k8s-monitoring/Alloy, constrained RBAC, VSO write credentials,
  explicitly allowed mesh scrapes, node-exporter and restricted audit-log reader.
  Keep operator/node-agent exceptions documented; validate rendered chart permissions.
- **Accept:** expected metrics, pod logs/events and audit events arrive; collectors
  cannot read arbitrary Secrets; write-path negative checks pass; resource limits fit be-1.

### B10.3 — Dashboards, host trust and console access — Planned

- **Files:** `observability/dashboards/`, Grafana provisioning and dashboard sync;
  proposed `src/host/trust.py`, console setup in each service module;
  `docs/runbook.md`, `docs/capacity.md`.
- **Build:** infrastructure, mesh-denial, API and log dashboards; host/browser trust
  for the lab CA; Vault/Gitea/Grafana logins and credential-location instructions.
  Gitea admin already exists; Vault userpass and Grafana setup do not.
- **Accept:** browser TLS without bypass, intended admin logins, no LAN console exposure,
  dashboards show current data. Record any absent metrics instead of accepting empty panels.

## Phase B11 — Repeatable verification and operator handoff

**Outcome:** a delivery run proves the implemented requirements with useful failure evidence.
**Legacy reference:** Phase 12, 10.2, 14.4. **Dependency:** checks grow from B04 onward;
full acceptance follows B10. Do not wait until this phase to test earlier steps.

### B11.1 — Verification runner and workflow — Planned

- **Files:** proposed `verify/` scripts/playbooks grouped by network, application and
  observability; `.gitea/workflows/verify.yml`; append to `deploy.yml`.
- **Build:** reuse earlier acceptance probes, explicit PASS/FAIL and evidence, nonzero
  exit on failure. Use scoped API identities and SSH only where needed. Keep helper
  code here rather than inventing one Python orchestration module per pipeline stage.
- **Accept:** broken tunnel, wrong authorization and unhealthy workload each fail the
  relevant check; scratch probes clean up; verification does not rotate/delete live keys.

### B11.2 — Change, drift and recovery evidence — Planned

- **Files:** workflow checks and `docs/runbook.md` evidence links.
- **Build/prove:** malformed change blocks delivery; corrected update succeeds; unchanged
  Terraform/Ansible converge without unintended work; application change deploys a new
  digest; Flux repairs drift; reboot recovers through `update` after firewall/unseal.
- **Accept:** record commit/run IDs for these scenarios and measured capacity, not only
  a green formatting job. Document that local host convergence precedes the CI gate;
  pipeline failure does not roll back host changes.

### B11.3 — Documentation that matches the built lab — Planned

- **Files:** `README.md`, `docs/runbook.md`, capacity document and existing diagrams;
  update this file's statuses.
- **Build:** actual prerequisites/commands, console and key-recovery procedures,
  credential locations, reboot/update behavior, destructive disk-replacement caveat,
  evidence links and unresolved scope. Resolve README conflict markers and obsolete
  CloudStack/command/resource instructions. Update diagrams from actual code.
- **Accept:** a reader can follow the current lab without being sent to missing files
  or old commands; no secrets are included; implemented and deferred requirements are explicit.

## Phase B12 — Complete teardown, destroy and restoration

**Outcome:** removal respects dependencies and leaves a demonstrably restored host.
**Legacy reference:** Phase 13 and §14, translated to libvirt. **Dependency:** B01.2,
B04.6; extend removal with every later service. Capture evidence before destructive tests.

### B12.1 — Full tenant cleanup — Planned

- **Files:** tenant orchestration introduced in B04.6; local bootstrap/Vault helpers.
- **Build:** serialize against CI; suspend Flux before deleting its objects; remove
  database/workloads before their operators/finalizers, then cluster integrations and
  tenant Vault entries. Keep SSH/admin/state available until their last consumer finishes.
  Finally destroy Terraform resources; delete state only after successful removal.
- **Accept:** repeat teardown succeeds, host platform remains available, agreed rebuild
  command restores the tenant, and a failed deletion leaves enough state to retry.

### B12.2 — Host cleanup and restoration — Partial

- **Files:** `platform_down()` and every host/service `down()`; baseline restore helpers.
- **Build:** stop runner execution but retain the identity/tools until tenant removal is
  done; then remove services, lab networks/files/packages/users and trust; restore prior
  DNS/network/time state. Tie Vault key deletion to confirmed data deletion. Preserve
  unrelated host resources according to B01.2's ownership contract.
- **Accept:** cleanup works after full and partial installs. Do not treat the current
  `destroy complete` message as proof: its implementation does not yet meet this contract.
  A host used for old CloudStack experiments needs separate verified legacy cleanup or
  a clean snapshot; that migration is not part of a new-host install.

### B12.3 — Post-removal proof — Planned

- **Files:** proposed `src/host/revert.py`, destroy wiring, runbook/evidence.
- **Build:** compare packages/sources, network, services, users/trust and lab files to
  baseline after removal and reboot. Keep baseline/evidence when a check fails.
- **Accept:** checks pass on a disposable full build, repeated removal is harmless,
  original connectivity returns, and a subsequent fresh build succeeds. Only then mark
  requirement R4 verified.

## Deferred phase B13 — Backup, restore and key-loss demonstration

**Status: Deferred, not a hidden dependency.** The old plan explicitly cut live R3
drills from the review build. Keep their implementation path here so the requirement
is not mistaken for complete. Enable this phase when scope is expanded.

| Step | Files to build | Outcome and acceptance |
|---|---|---|
| B13.1 — Backup | `backup/` helper(s), `.gitea/workflows/backup.yml`, runner-owned backup directory setup | Pair a Vault Raft snapshot with a PostgreSQL dump and relevant Terraform state; verify readable/nonempty backup formats; keep unseal material separately. |
| B13.2 — Database restore | Restore helper/playbook and dispatch workflow | Fresh backup, controlled database recreation and restore; restored rows decrypt; record counts and avoid a routine deploy triggering the drill. |
| B13.3 — Vault DR | Local root-owned orchestration for isolated scratch Vault/Postgres | Restore snapshot with original recovery material and decrypt a known canary; never expose the unseal key to CI. |
| B13.4 — Crypto-shredding | Extend scratch DR drill | Delete only the scratch Transit key; decryption fails while live data/key remain untouched; clean up scratch resources. |
| B13.5 — Schedules | `.gitea/workflows/schedules.yml` | Only after backup/verify work: scheduled runs with concurrency coordinated against delivery and teardown. |

## Other deferred or excluded work

| Work | Treatment |
|---|---|
| CloudStack, its system VMs/DB/NFS/accounts | Excluded. Do not restore old phase dependencies. |
| MinIO/S3 Terraform backend, Packer golden images | Optional future architecture, absent from the core path. |
| Conftest policy-as-code | Deferred until core delivery is proven. Add a saved plan → JSON → policy → apply-the-same-plan sequence if enabled. |
| PR gate and protected main | Explicitly excluded for the agreed single-operator flow. |
| Tracing/Tempo, public-image mirroring, AD/SSO, admission/signing layers | Optional extensions after capacity is measured. |
| Broad unit-test framework and extra CLI commands | Not prerequisites. Use focused checks and acceptance evidence appropriate to each step. |

## Requirement and evidence map

These IDs refer to the legacy verification catalog, not to already-written tests.
Adapt their wording to the current architecture when implementing B11.

| Requirement | Build steps | Proof to retain |
|---|---|---|
| R1 — VPC simulation and VPN | B04–B06 | N1–N6: isolation, controlled egress, hub-only path, tunnel-down failure, actual runner identity. |
| R2 — Database/encryption and secure application | B02, B07–B09 | E1–E3, T1–T3, Z1–Z2, P1–P5, S1–S4, K1, A1; scratch keys for rotation tests. |
| R3 — Backup/restore/key loss | Deferred B13 | B1–B3 only after real drills. A design walkthrough is not a passed recovery test. |
| R4 — Reversibility | B01.2, B04.6, B12 | V1–V5 against actual baseline and current lab-owned resources. |
| R5 — Pipeline and GitOps | B03–B04, B07, B11 | Failed check, corrected delivery, no-change update, revision/digest and Flux drift proof. Old PR-only G1 and scheduled G3 do not apply to current scope. |
| R6 — Observability | B10 | O1–O5: metrics/logs, denials, audit trail and protected write paths. |
| R7 — Consoles | B02.5, B03.1, B10.3 | C1 for Vault, Gitea and Grafana. CloudStack/MinIO consoles are excluded. |

Drop old H2 CloudStack health checks; use libvirt/VM/cloud-init readiness instead.
Do not equate `libvirt` group membership with a strong host security boundary; the
single trusted infrastructure owner is the accepted model. Kubernetes/Vault policy
checks still prove the intended behavior of those particular credentials.

## Session handoff

Replace this block as work progresses:

- **Current milestone:** B04, repeatable Terraform delivery from CI.
- **Last evidence:** repository analysis plus prior mocked run-following checks; no
  fresh full deployment certified by this document.
- **Next step:** B04.1 state-directory implementation, with B01.1–B01.2 completed
  before clean-build/destructive acceptance is claimed.
- **Open checks:** seed format and persistent artifacts, repeat/reboot apply,
  inventory consumption, minimal tenant teardown.
- **Working-tree boundary:** this document was added without modifying existing code,
  workflows, Terraform changes or `PLAN-enterprise.md`.
