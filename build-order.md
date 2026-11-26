# Lab build order (walkthrough)

This document walks the lab from start to finish so that you can understand every piece of it: what runs, in which order, which file and which function does the work, what each piece leaves behind for the next one, and why it sits where it sits. It is meant for reading the existing code, not for writing new code. It describes the code at commit `0af7956` (2026-11-25), and every `file:line` citation refers to that commit. It replaced the previous version of this file on 2026-11-26. That version mixed the current design with dated history (which run proved what, in which order the features were built, the verification evidence); it stays in git history (`git show 0af7956:build-order.md`). The decisions that shaped the lab, including the designs that were dropped, are summarized in Appendix A. Appendix B lists the repo documents that still describe an older build. Appendix C lists changes that were reviewed and agreed but are **not applied** yet; each one is also marked in the step it touches with a `Marked change (not applied)` note.

## How to read this

The lab is walked as 13 phases (0 to 12), in the order the code runs; the two places where the walk departs from that order (monitoring in Phase 3, k8s-monitoring in Phase 10) say why. Each phase is split into numbered steps (`Step N.k`), each step names the files it introduces, and each file is broken into the functions or units it defines, in the order you should read them. A step numbered `N.0` holds the settings or the pattern that the rest of its phase shares. Every phase opens with a paragraph on what it does and when it runs, then **Needs from earlier phases** (what must already exist) and **Hands on** (what the phase leaves for the later ones). Every step then has the same fields: **Files**; a **Build, in this order** table (unit, what it does, who calls it and what it calls, what it reads or writes on the system); **Why here** (why the step sits at this point in the order); **How it connects** (the links to earlier and later steps); **Re-run and removal** (what a second run does, and which `down()` or command removes it); **Check it yourself** (read-only commands to see the result on a running lab; `(sudo)` marks the ones that need root, and `ssh <vm> sudo ...` uses the VMs' passwordless sudo); and **Watch out** (pitfalls, hand-copied values and known limitations). Paths are relative to the repo root, and commands assume you are in it. "`platform_up` step N" is the Nth call in `platform_up()` (`main.py:32-47`). The Reference at the end collects what spans many steps: the hand-copied values (R1), the Vault credential flow (R2), every external download (R3), what rebuilds a VM (R4), the order rules (R5) and the security boundaries (R6).

**Phase map:**

| Phase | Steps | Runs when | Main files |
|---|---|---|---|
| 0 Orientation | 0.1 | Nothing runs: read before Phase 1 (Appendix B after Phase 11) | `README.md`, `docs/diagram/hld/`, `docs/three-vpc-design.md` |
| 1 Entry: shell shim, Python entry, shared library, commit | 1.1-1.7 | Every `sudo ./bootstrap.sh <command>`, before `platform_up` step 1; the commit only for `up` and `update` | `bootstrap.sh`, `main.py`, `lib/log.py`, `lib/config.py`, `lib/system.py`, the `__init__.py` files, `.gitignore` |
| 2 Host base | 2.0-2.7 | `platform_up` steps 1-7, on every `up`, `update` and `teardown`; their `down()`s in `destroy` | `host/*.py`, `host/config/config.py`, `host/files/`, `podman/` |
| 3 Host services | 3.0-3.10 | `platform_up` steps 8-12 and 14 | `services/coredns/`, `services/squid/`, `lib/pki.py`, `lib/cfssl/`, `services/vault/`, `services/traefik/`, `services/monitoring/` |
| 4 CI platform | 4.1-4.10 | `platform_up` steps 13, 15 and 16 | `services/gitea/`, `host/ssh_access.py`, `host/files/60-lab-ssh.conf`, `services/gitea/runner/` |
| 5 Trigger and first pipeline jobs | 5.1-5.6 | The command tail after `platform_up` (push or dispatch, then follow the run); `deploy.yml` jobs `check` and `image` on the host runner | `main.py` (`cmd_*` tails), `services/gitea/gitea.py`, `.gitea/workflows/deploy.yml`, `check.yml`, `image.yml`, `frontend/` |
| 6 Terraform | 6.1-6.8 | `deploy.yml` job `terraform` (`terraform.yml` job `apply`) | `.gitea/workflows/terraform.yml`, `terraform/` |
| 7 Ansible VM base | 7.1-7.5 | `deploy.yml` job `ansible` (`ansible.yml` job `configure`): plays 1 and 2 of `ansible/site.yml` | `.gitea/workflows/ansible.yml`, `ansible/ansible.cfg`, `inventory.yml`, `site.yml`, `group_vars/`, `host_vars/`, roles `vm_ready`, `common`, `wireguard` |
| 8 Cluster and GitOps on be-1 | 8.1-8.7 | Play 3 (be-1), with Flux Kustomizations `lab-cnpg` and `lab-apps` applying in between | roles `k3s`, `fluxcd`, `app_secrets`, `app_deployed`; `kubernetes/cnpg/`, `kubernetes/apps/` |
| 9 App edge on fe-1 | 9.1-9.2 | Play 4 (fe-1); then every request to the app | role `frontend`; `frontend/` |
| 10 Observability | 10.1-10.3 | Play 5 (all VMs); Flux Kustomization `lab-monitoring` (from Step 8.2 on); the host side built in Phase 3 | role `alloy`, `kubernetes/monitoring/` |
| 11 Runtime paths and demo | 11.1-11.4 | After a green `deploy` run; the operator runs `demo/load.sh` by hand | `demo/load.sh` (the rest is read again along each path) |
| 12 Lifecycle | 12.1-12.3 | `teardown` (`teardown.yml`), `destroy` (`platform_down`), and the operating rules for reboots, LAN IP changes, edits and re-runs | `.gitea/workflows/teardown.yml`, `main.py`, every `down()` |
| Reference | R1-R6 | | |
| Appendix A | | | Decisions and dropped designs |
| Appendix B | | Nothing runs: read after Phase 11 | Documents that describe an older build: `docs/diagram/lld/` |
| Appendix C | C1-C11 | Nothing runs: changes marked, not applied | Pending changes and where they are marked |

## Phase 0: Orientation

No code runs in this phase. It is the map you carry through the rest of the walk: what the lab is, one picture of the host, the three VMs, their networks and services, the order in which `main.py` builds the host (the table of contents for Phases 2 to 4; the command tail, the jobs and the plays continue in Phases 5 to 10), and which documents in the repo no longer match the code. Read Step 0.1 before Phase 1. Some repo documents (parts of `README.md`, the HLD, the two LLD pages) no longer match the code; Step 0.1's Watch out and Appendix B list where. Rely on this walk and the code. Read Appendix B after Phase 11, when you can see for yourself where those documents are wrong. After this phase you should be able to name every box in the picture and the phase that builds it.

**Needs from earlier phases:**
- Nothing.

**Hands on:**
- The names used everywhere: host bridge `mgmtbr1` 10.250.0.1/24, libvirt networks `wan` (198.51.100.0/24), `site-a`, `site-hub`, `site-c`, VMs `fe-1`, `tun-1`, `be-1`, and the DNS zone `lab.test`.
- The 16 `platform_up` steps (`main.py:30-47`) as the table of contents for Phases 2 to 4. The command tail, the pipeline jobs and the Ansible plays follow them in Phases 5 to 10.
- A list of documents to correct or ignore: parts of `README.md` and gaps in the HLD (Step 0.1), and the two LLD pages (Appendix B).

### Step 0.1: What the lab is meant to be

**Files:**
- `README.md`: the front page. Purpose, VM address table, usage, folder map, where files live.
- `docs/diagram/hld/overall-architecture.md`: the high-level picture, described in words.
- `docs/diagram/hld/overall-architecture.drawio`: the high-level picture itself (draw.io).
- `docs/three-vpc-design.md`: the design record for the three-VPC topology. It says itself that it is a design and does not claim the topology is deployed (`:3-4`).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `README.md:1-16` intro and VM table | One Ubuntu 24.04 host builds and changes a small private cloud through a pipeline. The VM table (fe-1, tun-1, be-1 with site, wan and mgmt addresses) matches `terraform/compute.tf:5-40`. | First page a reader opens -> links `build-order.md` (`:18`) and `docs/` (`:74-75`) | Nothing (documentation) |
| 2 | `README.md:21-57` Host, Usage, Pipeline, Repository layout | Host size, the commands, the pipeline and the folder map. Several lines are stale (see Watch out). | Reader | Nothing |
| 3 | `README.md:59-75` Where things live, Docs | Where the CA, the Vault init files, the tfstate and the log live, plus the web UI addresses. Matches the code. | Reader -> `docs/three-vpc-design.md`, `docs/diagram/` | Nothing |
| 4 | `overall-architecture.md` | Sections Outside the host, Host, Podman, Host services, KVM/libvirt and VPC (`:6-67`), one table per box of the drawing (`:3`). Mostly right, with gaps (see Watch out). | Companion to the `.drawio` | Nothing |
| 5 | `overall-architecture.drawio` | The HLD drawing. It has a PKI box and no box for the monitoring stack. | Opened in draw.io | Nothing |
| 6 | `three-vpc-design.md` | The decision (three VMs, each its VPC's VPN endpoint, `:6-18`), topology, address plan, WireGuard routing, firewall ownership, files to change and acceptance tests (`:20-330`). It is the intent behind the code. Names and sizes differ from what was built (see Watch out). | Linked from `README.md:74` | Nothing |

**Picture (what the code at HEAD builds):**

```text
  LAN browser --https://app.lab.test--> HOST_IP:443 --nft DNAT--> fe-1 198.51.100.11:443
  (CoreDNS answers app.lab.test with HOST_IP)   Internet: host traffic only; VMs via Squid
+-- host: Ubuntu 24.04 + KVM, driven by `sudo ./bootstrap.sh <command>` -----------------+
| systemd   chrony :123 | libvirtd | lab-runner (Gitea Actions runner, label host, root) |
| nftables  bridge lab_sg (per-VM security groups) + inet lab_vmfw (DNAT, host filter)   |
| Podman    CoreDNS :53 | Squid :3128 | Vault :8200 | Traefik :443 -> Gitea, Grafana,    |
|           Prometheus, Loki | host Alloy                                                |
| files     <repo>/state (log, lock, marker, pki) | /var/lib/lab (tfstate, VM disks,     |
|           runner home, image tarball, Vault init files)                                |
| bridges   mgmtbr1 10.250.0.1/24 (host-only) | wan 198.51.100.1/24 (libvirt, routed)    |
|           site-a, site-hub, site-c (libvirt, isolated; no host address on them)        |
+-------------+------------------------------+------------------------------+------------+
              |                              |                              |
+-------------+------------+   +-------------+------------+   +-------------+------------+
| fe-1   1 vCPU, 1 GiB     |   | tun-1  1 vCPU, 512 MiB   |   | be-1   2 vCPU, 4 GiB     |
| eth0 site-a 10.1.1.10    |   | eth0 site-hub 10.2.1.10  |   | eth0 site-c 10.3.1.10    |
| eth1 wan  198.51.100.11  |   | eth1 wan  198.51.100.12  |   | eth1 wan  198.51.100.13  |
| eth2 mgmt 10.250.0.110   |   | eth2 mgmt 10.250.0.111   |   | eth2 mgmt 10.250.0.112   |
| frontend container       |   | WireGuard hub            |   | k3s: Traefik :8000       |
|  Flask/gunicorn :443     |   |  wg0 :51820 (fe-1)       |   |  -> Ingress -> PostgREST |
|  (Podman Quadlet)        |   |  wg1 :51821 (be-1)       |   |  -> CNPG pg, 2 instances |
| Alloy agent              |   | Alloy agent              |   | Flux pulls lab/lab       |
|                          |   |                          |   | Alloy, k8s-monitoring    |
+-------------+------------+   +-----+--------------+-----+   +-------------+------------+
              |  wg0 10.99.0.0/24    |              |  wg1 10.99.1.0/24     |
              +----------------------+              +-----------------------+
  Each VM: eth0 on its own site bridge, eth1 on wan, eth2 on mgmtbr1.
  Both tunnels are UDP over wan to tun-1 198.51.100.12 (:51820 for fe-1, :51821 for be-1).
  App call: fe-1 (src 10.1.1.10) -> wg0 -> tun-1 (only tcp 8000) -> wg1 -> 10.3.1.10:8000
  VM -> host, mgmt only: DNS 53, NTP 123, Squid 3128, Traefik 443 (Alloy push, Flux pull)
  host -> VM: SSH over mgmt (Ansible from the runner; the operator's `ssh fe-1`)
```

Sources for the picture: networks `terraform/network.tf:1-62`; VM sizes and addresses `terraform/compute.tf:5-40`, NICs `:146-165` named eth0-eth2 by `terraform/cloud-init/network-config.yaml.tftpl:3-19`; DNAT `host/files/nftables-vmfw.nft:118-129`; VM-to-host rules `:155,175-176`; ports `services/*/compose.yaml`, `services/coredns/conf/Corefile:2-8`, `services/squid/conf/squid.conf:4`; Traefik routes `services/traefik/dynamic/*.yml`; tunnels `ansible/host_vars/*.yml`, `ansible/roles/wireguard/templates/wg.conf.j2:17-18`; hub filter `ansible/roles/wireguard/files/hub-forward.nft:13`; k3s Traefik on 8000 `ansible/roles/k3s/files/traefik-config.yaml:9-15`; Ingress and CNPG `kubernetes/apps/db/postgrest.yaml:52-81`, `postgres.yaml:2-6`; frontend `ansible/roles/frontend/templates/frontend.container.j2:7-9`, `frontend/Dockerfile:14`.

**Table of contents (`platform_up`, `main.py:30-47`, then the rest of a run):**

| # | Call | What it leaves behind | Walkthrough |
|---|---|---|---|
| 1 | `preflight.up()` `:32` | Nothing. It refuses a host without read/write `/dev/kvm` and logs the LAN card and address. | Step 2.1 |
| 2 | `network.up()` `:33` | Bridge `mgmtbr1` 10.250.0.1/24 from `/etc/netplan/60-lab-mgmtbr1.yaml`, plus a `~lab.test` DNS route | Step 2.2 |
| 3 | `ntp.up()` `:34` | chrony, serving time on 10.250.0.1 to 10.250.0.0/24 | Step 2.3 |
| 4 | `podman.up()` `:35` | Podman 6 from the pinned alvistack repo, `docker-compose-v2` from Ubuntu's archive, `podman.socket` | Step 2.4 |
| 5 | `kvm.up()` `:36` | QEMU/KVM and libvirt, `qemu:///system` answering | Step 2.5 |
| 6 | `vmfw.up()` `:37` | nft tables `bridge lab_sg` and `inet lab_vmfw` (reloaded every run), marker `/run/lab/vmfw.loaded` | Step 2.6 |
| 7 | `toolchain.up()` `:38` | Terraform, ansible-core with `cloud.terraform`, Node, Trivy | Step 2.7 |
| 8 | `dns.up()` `:39` | CoreDNS for `lab.test` on 10.250.0.1 and the LAN address | Step 3.1 |
| 9 | `squid.up()` `:40` | Allowlist proxy on 10.250.0.1:3128 | Step 3.2 |
| 10 | `certs_changed = pki.up()` `:41` | Lab CA plus the leaves `vault`, `gateway` and `app-edge` in `state/pki/`, and a flag saying whether any were new | Step 3.3 |
| 11 | `vault.up(certs_changed)` `:42` | Vault on 10.250.0.1:8200, initialized, unsealed, with AppRoles and KV seeds | Steps 3.4-3.7 |
| 12 | `traefik.up(certs_changed)` `:43` | HTTPS gateway on 10.250.0.1:443 | Step 3.8 |
| 13 | `gitea.up()` `:44` | Gitea with admin, org and repo `lab/lab`, runner token, Actions secrets, Flux token | Steps 4.1-4.5 |
| 14 | `monitoring.up()` `:45` | Prometheus, Loki, Grafana and the host's Alloy | Steps 3.9-3.10 |
| 15 | `ssh_access.up()` `:46` | Operator key `~/.ssh/lab_operator` and ssh aliases `fe-1`, `tun-1`, `be-1` | Step 4.6 |
| 16 | `runner.up()` `:47` | `lab-runner.service` (gitea-runner, label `host`) | Steps 4.7-4.10 |
| tail | `cmd_up` `:75-78`, `cmd_update` `:87-88` | Push the commit (or dispatch), then follow the run until it ends | Steps 5.1-5.3 |
| jobs | `.gitea/workflows/deploy.yml:12-24` | check -> image -> terraform -> ansible, all on the runner | Steps 5.4-5.6, Phases 6-7 |
| plays | `ansible/site.yml:1-33` | 1 inventory check, 2 vm_ready/common/wireguard, 3 k3s/fluxcd/app_secrets/app_deployed on be-1, 4 frontend on fe-1, 5 alloy on all VMs | Phases 7-10 |
| after | | Request, control and telemetry paths; teardown, destroy, reboot | Phases 11-12 |

**Why here:** You need the names and the overall shape before any code. Every later step builds one box or one line of the picture, and the table of contents tells you which step that is.

**How it connects:**
- The VM address table (`README.md:12-16`) holds the same data as `terraform/compute.tf:5-40` (Step 6.5) and the ssh aliases in `host/files/60-lab-ssh.conf:14-21` (Step 4.6). These copies are kept in sync by hand.
- Each of rows 1-16 maps to one or more of Steps 2.1 to 4.10 (see the Walkthrough column). Steps 2.0 and 3.0 hold the settings their phase shares. Only monitoring (row 14) is read out of order, in Phase 3, because it does not depend on Gitea and Gitea does not depend on it.
- Section 6 of `three-vpc-design.md` is the intent behind `host/files/nftables-vmfw.nft` (Step 2.6) and the hub filter on tun-1 (Step 7.5).

**Re-run and removal:** Nothing runs. A doc edit is still a commit, though: `update` commits it (Step 1.7), and the push starts a full `deploy.yml` run, because the workflow triggers on every push to main and has no path filter (`.gitea/workflows/deploy.yml:3-6`).

**Check it yourself:**
- `sed -n 30,47p main.py`: the 16 calls in the order of the table.
- `ip -br link show type bridge`: `mgmtbr1` is always there. `wan`, `site-a`, `site-hub` and `site-c` exist while the Terraform networks exist.
- `virsh -c qemu:///system list --all` (sudo, or as a member of the libvirt group): fe-1, tun-1 and be-1.

**Watch out:**
- Stale lines in `README.md`:
  - `:5-7`: the platform list leaves out Squid and the monitoring stack, although both are `platform_up` steps (`main.py:40,45`).
  - `:28`: "Always run as root". `bootstrap.sh:14-15` refuses a root shell that has no `SUDO_UID`. Run `sudo` from your own account.
  - `:31-33`, `:46`: only `up|update|destroy`. `teardown` also exists (`main.py:111`).
  - `:39-40`: the pipeline is given as check -> terraform -> ansible. `deploy.yml:13-24` also has `image`, and `README.md:56` gets that right.
  - `:50`: says every service folder has a `config/`. Only gitea, gitea/runner and monitoring have one. Vault's settings live in `lib/config.py:41-46`, Squid's at the top of `services/squid/squid.py:11`.
  - `:54`: the `kubernetes/` description leaves out `cnpg/`.
- Gaps in `overall-architecture.md`:
  - The Podman table (`:26-32`) has no Prometheus, Loki, Grafana or Alloy.
  - Traefik is said to route only `gitea.lab.test` (`:28`). It also routes grafana, prometheus and loki (`services/traefik/dynamic/*.yml`).
  - PKI is listed as a systemd service (`:43`). It is a set of files that `pki.up` makes once (Step 3.3).
  - The VMs are said to reach "DNS and Squid" on 10.250.0.1 (`:53`). They also reach NTP and Traefik 443 (`host/files/nftables-vmfw.nft:155,175-176`).
  - The `.drawio` has the same gaps.
- `three-vpc-design.md` is a record of the plan, not of the build:
  - It names the networks vpc-east/vpc-hub/vpc-west (`:37,58-60`). The code calls them site-a/site-hub/site-c (`terraform/network.tf:2,15,28`).
  - Its VM sizes (`:104-105`) differ from `terraform/compute.tf:5-6,18-19,31-32`.
  - It plans the tables `inet lab_vpc` and `bridge lab_vpc_l2` (`:161-162`). The code has `bridge lab_sg` and `inet lab_vmfw` (`nftables-vmfw.nft:13,115`).
  - It plans `host/vpc.py` and `host/files/nftables-vpc.nft` (`:255-256`). The code has `host/vmfw.py` and `host/files/nftables-vmfw.nft`.
  - It plans an API name `api.backend.lab.test` (`:135`). The frontend defaults to the IP `10.3.1.10:8000` (`frontend/app.py:10`), and the Corefile has no such name.

> **Marked change (not applied), C11:** Update the stale parts of `README.md` and the HLD listed in this step's Watch out, and the LLD pages in Appendix B (or delete the LLD pages and point to Phase 8 and Step 11.1). See Appendix C.

## Phase 1: Entry: shell shim, Python entry, shared library, commit

This phase is the code that runs on every `sudo ./bootstrap.sh <command>` before the first host step. The shell shim checks sudo and Python and hands over to `main.py`. `main.py` parses the command, starts logging, takes a single-run lock and dispatches. Behind it sit the shared library (`lib/config.py`, `lib/log.py`, `lib/system.py`) and the package layout that makes the imports work. Last comes the command gate: `up` refuses an initialized lab, `update` and `teardown` refuse a fresh one. For `up` and `update`, the gate is followed by `gitea.commit_changes()`, which commits the working tree as the operator before `platform_up` step 1. Afterwards you have a root Python process that holds `state/run.lock`, logs to the console and to `state/bootstrap.log`, and (for up/update) a local commit that is exactly the tree the host steps are about to apply.

**Needs from earlier phases:**
- Phase 0: only the mental model.
- From outside the repo: an Ubuntu 24.04 host (`/dev/kvm` is checked later, Step 2.1); an operator account with sudo; `git`, and a clone owned by the operator (no step installs git); `python3` >= 3.12 (24.04 ships 3.12); internet access for apt.

**Hands on:**
- A root process, started in the repo root, with `SUDO_UID`/`SUDO_GID` in its environment (used by Step 1.7 and Step 4.6).
- `state/` (created by root), `state/bootstrap.log` (appended every run), `state/run.lock` (held for the whole run).
- `lib.config` constants (bridge, VM network, paths, Compose socket, PKI table, Vault endpoint) used by Phases 2-4.
- `lib.system` helpers (`ip_json`, `apt_install`, `apt_purge`, `missing_packages`, `systemctl_ok`, `write_file`, `install_file`, `compose`) used by every host step and service.
- The marker `state/initialized`. It is read here, touched by `cmd_up` in Step 5.1 and removed by `cmd_destroy` in Step 12.2.
- A local commit `HEAD` equal to the applied tree. Step 5.2 pushes it to Gitea's main.

### Step 1.1: Shell shim

**Files:**
- `bootstrap.sh`: the only command the operator types. It checks the caller and Python, then `exec`s `python3 -B main.py <args>` from the repo root.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Shell options and globals | `set -euo pipefail` (`bootstrap.sh:3`) stops on any failing command or unset variable. `PYTHON_PKG=python3.12` (`:5`) is the apt fallback package, `PYTHON=python3` (`:6`) the interpreter, `QUIET=0` (`:7`) a flag. | Read by the functions below | None |
| 2 | `log()` | Prints `[+] msg` to stdout (`:9`), the same prefix that `lib/log.py` uses. | `ensure_python` (`:25,:29`) | stdout |
| 3 | `die()` | Prints `[x] msg` to stderr and exits 1 (`:10`). | `ensure_root` (`:15`), `ensure_python` (`:39`) | stderr |
| 4 | `ensure_root()` | Requires `EUID` 0 **and** `SUDO_UID` set and non-zero. Otherwise dies with "run bootstrap.sh with sudo from your own account (not a root shell)" (`:12-17`). The comment at `:13` gives the reason: git runs as that user. | `main` (`:48`) -> `die` | env `EUID`, `SUDO_UID` |
| 5 | `check_python_version()` | `python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))'` with errors hidden. Exit 0 means 3.12 or newer (`:19-21`). | `ensure_python` (`:24,:38`) | Runs `python3` from sudo's PATH |
| 6 | `ensure_python()` | If the check passes, prints "Python >= 3.12 found" unless `QUIET` and returns (`:24-27`). Otherwise runs `apt-get update` (lock timeout 120 s, `APT::Update::Error-Mode=any`, `:31`), then `apt-get install python3.12` noninteractive, keeping old config files (`:32-36`), re-checks, and dies if still too old or missing (`:38-40`). | `main` (`:49`) -> `check_python_version`, `log`, `die` | apt, only in the fallback |
| 7 | `main()` | `cd` to the script's own folder (`:44`). Sets `QUIET=1` for no arguments, `-h` or `--help` (`:45-47`). Then `ensure_root` (`:48`), `ensure_python` (`:49`), and `exec python3 -B main.py "$@"` (`:50`). | Script body -> `ensure_root`, `ensure_python`, `main.py` | Working directory = repo root. The shell process is replaced by Python. |
| 8 | `main "$@"` | Runs `main` with the operator's arguments (`:53`). | sudo | None |

**Why here:** It is the first thing that runs. It exists because the Python needs the following, and the operator should not have to remember any of it:
- **Root via sudo.** Every host step changes system state: apt, netplan, nft, systemctl, `/var/lib/lab`, and the rootful Podman socket `unix:///run/podman/podman.sock` (`lib/config.py:25`).
- **`SUDO_UID` (with `SUDO_GID`, which sudo sets alongside it).** Python later acts as the operator in two places. `gitea.git()` runs git as `SUDO_UID:SUDO_GID` with the operator's HOME, so `.git` stays operator-owned (`services/gitea/gitea.py:176-186`). `ssh_access` puts the operator key in the operator's `~/.ssh` (`host/ssh_access.py:20,36`). A root shell has no operator to act as, so the shim refuses it.
- **`-B`.** Root never writes `.pyc` files into the operator's checkout. Without it, root-owned `__pycache__/` folders would appear next to the code. Git would ignore them (`.gitignore:2`), but the operator could not delete them or write their own bytecode there.
- **`cd`.** The relative `main.py` resolves from any working directory (`sudo ~/lab/bootstrap.sh update`). Python then puts `main.py`'s folder, the repo root, first on `sys.path`, and that is what makes `lib`, `host`, `podman` and `services` importable (Step 1.6). No Python code depends on the working directory: paths are built from `BASE_DIR`, which comes from `__file__` (`lib/config.py:11`).
- **`exec`.** The shell is replaced by Python, so `main()`'s return value becomes the script's exit code, and Ctrl-C goes straight to Python (`KeyboardInterrupt` -> 130, `main.py:151-153`).

`ensure_root` runs before `ensure_python` because the apt fallback needs root. The price is that even `--help` needs sudo. The version check comes before `exec` because `lib/log.py:6` imports `typing.override`, which is new in 3.12. It is the only 3.12-only feature in the repo, and on an older `python3` it would fail at import, before any logging exists.

**How it connects:**
- `SUDO_UID`/`SUDO_GID` -> `gitea.git()` (Step 1.7) and `ssh_access.operator_key()`/`up()` (Step 4.6).
- Root -> every host step from Step 2.1 on.
- `python3 -B main.py` from the repo root -> `main.py`'s folder is `sys.path[0]`, so the package imports in `main.py:11-22` resolve (Steps 1.2, 1.6). `-B` keeps root-owned bytecode out of the checkout, so the only root-owned thing in it is `state/` (Step 1.3).
- Python >= 3.12 -> `typing.override` in `lib/log.py` (Step 1.3).
- Exit code: `main()`'s return (Step 1.2) and `sys.exit(1)` in a step or in `follow_run` (Step 5.3) become the exit code of `bootstrap.sh`.

**Re-run and removal:** Stateless. Every run repeats the same checks, and on Ubuntu 24.04 the apt branch never runs. No `down()` exists. `destroy` leaves the script alone, and a `python3.12` installed by the fallback would never be purged.

**Check it yourself:**
- `./bootstrap.sh update` without sudo: prints `[x] run bootstrap.sh with sudo from your own account (not a root shell)` and exits 1 before doing anything.
- `python3 -c 'import sys; print(sys.version_info >= (3, 12))'`: `True` on this host.
- `find . -name __pycache__ -user root`: prints nothing, because root never writes bytecode (`-B`). Any `__pycache__` you find is your own.

**Watch out:**
- The apt fallback cannot fix anything. `/usr/bin/python3` belongs to `python3-minimal`, so installing `python3.12` does not change what `python3` runs. On 24.04 the check passes anyway.
- The check looks only at the environment. A `sudo -i` shell still carries `SUDO_UID`, so running `./bootstrap.sh` inside it passes. Running `sudo ./bootstrap.sh` from that root shell sets `SUDO_UID=0` and is refused.
- `bootstrap.sh` checks `SUDO_UID` but not `SUDO_GID`. sudo always sets both, and `gitea.git()` and `ssh_access.up()` read both.

> **Marked change (not applied), C4:** Replace `ensure_python` and its apt fallback with a plain check that stops with a clear message (`check_python_version || die "python3 >= 3.12 required (Ubuntu 24.04)"`), and drop `log()`, `QUIET` and `PYTHON_PKG`, which only serve the fallback. The fallback cannot work (see Watch out). See Appendix C.

### Step 1.2: Command skeleton and table of contents

**Files:**
- `main.py`: the Python entry point. It defines the four commands, the 16-step `platform_up` and the 15-step `platform_down`, the single-run lock and the top-level error handler. It imports every step module, so it doubles as the lab's table of contents.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Module docstring and stdlib imports | The docstring states the contract: bootstrap.sh runs `python3 -B main.py <command>` from the repo root (`main.py:1`). It imports argparse, fcntl, logging, shutil, subprocess, sys and Callable (`:3-9`). | None | None |
| 2 | Step imports | Imports every host step, `lib.config`, `lib.pki`, `setup_logging`, every service module, and `gitea_config`, which is used only for `GITEA_TEARDOWN_WORKFLOW` (`:11-22`, `:97`). Importing has no side effects beyond constants and loggers, so loading everything up front is cheap. | Python at start -> the packages of Step 1.6 | None |
| 3 | `log` | `logging.getLogger(__name__)` (`:24`). Output goes through the root handlers set up in Step 1.3. | `cmd_*`; `main` (`:145,152,156,159`) | None |
| 4 | `LOCK_FILE`, `INITIALIZED_MARKER` | `state/run.lock` and `state/initialized` under `config.STATE_DIR` (`:26-27`). | `main` (`:141`); `cmd_*` (`:70,77,82,92,104`) | Names only |
| 5 | `platform_up() -> None` | The 16 host steps in order (`:30-47`, table in Step 0.1). The only value passed between steps is `certs_changed`, from `pki.up()` to `vault.up()` and `traefik.up()` (`:41-43`). | `cmd_up` `:74`, `cmd_update` `:86`, `cmd_teardown` `:95` -> Steps 2.1-4.10 | Through the steps |
| 6 | `platform_down() -> None` | The 15 removal steps (`:50-66`). `preflight` has no `down()`. The order is explained in Step 12.2. | `cmd_destroy` `:102` | Through the steps |
| 7 | `cmd_up`, `cmd_update`, `cmd_teardown`, `cmd_destroy` | One function per command (`:69-105`). Their marker gates and the commit are Step 1.7. Their tails are Step 5.1 (all three; teardown is read again as one flow in Step 12.1) and Step 12.2 (destroy). | `COMMANDS` | See those steps |
| 8 | `COMMANDS` | `dict[str, tuple[Callable[[], None], str]]`: name -> (function, help text) for `up`, `update`, `teardown`, `destroy` (`:108-113`). The single list that both the subcommands and the dispatch use. | `parse_args` `:124`, `main` `:148` | None |
| 9 | `parse_args(argv: list[str] \| None) -> argparse.Namespace` | prog `bootstrap.sh`, with a description that points to build-order.md (`:118-121`). One subparser per `COMMANDS` entry (`:123-125`). With no command, prints help and calls `sys.exit(1)` (`:128-130`). argparse itself exits 0 on `-h` and 2 on an unknown command. | `main` `:136` | stdout/stderr only |
| 10 | `main(argv: list[str] \| None = None) -> int` | `parse_args` (`:136`), then `setup_logging()` (`:138`), then `open(state/run.lock, "w")` and `fcntl.flock(LOCK_EX \| LOCK_NB)` (`:141-143`). If the lock is busy: "another bootstrap.sh run is in progress", return 1 (`:144-146`). Otherwise runs `COMMANDS[command]` (`:148-150`). | `__main__` guard -> `parse_args`, `setup_logging`, `cmd_*` | Creates/truncates and locks `state/run.lock` |
| 11 | Central error handler | `KeyboardInterrupt` -> `[x] <cmd> interrupted`, 130 (`:151-153`). `CalledProcessError` -> `[x] <cmd> failed: <argv0> exited with N`, traceback to the log file only, 1 (`:154-157`). Any other `Exception` -> `[x] <cmd> failed: <message>`, 1 (`:158-160`). `SystemExit`, raised by a step's `sys.exit(1)`, is not caught and passes through with its own code. | Wraps `func()` | Traceback to `state/bootstrap.log` |
| 12 | `if __name__ == "__main__": sys.exit(main())` | `main()`'s return value becomes the process exit code, and through `exec` the exit code of `bootstrap.sh` (`:165-166`). | python3 | Exit code |

**Why here:** Read `main.py` first, because it is the skeleton. Everything else in the repo is reached from `platform_up`, `platform_down` or a `cmd_*`. At runtime the order is slightly different. The import lines evaluate the package layout (Step 1.6) and the `lib.config` constants (Step 1.4) before `main()` starts. Inside `main()`, `parse_args` comes first, so help and usage errors exit without creating `state/`. `setup_logging` (Step 1.3) comes before the lock because it creates `state/`, and `open(LOCK_FILE)` needs that folder (`lib/log.py:49`, `main.py:138-141`).

**How it connects:**
- `platform_up` calls Steps 2.1 to 4.10 in table order. `certs_changed` links Step 3.3 to Steps 3.4 and 3.8.
- `main()` relies on `state/` from `setup_logging` (Step 1.3) and on `config.STATE_DIR` (Step 1.4).
- `COMMANDS` -> gates (Step 1.7) -> tails (Steps 5.1, 12.1, 12.2).
- `sys.exit(1)` inside steps (for example `host/preflight.py:15-16`, `host/network.py:53-55`) and in `follow_run` (Step 5.3) reach the operator as exit 1 without a "failed" line. The step has already printed its own reason.

**Re-run and removal:** Every run opens and locks `state/run.lock`. The kernel drops the lock when the process exits, even on a crash (comment at `:140`), so a stale lock is impossible. A second run started meanwhile exits 1 at the lock without touching anything, apart from its own error line in the log. `destroy` keeps `state/run.lock`.

**Check it yourself:**
- `python3 -B main.py --help` as yourself, from the repo root: lists `up`, `update`, `teardown`, `destroy` with their help texts. Nothing is written: the imports have no side effects and argparse exits before `setup_logging`.
- `sudo ./bootstrap.sh; echo $?` (sudo): prints help, exit status 1, and `tail -n 1 state/bootstrap.log` is unchanged.

**Watch out:**
- The `platform_up` docstring says "unchanged steps do nothing" (`:31`). Two steps do work every run: vmfw reloads its tables (`host/vmfw.py:31-32`), and podman downloads the repo key (`podman/podman.py:16`).
- The argparse description points readers to `build-order.md` (`:120`), which is this document.

> **Marked change (not applied), C9:** Fix the `platform_up` docstring (`main.py:31`): "unchanged steps do nothing" is not true, because vmfw reloads its rules (Step 2.6) and podman downloads its repo key (Step 2.4) on every run. See Appendix C.

### Step 1.3: Logging

**Files:**
- `lib/__init__.py`: empty (0 bytes). Makes `lib` a regular package (see Step 1.6).
- `lib/log.py`: logging setup. The console shows `[+]/[!]/[x] message`. `state/bootstrap.log` gets timestamped lines plus tracebacks.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `lib/__init__.py` | Empty package marker. | Python import of `lib.*` | None |
| 2 | Module docstring and imports | `from typing import override` (`lib/log.py:6`) is the reason for the 3.12 check in Step 1.1. `from lib import config` (`:8`) supplies `STATE_DIR`. | None | None |
| 3 | `PREFIX` | `dict[int, str]`: INFO `[+]`, WARNING `[!]`, ERROR `[x]` (`:10-14`). Any other level is shown as `[?]` (`:24`). | Both formatters | None |
| 4 | `LOG_FILE` | `state/bootstrap.log` (`:16`). | `setup_logging` | Name only |
| 5 | `ConsoleFormatter.format(self, record: logging.LogRecord) -> str` | Returns `"<prefix> <message>"` (`:19-25`). It replaces `format` entirely, so an attached traceback never reaches the console. | Console handler | stderr |
| 6 | `FileFormatter.format(self, record: logging.LogRecord) -> str` | Local time in ISO format with UTC offset, to the second (`:33-34`), then the console text, then the traceback when `exc_info` is set (`:35-36`). Subclass of `ConsoleFormatter` (`:28`). | File handler | `state/bootstrap.log` |
| 7 | `setup_logging() -> None` | Returns early if the root logger already has handlers (`:42-44`). Adds a stderr handler with `ConsoleFormatter` (`:46-47`), creates `state/` (`:49`), adds an append-mode, utf-8 `FileHandler` with `FileFormatter` (`:50-51`), sets the root level to INFO (`:53`) and attaches both handlers (`:54-55`). | `main.main` `:138` | Creates `state/` (root-owned). Appends to `state/bootstrap.log`. |

**Why here:** Logging is the first thing `main()` sets up after parsing arguments. Every later module only calls `logging.getLogger(__name__)` and relies on these root handlers. It also has a side job: the `mkdir` at `:49` is what creates `state/`, which the lock (Step 1.2) and the marker's `touch()` (Step 5.1) need; `pki.up` creates `state/pki/` itself (`lib/pki.py:20`).

**How it connects:**
- `LOG_FILE` is derived from `config.STATE_DIR` (Step 1.4).
- `exc_info=True` in the error handler (`main.py:156,159`) -> tracebacks land only in the file, through `FileFormatter`.
- `state/` -> `state/run.lock` (Step 1.2), `state/initialized` (Steps 1.7, 5.1), `state/pki/` (Step 3.3).

**Re-run and removal:** Each run appends. The file is never rotated or truncated. `destroy` removes `state/pki` (via `pki.down`) and the marker, but keeps `state/bootstrap.log` and `state/run.lock` (`main.py:101-105`, `lib/pki.py:54-58`). That makes the log the record of every bootstrap run on this host.

**Check it yourself:**
- `tail -n 5 state/bootstrap.log`: lines like `YYYY-MM-DDTHH:MM:SS-05:00 [+] ...`.
- `grep -n -A3 ' failed: ' state/bootstrap.log | head`: a traceback follows each failure line in the file. On the console the same failure was a single `[x]` line.
- `ls -ld state state/bootstrap.log`: owned by root.

**Watch out:**
- The log holds only Python's own log lines. Output from apt, compose, git, ssh-keygen and the rest goes straight to the terminal. So does the tail of a failed job's log, which `follow_run` prints with `print(..., file=sys.stderr)` (`services/gitea/gitea.py:266-267`). Use `sudo ./bootstrap.sh update 2>&1 | tee run.txt` if you want everything. All console logging goes to stderr.

### Step 1.4: Shared settings

**Files:**
- `lib/config.py`: constants used across the host steps and services: paths, bridge, apt env, Compose binary and socket, the PKI layout and certificate table, the Vault endpoint and files. It imports nothing from the lab (`:1-5`).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Module docstring | "Lab settings shared by more than one module" (`lib/config.py:1`). Not true of every constant (see Watch out). | None | None |
| 2 | Lab: `LAB_ADMIN` | `"labadmin"` (`:8`), the admin user name for Gitea and Grafana. | `services/gitea/gitea.py:57-75,144,147`; `services/monitoring/monitoring.py:34` | None |
| 3 | Paths: `BASE_DIR`, `STATE_DIR`, `LAB_DIR`, `SERVICES_DIR` | Repo root from `__file__` (`:11`), `<repo>/state` (`:12`), `/var/lib/lab` (`:13`), `<repo>/services` (`:14`). | `BASE_DIR`: `gitea.py:167,183`. `STATE_DIR`: `lib/log.py:16`, `main.py:26-27`. `LAB_DIR`: `main.py:103`, `services/vault/vault.py:59`. `SERVICES_DIR`: `lib/system.py:77` | Name paths that later steps create |
| 4 | Network: `BRIDGE`, `VMNET` | `"mgmtbr1"` (`:17`) and `ip_interface("10.250.0.1/24")` (`:18`). | Logic: `host/network.py` (bridge checks, conflicts, wait). Log text only: `host/ntp.py:26-31`, `services/coredns/dns.py:17`, `services/squid/squid.py:20`, `services/traefik/traefik.py:15`. `VMNET` also feeds the vault cert SAN (`:36`) and `VAULT_ADDR` (`:43`) | None |
| 5 | Apt: `APT_ENV` | `{**os.environ, "DEBIAN_FRONTEND": "noninteractive"}` (`:21`), a snapshot of the environment taken at import. | `lib/system.py:38,42,49` | None |
| 6 | Podman / Compose: `COMPOSE`, `DOCKER_HOST` | `/usr/libexec/docker/cli-plugins/docker-compose` (`:24`) and `unix:///run/podman/podman.sock` (`:25`): the Compose binary from `docker-compose-v2`, pointed at Podman's Docker-compatible API. | `lib/system.py:75,77` | None |
| 7 | PKI paths: `CFSSL_DIR`, `PKI_DIR`, `LAB_CA`, `LAB_CA_CERT` | `<repo>/lib/cfssl` (`:28`), `<repo>/state/pki` (`:29`), file stem `"ca"` (`:30`), `state/pki/ca.pem` (`:31`). | `CFSSL_DIR`, `LAB_CA`: `lib/pki.py` only. `PKI_DIR`: `lib/pki.py`, `services/vault/vault.py:137-138`. `LAB_CA_CERT`: `vault.py:34`, `gitea.py:40,160`, `services/gitea/runner/runner.py:52`, `monitoring.py:42` | None |
| 8 | `CERTS` | `dict[str, tuple[str, list[str], tuple[int, int]]]`: name -> (profile, hosts, key owner uid/gid) (`:33-39`). `vault`: server, `vault.lab.test`, 10.250.0.1, 127.0.0.1, key owner (100, 1000), the uid Vault runs as inside its image. `gateway`: server, gitea/grafana/prometheus/loki `.lab.test`, (0, 0). `app-edge`: server, `app.lab.test`, (0, 0). | `lib/pki.py:25,34` (Step 3.3) | None |
| 9 | Vault: `VAULT_PORT`, `VAULT_ADDR`, `VAULT_INIT_FILE`, `VAULT_POLICY_DIR`, `VAULT_APPROLE_FILE` | `8200` (`:42`), `https://10.250.0.1:8200` (`:43`), `/var/lib/lab/vault-init.json` (`:44`), `services/vault/policies` (`:45`), `/var/lib/lab/approle.json` (`:46`). | `services/vault/vault.py` only; `VAULT_PORT` only at `:43` | None |

**Why here:** It is the root of the import graph. `lib/log.py` and `lib/system.py` import it, and so do most host and service modules. It has no dependencies of its own, so it can be evaluated first, at import time.

**How it connects:**
- `BRIDGE`/`VMNET` -> the bridge (Step 2.2), chrony (Step 2.3), and the addresses CoreDNS, Squid, Vault and Traefik bind (Steps 3.1, 3.2, 3.4, 3.8).
- `COMPOSE`/`DOCKER_HOST`/`SERVICES_DIR` -> `system.compose()` (Step 1.5) -> every Podman service (Phase 3, Step 4.1).
- `CERTS`, `PKI_DIR`, `CFSSL_DIR` -> `pki.up()` (Step 3.3). `LAB_CA_CERT` -> every HTTPS client on the host (Vault, Gitea, monitoring) and the runner's copy `/etc/lab-runner/ca.pem` (Step 4.8).
- `VAULT_*` -> the Vault client and lifecycle (Steps 3.4-3.7). `LAB_ADMIN` -> Gitea admin (Step 4.2) and Grafana admin (Step 3.10).

**Re-run and removal:** Values only. Nothing is written, and there is no `down()`. `LAB_DIR` is the folder `cmd_destroy` deletes with `rmtree` (`main.py:103`, Step 12.2).

**Check it yourself:**
- From the repo root: `python3 -B -c 'from lib import config; print(config.VAULT_ADDR, config.LAB_CA_CERT); print(config.CERTS["vault"])'`. It prints `https://10.250.0.1:8200`, the `state/pki/ca.pem` path, and the vault row.
- `git grep -nw '10\.250\.0\.1' -- ':!lib/config.py' ':!docs' ':!*.md' | wc -l`: how many lines outside `lib/config.py` (code and comments) name the host address by hand.

**Watch out:**
- Values copied by hand that must change together with this file:
  - `BRIDGE`/`VMNET` also appear in `host/files/60-lab-mgmtbr1.yaml:8-12` (whose comment at `:2` says so), `host/files/chrony-lab.conf:4,7`, `services/coredns/conf/Corefile:3,5,19`, `services/squid/conf/squid.conf:4,6`, `services/vault/compose.yaml:10`, `services/traefik/compose.yaml:15`, `host/files/nftables-vmfw.nft:147-178`, `services/traefik/dynamic/allowlists.yml:7-13`, `terraform/compute.tf:162`, `terraform/cloud-init/network-config.yaml.tftpl:22` (the VMs' DNS server) and `ansible/group_vars/all.yml:4`.
  - `LAB_DIR` (`/var/lib/lab`) is hard-coded in `services/gitea/runner/config/config.py:13`, `services/gitea/runner/files/{config.yaml,lab-runner.service}`, `terraform/provider.tf:16`, `terraform/storage.tf:5` (pool `/var/lib/lab/pool`), `.gitea/workflows/{terraform,teardown,image}.yml` and the Ansible alloy and frontend roles.
  - `LAB_ADMIN` is copied as `flux_git_user` in `ansible/roles/fluxcd/defaults/main.yml:2`.
  - The `CERTS` names are file names that the compose mounts (`services/vault/compose.yaml:18-20`, `services/traefik/compose.yaml:19-20`, `services/traefik/dynamic/tls.yml:3-4`) and `vault.py:137-138` expect.
- Several groups have a single user: the Vault constants (`vault.py`), `CFSSL_DIR`/`LAB_CA`/`CERTS` (`pki.py`), and `APT_ENV`/`COMPOSE`/`DOCKER_HOST` (`system.py`). So the docstring at `:1` overstates "shared". `VAULT_PORT` is used only to build `VAULT_ADDR`.

### Step 1.5: Shared helpers

**Files:**
- `lib/system.py`: small host-command helpers shared by the host steps and services: `ip -j`, dpkg/apt, systemctl checks, write-if-different file installs, and the `docker-compose` wrapper that talks to the Podman socket.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Module docstring, imports, `log` | "Helpers for running host commands, shared by more than one module" (`lib/system.py:1`). Imports `lib.config` (`:9`). `log` (`:11`) is used only by `apt_install`. | None | None |
| 2 | `ip_json(*args: str) -> list[dict]` | Runs `ip -j <args>` with check=True and returns the parsed JSON (`:14-17`). | `host/preflight.py:23,27`; `host/network.py:23,34,40` -> `ip` | Reads routes, addresses, links |
| 3 | `missing_packages(packages: list[str]) -> list[str]` | One `dpkg-query -W -f=${db:Status-Status} <pkg>` per package. Every package whose output is not `installed` counts as missing, including unknown names (`:20-28`). | `apt_install` `:33`; `podman/podman.py:35,60` | Reads the dpkg database |
| 4 | `apt_install(packages: list[str]) -> bool` | Does nothing and returns False if nothing is missing. Otherwise runs `apt-get -qq update` (lock timeout 120 s) and then `apt-get install -y -qq --no-install-recommends` for the missing packages only, with `APT_ENV`, and returns True (`:31-43`). No recommends, because `docker-compose-v2` would otherwise pull in docker.io and start a Docker daemon (`:39`). | `host/kvm.py:15`, `host/ntp.py:15,44`, `host/toolchain.py:68`, `host/vmfw.py:24`, `lib/pki.py:19`, `podman/podman.py:41` -> `missing_packages`, apt-get | apt lists, installed packages |
| 5 | `apt_purge(packages: list[str]) -> None` | `apt-get purge -y -qq` (lock timeout 120 s), with no autoremove (`:46-49`). | `host/kvm.py:47`, `host/ntp.py:43`, `host/toolchain.py:130`, `lib/pki.py:57`, `podman/podman.py:63` | Removes packages and their config |
| 6 | `systemctl_ok(verb: str, unit: str) -> bool` | True if `systemctl <verb> --quiet <unit>` exits 0 (`:52-54`), for example is-active or is-enabled. | `host/kvm.py:20`, `host/ntp.py:27`, `podman/podman.py:31`, `services/gitea/runner/runner.py:96` | Reads systemd state |
| 7 | `write_file(content: bytes, dst: Path, mode: int) -> bool` | Returns False if `dst` already holds exactly `content`. Otherwise `touch`, `chmod(mode)`, then write, so secret content never sits in a file with a looser mode. Returns True (`:57-65`). | `install_file`; `host/toolchain.py:62,98,112`; `runner.py:42,66` | Writes `dst` |
| 8 | `install_file(src: Path, dst: Path, mode: int) -> bool` | `write_file(src.read_bytes(), dst, mode)`: copies a repo file when it differs (`:68-70`). | `host/network.py:65`, `host/ntp.py:17,19`, `host/ssh_access.py:45`, `podman/podman.py:21-22`, `runner.py:51,52,91` -> `write_file` | Writes `dst` |
| 9 | `compose(service: str, *args: str, env: dict[str, str] \| None = None) -> None` | Runs `docker-compose -f services/<service>/compose.yaml <args>` with `DOCKER_HOST` set to the Podman socket plus any extra env, check=True (`:73-80`). Relative paths in a compose file resolve against that file's folder, so `../../state/pki/...` mounts reach the repo's `state/`. Each compose file names its project `lab-<service>` (for example `services/traefik/compose.yaml:1`). | `services/coredns/dns.py:16,25`, `services/squid/squid.py:19,28`, `services/vault/vault.py:228,255`, `services/traefik/traefik.py:14,23`, `services/gitea/gitea.py:285,301`, `services/monitoring/monitoring.py:59,69` | Podman containers, networks and volumes |

**Why here:** Every host step from Step 2.1 on, and every service, is written on top of these primitives. Their "only if missing or different" behaviour is what makes `platform_up` safe to re-run. `compose()` cannot work until Podman and its socket exist (Step 2.4), which is why every Compose service comes after `podman.up()`.

**How it connects:**
- `apt_install`/`apt_purge` -> the up/down pairs of ntp, podman, kvm, toolchain and pki (Steps 2.3-2.7, 3.3, 12.2). vmfw installs nftables and never purges it (`host/config/config.py:58-59`).
- `install_file` -> netplan (Step 2.2), chrony files (Step 2.3), alvistack source/pin (Step 2.4), the ssh drop-in (Step 4.6), and the runner config, CA copy and unit (Steps 4.8, 4.10).
- `write_file` -> downloaded binaries (Step 2.7, Step 4.8) and `/etc/lab-runner/ssh.pub` (Step 4.9). The returned "changed" flag drives restarts.
- `compose` -> CoreDNS, Squid, Vault, Traefik, Gitea and monitoring (Steps 3.1-3.10, 4.1, 4.5).
- `ip_json` -> preflight's `detect_network()` (Step 2.1), which vmfw and CoreDNS call again live (Steps 2.6, 3.1).

**Re-run and removal:** Idempotent by design. `apt_install` skips even `apt-get update` when nothing is missing. `write_file`/`install_file` leave equal files alone. `compose up -d` leaves unchanged containers running. Removal is done by the callers: `apt_purge` in their `down()`s, and `compose(..., "down")` in each service's `down()`.

**Check it yourself:**
- `dpkg-query -W -f='${db:Status-Status}\n' chrony golang-cfssl`: `installed` twice. This is the exact test `missing_packages` runs.
- `stat -c '%a %U %n' /etc/netplan/60-lab-mgmtbr1.yaml`: `600 root`. `install_file(..., 0o600)` set the mode (`host/network.py:65`).
- `sudo env DOCKER_HOST=unix:///run/podman/podman.sock /usr/libexec/docker/cli-plugins/docker-compose ls` (sudo): the `lab-*` projects, through the same binary and socket `compose()` uses.

**Watch out:**
- `apt_install`'s `apt-get update` (`:37`) lacks `-o APT::Update::Error-Mode=any`, which `bootstrap.sh:31` has. A failed index download is then only a warning, and the real error shows up later as a failed install.
- `write_file` does not re-apply `mode` when the content is unchanged (a hand-made chmod survives). It is not atomic. It assumes the parent folder exists, so callers create it first (for example `host/ntp.py:18`, `services/gitea/runner/runner.py:50`).

### Step 1.6: Package layout

**Files:**
- `host/__init__.py`, `podman/__init__.py`, `services/__init__.py` (with `lib/__init__.py` from Step 1.3): the top-level packages.
- `services/coredns/__init__.py`, `services/squid/__init__.py`, `services/vault/__init__.py`, `services/traefik/__init__.py`, `services/gitea/__init__.py`, `services/gitea/runner/__init__.py`, `services/monitoring/__init__.py`: one package per host service.
- `host/config/__init__.py`, `podman/config/__init__.py`, `services/gitea/config/__init__.py`, `services/gitea/runner/config/__init__.py`, `services/monitoring/config/__init__.py`: one settings package per step that has its own `config.py`.

All 16 files are empty (0 bytes).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Top-level packages `lib`, `host`, `podman`, `services` | Make `from host import ...`, `from lib import ...`, `from podman import podman` and `from services.<x> import <y>` work (`main.py:11-22`). They resolve because `main.py`'s folder, the repo root, is `sys.path[0]`. | `main.py` imports | None |
| 2 | Service packages | `services.coredns` (module `dns`), `services.squid` (`squid`), `services.vault` (`vault`), `services.traefik` (`traefik`), `services.gitea` (`gitea`), `services.gitea.runner` (`runner`), `services.monitoring` (`monitoring`). The runner is nested inside gitea. | `main.py:14-22`, and other services (for example `services/gitea/gitea.py:20` imports `services.vault`) | None |
| 3 | Settings packages | Each holds a `config.py` with that step's settings, imported as `from <pkg>.config import config`: `host/kvm.py:7`, `podman/podman.py:9`, `gitea.py:18`, `runner.py:16`, `monitoring.py:15`, `main.py:20`. | Step modules | None |
| 4 | Import conventions (no file) | `lib.config` is imported as `config` where it is the only config (`dns.py:7`, `squid.py:7`, `traefik.py:6`, `vault.py:17`, `pki.py:9`, `system.py:9`, `log.py:8`), and as `lab_config` where a package config is also needed (`host/network.py:13-14`, `host/ntp.py:6-7`, `gitea.py:16-18`, `runner.py:13-16`, `monitoring.py:13-15`). CoreDNS, Squid, Traefik and Vault have no settings package: their settings sit at the top of the module (`squid.py:11`) or in `lib/config.py:41-46`. | None | None |
| 5 | Layering (no file) | `lib` imports only `lib` (`lib/config.py:1`). `host` imports `lib`, and vmfw also imports `host.preflight` (`host/vmfw.py:7`). Services import `lib`, `podman`, `services.vault`, and two host modules: `services/coredns/dns.py:6` (`host.preflight.detect_network`) and `services/gitea/runner/runner.py:12` (`host.ssh_access`). | None | None |
| 6 | Data folders (no `__init__.py`) | `host/files`, `podman/files`, `lib/cfssl`, `services/*/conf`, `services/traefik/dynamic`, `services/*/files`, `services/gitea/runner/files`, `services/vault/policies` are read by path, never imported. | Step modules via `Path` constants | Read only |

**Why here:** `main.py`'s import lines (Step 1.2) resolve these packages before any code runs. Knowing the layout explains every import line you meet from Phase 2 on. It also explains why six files are each called `config.py` (`lib/config.py`, `host/config/config.py`, `podman/config/config.py` and the three service ones).

**How it connects:**
- Needs `sys.path[0]` = repo root, which is `main.py`'s folder when `bootstrap.sh` runs `python3 -B main.py` (Step 1.1).
- The settings packages are read with each step: `host/config` and `podman/config` (Step 2.0), `services/gitea/config` (Step 4.1), `services/gitea/runner/config` (Step 4.7), `services/monitoring/config` (Step 3.10).
- The cross-layer imports tie Step 3.1 and Step 2.6 to Step 2.1 (`detect_network`), and Step 4.9 to Step 4.6 (`ssh_access.public_key`).

**Re-run and removal:** No runtime state. With `-B`, no bytecode is written. The `__pycache__/` folders you may find are from your own Python runs, and git ignores them (`.gitignore:2`).

**Check it yourself:**
- `git ls-files '*__init__.py' | wc -l`: 16. Then `git ls-files '*__init__.py' | xargs wc -c | tail -n 1`: 0 total.
- From the repo root: `python3 -B -c 'from services.vault import vault; print(vault.__file__)'` resolves to `services/vault/vault.py`. Importing it has no side effects.

**Watch out:**
- Any snippet that imports lab code must run from the repo root and use the full dotted path, for example `from services.vault import vault`. `from vault import vault` (as in the previous version of this file) raises ImportError.

### Step 1.7: Command gate and commit (runs before platform_up)

**Files:**
- `main.py`: the marker gates at the top of each `cmd_*` and the `commit_changes()` calls (the command tails are Steps 5.1, 12.1 and 12.2).
- `services/gitea/gitea.py`: `git()` and `commit_changes()` only. The rest of the file is built in Steps 4.2-4.5 (API client, admin, org/repo, credentials, lifecycle) and Steps 5.2-5.3 (push, dispatch, wait, follow).
- `services/gitea/config/config.py`: `COMMIT_IDENTITY` only. The Gitea URLs, Vault paths, workflow names and poll settings are Step 4.1.
- `.gitignore`: what `git add -A` leaves out, and so what never reaches Gitea.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `cmd_up()` gate | If `state/initialized` exists: `[+] initial infrastructure already initialized; use update` and **return**, exit 0 (`main.py:69-72`). Otherwise `gitea.commit_changes()` (`:73`), then `platform_up()` and the tail (Step 5.1). | `COMMANDS["up"]` -> `commit_changes` | Reads the marker |
| 2 | `cmd_update()` gate | If the marker is missing: `[x] the lab is not initialized yet; run up first`, `sys.exit(1)` (`:81-84`). Otherwise `commit_changes()` (`:85`), then `platform_up()` and the tail. | `COMMANDS["update"]` -> `commit_changes` | Reads the marker |
| 3 | `cmd_teardown()` gate | If the marker is missing: `[x] ... nothing to tear down`, `sys.exit(1)` (`:91-94`). **No commit**: it goes straight to `platform_up()` and dispatches `teardown.yml` as it is on Gitea's main (Step 12.1). | `COMMANDS["teardown"]` | Reads the marker |
| 4 | `cmd_destroy()` | No gate and no confirmation. Straight to `platform_down()` (`:101-105`, Step 12.2). | `COMMANDS["destroy"]` | See Step 12.2 |
| 5 | `COMMIT_IDENTITY` | `["-c", "user.name=lab operator", "-c", "user.email=operator@lab.test"]` (`services/gitea/config/config.py:23`), so bootstrap's commits work without any git identity configured and stand apart from hand-made ones. | `commit_changes` | None |
| 6 | `git(*args: str) -> str` | Runs `git -C <repo> <args>` as `SUDO_UID:SUDO_GID`, with HOME set to that user's home (sudo sets it to `/root`, which they cannot read). stdout is captured and returned stripped, stderr goes to the terminal, check=True (`services/gitea/gitea.py:176-186`). | `commit_changes`; `push` `:171`, `main_differs` `:206` (Step 5.2) -> git | The repo's `.git`, as the operator |
| 7 | `commit_changes() -> None` | If `git status --porcelain` is empty: `no uncommitted changes`, return (`:191-193`). Otherwise `git add -A` (`:194`), then commit `-q -m "update YYYY-MM-DD HH:MM"` (local time) with `COMMIT_IDENTITY` (`:195`), and log the short sha (`:196`). | `cmd_up` `:73`, `cmd_update` `:85` -> `git` | New commit in the operator's checkout |
| 8 | `.gitignore` rules | `/state/` (log, lock, marker and the CA private key in `state/pki`), `__pycache__/`, `*.tfstate*`, `terraform/.terraform/`, `senior/` (`.gitignore:1-5`). The `review/` folder is ignored only by the local, untracked `.git/info/exclude:9`. | git, through `commit_changes`' `git add -A` | None |

**Why here:** The gate runs first, so a refused command (`up` on an initialized lab, `update` or `teardown` on a fresh one) commits nothing (`main.py:70-73`, `:82-85`). The commit runs before `platform_up` so that the commit later pushed is exactly the tree `platform_up` applied (`push`'s docstring, `services/gitea/gitea.py:153`). It even runs before preflight. So a host that then fails a step still gets the commit, which is harmless: the next `update` finds a clean tree. `teardown` skips the commit on purpose. It must not push local edits, because it only dispatches `teardown.yml` from Gitea's main.

**How it connects:**
- `SUDO_UID`/`SUDO_GID` come from Step 1.1.
- Local `HEAD` -> `main_differs`/`push`/`start_run` (Step 5.2) push it to Gitea's main. `deploy.yml` then runs that commit (Step 5.4), and its sha travels on as `GITHUB_SHA` (the image tag, Flux's revision).
- `state/initialized`: read here, touched by `cmd_up` after `start_run` (Step 5.1), unlinked by `cmd_destroy` (Step 12.2), kept by `teardown` (Step 12.1).
- `git()` is reused by `push` and `main_differs` (Step 5.2). `COMMIT_IDENTITY` sits with the other Gitea settings (Step 4.1).

**Re-run and removal:** On a clean tree `commit_changes` only logs `no uncommitted changes`. If Gitea's main already holds `HEAD`, Step 5.2 then dispatches a run instead of pushing. A second `up` stops at the gate. Nothing is removed. `destroy` leaves the local git history alone, while `gitea.down` deletes the Gitea repo with its volumes (Step 12.2). After `destroy` the marker is gone, so `up` works again and pushes the full history into a new repo.

**Check it yourself:**
- `git status --porcelain`: exactly what the next `update` will commit.
- `git log -5 --format='%h %an <%ae> %s'`: bootstrap's commits show `lab operator <operator@lab.test>` and `update YYYY-MM-DD HH:MM`. Hand-made commits keep your own identity.
- `git check-ignore -v state review` prints `.gitignore:1:/state/` and `.git/info/exclude:9:/review/`. `find .git ! -user "$(id -un)" | head` prints nothing: every commit was written as you. Root's `git push` (Step 5.2) writes nothing into `.git`.

**Watch out:**
- `git add -A` commits every file that is not ignored, and the push sends it to Gitea and starts a pipeline. `.gitignore:5` names a `senior/` folder that does not exist, while `review/` is protected only by `.git/info/exclude`, which a fresh clone does not have.
- Do not edit the checkout during a run. The commit is taken before `platform_up` starts, but the steps read their files (netplan, nft, compose, Corefile) from the working tree as they go. An edit made mid-run can be applied to the host without being in the pushed commit.
- `up` on an initialized lab exits 0 having done nothing, while `update` and `teardown` exit 1 on the wrong state. `destroy` has no guard or prompt at all.
- `git()` passes `user=` and `group=` but no `extra_groups`, so git keeps root's supplementary groups (`gitea.py:182-186`). It is a small leak of privilege, not a functional problem.

> **Marked change (not applied), C3:** Replace the stale `senior/` line in `.gitignore:5` with `/review/`. Today `review/` is ignored only by the local `.git/info/exclude`, so on a fresh clone `git add -A` in `commit_changes` would commit review notes and push them to Gitea, which also starts a pipeline. See Appendix C.

## Phase 2: Host base

Phase 2 turns a plain Ubuntu 24.04 host into a base that the platform services and the pipeline can run on. It checks that KVM works, creates the host-only bridge `mgmtbr1` (10.250.0.1/24), makes chrony serve time on that bridge, installs Podman 6 with its API socket, installs libvirt, loads the VM firewall, and installs the CI binaries. It runs as `platform_up` steps 1-7 (`main.py:32-38`), right after the command gate (Step 1.7) on every `up`, `update` and `teardown` (`main.py:74`, `:86`, `:95`); `up` and `update` also commit first, `teardown` does not. `up` on a lab that is already initialized returns before it gets here (`main.py:70-72`). `destroy` runs the matching `down()` functions inside `platform_down` (`main.py:54-56`, `:64-66`). Every step checks first and changes only what differs. The one exception is vmfw, which reloads its rules on every run. When the phase ends the host has an empty bridge holding 10.250.0.1, NTP on 10.250.0.1:123, a Podman socket with no containers yet, libvirt with no lab domains, the two nft tables loaded in the kernel (their rules name taps that do not exist yet) plus `/run/lab/vmfw.loaded`, and terraform, ansible-core, node and trivy installed. No `lab.test` name resolves yet (CoreDNS arrives in Step 3.1), and no VM exists yet (Phase 6).

**Needs from earlier phases:**
- A root process started with sudo from the operator's account, with `SUDO_UID` set (`bootstrap.sh:12-17`), and the repo root as the working directory (`bootstrap.sh:44`) (Step 1.1).
- `platform_up` order and the error style (`main.py:30-47`, `:149-160`). Modules stop with `log.error` + `sys.exit(1)`. Exceptions such as a failed `subprocess.run(check=True)` are caught by `main()` (Step 1.2).
- `lib/config.py`: `BRIDGE = "mgmtbr1"` (`:17`), `VMNET = 10.250.0.1/24` (`:18`), `APT_ENV` (`:21`), `COMPOSE`/`DOCKER_HOST` (`:24-25`), `LAB_DIR = /var/lib/lab` (`:13`) (Step 1.4).
- `lib/system.py` helpers: `ip_json` (`:14-17`), `missing_packages` (`:20-28`), `apt_install` (`:31-43`; runs `apt-get update` and `install --no-install-recommends` only when something is missing), `apt_purge` (`:46-49`), `systemctl_ok` (`:52-54`), `write_file` (`:57-65`), `install_file` (`:68-70`) (Step 1.5).
- Things the host must provide, which no code creates: Ubuntu 24.04, nested virtualization (`/dev/kvm`), an IPv4 default route, and internet access for apt, the opensuse key, HashiCorp, nodejs.org, GitHub and Ansible Galaxy.

**Hands on:**
- Bridge `mgmtbr1` with port `mgmtbr1-anchor`, address 10.250.0.1/24, file `/etc/netplan/60-lab-mgmtbr1.yaml`. The host's resolver sends `~lab.test` queries to 10.250.0.1, which starts answering in Step 3.1.
- chrony: `/etc/chrony/conf.d/chrony-lab.conf`, `/etc/systemd/system/chrony.service.d/chrony-makestep.conf`, NTP on udp 10.250.0.1:123 for the VMs' timesyncd (Step 7.4).
- Podman: keyring `/etc/apt/keyrings/alvistack.asc`, source `/etc/apt/sources.list.d/lab-alvistack.list`, pin `/etc/apt/preferences.d/lab-alvistack`. Packages podman, podman-netavark, podman-aardvark-dns, docker-compose-v2. `podman.socket` serves `/run/podman/podman.sock`. Also the `podman` CLI and the `podman.check()` guard.
- libvirt: `libvirtd.socket` and `qemu:///system`, used by Terraform (Phase 6) and by teardown (Step 12.1).
- VM firewall: kernel tables `bridge lab_sg` and `inet lab_vmfw`, plus the marker `/run/lab/vmfw.loaded` that `terraform.yml:16` checks. DNAT of `<host LAN IP>:443` to fe-1 198.51.100.11:443. Input holes on 10.250.0.1: udp 53/123 and tcp 53/3128. A forward hole for the VM mgmt IPs to 10.250.0.1:443 (Traefik).
- `preflight.detect_network()`, used again by CoreDNS (Step 3.1).
- `/usr/local/bin/terraform` 1.17.2, `/usr/local/bin/node` 24.22.3, `/usr/local/bin/trivy` 0.76.2, apt `ansible-core`, collection `cloud.terraform` 4.0.0 in `/usr/share/ansible/collections`.
- Settings modules `host/config/config.py` (this includes the ssh_access group, used in Step 4.6) and `podman/config/config.py`.

### Step 2.0: Host and Podman settings

**Files:**
- `host/config/config.py`: settings for every host step, grouped by step. Values shared lab-wide (BRIDGE, VMNET) stay in `lib/config.py` (docstring `:1`).
- `podman/config/config.py`: the Podman package lists, the home:alvistack apt repository paths, and the name of the API socket.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `FILES` (host) | Path of `host/files/`, the folder every file installed by the host steps comes from (`host/config/config.py:5`) | read by the `*_SRC` constants below | none |
| 2 | Network group | `BRIDGE_ANCHOR = "mgmtbr1-anchor"`, `NETPLAN_SRC`, `NETPLAN_FILE = /etc/netplan/60-lab-mgmtbr1.yaml`, `BRIDGE_UP_TIMEOUT = 30` s (`host/config/config.py:7-11`) | read by `host/network.py` (Step 2.2) | names the netplan target |
| 3 | NTP group | `CHRONY_PACKAGES = ["chrony"]`, `CHRONY_SERVICE = "chrony"`, `CHRONY_CONF_SRC/DEST` -> `/etc/chrony/conf.d/chrony-lab.conf`, `CHRONY_DROPIN_SRC/DEST` -> `/etc/systemd/system/chrony.service.d/chrony-makestep.conf` (`host/config/config.py:13-19`) | read by `host/ntp.py` (Step 2.3) | names the two chrony targets |
| 4 | KVM and libvirt group | `KVM_PACKAGES` (libvirt-daemon-system, libvirt-daemon-driver-qemu, libvirt-clients, qemu-system-x86, qemu-utils). Then what Terraform creates (comment `:24`): `LAB_DOMAINS` fe-1/tun-1/be-1, `LAB_NETWORKS` site-a/site-hub/site-c/wan, `LAB_POOL = "lab"`. Also `LIBVIRT_SOCKET = "libvirtd.socket"` and `LIBVIRT_URI = "qemu:///system"` (`host/config/config.py:21-29`) | read by `host/kvm.py` (Step 2.5). `LAB_DOMAINS` is also read by `network.reattach_taps` (`host/network.py:41`) | none |
| 5 | Toolchain `BIN_DIR` | `/usr/local/bin`: on the default PATH, where the runner binary also goes (`host/config/config.py:31-32`) | read by `host/toolchain.py` (Step 2.7) | target folder for binaries |
| 6 | Terraform pins | `TERRAFORM_VERSION = "1.17.2"`, zip URL, `TERRAFORM_SHA256` (`host/config/config.py:34-37`) | read by `ensure_terraform` | none |
| 7 | Ansible pins | `ANSIBLE_PACKAGES = ["ansible-core"]`. `ANSIBLE_GALAXY = /usr/bin/ansible-galaxy` is a full path so that `installed_version_ok` can test whether it exists. `CLOUD_TERRAFORM_VERSION = "4.0.0"`. `COLLECTIONS_DIR = /usr/share/ansible/collections`, which is on Ansible's default search path (`host/config/config.py:39-43`) | read by `ensure_ansible` | none |
| 8 | Node pins | `NODE_VERSION = "24.22.3"`, tar.xz URL, `NODE_SHA256`, `NODE_MEMBER` (only `bin/node` is taken from the archive) (`host/config/config.py:45-49`) | read by `ensure_node` | none |
| 9 | Trivy pins | `TRIVY_VERSION = "0.76.2"`, tar.gz URL, `TRIVY_SHA256`, `TRIVY_MEMBER = "trivy"` (`host/config/config.py:51-55`) | read by `ensure_trivy` | none |
| 10 | vmfw group | `VMFW_PACKAGES = ["nftables"]`: installed if missing, never purged (`:58`). `VMFW_BRIDGE_CT_MODULE = "nf_conntrack_bridge"`. `VMFW_NFT_SRC`. `VMFW_TABLES = ["bridge lab_sg", "inet lab_vmfw"]`. `VMFW_MARKER = /run/lab/vmfw.loaded` (`host/config/config.py:57-63`) | read by `host/vmfw.py` (Step 2.6). The marker path is also hard-coded in `.gitea/workflows/terraform.yml:16` | names the marker |
| 11 | ssh_access group | `SSH_CONFIG_SRC/FILE` -> `/etc/ssh/ssh_config.d/60-lab-ssh.conf`. `OPERATOR_KEY_NAME = "lab_operator"`, which must match `IdentityFile` in `host/files/60-lab-ssh.conf` (`host/config/config.py:65-68`) | read by `host/ssh_access.py` (Step 4.6). Not used in this phase | none |
| 12 | `FILES` (podman) | Path of `podman/files/` (`podman/config/config.py:5`) | read by `podman.repo` | none |
| 13 | `PACKAGES` | `podman`, `podman-netavark`, `podman-aardvark-dns`, `docker-compose-v2` (`podman/config/config.py:7-8`) | read by `podman.up`, `check`, `down` | none |
| 14 | `DEPENDENCIES` | Ten packages that alvistack's Podman 6 pulls in (buildah, skopeo, conmon, crun, containers-common, containers-storage, catatonit, containernetworking, containernetworking-plugins, passt). Purged on destroy together with `PACKAGES` (`podman/config/config.py:9-11`) | read by `podman.down` | none |
| 15 | Apt repository paths | `KEY_URL` (home:alvistack `xUbuntu_24.04/Release.key`), `KEYRING = /etc/apt/keyrings/alvistack.asc`, `SOURCE = /etc/apt/sources.list.d/lab-alvistack.list`, `PIN = /etc/apt/preferences.d/lab-alvistack` (`podman/config/config.py:13-17`) | read by `podman.repo`, `podman.down` | names the three apt files |
| 16 | `SOCKET` | `"podman.socket"`, the API socket Compose talks to (`podman/config/config.py:19-20`) | read by `socket_ready`, `up`, `down` | none |

**Why here:** These modules hold constants only and have no side effects. They are imported when `main.py` imports the host and podman modules (`main.py:11`, `:15`), so they load before `platform_up` starts. Read them first: they name every path, package, version and libvirt object that Steps 2.1-2.7 touch. Several of the values are copies of names chosen somewhere else, so the keep-in-sync list starts here.

**How it connects:**
- `LAB_DOMAINS`/`LAB_NETWORKS`/`LAB_POOL` repeat the Terraform names: the `locals.vms` keys in `terraform/compute.tf:3,16,29`, the network names in `terraform/network.tf:2,15,28,41`, and the pool in `terraform/storage.tf:2` (Steps 6.3-6.7). `kvm.remove_lab_vms` uses them on destroy (Step 12.2).
- `TERRAFORM_VERSION` must equal `required_version = "= 1.17.2"` in `terraform/provider.tf:2` (Step 6.2).
- `VMFW_MARKER` is the file that the terraform job's first check tests (`.gitea/workflows/terraform.yml:15-16`, Step 6.1).
- `PACKAGES[:3]` + `DEPENDENCIES` together are the `Package:` line of `podman/files/lab-alvistack.pref:2` (Step 2.4).

**Re-run and removal:** No runtime state. An edited value takes effect on the next `update`, in the step that reads it. For example, a new `TERRAFORM_VERSION` + `TERRAFORM_SHA256` makes `ensure_terraform` download the new binary. There is nothing to remove.

**Check it yourself:**
- From the repo root: `python3 -B -c 'from host.config import config as c; print(c.TERRAFORM_VERSION)'; grep -n required_version terraform/provider.tf`. The two versions must match.
- `grep -n '^Package:' podman/files/lab-alvistack.pref` and compare it with `podman/config/config.py:8-11`.

**Watch out:** A version bump needs the matching SHA256. Otherwise `download()` raises `sha256 mismatch` and `update` stops at step 7. The hand-copied pairs are `TERRAFORM_VERSION` <-> `provider.tf:2`, `LAB_*` <-> the Terraform names, `DEPENDENCIES` <-> the `.pref` line, and `OPERATOR_KEY_NAME` <-> `IdentityFile`.

### Step 2.1: preflight (platform_up step 1)

**Files:**
- `host/preflight.py`: a fail-fast KVM check, and live detection of the host's LAN (card, IP, gateway).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `check_host() -> None` | Logs an error ("is nested virtualization on?") and calls `sys.exit(1)` unless `/dev/kvm` is readable and writable (`host/preflight.py:12-18`) | `up` -> `os.access` | reads `/dev/kvm` |
| 2 | `detect_network() -> dict` | The first IPv4 default route gives `card` (dev) and `gateway`. That card's first IPv4 address gives `host_ip`, `prefix` and `dhcp` (the `dynamic` flag). Returns `{card, host_ip, prefix, gateway, dhcp}`. It reads live on every call and caches nothing (`host/preflight.py:21-36`) | `log_network` (`:41`), `vmfw.up` (`host/vmfw.py:28`), `dns.up` and `dns.down` (`services/coredns/dns.py:15`, `:25`) -> `ip_json` | runs `ip -j -4 route show default` and `ip -j -4 addr show dev <card>` |
| 3 | `log_network() -> None` | Logs `LAN: <card> on <ip>/<prefix>, gateway <gw> (DHCP\|static)`, so every run records the network the lab is building on (`host/preflight.py:39-44`) | `up` -> `detect_network` | console and `state/bootstrap.log` |
| 4 | `up() -> None` | `check_host()`, then `log_network()` (`host/preflight.py:47-49`) | `platform_up` step 1 (`main.py:32`) | none |

**Why here:** This is the first host step. It refuses a host without a usable `/dev/kvm` before anything is installed (module docstring `host/preflight.py:1`). It has no `down()` because it installs nothing. `detect_network` lives here because this is where the LAN facts are first needed. Later steps call it again instead of receiving a stored value.

**How it connects:**
- `vmfw.render_rules` writes `card` and `host_ip` into the ruleset as `$lan_card` and `$host_ip` (Step 2.6).
- `dns.up` passes `host_ip` to CoreDNS as `HOST_IP`. CoreDNS binds that address and answers `app.lab.test` with it (`services/coredns/dns.py:15-16`, `services/coredns/conf/Corefile:3,6`, Step 3.1). Together with the vmfw DNAT this is the app ingress: name -> host LAN IP -> DNAT -> fe-1.
- `/dev/kvm` is what libvirt (Step 2.5) and the `type = "kvm"` domains (`terraform/compute.tf:93`, Step 6.7) need.
- `services/coredns/dns.py:6` imports `detect_network` from `host.preflight`. It is one of two service modules that import from `host/`. The other is `services/gitea/runner/runner.py:12` (`host.ssh_access`, Step 4.9; see Step 1.6 row 5).

**Re-run and removal:** Read-only, and it gives the same result on every run unless the LAN changed. A missing `/dev/kvm` gives a clean exit 1 with a message. With no IPv4 default route, or no IPv4 address on the card, it raises `IndexError` at `:23` or `:27`, and `main()` prints a generic "up failed: list index out of range" (`main.py:158-160`). No `down()`.

**Check it yourself:**
- `ls -l /dev/kvm; ip -4 route show default`
- `grep 'LAN:' state/bootstrap.log | tail -1`

**Watch out:** The LAN IP is read again on every run, but only then. If DHCP gives the host a new address, the vmfw DNAT and CoreDNS's `app.lab.test` keep the old one until the next `update`. On a host with two default routes, or several addresses on the card, `detect_network` takes whichever one `ip` lists first.

### Step 2.2: network (platform_up step 2): bridge mgmtbr1

**Files:**
- `host/network.py`: creates `mgmtbr1` through netplan and keeps the VMs' mgmt taps attached to it.
- `host/files/60-lab-mgmtbr1.yaml`: the netplan definition, installed to `/etc/netplan/`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Header comment | Says the file must match `BRIDGE`/`VMNET` in `lib/config.py` and `BRIDGE_ANCHOR` in `host/config/config.py` (`host/files/60-lab-mgmtbr1.yaml:1-2`) | documentation | none |
| 2 | Anchor port + `ignore-carrier` | The dummy device `mgmtbr1-anchor` is the bridge's permanent port (`:5-6`, `:9`). `ignore-carrier: true` (`:14`) keeps the bridge configured with no VM attached, so 10.250.0.1 exists before any VM does (`host/files/60-lab-mgmtbr1.yaml`) | applied by `netplan apply` | creates netdevs `mgmtbr1-anchor` and `mgmtbr1` |
| 3 | `addresses: [10.250.0.1/24]` | The host's address on the VM management network. Must equal `VMNET` in `lib/config.py:18` (`host/files/60-lab-mgmtbr1.yaml:10`) | `netplan apply` | address on `mgmtbr1` |
| 4 | `nameservers` 10.250.0.1, `search: [~lab.test]` | `~lab.test` is a routing domain: the host sends only `*.lab.test` queries to CoreDNS on this link, and all other names keep using the LAN DNS (`host/files/60-lab-mgmtbr1.yaml:11-13`) | `netplan apply` -> systemd-resolved | per-link DNS settings |
| 5 | `parameters: stp: false` | No STP listening delay when a tap joins (`host/files/60-lab-mgmtbr1.yaml:15-16`) | `netplan apply` | bridge setting |
| 6 | `vmnet_conflicts() -> list[str]` | Returns, as `"<dst> on <dev>"`, every IPv4 route whose destination overlaps 10.250.0.0/24. It skips `default` and mgmtbr1's own route, so a re-run passes (`host/network.py:20-28`) | `up` -> `ip_json`, `ipaddress` | reads the routing table |
| 7 | `check() -> bool` | True if the `mgmtbr1` link holds 10.250.0.1 (`host/network.py:31-35`) | `up`, `wait_bridge` -> `ip_json` | reads addresses |
| 8 | `wait_bridge() -> None` | Polls `check()` once a second for up to `BRIDGE_UP_TIMEOUT` (30) seconds. If the address has not appeared, logs an error and calls `sys.exit(1)` (`host/network.py:47-55`) | `up` -> `check`, `time.sleep` | none |
| 9 | `reattach_taps() -> None` | For `fe-1-mgmt`, `tun-1-mgmt`, `be-1-mgmt` (built from `LAB_DOMAINS`): if the tap exists and its master is not `mgmtbr1`, runs `ip link set <tap> master mgmtbr1` (`host/network.py:38-44`) | `up` (`:66`, `:71`) -> `ip_json`, `ip link` | moves taps back onto the bridge |
| 10 | `up() -> None` | Exits 1 if there are conflicts (`:60-63`). Installs the YAML with mode 0600 (`:65`). If the file was unchanged and `check()` passes: `reattach_taps`, log, return (`:65-68`). Otherwise: `netplan apply` (`:69`), `wait_bridge` (`:70`), `reattach_taps` (`:71`) (`host/network.py:58-72`) | `platform_up` step 2 (`main.py:33`) -> the units above, `install_file` | writes `/etc/netplan/60-lab-mgmtbr1.yaml`, runs `netplan apply` |
| 11 | `down() -> None` | Unlinks the YAML and runs `netplan apply`. Then runs `ip link delete` on `mgmtbr1` and `mgmtbr1-anchor` if they still appear under `/sys/class/net`, because the renderer leaves removed devices in place (`host/network.py:75-82`) | `platform_down`, last step (`main.py:66`) | removes the file and both devices |

**Why here:** It runs right after preflight because every listener on 10.250.0.1 needs the address to exist first: chrony (Step 2.3), CoreDNS (3.1), Squid (3.2), the Vault and Traefik port mappings (3.4, 3.8), and every VM's eth2 (6.7). `vmnet_conflicts` runs before any change. A host whose LAN, VPN or container network already uses 10.250.0.0/24 stops before its networking is touched.

**How it connects:**
- 10.250.0.1 is chrony's `bindaddress` (`host/files/chrony-lab.conf:7`, Step 2.3) and the CoreDNS `bind` (`services/coredns/conf/Corefile:3,19`, Step 3.1). It is also Squid's `http_port` (`services/squid/conf/squid.conf:4`, Step 3.2), Vault's published `10.250.0.1:8200` (`services/vault/compose.yaml:10`, Step 3.4), and Traefik's `10.250.0.1:443` (`services/traefik/compose.yaml:15`, Step 3.8).
- `terraform/compute.tf:159-163` attaches each VM's eth2 to bridge `mgmtbr1` as tap `<vm>-mgmt` (Step 6.7). `reattach_taps` uses the same tap names.
- The vmfw rules match `iifname "mgmtbr1"` in `inet lab_vmfw` and the `<vm>-mgmt` taps in `bridge lab_sg` (Step 2.6).
- With the `~lab.test` route the host can resolve `gitea.lab.test` and the other lab names once CoreDNS runs (Step 3.1). The Gitea API calls and the runner registration depend on that (Steps 4.2, 4.10).

**Re-run and removal:** On a second run `install_file` finds identical bytes and `check()` passes, so the step only runs `reattach_taps` and does no `netplan apply`. That call also repairs taps left detached by a crashed run or by a `netplan apply` someone ran by hand. Any byte change in the YAML, even a comment, triggers `netplan apply`, which rebuilds the bridge; the taps are then reattached. Removal: `network.down` is the last step of destroy (`main.py:66`), after everything that bound 10.250.0.1 is gone.

**Check it yourself:**
- `ip -br addr show mgmtbr1` shows UP with 10.250.0.1/24.
- `ip -br link show master mgmtbr1` lists `mgmtbr1-anchor`, plus the `<vm>-mgmt` taps once the VMs run.
- `resolvectl domain mgmtbr1` shows `~lab.test`.

**Watch out:** `netplan apply` applies the host's whole netplan configuration, not only this file. The YAML sets no renderer, and the comments disagree about which one runs: NetworkManager in `host/config/config.py:11` and `host/network.py:70`, networkd in `host/network.py:76`. The address 10.250.0.1 is copied by hand into many files, and no single source defines it. The copies are listed in Step 1.4 (Watch out) and in R1.

> **Marked change (not applied), C9:** Make the comments agree on the renderer: NetworkManager at `host/network.py:70` and `host/config/config.py:11`, networkd at `host/network.py:76` (see Watch out). See Appendix C.

### Step 2.3: ntp (platform_up step 3): chrony serves the VMs

**Files:**
- `host/ntp.py`: installs chrony and makes it serve time to the VMs.
- `host/files/chrony-lab.conf`: conf.d snippet that says who may ask for time and which address to listen on.
- `host/files/chrony-makestep.conf`: chrony.service drop-in that lets chrony step the clock at any time.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `allow 10.250.0.0/24` | Makes chrony an NTP server, for the VM network only (`host/files/chrony-lab.conf:3-4`) | read by chronyd at start | none |
| 2 | `bindaddress 10.250.0.1` | Listens for NTP clients only on mgmtbr1's address, not on the LAN (`host/files/chrony-lab.conf:6-7`) | read by chronyd at start | udp 10.250.0.1:123 |
| 3 | `[Service] ExecStartPost=-+/usr/bin/chronyc makestep 1 -1` | After every chrony start, tells chronyd to step the clock whenever it is more than 1 s off, with no limit on the number of updates. This cannot go in conf.d because Ubuntu's chrony.conf sets `makestep 1 3` after reading conf.d. `-` ignores a failure; `+` runs the command with full privileges. Reason: after a VMware suspend/resume the host is hours behind, and slewing would take days (`host/files/chrony-makestep.conf:1-5`) | systemd, on chrony start -> chronyc | runtime chronyd setting |
| 4 | `up() -> None` | `apt_install(["chrony"])`, which replaces systemd-timesyncd (`:15`). Installs the conf file with mode 0644 (`:17`). Creates the drop-in directory and installs the drop-in (`:18-19`). Runs `daemon-reload` if the drop-in changed (`:20-21`). If either file changed it restarts chrony, because allow/bindaddress are read only at start and the unit has no reload (`:23-26`). If nothing changed but chrony is inactive, it runs `enable --now` (`:27-29`). Otherwise it only logs (`host/ntp.py:13-31`) | `platform_up` step 3 (`main.py:34`) -> `apt_install`, `install_file`, `systemctl_ok`, `systemctl` | writes the two files, (re)starts `chrony.service` |
| 5 | `down() -> None` | Unlinks both files, removes the drop-in directory if it is empty, runs `daemon-reload`, purges chrony, and reinstalls `systemd-timesyncd` (`host/ntp.py:34-45`) | `platform_down` (`main.py:65`) -> `apt_purge`, `apt_install` | restores the stock time daemon |

**Why here:** chrony binds 10.250.0.1, so it must come after Step 2.2. Nothing else on the host depends on it. Its consumers are the VMs in Phase 7. It sits here with the rest of the host base.

**How it connects:**
- The VMs use it. `ansible/group_vars/all.yml:4` sets `ntp_server: 10.250.0.1`. The common role writes timesyncd `NTP=` with an empty `FallbackNTP=` and restarts timesyncd (`ansible/roles/common/tasks/main.yml:10-28`, Step 7.4). It does this before apt, because a VM clock that is hours off makes apt reject the package lists (`:1`).
- vmfw opens udp 123 on 10.250.0.1 for traffic from mgmtbr1 (`host/files/nftables-vmfw.nft:175`, Step 2.6).
- The lab configures no upstream servers for the host itself. chrony keeps the package's default sources and reaches them over the host's normal internet route.

**Re-run and removal:** A second run restarts nothing unless a file changed, and starts chrony only if it is stopped. Removal: `ntp.down` runs after `podman.down` (`main.py:64-65`). Its `apt_install(["systemd-timesyncd"])` therefore runs `apt-get update` after the alvistack source is already gone. It runs before `network.down` (`main.py:66`), which reverses the up order.

**Check it yourself:**
- `chronyc tracking` shows the host is synchronised.
- `ss -uln 'sport = :123'` shows a listener on 10.250.0.1:123.
- `systemctl cat chrony | grep makestep` shows the drop-in.

**Watch out:** The VMs have no fallback NTP source, so the host's clock is the only clock the lab has. If the host is wrong, every VM follows it.

### Step 2.4: podman (platform_up step 4): container runtime

**Files:**
- `podman/podman.py`: adds the pinned repository, installs Podman 6 and Compose, enables the API socket, and provides the `check()` guard.
- `podman/files/lab-alvistack.list`: the apt source line.
- `podman/files/lab-alvistack.pref`: the apt pin.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Source line | `deb [signed-by=/etc/apt/keyrings/alvistack.asc] https://downloadcontent.opensuse.org/repositories/home:/alvistack/xUbuntu_24.04/ /`: a flat repository, trusted only through the lab keyring (`podman/files/lab-alvistack.list:1`) | apt | `/etc/apt/sources.list.d/lab-alvistack.list` |
| 2 | Pin block 1 | The 13 Podman stack packages from origin `downloadcontent.opensuse.org`, at priority 990. That beats Ubuntu's 500, so the stack comes from alvistack. The pin names the origin server because mirrors lag behind its index (`podman/files/lab-alvistack.pref:1-4`) | apt | `/etc/apt/preferences.d/lab-alvistack` (no `.pref` suffix) |
| 3 | Pin block 2 | Every other package from that origin gets -1, so it is never installed from there. That keeps `docker-compose-v2` coming from Ubuntu (`podman/files/lab-alvistack.pref:6-9`) | apt | same file |
| 4 | `repo() -> None` | Downloads `Release.key` on every run, with a 30 s timeout (`:16`). Writes the keyring with mode 0644 only if it is missing or different (`:17-20`). Installs the `.list` and `.pref` files with mode 0644 (`:21-22`). Logs whether anything changed (`podman/podman.py:14-27`) | `up` -> `urllib.request.urlopen`, `install_file` | network (opensuse); the three apt files |
| 5 | `socket_ready() -> bool` | True if `podman.socket` is enabled and active (`podman/podman.py:30-31`) | `check`, `up` -> `systemctl_ok` ×2 | none |
| 6 | `check() -> bool` | True if all `PACKAGES` are installed and the socket is ready (`podman/podman.py:34-35`) | the first line of every service `down()`: `services/coredns/dns.py:22`, `services/squid/squid.py:25`, `services/vault/vault.py:252`, `services/traefik/traefik.py:20`, `services/gitea/gitea.py:298`, `services/monitoring/monitoring.py:66` -> `missing_packages`, `socket_ready` | none |
| 7 | `up() -> None` | Runs `repo()`, then `apt_install(PACKAGES)` (logs if nothing was missing). Then `systemctl enable --now podman.socket`, unless the socket is already ready (`podman/podman.py:38-48`) | `platform_up` step 4 (`main.py:35`) -> `repo`, `apt_install`, `socket_ready`, `systemctl` | installs packages; rootful API socket `/run/podman/podman.sock` |
| 8 | `down() -> None` | If `podman` exists: `systemctl disable --now podman.socket`, then `podman system reset --force`, which stops and removes every container, image and volume (`:53-56`). Then `rmtree /var/lib/containers` (`:57`). Then purges only those of `PACKAGES + DEPENDENCIES` that are installed (`:58-63`). Finally unlinks the keyring, source and pin (`:64-65`) (`podman/podman.py:51-66`) | `platform_down` (`main.py:64`) -> `missing_packages`, `apt_purge` | wipes all rootful container state and the packages |

**Why here:** It must come before Step 3.1, the first user of `system.compose`. `compose()` talks to `DOCKER_HOST = unix:///run/podman/podman.sock` (`lib/system.py:73-80`, `lib/config.py:25`). Inside the step, `repo()` must come before `apt_install`, because the pin decides which repository the packages come from. It does not depend on Steps 2.2 or 2.3. It sits here with the other package installs.

**How it connects:**
- Every compose project uses the socket through `system.compose` and Ubuntu's plugin `/usr/libexec/docker/cli-plugins/docker-compose` (`lib/config.py:24`): CoreDNS, Squid, Vault, Traefik, monitoring and Gitea (Steps 3.0-3.10, 4.1).
- The `podman` CLI: `gitea.gitea_admin` runs `podman exec gitea gitea admin user create` (`services/gitea/gitea.py:61`, Step 4.2). The image job runs `podman build` and `podman save` (`.gitea/workflows/image.yml:15,20`, Step 5.6).
- `check()` makes every service `down()` do nothing once Podman is gone (Step 12.2).
- `apt_install` passes `--no-install-recommends` (`lib/system.py:39-40`), so `docker-compose-v2` does not pull in docker.io and a Docker daemon.

**Re-run and removal:** Each run downloads the key over HTTPS once. The three files are rewritten only if they changed. apt runs only if a package is missing, and the socket is enabled only if it is not ready. Removal: `podman.down` runs after every service down (`main.py:57-64`), and its reset also removes any container those left behind. It purges only installed names, because on a second destroy the repo files are already gone and apt no longer knows names like `podman-netavark` (comment `:58`).

**Check it yourself:**
- `systemctl is-active podman.socket` prints `active`.
- `apt-cache policy podman` shows the installed version coming from `downloadcontent.opensuse.org` with priority 990.
- `podman --version`

**Watch out:** Every `update` needs `downloadcontent.opensuse.org` to be reachable, because the key is fetched on every run (`podman/podman.py:16`). If it is down, the run stops at step 4. `apt_install` installs missing packages but never upgrades them: a host that already had Ubuntu's podman keeps it until someone runs an apt upgrade. `DEPENDENCIES` must match the `.pref` `Package:` line minus the three podman names, or destroy leaves packages behind. The step only works on Ubuntu 24.04 (`xUbuntu_24.04` in `KEY_URL` and in the `.list`).

> **Marked change (not applied), C6:** Download the alvistack key only when the keyring is missing (`podman/podman.py:16`), and write it with `system.write_file` instead of the hand-written compare-and-write (`:18-20`). Today every run needs the openSUSE mirror to be reachable. See Appendix C.

### Step 2.5: kvm (platform_up step 5): libvirt

**Files:**
- `host/kvm.py`: installs QEMU/KVM and libvirt for the runner's Terraform jobs. On destroy it removes the lab's libvirt objects before purging the packages.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `up() -> None` | `apt_install(KVM_PACKAGES)` (`:15-18`). `systemctl enable --now libvirtd.socket` unless it is already enabled and active (`:20-24`). Then `virsh --connect qemu:///system list --all` with `check=True` and a 30 s timeout, to prove libvirt answers (`:26-29`) (`host/kvm.py:13-30`) | `platform_up` step 5 (`main.py:36`) -> `apt_install`, `systemctl_ok`, `systemctl`, `virsh` | packages; `libvirtd.socket` |
| 2 | `remove_lab_vms() -> None` | Runs `virsh destroy`, then `undefine`, for each of `LAB_DOMAINS`. Then `net-destroy`/`net-undefine` for each of `LAB_NETWORKS`, then `pool-destroy`/`pool-undefine lab`. No `check` and the output is captured, so anything already gone is skipped silently (`host/kvm.py:33-40`) | `down` -> `virsh` ×16 | libvirt domains, networks, pool |
| 3 | `down() -> None` | Calls `remove_lab_vms()` if `virsh` exists, then `apt_purge(KVM_PACKAGES)`. The disk files stay until `cmd_destroy` removes `/var/lib/lab` (`host/kvm.py:43-48`, `main.py:103`) | `platform_down` (`main.py:55`) -> `remove_lab_vms`, `apt_purge` | removes the packages |

**Why here:** No host step depends on libvirt. The only hard rule is that libvirt must exist before the first Terraform job (`.gitea/workflows/terraform.yml:17-20`, Step 6.1) and before teardown (`.gitea/workflows/teardown.yml:21-24`). It sits here with the package installs. It needs `/dev/kvm`, which Step 2.1 checked.

**How it connects:**
- `terraform/provider.tf:20-22` uses `uri = "qemu:///system"` (Step 6.2). Terraform runs as root in the host-mode runner.
- `terraform.yml:17-18` and `teardown.yml:21-22` run the same `virsh --connect qemu:///system list` as a precondition (Steps 6.1, 12.1).
- The `LAB_*` names match `terraform/network.tf`, `storage.tf` and `compute.tf` (Steps 6.3, 6.4, 6.7).
- `kvm.down` runs before `vmfw.down` (`main.py:55-56`), so no VM is still running after its firewall is gone.

**Re-run and removal:** A second run does a package check, two `systemctl` probes and one `virsh list`. Removal: `down()` as described above. The pool directory `/var/lib/lab/pool` (`terraform/storage.tf:5`) and the state `/var/lib/lab/tfstate` (`terraform/provider.tf:16`) are removed with `/var/lib/lab` in `cmd_destroy`.

**Check it yourself:**
- `systemctl is-active libvirtd.socket`
- (sudo) `sudo virsh -c qemu:///system list --all`: empty until Phase 6, then fe-1, tun-1 and be-1.

**Watch out:** `remove_lab_vms` hides every error. If the `LAB_*` values drift from the Terraform names, destroy leaves those objects defined and prints nothing. The `teardown` command removes the VMs through Terraform (Step 12.1), not through this function.

### Step 2.6: vmfw (platform_up step 6): VM firewall

**Files:**
- `host/vmfw.py`: renders and loads the ruleset on every run, then leaves the marker.
- `host/files/nftables-vmfw.nft`: the ruleset. `bridge lab_sg` holds the security groups for VM-to-VM traffic inside one bridge. `inet lab_vmfw` holds the rules for anything routed through, or delivered to, the host's IP layer.

The two tables see the same traffic at different layers:
- **Bridge family (`lab_sg`)** sees Ethernet frames as they enter or cross a bridge. Its `iifname`/`oifname` are tap names (`fe-1-wan`, `be-1-mgmt`, ...).
- **Inet family (`lab_vmfw`)** sees IP packets that the host routes or receives. Its `iifname` is the bridge device (`mgmtbr1`, `wan`).
- **How a VM's packet passes through:**
  - VM to host: the frame first passes `lab_sg prerouting` (the source checks), then the host's IP layer (`lab_vmfw input`, or `forward` after a Podman DNAT).
  - VM to VM on one bridge: `lab_sg prerouting`, then `lab_sg forward`.
  - Host to VM: frames the host sends go out through the bridge output hook, which no lab chain filters. The replies come back through the input chain.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Ruleset header | Explains the model: stateful and allow-only per VM card, using bridge conntrack (`nf_conntrack_bridge`). Once loaded, that module tracks frames on every bridge, and bridged and routed traffic share one conntrack table (`host/files/nftables-vmfw.nft:1-8`) | documentation | none |
| 2 | `lab_sg` reload idiom | `table bridge lab_sg` creates the table if it is missing, and `delete table bridge lab_sg` then deletes it. Both run in the same transaction as the new definition at `:13`, so the table is replaced with no gap (`host/files/nftables-vmfw.nft:10-11`) | `nft -f` | kernel table `bridge lab_sg` |
| 3 | Group sets | `sg_frontend {fe-1-wan}`, `sg_hub {tun-1-wan}`, `sg_backend {be-1-wan}`: a card is in a group by being in its set. The tap names come from `terraform/compute.tf:157` (`host/files/nftables-vmfw.nft:15-26`) | matched by `forward`, `sg_hub_in` | none |
| 4 | `mgmt_taps`, `lab_taps` | The three mgmt taps, and all six lab taps (the `-wan` and `-mgmt` taps; the `<vm>-vpc` taps are in no set, see Step 6.7). Only frames from and between these taps are filtered; Podman's and libvirt's bridges and `mgmtbr1-anchor` are not (`host/files/nftables-vmfw.nft:27-36`) | matched by `prerouting`, `forward` | none |
| 5 | `lab_addrs` | `ifname . ipv4_addr` pairs giving each card's own address: wan 198.51.100.11/.12/.13, mgmt 10.250.0.110/.111/.112. Copied from `terraform/compute.tf:10-11,23-24,36-37` (`host/files/nftables-vmfw.nft:37-42`) | used by the source and destination checks | none |
| 6 | chain `prerouting` (bridge) | Hook bridge prerouting at priority -300, which is before bridge conntrack at -200. Source checks on every frame a lab tap sends, whether it goes to another VM or to the host (`host/files/nftables-vmfw.nft:44-60`) | kernel hook | packet verdicts, counters |
| 7 | chain `forward` (bridge) | Hook bridge forward: frames from one tap to another tap only. Every rule is listed in the packet-path table below (`host/files/nftables-vmfw.nft:62-96`) | kernel hook -> jumps to the `sg_*_in` chains | verdicts, counters |
| 8 | chain `sg_hub_in` | New WireGuard flows to the hub: udp 51820 from the frontend, udp 51821 from the backend (`host/files/nftables-vmfw.nft:98-101`) | jumped to from `forward:90` | verdicts |
| 9 | chains `sg_frontend_in`, `sg_backend_in` | Empty: no other VM may open anything to the spokes (`host/files/nftables-vmfw.nft:103-108`) | jumped to from `forward:91-92` | none |
| 10 | `lab_vmfw` reload idiom | The same create-then-delete idiom for `table inet lab_vmfw` (`host/files/nftables-vmfw.nft:112-113`) | `nft -f` | kernel table `inet lab_vmfw` |
| 11 | chain `prerouting` (nat) | Hook nat prerouting at priority dstnat: HTTPS from the LAN to the host's LAN IP goes to fe-1 (`host/files/nftables-vmfw.nft:116-122`) | kernel hook | DNAT |
| 12 | chain `output` (nat) | Hook nat output at priority dstnat: the same DNAT for the host's own browser, because prerouting never sees traffic the host starts (`host/files/nftables-vmfw.nft:124-129`) | kernel hook | DNAT |
| 13 | chain `forward` (filter) | Routed traffic: no VM egress, no relaying from VM to VM, LAN ingress to fe-1, and VMs to Traefik only (`host/files/nftables-vmfw.nft:131-158`) | kernel hook | verdicts, counters |
| 14 | chain `input` (filter) | Traffic for the host itself: over wan, replies only; over mgmt, DNS, NTP and Squid to 10.250.0.1, plus some ICMP to any host address (`host/files/nftables-vmfw.nft:160-179`) | kernel hook | verdicts, counters |
| 15 | `render_rules(network: dict) -> bytes` | Puts `define lan_card = "<card>"` and `define host_ip = <ip>` in front of the file's bytes (`host/vmfw.py:13-19`) | `up` -> reads `VMFW_NFT_SRC` | none |
| 16 | `up() -> None` | `apt_install(["nftables"])` (`:24`). `modprobe nf_conntrack_bridge` (`:27`): the kernel would autoload it, but loading it here makes the dependency explicit and fails earlier (`:25-26`). Then `detect_network()` (`:28`) and `render_rules` (`:29`). `nft -c -f -` checks the rules (`:31`), then `nft -f -` loads both tables in one transaction (`:32`). Finally creates `/run/lab` and touches the marker (`:34-35`) (`host/vmfw.py:22-37`) | `platform_up` step 6 (`main.py:37`) -> `apt_install`, `modprobe`, `detect_network`, `render_rules`, `nft` | kernel tables, `/run/lab/vmfw.loaded` |
| 17 | `down() -> None` | `nft destroy table` for each entry in `VMFW_TABLES` (no error if a table is absent), then unlinks the marker. nftables stays installed, and libvirt's and Podman's own tables stay (`host/vmfw.py:40-45`) | `platform_down` (`main.py:56`) -> `nft` | removes both tables and the marker |

**Packet-path table, `bridge lab_sg` (every rule, in file order):**

| Chain: rule (line) | Which traffic | Verdict | Why |
|---|---|---|---|
| prerouting: `iifname != @lab_taps return` (`:52`) | Frames not sent by a lab VM tap: Podman and libvirt bridges, the anchor | leave the chain, unfiltered | The security groups apply to VM cards only |
| prerouting: `ether type { 8021q, 8021ad } counter drop` (`:57`) | VLAN-tagged frames from a VM | drop | The VMs use no VLANs. A tagged ARP would skip the ARP check, because its Ethernet type is the tag's (`:53-56`) |
| prerouting: `iifname . ip saddr != @lab_addrs counter drop` (`:58`) | IPv4 from a tap whose source address is not that tap's own | drop | No spoofing: a VM cannot pass a forged packet off as a reply in another VM's connection (`:44-48`), and Traefik and Squid can trust source IPs (`services/traefik/dynamic/allowlists.yml:1`) |
| prerouting: `iifname . arp saddr ip != @lab_addrs counter drop` (`:59`) | ARP announcing an IP that is not the tap's own | drop | No ARP poisoning of the host's or the hub's cache (`:47-48`) |
| prerouting: policy accept (`:50`) | Everything else a tap sends (IPv6 included; the later chains handle it) | continue | Next come bridge conntrack, then `forward` or local delivery |
| forward: `iifname != @lab_taps return`, `oifname != @lab_taps return` (`:65-66`) | Frames to or from a port that is not a lab tap | leave the chain | This chain is only for VM to VM. Frames for the host are delivered locally and never reach this hook |
| forward: `iifname @mgmt_taps counter drop` (`:69`) | Any frame between two VMs on mgmtbr1: ARP, IP, even "replies" | drop | mgmt is only for host <-> VM (`:68`) |
| forward: `oifname . ip daddr != @lab_addrs counter drop` (`:72`) | IPv4 on wan addressed to an IP that is not the receiving card's own: broadcast, or using another VM as a router | drop | Destination check: a card receives only frames for its own address (`:71`) |
| forward: four `ether type arp accept` rules (`:76-79`) | ARP fe-1 <-> tun-1 and be-1 <-> tun-1 | accept | ARP carries no connection state, so it is allowed before the stateful rules, and only between cards that may talk (`:74-75`) |
| forward: four `ct state established,related accept` rules (`:84-87`) | Replies and related ICMP inside a spoke <-> hub pair | accept | Stateful. Limited to the pairs, so an ICMP error naming another VM's connection is not accepted as "related" (`:81-83`) |
| forward: `oifname @sg_hub jump sg_hub_in` (`:90`) -> `sg_hub_in` (`:99-100`) | New IPv4 UDP to `tun-1-wan`: from fe-1 to dport 51820, from be-1 to dport 51821 | accept | WireGuard: the hub listens on 51820/51821 (`ansible/host_vars/tun-1.yml:5,13`), and the spokes dial those ports (`fe-1.yml:6`, `be-1.yml:6`) |
| forward: `oifname @sg_frontend jump sg_frontend_in`, `oifname @sg_backend jump sg_backend_in` (`:91-92`) | New traffic toward fe-1 or be-1 | nothing accepted (empty chains); falls through to the drop | The spokes start their own tunnels and the hub never opens one (`:103`). `PersistentKeepalive = 25` on the spokes keeps the conntrack entry alive (`ansible/roles/wireguard/templates/wg.conf.j2:19`) |
| forward: `counter drop` (`:95`) | Everything else between taps: fe-1 <-> be-1 (even ARP), other ports and protocols, IPv6 | drop | Default deny (`:94`) |

**Packet-path table, `inet lab_vmfw` (every rule, in file order):**

| Chain: rule (line) | Which traffic | Verdict | Why |
|---|---|---|---|
| nat prerouting: `iifname $lan_card ip daddr $host_ip tcp dport 443 dnat ip to 198.51.100.11` (`:121`) | A LAN client to the host's LAN IP on port 443 | DNAT to fe-1:443 | App ingress. Traefik listens on 10.250.0.1:443, so it is not affected (`:116-117`) |
| nat output: `ip daddr $host_ip tcp dport 443 dnat ip to 198.51.100.11` (`:128`) | A host process to the host's LAN IP on port 443 | DNAT to fe-1:443 | Prerouting never sees traffic the host starts itself (`:124`) |
| forward: `iifname { "wan", "mgmtbr1" } oifname { "wan", "mgmtbr1" } counter drop` (`:147`) | Anything the host would route from a VM-facing interface back to one: VM to VM through the host on either network, even as a "reply" | drop | It comes before `established` because routed and bridged flows share one conntrack table. An ICMP error naming another VM's connection, such as the host's own SSH session into a VM, would otherwise count as related (`:143-146`) |
| forward: `ct state established,related accept` (`:149`) | Replies of allowed flows: fe-1 -> LAN client, Traefik -> VM | accept | Stateful |
| forward: `iifname $lan_card oifname "wan" ip daddr 198.51.100.11 tcp dport 443 ct status dnat accept` (`:150`) | A new LAN -> fe-1:443 connection that the rule at `:121` DNATed | accept | Must come before `:153`. `ct status dnat` means a LAN host routing straight to 198.51.100.11 is not let in |
| forward: `iifname "wan" counter drop` (`:152`) | Everything else from the wan, above all VM -> LAN/internet (each VM's default route points at 198.51.100.1, `terraform/cloud-init/network-config.yaml.tftpl:13-15`) | drop | No VM egress. Packages go through Squid, which is host traffic (`:131-134`) |
| forward: `oifname "wan" counter drop` (`:153`) | Everything else toward the wan: LAN hosts or containers to a VM's wan IP | drop | Only the DNATed app flow reaches fe-1 |
| forward: `iifname "mgmtbr1" ip saddr { 10.250.0.110, 10.250.0.111, 10.250.0.112 } ct original ip daddr 10.250.0.1 ct original proto-dst 443 ct status dnat accept` (`:155`) | VM -> 10.250.0.1:443. Podman's port mapping DNATs it into the Traefik container (`services/traefik/compose.yaml:15`), so the packet is forwarded, not delivered to input | accept | The one VM -> container path. The original destination is pinned to 10.250.0.1:443, so no other port mapping on 443 qualifies (`:154`). Traefik then narrows by source and path (`allowlists.yml`, Step 3.8) (`:135-139`) |
| forward: `iifname { "mgmtbr1", "site-a", "site-hub", "site-c" } counter drop` (`:156`) | The rest from mgmt: VM -> Vault 10.250.0.1:8200 (also a Podman DNAT), VM -> internet via 10.250.0.1. The site bridges are listed as a guard | drop | VMs reach only Traefik through the host's routing |
| forward: `oifname { "mgmtbr1", "site-a", "site-hub", "site-c" } counter drop` (`:157`) | Anything routed toward the VMs' mgmt or site networks | drop | The site bridges have no host address (`terraform/network.tf:1-38`). The rule is a guard in case one ever gets one (`:132-133`) |
| forward: policy accept (`:141`) | Other routed traffic, such as Podman containers to the internet | accept | lab_vmfw only constrains the VM-facing interfaces |
| input: `iifname "wan" ct state established,related accept` (`:171`) | Replies to connections the host started over the wan (for example the host's browser -> fe-1 via `:128`) | accept | Stateful |
| input: `iifname "wan" counter drop` (`:172`) | VM -> any host address over the wan (198.51.100.1, the LAN IP, ...) | drop | VMs reach host services only over mgmt (`:160`) |
| input: `iifname "mgmtbr1" ct state established,related accept` (`:174`) | Replies to the host's own connections into the VMs: ssh, and Ansible from the runner | accept | (`:166-167`) |
| input: `iifname "mgmtbr1" ip daddr 10.250.0.1 udp dport { 53, 123 } accept` (`:175`) | DNS to CoreDNS and NTP to chrony | accept | Services the VMs use |
| input: `iifname "mgmtbr1" ip daddr 10.250.0.1 tcp dport { 53, 3128 } accept` (`:176`) | DNS over TCP, and Squid | accept | Services the VMs use |
| input: `iifname "mgmtbr1" icmp type { echo-request, destination-unreachable, time-exceeded } accept` (`:177`) | Ping and ICMP errors, to any host address | accept | Diagnostics and path errors |
| input: `iifname "mgmtbr1" counter drop` (`:178`) | Everything else from mgmt: host sshd, CoreDNS on the LAN IP, aardvark-dns on 10.89.x.1, anything added later | drop | The service rules match 10.250.0.1 only, the address the VMs are given (`:161-165`) |
| input: policy accept (`:169`) | Traffic arriving on the LAN card, lo or Podman bridges | accept | Outside the VM firewall's scope |

**The same rules, read by path:**

| Path | Rules it meets | Result |
|---|---|---|
| VM -> VM on mgmtbr1 | lab_sg forward `:69` | dropped |
| fe-1 -> tun-1 udp 51820, be-1 -> tun-1 udp 51821 | lab_sg prerouting `:58`, forward `:72`, `sg_hub_in:99-100`; replies `:85`, `:87` | allowed (the WireGuard underlay) |
| fe-1 <-> be-1 on wan, anything | lab_sg forward `:95` | dropped; they talk only through the hub's tunnels |
| VM -> CoreDNS, chrony or Squid on 10.250.0.1 | lab_sg prerouting, lab_vmfw input `:175-176` | allowed |
| VM -> Traefik 10.250.0.1:443 | lab_sg prerouting, Podman DNAT, lab_vmfw forward `:155` | allowed, then filtered by Traefik's allowlists |
| VM -> Vault 10.250.0.1:8200 | lab_vmfw forward `:156` | dropped; the pipeline reads Vault from the host (`.gitea/workflows/ansible.yml:18-20`) |
| VM -> host sshd or any other host port | input `:178` (mgmt) or `:172` (wan) | dropped |
| VM -> internet directly | forward `:152` (via wan) or `:156` (via mgmt) | dropped; the VM must use Squid |
| LAN browser -> `https://app.lab.test` (resolves to the host's LAN IP) | nat prerouting `:121`, forward `:150`; replies `:149` | reaches fe-1 |
| Host browser -> host LAN IP:443 | nat output `:128`; replies input `:171` | reaches fe-1 |
| Host (runner, operator) -> VM ssh | host output (not filtered); replies input `:174` | allowed |
| Forged source, forged ARP or VLAN-tagged frame from a VM | lab_sg prerouting `:57-59` | dropped |

**Why here:** It needs `detect_network` (Step 2.1) for `$lan_card`/`$host_ip`, and it needs the nftables package. It must be loaded before any VM can run: the terraform job refuses to apply without `/run/lab/vmfw.loaded` (`.gitea/workflows/terraform.yml:15-16`, Step 6.1). It does not need `mgmtbr1`, the taps or the libvirt bridges to exist, because `iifname`/`oifname` compare names on each packet. So the tables load on a host with no VM, and running it after Step 2.5 is a grouping choice, not a dependency. The order that matters is in destroy: kvm before vmfw. Its input holes serve chrony (2.3), CoreDNS (3.1) and Squid (3.2). Its forward hole serves Traefik (3.8).

**How it connects:**
- The marker `/run/lab/vmfw.loaded` is the first check of the terraform job (Step 6.1).
- The `$host_ip` DNAT, CoreDNS's `app.lab.test -> HOST_IP` (`services/coredns/conf/Corefile:6`, Step 3.1) and the frontend on 198.51.100.11:443 (Phase 9) together make the app ingress path (Step 11.1).
- Names and addresses are copied from `terraform/compute.tf:10-11,23-24,36-37,157,163` and `terraform/network.tf` (Steps 6.4, 6.5). The WireGuard ports are copied from the host_vars (Step 7.5).
- The lab_sg source check, plus rule `:155`, is what lets Traefik's `ipAllowList` (`services/traefik/dynamic/allowlists.yml:5-13`, Step 3.8) and Squid's `acl backend src 10.250.0.112` (`services/squid/conf/squid.conf:8`, Step 3.2) trust VM source IPs. "No VM egress except Squid" is the premise of `squid.conf:1-3`.

**Re-run and removal:** Every run renders the ruleset again (picking up the current LAN IP), reloads both tables in one transaction (counters reset to zero), and touches the marker again. Running VMs are never unfiltered during the swap. If `nft -c` fails, the run stops and the old rules stay loaded. **Reboot:** the tables and the `/run` marker vanish together. The domains have `autostart = false` (`terraform/compute.tf:98`), so no VM runs unfiltered. The next `update` reloads the rules; `up` would return early on an initialized lab (`main.py:70-72`). The pipeline's `terraform apply` (`running = true`, `compute.tf:97`) then starts the VMs. **Removal:** `vmfw.down` in destroy (`main.py:56`), after `kvm.down`.

**Check it yourself:**
- `ls -l /run/lab/vmfw.loaded`: its timestamp is the last run.
- (sudo) `sudo nft list chain inet lab_vmfw forward` and `sudo nft list table bridge lab_sg` show the loaded rules, with drop counters.
- After Phase 7: `ssh fe-1 ping -c1 -W2 198.51.100.13` fails (fe-1 and be-1 share no group), and `ssh fe-1 curl -sS -m5 https://1.1.1.1` times out (no egress).

**Watch out:**
- Every VM name, tap name, address and WireGuard port in the file is a hand copy of Terraform and the host_vars. Adding a VM or changing an IP means editing the sets (`:15-42`) and the source set in `:155`.
- After the host's LAN IP changes, `$host_ip` stays stale until the next `update`.
- In nftables a drop in any base chain is final, while an accept only ends that one chain. So libvirt's and Podman's own accept rules cannot open what lab_vmfw drops.
- Once loaded, `nf_conntrack_bridge` tracks frames on every bridge, Podman's and libvirt's included (`:6-7`).
- The comment at `terraform/compute.tf:98` names `bootstrap up` as the command that reloads these rules after a reboot. It is `update` (Step 6.7, Watch out).

### Step 2.7: toolchain (platform_up step 7): CI binaries on the host

**Files:**
- `host/toolchain.py`: installs the pinned, sha256-checked terraform, node and trivy binaries, plus apt `ansible-core` and the `cloud.terraform` collection, for the pipeline jobs.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `installed_version_ok(cmd: list[str], version: str) -> bool` | Returns False if `cmd[0]` does not exist (`:22-23`), cannot run, or exits non-zero. Runs with a 30 s timeout and `CHECKPOINT_DISABLE=1` (no HashiCorp version check call). True if `version` is one of the whitespace-separated words in stdout (`host/toolchain.py:20-39`) | the four `ensure_*` -> `subprocess.run` | runs the tool |
| 2 | `download(url: str, sha256: str) -> bytes` | Reads the whole file into memory (120 s timeout). Raises `RuntimeError` if the sha256 does not match (`host/toolchain.py:42-50`) | `ensure_terraform`, `ensure_node`, `ensure_trivy` -> `urllib`, `hashlib` | network |
| 3 | `ensure_terraform() -> None` | Skips if `/usr/local/bin/terraform version` prints `v1.17.2`. Otherwise downloads the zip, reads only the member `terraform`, and `write_file`s it with mode 0755 (`host/toolchain.py:53-63`) | `up` -> `installed_version_ok`, `download`, `write_file` | `/usr/local/bin/terraform` |
| 4 | `ensure_ansible() -> None` | `apt_install(["ansible-core"])` from Ubuntu. Skips the rest if `ansible-galaxy collection list cloud.terraform -p /usr/share/ansible/collections` shows `4.0.0`. Otherwise runs `ansible-galaxy collection install cloud.terraform:==4.0.0 -p ...`, pinned by version only (`host/toolchain.py:66-85`) | `up` -> `apt_install`, `installed_version_ok`, `ansible-galaxy` | `/usr/share/ansible/collections/ansible_collections/cloud/` |
| 5 | `ensure_node() -> None` | Same pattern. Takes only `node-v24.22.3-linux-x64/bin/node` from the tar.xz (no npm) (`host/toolchain.py:88-99`) | `up` | `/usr/local/bin/node` |
| 6 | `ensure_trivy() -> None` | Same pattern. Takes only the member `trivy` from the tar.gz (`host/toolchain.py:102-113`) | `up` | `/usr/local/bin/trivy` |
| 7 | `up() -> None` | The four ensures, in order (`host/toolchain.py:116-121`) | `platform_up` step 7 (`main.py:38`) | none |
| 8 | `down() -> None` | Unlinks the three binaries, removes `ansible_collections/cloud` (the whole `cloud` namespace), and purges `ansible-core` (`host/toolchain.py:124-131`) | `platform_down` (`main.py:54`) -> `apt_purge` | removes the toolchain |

**Why here:** It needs nothing from the other host steps, only internet access. It must exist before the runner's first job (Phase 5). It is the last host-base step before the services.

**How it connects:**
- terraform is used by `check.yml:13-15` (Step 5.5), `terraform.yml:19-20` (Step 6.1), `ansible.yml:37-38` (Step 7.1) and `teardown.yml:23-24` (Step 12.1). Its version must equal `terraform/provider.tf:2`.
- trivy is used by `check.yml:16-17` (Step 5.5) and `image.yml:22-25` (Step 5.6).
- `ansible-playbook site.yml` runs in `ansible.yml:47`. The inventory plugin `cloud.terraform.terraform_provider` (`ansible/inventory.yml:2`) reads the Terraform state (Steps 7.1-7.2).
- node runs the JavaScript actions on the host-mode runner (label `host:host`, `services/gitea/runner/files/config.yaml:10-11`). These are `actions/checkout@v4` in every job workflow (`check.yml:10`, `image.yml:10`, `terraform.yml:12`, `ansible.yml:12`, `teardown.yml:18`; `deploy.yml` has no steps), `hashicorp/vault-action@v4` and `webfactory/ssh-agent` (`ansible.yml:18,33`), and `actions/upload-artifact@v4` (`image.yml:28`). `NODE_EXTRA_CA_CERTS=/etc/lab-runner/ca.pem` (`ansible.yml:10`) makes node trust the lab CA when it talks to `https://vault.lab.test:8200` (Steps 4.8, 7.1).

**Re-run and removal:** A second run does four version probes and downloads only on a mismatch. Removal: `toolchain.down` (`main.py:54`) runs right after `runner.down` and `ssh_access.down`, so no job can still be using the tools.

**Check it yourself:**
- `terraform version; node --version; trivy --version`
- `ansible-galaxy collection list cloud.terraform -p /usr/share/ansible/collections`

**Watch out:**
- `write_file` replaces a binary in place: touch, chmod, then write (`lib/system.py:57-65`). Bumping a version while a job is running that binary can fail with "Text file busy".
- `cloud.terraform` is pinned by version only, while the three binaries are pinned by sha256. `ansible-core` is whatever version Ubuntu 24.04 ships.

## Phase 3: Host services

Phase 3 starts the platform services that everything later talks to. It brings up CoreDNS for the `lab.test` names and Squid as the VMs' only way to the internet. It makes the lab PKI (one root CA and three leaf certificates). It starts Vault: init, unseal, AppRole identities, root token revocation, and the pipeline secrets in KV. It starts Traefik, the HTTPS gateway with per-route IP allowlists. Last comes the monitoring stack: Prometheus, Loki, Grafana and the host's own Alloy agent. It runs as `platform_up` steps 8-12 (`main.py:39-43`) and step 14 (`main.py:45`) on every `up`, `update` and `teardown` (`main.py:74`, `:86`, `:95`). Step 13, `gitea.up` (`main.py:44`), runs between Traefik and monitoring in the real run. It is read in Phase 4: monitoring does not depend on Gitea, and Gitea does not depend on monitoring. `destroy` runs the matching `down()` functions in reverse order (`main.py:57-63`). When the phase ends, the host answers `*.lab.test` on 10.250.0.1:53 and on its LAN IP. Squid listens on 10.250.0.1:3128. `state/pki/` holds the CA and the `vault`, `gateway` and `app-edge` leaves. Vault is unsealed on 10.250.0.1:8200, its root token is revoked, and the AppRole `lab-bootstrap` is the only identity bootstrap uses. KV holds the pipeline's SSH key, the app database password, the app-edge certificate and the Grafana admin. Traefik serves seven routers on 10.250.0.1:443. Prometheus and Loki already receive the host's metrics and journal through Traefik. Gitea is still missing in reading order, so the `gitea` routes answer 502 until Step 4.1. No VM exists yet.

**Needs from earlier phases:**
- A root process in the repo root with logging and the run lock (Steps 1.1-1.3). `setup_logging` creates `state/` (`lib/log.py:49`), and `state/pki/` is created inside it.
- `lib/config.py` (Step 1.4): `VMNET` 10.250.0.1/24 (`:18`), `LAB_DIR = /var/lib/lab` (`:13`), `SERVICES_DIR` (`:14`), `COMPOSE`/`DOCKER_HOST` (`:24-25`), the PKI group (`:28-39`), the Vault group (`:42-46`), `LAB_ADMIN` (`:8`).
- `lib/system.py` (Step 1.5): `compose()` (`:73-80`), `apt_install`/`apt_purge` (`:31-49`).
- The package layout: each service imports as `services.<name>.<module>` (Step 1.6, `main.py:14-22`).
- `preflight.detect_network()` for the host's LAN IP (Step 2.1, `host/preflight.py:21-36`).
- 10.250.0.1 on `mgmtbr1`, and the host resolver route that sends `~lab.test` to 10.250.0.1 (Step 2.2, `host/files/60-lab-mgmtbr1.yaml:10-13`).
- The Podman API socket, the Compose plugin, and `podman.check()` (Step 2.4).
- vmfw (Step 2.6). The input chain opens udp 53/123 and tcp 53/3128 on 10.250.0.1 to the VMs (`host/files/nftables-vmfw.nft:175-176`). The forward chain lets the three VM mgmt IPs reach the DNATed 10.250.0.1:443 (`:155`). lab_sg drops spoofed sources, which is what lets Traefik and Squid trust a VM's source address.
- Internet access for apt (`golang-cfssl`) and for the image pulls from docker.io.

**Hands on:**
- DNS: `gitea`, `vault`, `proxy`, `grafana`, `prometheus` and `loki.lab.test` -> 10.250.0.1. `app.lab.test` -> the host LAN IP. `k3s.lab.test` -> 10.250.0.112 (nothing uses it). All are served on 10.250.0.1:53 and `<host LAN IP>:53`.
- Egress proxy `http://proxy.lab.test:3128` (10.250.0.1:3128).
- PKI: `state/pki/ca.pem` (+ `ca-key.pem`), and the leaves `vault`, `gateway` and `app-edge` as `.pem`/`-key.pem`/`.csr`. Also the `certs_changed` flag for Vault and Traefik.
- Vault: `https://10.250.0.1:8200` = `https://vault.lab.test:8200` (host only). Files `/var/lib/lab/vault-init.json` (unseal key, revoked root token) and `/var/lib/lab/approle.json` (lab-bootstrap's role_id + secret_id). Policies `lab-bootstrap` and `lab-pipeline`. The AppRole auth method with role `lab-bootstrap`. KV v2 at `kv/` with `kv/data/lab/pipeline/{ssh,app-db,app-edge}` and `kv/data/lab/bootstrap/grafana-admin`. The library functions `vault.vault_api` and `vault.login` (used by monitoring, Gitea, the runner and `main.py`) and `vault.approle_credentials` (used by Gitea).
- Traefik: `https://{gitea,grafana,prometheus,loki}.lab.test` on 10.250.0.1:443. The middlewares `host-only`, `vms-and-host` and `flux-and-host`. The Podman network `lab-backend`, which Gitea (Step 4.1) and monitoring join.
- Monitoring: the push URLs `https://prometheus.lab.test/api/v1/write` and `https://loki.lab.test/loki/api/v1/push`, and the Grafana UI with two dashboards.
- Compose projects `lab-coredns`, `lab-squid`, `lab-vault`, `lab-traefik`, `lab-monitoring`. Containers `coredns`, `squid`, `vault`, `traefik`, `prometheus`, `loki`, `grafana`, `alloy`. Volumes `lab-vault_vault-data` and `lab-monitoring_{prometheus,loki,grafana,alloy}-data`. Networks `lab-vault` and `lab-backend`.

### Step 3.0: The service pattern

**Files:**
- `lib/system.py` (introduced in Step 1.5): this phase uses only `compose()`, the one function through which every service drives its project.
- `podman/podman.py` (introduced in Step 2.4): this phase uses only `check()`, the guard at the top of every service `down()`.
- `lib/config.py` (introduced in Step 1.4): this step uses `SERVICES_DIR`, `COMPOSE` and `DOCKER_HOST`.
- The empty package markers `services/__init__.py` and `services/<name>/__init__.py` are covered in Step 1.6.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `SERVICES_DIR`, `COMPOSE`, `DOCKER_HOST` | Defined in Step 1.4 (rows 3 and 6): `<repo>/services` with one folder per host Podman service, Ubuntu's Compose v2 plugin binary run directly, and Podman's Docker-compatible socket (`lib/config.py:14,24-25`) | read by `compose()`. `SERVICES_DIR` also builds `VAULT_POLICY_DIR` (`:45`) | none |
| 2 | `compose(service: str, *args: str, env: dict[str, str] \| None = None) -> None` | Built in Step 1.5 (row 9). What matters for the services: it lays `env` over the process environment, so `env` fills the `${...}` variables in the compose file. `check=True`: a failed compose raises `CalledProcessError`, which `main()` turns into exit 1 with the traceback in the log file only (`lib/system.py:73-80`, `main.py:154-157`) | `up`/`down` of dns, squid, vault, traefik, monitoring (and gitea, Step 4.1) -> `subprocess.run` | the Podman socket: pulls images, creates and removes containers, networks and volumes |
| 3 | `podman.check() -> bool` | True if the Podman packages are installed and `podman.socket` is enabled and active (`podman/podman.py:34-35`) | the first line of `dns.down` (`services/coredns/dns.py:22`), `squid.down` (`services/squid/squid.py:25`), `vault.down` (`services/vault/vault.py:252`), `traefik.down` (`services/traefik/traefik.py:20`), `monitoring.down` (`services/monitoring/monitoring.py:66`), and `gitea.down` | none |
| 4 | Service folder shape | Each service is `services/<name>/compose.yaml` (project `lab-<name>`, a fixed `container_name`, image tag pinned by `@sha256` digest, `restart: unless-stopped`) plus `<name>.py` (CoreDNS: `dns.py`) with `up()` and `down()`. Config files sit next to them and are mounted read-only. Monitoring adds a `config/` settings module, and Vault adds `policies/` | read by `compose()` | none |
| 5 | Recreate-on-change rule | Compose recreates a container when its definition changes (image, env, mounts, flags), but not when the content of a bind-mounted file changes. The lab handles config edits in four ways. (a) A hash of the config in an env var: `SQUID_CONF_HASH` (`services/squid/squid.py:18-19`, `services/squid/compose.yaml:10`), one `*_CONF_HASH` per monitoring folder (`services/monitoring/monitoring.py:57`, `services/monitoring/compose.yaml:15,28,43,62`). (b) `--force-recreate` when the PKI issued new certificates (`services/vault/vault.py:228-229`, `services/traefik/traefik.py:14`). (c) The service reloads by itself: CoreDNS's `reload` plugin (`services/coredns/conf/Corefile:11`), Traefik's file provider (`services/traefik/compose.yaml:11`). (d) Vault policies are uploaded through the API on every run (`services/vault/vault.py:243`) | design rule used by Steps 3.1-3.10 | none |
| 6 | Shared hardening | `cap_drop: [ALL]` on every service except CoreDNS (`services/squid/compose.yaml:14`, `services/vault/compose.yaml:22`, `services/traefik/compose.yaml:21`, `services/monitoring/compose.yaml:19,32,49,73`). Only Vault (10.250.0.1:8200) and Traefik (10.250.0.1:443) publish ports. CoreDNS, Squid and the host Alloy use the host network. Prometheus, Loki and Grafana are reachable only through Traefik | compose files | none |

**Why here:** Every service below is built from this pattern, so read it once first. It needs Podman's socket and the Compose plugin (Step 2.4). It also needs 10.250.0.1 on `mgmtbr1` (Step 2.2), because CoreDNS and Squid bind to it and Vault and Traefik publish on it.

**How it connects:**
- Every `compose()` call in Steps 3.1-3.10 and 4.1 goes through the socket that Step 2.4 enables.
- `podman.check()` makes every service `down()` a no-op once Podman is gone, so `destroy` can be re-run after a partial removal (Step 12.2).
- `certs_changed` from Step 3.3 feeds rule 5(b) in Steps 3.7 and 3.8.

**Re-run and removal:** `compose up -d` on an unchanged project does nothing. Each `down()` is guarded by `podman.check()`. `podman.down` runs after all of them (`main.py:57-64`), and its `podman system reset --force` removes anything they left behind (`podman/podman.py:56`).

**Check it yourself:**
- (sudo) `sudo podman ps --format '{{.Names}} {{.Status}}'` lists coredns, squid, vault (healthy), traefik, gitea (healthy), prometheus, loki, grafana and alloy.
- `systemctl is-active podman.socket` prints `active`.

**Watch out:** The containers are rootful. A plain `podman ps` as the operator looks at a separate rootless store and shows nothing.

### Step 3.1: CoreDNS (platform_up step 8)

**Files:**
- `services/coredns/dns.py`: starts CoreDNS with the live LAN IP, and removes it.
- `services/coredns/compose.yaml`: project `lab-coredns`, one host-network container.
- `services/coredns/conf/Corefile`: the `lab.test` zone from an inline hosts list, plus a block that refuses and logs every other name.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Corefile `lab.test:53` block, `bind` | A server block for the zone `lab.test`. `bind 10.250.0.1 {$HOST_IP}` listens only on the mgmt address and the LAN IP, not on 0.0.0.0 (`services/coredns/conf/Corefile:2-3`). Binding named addresses leaves port 53 free on the host's other addresses: systemd-resolved's stub on 127.0.0.53, and Podman's aardvark-dns on its 10.89.x.1 gateways (named in the comment at `host/files/nftables-vmfw.nft:164`) | read by CoreDNS at start and on reload | udp/tcp 53 on 10.250.0.1 and the LAN IP |
| 2 | Corefile `hosts` entries | `gitea`, `vault`, `proxy`, `grafana`, `prometheus` and `loki.lab.test` -> 10.250.0.1 (`:5`). `app.lab.test` -> `{$HOST_IP}` (`:6`). `k3s.lab.test` -> 10.250.0.112 (`:7`) | lookups from the host, the VMs and LAN clients | none |
| 3 | `errors`, `log`, `reload` | Errors and a query log go to the container's stdout. `reload` re-reads an edited Corefile by itself, so no recreate is needed (`:9-11`) | CoreDNS | container log |
| 4 | Corefile `.:53` block | The same `bind` (`:19`). `template ANY ANY { rcode REFUSED }` refuses every name outside `lab.test` (`:21-23`), and `errors`/`log` record each refused query (`:25-26`). The comment explains the choice: the VMs reach the internet only through Squid, which resolves names on the host, so a recursive resolver here would only give a VM or pod a DNS side channel around Squid's allowlist (`:14-17`) | VM and pod lookups of internet names | container log (the comment says: journal -> Loki) |
| 5 | `compose.yaml` service `coredns` | Image `coredns/coredns:1.15.0@sha256:...`, `container_name: coredns`, `restart: unless-stopped`, `network_mode: host` so it can bind host addresses, env `HOST_IP: ${HOST_IP}`, `./conf` mounted read-only at `/etc/coredns`, `-conf /etc/coredns/Corefile`. No `cap_drop`: it binds port 53 (`services/coredns/compose.yaml:1-13`) | `compose("coredns", ...)` | container `coredns` |
| 6 | `up() -> None` | Reads `host_ip` live with `detect_network()` and runs `compose coredns up -d` with `HOST_IP` set. Logs both addresses (`services/coredns/dns.py:13-17`) | `platform_up` step 8 (`main.py:39`) -> `detect_network`, `compose` | starts or keeps the container |
| 7 | `down() -> None` | Returns early if `podman.check()` fails. Otherwise runs `compose coredns down`, calling `detect_network()` again only to fill `${HOST_IP}` (`services/coredns/dns.py:20-26`) | `platform_down` (`main.py:63`) -> `podman.check`, `detect_network`, `compose` | removes the container |

**Why here:** It is the first service, because later steps use the names. Gitea's API calls and the runner registration use `gitea.lab.test` (Steps 4.2, 4.10). `wait_ready` and the host Alloy use `prometheus.lab.test` and `loki.lab.test` (Step 3.10). The pipeline uses `vault.lab.test` (Step 7.1), and the VMs use every name from Phase 6 on. It needs only 10.250.0.1 (Step 2.2), Podman (Step 2.4) and the LAN IP (Step 2.1). Vault does not need it, because `vault_api` uses the IP (`lib/config.py:43`).

**How it connects:**
- The host resolves `lab.test` here through the netplan route `nameservers 10.250.0.1` + `search ~lab.test` (`host/files/60-lab-mgmtbr1.yaml:11-13`, Step 2.2). Other names go to the LAN resolver.
- The VMs get DNS server 10.250.0.1 from cloud-init (`terraform/cloud-init/network-config.yaml.tftpl:22`, Step 6.6). vmfw lets them reach port 53 on 10.250.0.1 only (`host/files/nftables-vmfw.nft:175-176`, Step 2.6).
- `app.lab.test` -> LAN IP, plus the vmfw DNAT `<LAN IP>:443` -> fe-1 198.51.100.11 (`host/files/nftables-vmfw.nft:121,128`), is the app's ingress path (Steps 2.6, 11.1).
- `proxy.lab.test` points the VMs at Squid (Step 3.2). The four gateway names must match the `gateway` certificate's SANs (`lib/config.py:37`, Step 3.3) and Traefik's `Host()` rules (Step 3.8). `vault.lab.test` must match the vault certificate's SANs (`lib/config.py:36`).

**Re-run and removal:** `compose up -d` changes nothing while the image and `HOST_IP` are unchanged. A new LAN IP (DHCP) changes the env, so compose recreates the container. A Corefile edit is invisible to compose (bind mount), but the `reload` plugin picks it up. `down()` removes the container and keeps nothing.

**Check it yourself:**
- `dig +short @10.250.0.1 gitea.lab.test` prints `10.250.0.1`.
- `dig @10.250.0.1 example.com | grep status:` shows `REFUSED`.
- `resolvectl query grafana.lab.test` answers 10.250.0.1 through link `mgmtbr1`.

**Watch out:** The list of names is copied by hand: Corefile, the `gateway` SANs, Traefik's rules, and the client URLs (Steps 3.3, 3.8, 3.10, 10.1). `k3s.lab.test` has no consumer anywhere in the repo. `HOST_IP` is read live on each run. After a LAN IP change, CoreDNS binds an address that is gone, and `app.lab.test` points at the old IP, until the next `update`. `down()` needs a default route, because `detect_network()` raises `IndexError` without one (`host/preflight.py:23`).

### Step 3.2: Squid (platform_up step 9): the VMs' only way out

**Files:**
- `services/squid/squid.py`: starts Squid with a hash of its config, and removes it.
- `services/squid/compose.yaml`: project `lab-squid`, one host-network container.
- `services/squid/conf/squid.conf`: the allowlist proxy policy.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Header and `http_port` | The comment states the premise: vmfw gives the VMs no route out, so this proxy is their only way to the internet (`services/squid/conf/squid.conf:1-3`). `http_port 10.250.0.1:3128` listens on the mgmt address only (`:4`) | Squid | tcp 10.250.0.1:3128 |
| 2 | ACLs `vms`, `pkg_hosts` | `acl vms src 10.250.0.0/24`: any mgmt address, which includes the host's own 10.250.0.1 (`:6`). `acl pkg_hosts dstdomain .archive.ubuntu.com security.ubuntu.com`, where a leading dot means the domain and its subdomains (`:7`) | `http_access` | none |
| 3 | ACLs `backend`, `k3s_hosts` | `acl backend src 10.250.0.112`, be-1's mgmt address (`:8`). `acl k3s_hosts dstdomain get.k3s.io github.com release-assets.githubusercontent.com .docker.io .docker.com ghcr.io pkg-containers.githubusercontent.com` (`:9`) | `http_access` | none |
| 4 | Helper ACLs | `Safe_ports` 80 443, `SSL_ports` 443, `CONNECT` method, `ftp` protocol (`:10-13`) | `http_access` | none |
| 5 | `http_access` list | First match wins (`:15`): deny FTP (`:16`), deny non-80/443 ports (`:17`), deny CONNECT to anything but 443 (`:18`), allow `vms` to `pkg_hosts` (`:19`), allow `backend` to `k3s_hosts` (`:20`), deny everything else (`:21`) | every request | none |
| 6 | `cache`, `access_log`, `pid_filename` | `cache deny all`: no caching (`:23`). The access log is a file inside the container, `/var/log/squid/access.log`, which belongs to the image's user (`:24`). `pid_filename none` writes no pid file, so there is no in-place reconfigure: a config change recreates the container instead (`:25`) | Squid | file inside the container |
| 7 | `compose.yaml` service `squid` | Image `ubuntu/squid:7.2-26.04_edge@sha256:...`, `container_name: squid`, `restart: unless-stopped`, `network_mode: host`, env `SQUID_CONF_HASH: ${SQUID_CONF_HASH:-}`, `./conf` mounted read-only at `/etc/squid-lab`. The entrypoint is `squid-gnutls -N -d 1 -f /etc/squid-lab/squid.conf`: foreground, level-1 debug to stderr. `cap_drop: [ALL]` (`services/squid/compose.yaml:1-14`) | `compose("squid", ...)` | container `squid` |
| 8 | `SQUID_CONF` | Path of `conf/squid.conf` (`services/squid/squid.py:11`) | `up` | none |
| 9 | `up() -> None` | Puts the sha256 of `squid.conf` into `SQUID_CONF_HASH` and runs `compose squid up -d`. A changed file means a changed env, which recreates the container (`services/squid/squid.py:16-20`) | `platform_up` step 9 (`main.py:40`) -> `hashlib`, `compose` | reads `squid.conf`. Starts, keeps or recreates the container |
| 10 | `down() -> None` | Returns early if `podman.check()` fails. Otherwise runs `compose squid down` (`services/squid/squid.py:23-29`) | `platform_down` (`main.py:62`) -> `podman.check`, `compose` | removes the container |

**Why here:** No host step uses Squid. It sits next to CoreDNS because both serve the VMs, and it must be running before the pipeline's first package install on a VM (Phase 7). Squid resolves internet names itself through the host's resolver, so it does not need CoreDNS, which refuses those names anyway (`services/coredns/conf/Corefile:14-16`). The VMs do need CoreDNS, to find `proxy.lab.test`.

**How it connects:**
- `proxy_url: http://proxy.lab.test:3128` (`ansible/group_vars/all.yml:3`) feeds the apt proxy (`ansible/roles/common/tasks/main.yml:30-35`, Step 7.4), the k3s installer (`ansible/roles/k3s/tasks/main.yml:44,51-53`, Step 8.1) and the Flux CLI download (`ansible/roles/fluxcd/tasks/main.yml:9`, Step 8.2).
- Flux pulls the OCI charts through the proxy Secrets `kubernetes/cnpg/proxy-secret.yaml:9` and `kubernetes/monitoring/proxy-secret.yaml:9` (Steps 8.3, 10.2).
- vmfw opens tcp 3128 on 10.250.0.1 to the VMs (`host/files/nftables-vmfw.nft:176`) and drops all forwarded VM traffic except the Traefik flow (`:147-157`), so Squid is the only egress (Step 2.6).
- `acl backend src 10.250.0.112` copies be-1's `mgmt_ip` (`terraform/compute.tf:37`). It can trust the source address because lab_sg drops spoofed sources (Step 2.6).

**Re-run and removal:** Same hash, same env: compose does nothing. An edited `squid.conf` gives a new hash, and the container is recreated with the new policy. `down()` removes the container, and the access log goes with it.

**Check it yourself:**
- `curl -sI -x http://proxy.lab.test:3128 http://archive.ubuntu.com/ubuntu/ | head -1` from the host prints `HTTP/1.1 200 OK`. The host's 10.250.0.1 is inside `acl vms`.
- `curl -sI -x http://proxy.lab.test:3128 https://example.com | head -1` prints `HTTP/1.1 403 Forbidden`: Squid refuses the CONNECT.

**Watch out:** `dstdomain` has no `-n` on `squid.conf:7` and `:9`. Without it, when a request names a bare IP address (`CONNECT 203.0.113.5:443`) and no entry matches, Squid looks up the IP's reverse DNS (PTR) name and matches that against the list. Whoever controls an IP's PTR record can make it read `x.docker.io` or `x.archive.ubuntu.com` and pass the allowlist. `acl ... dstdomain -n ...` turns the reverse lookup off. Squid's per-request decisions are not in the journal or Loki: the access log is a file inside the container, lost on every recreate. The be-1 address (`terraform/compute.tf:37`) and the mgmt range (`lib/config.py:18`) are copied into `squid.conf` by hand.

> **Marked change (not applied), C1:** Add `-n` to both `dstdomain` ACLs (`squid.conf:7` and `:9`) so a request to a bare IP address never matches through the IP's reverse-DNS (PTR) name (see Watch out; reproduced: fe-1 reached `http://195.154.246.97/`, PTR `fr.archive.ubuntu.com`). Add an isolation probe that expects that URL to be blocked from fe-1. The config hash in the compose environment recreates the container on the next `update`. See Appendix C.
> **Marked change (not applied), C10:** The header comment (`squid.conf:1`) cites `build-order.md B08.1`, a section of the previous version of this file. See Appendix C.

### Step 3.3: PKI (platform_up step 10): lab CA and leaves

**Files:**
- `lib/pki.py`: installs cfssl, makes the root CA once, issues every missing leaf, and returns `certs_changed`.
- `lib/cfssl/ca-csr.json`: the root CA's request.
- `lib/cfssl/ca-config.json`: the signing policy for the leaves.
- `lib/config.py` (introduced in Step 1.4): this step uses the PKI group and the `CERTS` table.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `ca-csr.json` | CN `lab.test CA`, ECDSA P-256 key, CA lifetime `8760h` (one year) (`lib/cfssl/ca-csr.json:1-5`) | `cfssl gencert -initca` | none |
| 2 | `ca-config.json` | `signing.default` and the profile `server`, which are identical: `8760h`, usages `digital signature` and `server auth` (`lib/cfssl/ca-config.json:1-14`) | `cfssl gencert -config ... -profile server` | none |
| 3 | PKI paths | `CFSSL_DIR = lib/cfssl`, `PKI_DIR = state/pki`, `LAB_CA = "ca"`, `LAB_CA_CERT = state/pki/ca.pem` (`lib/config.py:28-31`) | `pki.up/down` (`CFSSL_DIR`, `PKI_DIR`, `LAB_CA`). `PKI_DIR` also by `vault.app_edge_cert` (`services/vault/vault.py:137-138`). `LAB_CA_CERT` is read by `vault_api`, `gitea_api`, `gitea.push`, `wait_ready` and `runner.ensure_config` | names the folder |
| 4 | `CERTS` | name -> (profile, hosts, key owner). `vault`: `vault.lab.test`, `10.250.0.1`, `127.0.0.1`, key owned by `(100, 1000)`, the Vault image's user (`lib/config.py:36`). `gateway`: `gitea`, `grafana`, `prometheus`, `loki.lab.test`, owner root (`:37`). `app-edge`: `app.lab.test`, owner root (`:38`). The first host becomes the CN (`lib/pki.py:40`) | `pki.up` | none |
| 5 | `PACKAGES` | `["golang-cfssl"]`, which provides `cfssl` and `cfssljson` (`lib/pki.py:12`) | `up`, `down` | none |
| 6 | `up() -> bool`, root part | `apt_install(PACKAGES)`, then `mkdir state/pki` (0755). If `ca.pem` is missing, it deletes every leaf's `.pem` (the old root's signatures no longer verify) and runs `cfssl gencert -initca`, feeding the JSON output to `cfssljson -bare state/pki/ca`. That writes `ca.pem`, `ca-key.pem` (0600) and `ca.csr` (`lib/pki.py:17-32`) | `platform_up` step 10 (`main.py:41`) -> `apt_install`, `cfssl`, `cfssljson` | writes `state/pki/ca*` |
| 7 | `up() -> bool`, leaf loop | For each `CERTS` entry: skip it if the cert and key exist and the key already has its owner uid. A crash before the chown therefore re-makes it. Otherwise it builds a CSR with an ECDSA P-256 key, signs it with the CA and the given profile, writes it with `cfssljson`, and `chown`s the key so the container user can read its 0600 key. Returns True if anything was made (`lib/pki.py:34-51`) | same -> `cfssl`, `cfssljson`, `os.chown` | writes `state/pki/<name>.pem`, `<name>-key.pem`, `<name>.csr` |
| 8 | `down() -> None` | `rmtree state/pki`, purge `golang-cfssl` (`lib/pki.py:54-58`) | `platform_down` (`main.py:61`) -> `apt_purge` | deletes the CA and every leaf |

**Why here:** Nothing before it uses TLS. It must come right before Vault and Traefik. Both bind-mount single files from `state/pki/` that they read at start (`services/vault/compose.yaml:18-20`, `services/traefik/compose.yaml:19-20`), and both take `certs_changed` (`main.py:41-43`). Later users: `vault.app_edge_cert` (Step 3.7), the host Alloy and `wait_ready` (Step 3.10), and the runner's CA copy (Step 4.8).

**How it connects:**
- `ca.pem` is the trust anchor for every host-side HTTPS client: `vault_api` (`services/vault/vault.py:34`, Step 3.5), `gitea_api` and `git push` (`services/gitea/gitea.py:40,160`, Steps 4.2, 5.2), `wait_ready` (`services/monitoring/monitoring.py:42`) and the host Alloy (`services/monitoring/compose.yaml:72`, Step 3.10).
- `runner.ensure_config` copies it to `/etc/lab-runner/ca.pem` (`services/gitea/runner/runner.py:52`, Step 4.8). From there it reaches the VMs' trust store through `var.lab_ca_cert_file` (`terraform/variables.tf:13-17`, Step 6.6), the ansible job's `NODE_EXTRA_CA_CERTS` (`.gitea/workflows/ansible.yml:10`, Step 7.1), and the Flux Secret `ca.crt` (`ansible/roles/fluxcd/templates/flux-git-auth.yaml.j2:11`, Step 8.2), which k8s-monitoring reuses (`kubernetes/monitoring/helmrelease.yaml:17-26`, Step 10.2).
- Leaves: `vault` is mounted by Vault (Step 3.4), and `gateway` by Traefik (Step 3.8). `app-edge` is copied into Vault KV (Step 3.7) and from there to fe-1 (Step 9.1). It is never mounted on the host.
- The return value `certs_changed` makes `vault.up` and `traefik.up` pass `--force-recreate` (Steps 3.7, 3.8).

**Re-run and removal:** A normal re-run logs "all certificates present" and returns False. A missing leaf, a missing key, or a key with the wrong owner re-issues only that leaf. A missing `ca.pem` makes a new root and re-issues every leaf. `down()` runs after `traefik.down` and `vault.down` (`main.py:59-61`), which mount these files.

**Check it yourself:**
- `openssl x509 -in state/pki/gateway.pem -noout -subject -enddate -ext subjectAltName` shows the four gateway names and an end date one year after issue.
- `ls -ln state/pki/`: `vault-key.pem` is owned by 100:1000, and every `*-key.pem` is mode 0600.
- `openssl verify -CAfile state/pki/ca.pem state/pki/vault.pem` prints `OK`.

**Watch out:** Every certificate lives 8760h, and nothing checks expiry: after a year, TLS fails everywhere at once. Editing the hosts of a `CERTS` entry does not re-issue it, because only existence and key owner are checked. Delete that leaf's `.pem` to force a new one. `certs_changed` is coarse: a new `app-edge` leaf alone also recreates Vault and Traefik. A new root has knock-on effects. The runner's copy changes, so the cloud-init seed changes, and the next pipeline run replaces every VM (`terraform/compute.tf:65,74-75`). The host Alloy keeps the old CA until it is recreated by hand (Step 3.10). uid 100 is the Vault image's user. On the host that number belongs to some local account (`getent passwd 100`), which can therefore read Vault's TLS key. The CA key stays in `state/pki/` in the working tree. `/state/` is git-ignored (`.gitignore:1`), and only single files (the leaves and `ca.pem`, never the folder or `ca-key.pem`) are mounted for TLS (`services/vault/compose.yaml:17-20`, `services/monitoring/compose.yaml:72`). The one exception is the host Alloy, which mounts the whole host root read-only for its node exporter (`/:/host/root:ro`, `services/monitoring/compose.yaml:68`), so the checkout, `state/pki/` included, is visible inside that container.

### Step 3.4: Vault server (platform_up step 11, part 1)

**Files:**
- `services/vault/compose.yaml`: project `lab-vault`: the Vault container, its published port, TLS mounts, data volume and healthcheck.
- `services/vault/vault.hcl`: Vault's server config: UI, raft storage, TLS listener, addresses.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Project and service | `name: lab-vault`. Image `hashicorp/vault:2.2.2@sha256:...`, `container_name: vault`, `restart: unless-stopped`, `command: ["server"]` (`services/vault/compose.yaml:1-8`) | `compose("vault", ...)` | container `vault` |
| 2 | Port and network | Publishes `10.250.0.1:8200:8200`, the host's mgmt address only. Network `vault`, named `lab-vault`, has no other member (`:9-11`, `:30-32`) | Podman | tcp 10.250.0.1:8200, network `lab-vault` |
| 3 | Environment | `VAULT_ADDR=https://127.0.0.1:8200` and `VAULT_CACERT=/vault/tls/ca.pem`, for the `vault` CLI inside the container, which the healthcheck runs (`:12-14`) | healthcheck | none |
| 4 | Mounts | `vault.hcl` read-only, plus three single files from `state/pki`: `vault.pem`, `vault-key.pem`, `ca.pem`. The comment explains why there is no folder mount: the CA key must never be inside a container (`:15-20`). The named volume `vault-data` sits at `/vault/file` (`:21`, `:34-35`) | Podman | volume `lab-vault_vault-data` |
| 5 | Privileges | `cap_drop: [ALL]`. No `no-new-privileges`: with Ubuntu's AppArmor it makes `socket()` fail (`:22-23`) | Podman | none |
| 6 | Healthcheck | `vault status >/dev/null; [ $$? -ne 1 ]` every 10 s, timeout 5 s, 3 retries (`:24-28`). `vault status` exits 0 when unsealed, 2 when sealed and 1 on error. So "healthy" means the server answers, sealed or not, uninitialized included | `compose up --wait` in `vault.up` (`services/vault/vault.py:227-228`) | none |
| 7 | `ui`, `disable_mlock` | The web UI is on (`services/vault/vault.hcl:3`). `disable_mlock = true` (`:4`): with `cap_drop: ALL` the container has no `IPC_LOCK` to lock memory, and HashiCorp recommends disabling mlock with integrated storage anyway | Vault | none |
| 8 | `storage "raft"` | Integrated storage at `/vault/file` (the volume), `node_id = "vault-1"`: a single-node raft cluster (`:6-9`) | Vault | the volume |
| 9 | `listener "tcp"` | `0.0.0.0:8200` inside the container, TLS with `vault.pem`/`vault-key.pem` (`:11-15`) | Vault | none |
| 10 | `api_addr`, `cluster_addr` | `api_addr = https://vault.lab.test:8200` is the address Vault advertises. `cluster_addr = https://127.0.0.1:8201` keeps the raft cluster port inside the container (it is not published) (`:17-18`) | Vault | none |

**Why here:** Vault needs the `vault` leaf and `ca.pem` from Step 3.3 at start. It does not need DNS or Traefik. It is the one HTTPS service that is not behind Traefik: it publishes its own port, and `vault_api` uses the IP. It must run before Step 3.5, which talks to it.

**How it connects:**
- The `vault` leaf's three SANs match its three clients: the pipeline's `vault-action` uses `vault.lab.test` (`.gitea/workflows/ansible.yml:20`, Step 7.1), `vault_api` uses `10.250.0.1` (`lib/config.py:43`, Step 3.5), and the healthcheck uses `127.0.0.1` (`services/vault/compose.yaml:13,25`).
- The key owner `(100, 1000)` from `CERTS` (Step 3.3) is what lets the container's user read the 0600 key.
- `vault.up` relies on the healthcheck passing while sealed: `--wait` returns, then init and unseal run (Steps 3.5, 3.7).
- The VMs cannot reach port 8200. vmfw's forward chain accepts only VM traffic whose original destination is 10.250.0.1:443 (`host/files/nftables-vmfw.nft:155-157`, Step 2.6).

**Re-run and removal:** Compose recreates the container only when `compose.yaml` changes, or with `--force-recreate` when `certs_changed` is true. The data survives in the volume. A new or restarted container starts sealed, and `vault.up` unseals it in the same run (Step 3.5). Removal is `vault.down` (Step 3.7): `compose down --volumes` deletes the container, the network `lab-vault` and the volume.

**Check it yourself:**
- `curl -s --cacert state/pki/ca.pem https://vault.lab.test:8200/v1/sys/seal-status | jq '{initialized, sealed, storage_type}'` shows `true`, `false`, `"raft"`.
- (sudo) `sudo podman inspect --format '{{.State.Health.Status}}' vault` prints `healthy`.

**Watch out:** `update` does not apply an edit to `vault.hcl`. It is a bind-mounted file, so compose sees no change, and unlike Squid and monitoring there is no hash variable. The container keeps the old config until it is recreated (by a cert change or by hand). "Healthy" does not mean ready: that is deliberate, so that `--wait` returns before init and unseal.

### Step 3.5: Vault client, init, unseal (platform_up step 11, part 2)

**Files:**
- `services/vault/vault.py`: this step covers `vault_api`, `init` and `unseal`.
- `lib/config.py` (introduced in Step 1.4): this step uses the Vault group.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Vault settings | `VAULT_PORT = 8200`. `VAULT_ADDR = https://10.250.0.1:8200`: the IP, so no DNS is needed. `VAULT_INIT_FILE = /var/lib/lab/vault-init.json`. `VAULT_POLICY_DIR = services/vault/policies`. `VAULT_APPROLE_FILE = /var/lib/lab/approle.json` (`lib/config.py:42-46`) | `vault.py` | names the two local files |
| 2 | `vault_api(method: str, path: str, body: dict \| None = None, token: str \| None = None) -> dict` | Sends `<method> https://10.250.0.1:8200/v1/<path>` with a JSON body and `X-Vault-Token`. TLS is verified against `state/pki/ca.pem`, with a 10 s timeout. Secrets travel in the body, never in argv. A GET that returns 404 gives `{}`; any other HTTP error raises; an empty response gives `{}` (`services/vault/vault.py:23-42`) | `init`, `mount`, `unseal`, `ssh_key`, `app_db_passwords`, `app_edge_cert`, `policy`, `enable_approle`, `approle_credentials`, `login`, `revoke_root` in `vault.py`; `gitea.py:55,74,109,114,140,146`; `runner.py:64,78`; `monitoring.py:31,35` -> `urllib`, `ssl` | network: Vault's API |
| 3 | `init() -> None` | `GET sys/init`. Initialized and the file exists: logs and returns. Initialized but no file: exit 1, "the unseal key is lost". File exists but Vault is new: exit 1, "it belongs to an older Vault; move it away". Otherwise it sends `PUT sys/init` with 1 share and threshold 1, creates `/var/lib/lab` (0755) if needed, and writes the response (`keys`, `keys_base64`, `root_token`) with `O_EXCL`, mode 0600 and fsync (`services/vault/vault.py:45-65`) | `vault.up` (`:230`) -> `vault_api` | writes `/var/lib/lab/vault-init.json` |
| 4 | `unseal(key: str, timeout: int = 30) -> None` | `GET sys/seal-status`. If unsealed, it logs and returns. If sealed, it sends `PUT sys/unseal` with the key, exits 1 if Vault is still sealed, then polls `GET sys/health` once a second. A non-200 answer (sealed, standby) raises `HTTPError` and is retried until Vault is active. It exits 1 after `timeout` seconds (`services/vault/vault.py:77-94`) | `vault.up` (`:232`) -> `vault_api` | none |

**Why here:** Every later Vault call goes through `vault_api`. `init` must come before `unseal`, because the unseal key comes from init's file. `unseal` must come before any authenticated call (Steps 3.6, 3.7) and before every other Vault user in the run (Steps 3.10, 4.2-4.10, 5.1).

**How it connects:**
- Other modules import `vault_api`: Gitea (`services/gitea/gitea.py:55,74,109,114,140,146`, Steps 4.2, 4.4), the runner (`services/gitea/runner/runner.py:64,78`, Steps 4.9, 4.10) and monitoring (`services/monitoring/monitoring.py:31,35`, Step 3.10).
- `vault.up` reads `vault-init.json` on every run, for the unseal key and the (revoked) root token (`services/vault/vault.py:231-235`, Steps 3.6, 3.7).
- After a host reboot Vault is sealed until the next `update` or `teardown`. That is why `cmd_teardown` runs `platform_up` first (comment `main.py:95`, Step 12.1).
- `cmd_destroy` removes the whole of `/var/lib/lab` at the end (`main.py:103`, Step 12.2).

**Re-run and removal:** `init` logs "already initialized". `unseal` logs "already unsealed" unless the container restarted, in which case it unseals. The two refusal states stop the run with exit 1 and change nothing. Nothing here has its own removal. `vault.down` deletes the init file (Step 3.7).

**Check it yourself:**
- `ls -l /var/lib/lab/vault-init.json` shows `-rw------- root root`.
- `curl -s --cacert state/pki/ca.pem https://10.250.0.1:8200/v1/sys/health | jq '{initialized, sealed, standby}'` shows `true`, `false`, `false`.

**Watch out:** The only unseal key sits on the same host as the data it protects, in a root-only JSON file. The lab trades key separation for unattended unseal: root on the host has Vault. The root token in that file is revoked (Step 3.6), but the unseal key is enough to generate a new one. If Vault restarts outside a bootstrap run (a crash, a reboot), it stays sealed, and the pipeline's `vault-action` fails until the next `update`.

### Step 3.6: Vault identities and root revocation (platform_up step 11, part 3)

**Files:**
- `services/vault/vault.py`: this step covers `policy`, `enable_approle`, `approle_credentials`, `approle`, `login`, `revoke_root` and the first-run branch of `up()`.
- `services/vault/policies/lab-bootstrap.hcl`: the policy for bootstrap's own AppRole.
- `services/vault/policies/lab-pipeline.hcl`: the policy for the CI jobs' AppRole.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `lab-bootstrap.hcl` | Every path is named; there is no bare `*` (comment `:1-3`). `kv/data/*`: create, read, update, delete (`:6-8`). `kv/metadata/*`: read, list, delete (`:9-11`). `sys/mounts`: read, and `sys/mounts/kv`: create, read, update, for `mount()` (`:14-19`). `sys/policies/acl/lab-bootstrap` and `.../lab-pipeline`: create, read, update, only these two names, so this identity cannot create a stronger policy (`:22-27`). `sys/auth`: read (`:30-32`). `auth/approle/role/*`: create, read, update, delete, list (`:33-35`) | uploaded by `policy()` | Vault policy `lab-bootstrap` |
| 2 | `lab-pipeline.hcl` | `kv/data/lab/pipeline/*`: create, read, update. Anything else is denied, including `sys/*` and `auth/*`, so a job cannot widen its own access (`services/vault/policies/lab-pipeline.hcl:1-8`) | uploaded by `policy()` | Vault policy `lab-pipeline` |
| 3 | `policy(token: str) -> None` | For each `policies/*.hcl` in sorted order: `GET sys/policies/acl/<stem>`, and `PUT` the file text if it differs. The file name is the policy name (`services/vault/vault.py:149-160`) | `up` with root on the first run (`:236`), and with lab-bootstrap on every run (`:243`) -> `vault_api` | Vault policies |
| 4 | `enable_approle(token: str) -> None` | `GET sys/auth`. If `approle/` is missing, `POST sys/auth/approle` (`services/vault/vault.py:163-170`). Only root can do this: lab-bootstrap has no rule for `sys/auth/approle` | `up`, first run only (`:237`) -> `vault_api` | the AppRole auth method |
| 5 | `approle_credentials(token: str, role: str) -> dict` | `POST auth/approle/role/<role>` with `token_policies=[role]`, `token_ttl=1h`, `secret_id_ttl=8760h` (create or update). Then `GET .../role-id` and `POST .../secret-id`, which issues a new secret_id every call. Returns `{role_id, secret_id}` (`services/vault/vault.py:173-180`) | `approle` (`:189`); `gitea.pipeline_secrets` for role `lab-pipeline` (`services/gitea/gitea.py:131`, Step 4.4) -> `vault_api` | AppRole role `<role>` |
| 6 | `approle(token: str, role: str, creds_file: Path, owner: tuple[int, int]) -> None` | Skips if `creds_file` exists and is owned by `owner[0]`. Otherwise it gets credentials, deletes any leftover file, writes the JSON with `O_EXCL`, 0600 and fsync, and `chown`s it to `owner` (`services/vault/vault.py:183-199`). The only caller passes `("lab-bootstrap", /var/lib/lab/approle.json, (0, 0))`, so the owner check and chown never matter | `up`, first run only (`:238`) -> `approle_credentials` | writes `/var/lib/lab/approle.json` |
| 7 | `login(creds_file: Path = config.VAULT_APPROLE_FILE) -> str` | Reads `{role_id, secret_id}` from the file and sends `POST auth/approle/login`. Returns a fresh 1 h token with policy `lab-bootstrap`. No caller passes `creds_file` (`services/vault/vault.py:202-208`) | `vault.up` (`:239`), `gitea.up` (`services/gitea/gitea.py:286`), `monitoring.up` (`services/monitoring/monitoring.py:56`), `runner.up` (`services/gitea/runner/runner.py:108`), the command tails (`main.py:75,87,96`) -> `vault_api` | reads `/var/lib/lab/approle.json` |
| 8 | `revoke_root(root: str) -> None` | `POST auth/token/revoke-self` with the root token. A 403 means it is already revoked and is logged as such; any other error raises (`services/vault/vault.py:211-219`) | `up` on every run (`:240`) -> `vault_api` | revokes the root token |
| 9 | First-run branch in `up()` | `if not VAULT_APPROLE_FILE.exists()`: take `root_token` from `vault-init.json`, then `policy(root)`, `enable_approle(root)`, `approle(root, "lab-bootstrap", ...)` (`services/vault/vault.py:234-238`). Then, on every run, `token = login()` and `revoke_root(...)`. The order is deliberate: root is revoked only once `login()` works, so a broken AppRole never locks the lab out (comment `:240`) | `vault.up` | as above |

The Vault API paths the code calls outside KV, and who may call them:

| API path | Method | Called by | Token used | Allowed by |
|---|---|---|---|---|
| `sys/init` | GET, PUT | `init` | none | unauthenticated endpoint |
| `sys/seal-status`, `sys/unseal`, `sys/health` | GET, PUT, GET | `unseal` | none | unauthenticated endpoints |
| `sys/policies/acl/lab-bootstrap`, `sys/policies/acl/lab-pipeline` | GET, PUT | `policy` | root (first run), lab-bootstrap (every run) | root; `lab-bootstrap.hcl:22-27` |
| `sys/auth`, `sys/auth/approle` | GET, POST | `enable_approle` | root, first run only | root (lab-bootstrap may read `sys/auth` but not enable methods) |
| `auth/approle/role/<role>`, `.../role-id`, `.../secret-id` | POST, GET, POST | `approle_credentials` | root (role lab-bootstrap, first run); lab-bootstrap (role lab-pipeline, `gitea.pipeline_secrets`) | root; `lab-bootstrap.hcl:33-35` |
| `auth/approle/login` | POST | `login` | none (role_id + secret_id in the body) | unauthenticated endpoint |
| `auth/token/revoke-self` | POST | `revoke_root` | the root token itself | any token may revoke itself |
| `sys/mounts`, `sys/mounts/kv` | GET, POST | `mount` (Step 3.7) | lab-bootstrap | `lab-bootstrap.hcl:14-19` |

**Why here:** It needs an unsealed Vault and, on the first run, the root token from init (Step 3.5). `policy(root)` comes before `approle(root, ...)`, so that the role's `token_policies=["lab-bootstrap"]` names a policy that exists when the first login uses it. `enable_approle` must come before any role is created. `login` comes before `revoke_root`, and both come before Step 3.7, which runs entirely as lab-bootstrap. Mounting `kv/` after revocation shows that the policy file is enough.

**How it connects:**
- `/var/lib/lab/approle.json` is read by every `login()`. That makes five logins per run: `vault.up`, `monitoring.up` (Step 3.10), `gitea.up` (Steps 4.2-4.4), `runner.up` (Steps 4.8-4.10) and the command tail (Step 5.1).
- Policy `lab-pipeline` plus `approle_credentials` let `gitea.pipeline_secrets` create role `lab-pipeline` and store `VAULT_ROLE_ID`/`VAULT_SECRET_ID` as Gitea Actions secrets (`services/gitea/gitea.py:119-135`, Step 4.4). The ansible job's `vault-action` logs in with them (`.gitea/workflows/ansible.yml:18-30`, Step 7.1).
- File name = policy name = AppRole role name (`services/vault/vault.py:152,176`). Adding an identity means adding `policies/<role>.hcl` plus a rule for it in `lab-bootstrap.hcl:22-27`.

**Re-run and removal:** `policy` re-uploads only edited files. Vault resolves policies by name at request time, so existing tokens get the new rules at once. The first-run branch is skipped while `approle.json` exists. Each `login()` makes a new 1 h token, which is never revoked and simply expires. `revoke_root` gets a 403 and logs "root token is already revoked". `vault.down` deletes `approle.json` after the data (Step 3.7).

**Check it yourself:**
- `grep -E 'root token (revoked|is already revoked)' state/bootstrap.log | tail -1`
- (sudo) From the repo root: `sudo python3 -B -c 'from services.vault import vault; t = vault.login(); print(vault.vault_api("GET", "auth/token/lookup-self", token=t)["data"]["policies"])'` prints `['default', 'lab-bootstrap']`.

**Watch out:** Losing `approle.json` after the first run is a lockout. The branch then runs with a revoked root token, the first `policy(root)` call gets a 403, and the run fails. The code has no recovery path: a new root token has to be generated by hand with the unseal key. The same happens one year after the first run, when lab-bootstrap's secret_id expires (`secret_id_ttl 8760h`, `services/vault/vault.py:177`). Policies upload in alphabetical order with the lab-bootstrap token. A new policy file that sorts before `lab-bootstrap.hcl` is written before the edited lab-bootstrap rule that allows it, so the `update` that adds both fails with 403. The policies grant more than the code uses. CI only reads, but `lab-pipeline` allows create and update, and its comment about jobs writing WireGuard keys matches no job (`lab-pipeline.hcl:5`). `lab-bootstrap` allows `kv/metadata/*`, delete, and `sys/auth` read, which no code path needs.

> **Marked change (not applied), C2:** Make `services/vault/policies/lab-pipeline.hcl:5-8` read-only (`capabilities = ["read"]`) and drop its comment about jobs writing WireGuard keys (they travel as Ansible hostvars, Step 7.5). The pipeline only reads (vault-action, Step 7.1); today a job could overwrite the SSH key, the Flux token, the app-edge certificate or the database password. See Appendix C.

### Step 3.7: Vault KV seeding and lifecycle (platform_up step 11, part 4)

**Files:**
- `services/vault/vault.py`: this step covers `mount`, `ssh_key`, `app_db_passwords`, `app_edge_cert`, `up` and `down`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `mount(token: str, path: str, body: dict) -> None` | `GET sys/mounts`. If `<path>/` is missing, `POST sys/mounts/<path>` with `body` (`services/vault/vault.py:68-74`). `up` calls it with `kv` and `{"type": "kv", "options": {"version": "2"}}` (`:242`) | `up` -> `vault_api` | KV v2 engine at `kv/` |
| 2 | `ssh_key(token: str) -> None` | If `kv/data/lab/pipeline/ssh` exists, it logs and returns. Otherwise it runs `ssh-keygen -t ed25519 -N "" -C lab` in a temporary folder and stores `{private_key, public_key}`. It never replaces an existing pair (`services/vault/vault.py:97-113`) | `up` (`:244`) -> `vault_api`, `ssh-keygen` | KV `lab/pipeline/ssh`; temp files deleted |
| 3 | `app_db_passwords(token: str) -> None` | If `kv/data/lab/pipeline/app-db` is missing, it stores `{authenticator_password: token_urlsafe(24)}`. That is the only key: CNPG's postgres superuser has no password (peer auth only, docstring `:119`) (`services/vault/vault.py:116-131`) | `up` (`:245`) -> `vault_api` | KV `lab/pipeline/app-db` |
| 4 | `app_edge_cert(token: str) -> None` | Reads `state/pki/app-edge.pem` and `app-edge-key.pem`, compares them with `kv/data/lab/pipeline/app-edge`, and writes `{cert, key}` only if they differ (`services/vault/vault.py:134-146`) | `up` (`:246`) -> `vault_api` | reads `state/pki/app-edge*.pem`; KV `lab/pipeline/app-edge` |
| 5 | `up(certs_changed: bool) -> None` | Runs `compose vault up -d --wait --wait-timeout 60`, adding `--force-recreate` if `certs_changed` (`:228-229`). Then `init()`, reading the keys file, `unseal(keys_base64[0])` (`:230-232`). Then the first-run branch (Step 3.6), `login()`, `revoke_root()`. Then, as lab-bootstrap: `mount(kv v2)`, `policy`, `ssh_key`, `app_db_passwords`, `app_edge_cert` (`:242-247`) (`services/vault/vault.py:222-247`) | `platform_up` step 11 (`main.py:42`) -> all of the above, `compose` | container, volume, both JSON files, Vault config and KV |
| 6 | `down() -> None` | If `podman.check()` fails, it logs that the data and unseal key are kept and returns. Otherwise it runs `compose vault down --volumes`, then deletes `vault-init.json` and `approle.json`. The key goes only after the data it unlocks (`services/vault/vault.py:250-258`) | `platform_down` (`main.py:60`) -> `podman.check`, `compose` | removes the container, network, volume and both files |

Every KV path in the lab (KV v2: the API path is `kv/data/<path>`, and the secret sits under `data.data` in the response):

| KV path | Keys | Written by | Read by | Policy that allows it |
|---|---|---|---|---|
| `kv/data/lab/pipeline/ssh` | `private_key`, `public_key` | `vault.ssh_key`, once (`services/vault/vault.py:97-113`, this step) | `runner.ensure_ssh_key` reads `public_key` into `/etc/lab-runner/ssh.pub` (`services/gitea/runner/runner.py:64-66`, Step 4.9). The ansible job reads `private_key` for ssh-agent (`.gitea/workflows/ansible.yml:26,32-35`, Step 7.1) | bootstrap write/read: lab-bootstrap `kv/data/*` (`lab-bootstrap.hcl:6-8`). CI read: lab-pipeline `kv/data/lab/pipeline/*` (`lab-pipeline.hcl:6-8`) |
| `kv/data/lab/pipeline/app-db` | `authenticator_password` | `vault.app_db_passwords`, once (`services/vault/vault.py:116-131`) | the ansible job -> `APP_DB_AUTHENTICATOR_PASSWORD` (`.gitea/workflows/ansible.yml:28,44`) -> Secret `db-authenticator` (`ansible/roles/app_secrets/templates/db-authenticator.yaml.j2:9`, Step 8.5) | lab-bootstrap (write); lab-pipeline (read) |
| `kv/data/lab/pipeline/app-edge` | `cert`, `key` | `vault.app_edge_cert`, every run if the files differ (`services/vault/vault.py:134-146`) | the ansible job -> `APP_EDGE_CERT`, `APP_EDGE_KEY` (`.gitea/workflows/ansible.yml:29-30,45-46`) -> frontend role on fe-1 (`ansible/roles/frontend/tasks/main.yml:32,41`, Step 9.1) | lab-bootstrap (write); lab-pipeline (read) |
| `kv/data/lab/pipeline/gitea-flux` | `username`, `token` | `gitea.flux_token`, once (`services/gitea/gitea.py:138-149`, Step 4.4) | the ansible job reads `token` -> `FLUX_GIT_TOKEN` (`.gitea/workflows/ansible.yml:27,43`) -> Secret `flux-git-auth` (`ansible/roles/fluxcd/templates/flux-git-auth.yaml.j2:9`, Step 8.2) | lab-bootstrap (write); lab-pipeline (read) |
| `kv/data/lab/bootstrap/gitea-admin` | `username`, `password` | `gitea.gitea_admin`, once (`services/gitea/gitea.py:53-76`, Step 4.2) | `gitea.gitea_admin` on every run (`services/gitea/gitea.py:55`), from `gitea.up` and the command tails (`main.py:75,87,96`) | lab-bootstrap only. lab-pipeline has no rule for `lab/bootstrap/*`, so CI is denied |
| `kv/data/lab/bootstrap/gitea-runner` | `token` | `gitea.runner_registration_token`, once (`services/gitea/gitea.py:107-116`, Step 4.4) | `runner.ensure_registered`, only while the runner's `.runner` file is missing (`services/gitea/runner/runner.py:78`, Step 4.10) | lab-bootstrap only |
| `kv/data/lab/bootstrap/grafana-admin` | `username`, `password` | `monitoring.grafana_admin`, once (`services/monitoring/monitoring.py:29-37`, Step 3.10) | `monitoring.grafana_admin` on every run -> `GF_SECURITY_ADMIN_USER/PASSWORD` (`services/monitoring/compose.yaml:41-42`) | lab-bootstrap only |

What `vault.up` does in each state it can find:

| State when `vault.up` starts | Path through `up()` | Result |
|---|---|---|
| Nothing exists (first `up`, or the first run after `destroy`) | compose creates the container and volume. `init` sends `PUT sys/init` and writes `vault-init.json`. `unseal` unseals. `approle.json` is missing, so: `policy(root)`, `enable_approle(root)`, `approle(root)`. Then `login`, `revoke_root` (revoked now), `mount kv` as lab-bootstrap, `policy` (unchanged), and the three seed functions write | Vault initialized, unsealed and configured; root revoked; three pipeline secrets stored |
| Normal re-run, container running and unsealed | compose does nothing. `init`: "already initialized". `unseal`: "already unsealed". Branch skipped. `login`. `revoke_root`: 403, "already revoked". `mount`: "already mounted". `policy`: "unchanged". Seeds: "already exist" / "up to date" | no change |
| Container restarted or recreated (host reboot, `certs_changed`, a new image pin) | compose starts or recreates it, and the healthcheck passes while sealed. `init` skips. `unseal` sends `PUT sys/unseal` and waits for `sys/health`. The rest is as a normal re-run | unsealed again; data unchanged |
| A policy file was edited | `policy(token)` re-uploads it (`:243`) | new rules live for all tokens |
| `app-edge` was re-issued | `app_edge_cert` writes a new KV version | fe-1 gets it on the next pipeline run (Step 9.1) |
| An earlier run stopped after init, before `approle.json` was written | The root token is still valid, so the branch runs again (`enable_approle` skips) | recovers |
| An earlier run stopped after `approle.json`, before revocation | Branch skipped. `login` works, `revoke_root` revokes | recovers |
| `approle.json` lost after root was revoked | The branch runs with a revoked root token. `policy(root)` gets a 403 and the run fails | lockout; manual recovery only (Step 3.6) |
| Volume gone, `vault-init.json` kept | `init` exits 1: "belongs to an older Vault; move it away" | the operator must move away `vault-init.json` and `approle.json` too. A stale `approle.json` skips the branch, and `login` then fails against the new Vault |
| `vault-init.json` gone, volume kept | `init` exits 1: "the unseal key is lost" | no recovery in code |

**Why here:** `kv/` must be mounted, with the lab-bootstrap token from Step 3.6, before anything is stored. `app_edge_cert` needs the `app-edge` leaf from Step 3.3. The `kv/` mount (`services/vault/vault.py:242`) must exist before monitoring adds `grafana-admin` (Step 3.10) and Gitea adds its three entries (Steps 4.2, 4.4); those write their own paths and read none of the seeded ones (`services/monitoring/monitoring.py:29-37`, `services/gitea/gitea.py:53-76,107-116,138-149`). The seeded entries are first read by `runner.ensure_ssh_key` (`services/gitea/runner/runner.py:61-69`, Step 4.9) and the ansible job (Step 7.1).

**How it connects:**
- `ssh` -> `/etc/lab-runner/ssh.pub` -> `var.ssh_public_key_file` (`terraform/variables.tf:7-11`) -> the VMs' authorized keys through cloud-init (Steps 4.9, 6.6). The private half is loaded into the ansible job's ssh-agent (Step 7.1).
- `app-db` -> Secret `db/db-authenticator`, used by the CNPG managed role and PostgREST (Step 8.5).
- `app-edge` -> the TLS certificate and key of the frontend on fe-1 (Step 9.1).
- Gitea's and monitoring's create-once entries reuse the same mount and the same "GET, else create and POST" pattern (Steps 3.10, 4.2, 4.4).

**Re-run and removal:** See the state table. The seed functions write only what is missing (`ssh`, `app-db`) or different (`app-edge`). `down()` is the only path that deletes Vault data. `cmd_destroy` then removes `/var/lib/lab` anyway (`main.py:103`). Gitea and monitoring are removed before Vault (`main.py:57-60`), so Vault never holds credentials for a service that is still running.

**Check it yourself:**
- (sudo) From the repo root: `sudo python3 -B -c 'from services.vault import vault; t = vault.login(); print(vault.vault_api("LIST", "kv/metadata/lab/pipeline", token=t)["data"]["keys"])'` prints `['app-db', 'app-edge', 'gitea-flux', 'ssh']`. `gitea-flux` appears once Step 4.4 has run.
- `head -1 /etc/lab-runner/ssh.pub` (after Step 4.9) is the pipeline public key from `kv/data/lab/pipeline/ssh`, comment `lab`.

**Watch out:** The create-once secrets never rotate. Deleting one by hand makes the next run create a new value. For `ssh` that means a new `ssh.pub`, a new cloud-init seed, and a replacement of every VM on the next pipeline run (`terraform/compute.tf:65,74`). Vault keeps a second copy of the `app-edge` private key: anyone who can read `kv/data/lab/pipeline/*` (both identities) can impersonate `app.lab.test`.

### Step 3.8: Traefik gateway (platform_up step 12)

**Files:**
- `services/traefik/traefik.py`: starts Traefik, recreating it when certificates changed, and removes it.
- `services/traefik/compose.yaml`: project `lab-traefik`: entrypoint, file provider, port, the `lab-backend` network, certificate mounts.
- `services/traefik/dynamic/tls.yml`: loads the `gateway` certificate.
- `services/traefik/dynamic/allowlists.yml`: the three client-IP middlewares.
- `services/traefik/dynamic/gitea.yml`: routers `gitea-flux` and `gitea`, and service `gitea`.
- `services/traefik/dynamic/grafana.yml`: router and service `grafana`.
- `services/traefik/dynamic/loki.yml`: routers `loki-push` and `loki`, and service `loki`.
- `services/traefik/dynamic/prometheus.yml`: routers `prometheus-write` and `prometheus`, and service `prometheus`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Service `traefik`, static config | Image `traefik:v3.7.19@sha256:...`, `container_name: traefik`, `restart: unless-stopped`. Static config as flags: entrypoint `websecure` on `:8443` with TLS on by default, the file provider on `/etc/traefik/dynamic` (watched by default, so edits apply live), log level INFO, access log on. No API or dashboard flag (`services/traefik/compose.yaml:1-13`) | `compose("traefik", ...)` | container `traefik` |
| 2 | Port | `10.250.0.1:443:8443`. The entrypoint is 8443 because `cap_drop: [ALL]` removes the right to bind ports below 1024 (`:14-15`, `:21`) | Podman (DNAT into the container) | tcp 10.250.0.1:443 |
| 3 | Network `backend` = `lab-backend` | Declared and owned by this project (no `external`), so `traefik.up` creates it (`:16`, `:23-25`). Backends are reached on it by container name | Gitea (`external: true`, Step 4.1) and monitoring (Step 3.9) join it | Podman network `lab-backend` |
| 4 | Mounts | `./dynamic` read-only, plus `state/pki/gateway.pem` and `gateway-key.pem` as single files (`:17-20`). The key is root-owned 0600, which the container's root user can read as owner even without capabilities | Traefik | none |
| 5 | `tls.yml` | `tls.certificates`: the `gateway` cert and key (`services/traefik/dynamic/tls.yml:1-4`). Its SANs cover the four gateway names (`lib/config.py:37`) | file provider | none |
| 6 | Middleware `host-only` | `ipAllowList` `10.250.0.1/32`: the host only (operator browser, pipeline, health checks) (`services/traefik/dynamic/allowlists.yml:5-7`). The client IP is the TCP source; the comment notes that lab_sg stops VMs from claiming another address (`:1-2`). Any other source gets 403 | routers below | none |
| 7 | Middleware `vms-and-host` | `10.250.0.1`, `10.250.0.110`, `10.250.0.111`, `10.250.0.112`: every Alloy agent (`:8-10`) | push routers | none |
| 8 | Middleware `flux-and-host` | `10.250.0.1`, `10.250.0.112`: be-1's Flux and the host (`:11-13`) | `gitea-flux` | none |
| 9 | `gitea.yml` | Router `gitea-flux` (`:3-8`), catch-all router `gitea` (`:9-14`), service `gitea` -> `http://gitea:3000` (`:16-20`) | file provider | none |
| 10 | `grafana.yml` | Router `grafana` (`:3-7`), service `grafana` -> `http://grafana:3000` (`:9-13`) | file provider | none |
| 11 | `loki.yml` | Router `loki-push` (`:3-8`), catch-all `loki` (`:9-14`), service `loki` -> `http://loki:3100` (`:16-20`) | file provider | none |
| 12 | `prometheus.yml` | Router `prometheus-write` (`:3-8`), catch-all `prometheus` (`:9-14`), service `prometheus` -> `http://prometheus:9090` (`:16-20`) | file provider | none |
| 13 | `up(certs_changed: bool) -> None` | `compose traefik up -d`, adding `--force-recreate` when `pki.up()` issued new certificates, because they are read at start (`services/traefik/traefik.py:12-15`). No `--wait`: Traefik has no healthcheck | `platform_up` step 12 (`main.py:43`) -> `compose` | container, network |
| 14 | `down() -> None` | Returns early if `podman.check()` fails. Otherwise runs `compose traefik down`, which also removes `lab-backend`. Traefik keeps no state (`services/traefik/traefik.py:18-24`) | `platform_down` (`main.py:59`) -> `podman.check`, `compose` | removes the container and network |

Every router (all on entrypoint `websecure`, TLS with the `gateway` certificate). A higher priority is checked first. A router without a priority gets the length of its rule (Traefik's default).

| Router | Rule | Priority | Middleware (allowlist) | Backend | Who uses it |
|---|---|---|---|---|---|
| `gitea-flux` | `` Host(`gitea.lab.test`) && PathPrefix(`/lab/lab.git/`) `` | 100 | `flux-and-host` | `http://gitea:3000` | be-1's Flux GitRepository (`ansible/roles/fluxcd/files/flux-sync.yaml:9`, Step 8.2) |
| `gitea` | `` Host(`gitea.lab.test`) `` | 1 | `host-only` | `http://gitea:3000` | Gitea UI, API, push, runner (Steps 4.2-4.10, 5.2) |
| `grafana` | `` Host(`grafana.lab.test`) `` | default (rule length) | `host-only` | `http://grafana:3000` | the operator's browser |
| `loki-push` | `` Host(`loki.lab.test`) && Path(`/loki/api/v1/push`) && Method(`POST`) `` | 100 | `vms-and-host` | `http://loki:3100` | host Alloy (Step 3.10), VM Alloy (`ansible/roles/alloy/templates/config.alloy.j2:64`, Step 10.1), k8s-monitoring (`kubernetes/monitoring/helmrelease.yaml:37`, Step 10.2) |
| `loki` | `` Host(`loki.lab.test`) `` | 1 | `host-only` | `http://loki:3100` | `wait_ready` (`/ready`), queries from the host |
| `prometheus-write` | `` Host(`prometheus.lab.test`) && Path(`/api/v1/write`) && Method(`POST`) `` | 100 | `vms-and-host` | `http://prometheus:9090` | host Alloy, VM Alloy (`config.alloy.j2:30`), k8s-monitoring (`helmrelease.yaml:34`) |
| `prometheus` | `` Host(`prometheus.lab.test`) `` | 1 | `host-only` | `http://prometheus:9090` | `wait_ready` (`/-/ready`), UI and queries from the host |

**Why here:** Traefik needs the `gateway` leaf (Step 3.3) and 10.250.0.1 (Step 2.2). It does not need Vault: Vault publishes its own port, and the code runs Traefik after it only by convention. It must come before Gitea (Step 4.1), whose network `lab-backend` is external and created here, and whose API is reached only through these routes. It must also come before monitoring (Step 3.9), which joins `lab-backend` and whose `wait_ready` goes through the `host-only` catch-alls.

**How it connects:**
- The VMs reach Traefik only because vmfw accepts VM traffic whose original destination is 10.250.0.1:443 (`host/files/nftables-vmfw.nft:155`, Step 2.6). The allowlists then narrow it by source and path.
- Every host-side HTTPS call passes `host-only` because the host's source address toward 10.250.0.1 is 10.250.0.1, and Podman's DNAT does not masquerade it. That covers `gitea_api`, `git push`, the runner, `wait_ready` and the host Alloy.
- The `Host()` names repeat CoreDNS's hosts list (Step 3.1) and the `gateway` SANs (Step 3.3). The allowlist IPs repeat `mgmt_ip` in `terraform/compute.tf:11,24,37` (Step 6.5) and vmfw `:155`.
- `wait_ready` and the agents' push URLs are the routes' first clients (Steps 3.10, 10.1, 10.2). The `gitea` routes get a backend in Step 4.1.

**Re-run and removal:** `compose up -d` does nothing on an unchanged project. Edits in `dynamic/` apply live through the file provider, with no recreate. New certificates arrive through `--force-recreate`. `traefik.down` must run after `monitoring.down` and `gitea.down` (`main.py:57-59`), so that no container is still attached to `lab-backend`.

**Check it yourself:**
- `curl -s -o /dev/null -w '%{http_code}\n' --cacert state/pki/ca.pem https://prometheus.lab.test/-/ready` from the host prints `200`.
- `ssh fe-1 "curl -s -o /dev/null -w '%{http_code}\n' https://prometheus.lab.test/-/ready"` prints `403`: fe-1 is not `host-only`.
- `ssh fe-1 "curl -s -o /dev/null -w '%{http_code}\n' -X POST https://prometheus.lab.test/api/v1/write"` prints a 4xx from Prometheus itself (the body is empty), not 403: the push router let fe-1 through.

**Watch out:** The comment on `gitea-flux` says Flux "may only pull" (`gitea.yml:3`). The path prefix also matches git's push endpoint. Read-only is enforced by the Flux token's scope `read:repository` (`services/gitea/gitea.py:145`), not by the route. `host-only` depends on Podman not masquerading host traffic. If that ever changes, every bootstrap step after this one gets 403. A new service behind Traefik needs four hand edits: a Corefile entry, a `gateway` SAN (plus deleting `gateway.pem`, because a SAN edit is not re-issued), a dynamic file, and the client URL.

> **Marked change (not applied), C9:** The `gitea-flux` router comment (`services/traefik/dynamic/gitea.yml:3`) says Flux "may only pull". The route admits any request under `/lab/lab.git/` from be-1; pull-only comes from the token's `read:repository` scope (Step 4.4). Reword the comment. See Appendix C.

### Step 3.9: Monitoring backends and Grafana (platform_up step 14, part 1)

**Files:**
- `services/monitoring/compose.yaml`: project `lab-monitoring`. This step covers `prometheus`, `loki`, `grafana`, the volumes and the network. The `alloy` service is covered in Step 3.10.
- `services/monitoring/files/prometheus/prometheus.yml`: Prometheus config: no scrape jobs, one rule file.
- `services/monitoring/files/prometheus/rules.yml`: an empty rule group list.
- `services/monitoring/files/loki/loki.yml`: single-instance Loki: filesystem TSDB, 48 h retention, no delete API.
- `services/monitoring/files/grafana/provisioning/datasources/datasources.yml`: the Prometheus and Loki datasources.
- `services/monitoring/files/grafana/provisioning/dashboards/dashboard.yml`: the file provider that loads the dashboards.
- `services/monitoring/files/grafana/dashboards/node-exporter-full.json`: pinned upstream dashboard.
- `services/monitoring/files/grafana/dashboards/k8s-views-namespaces.json`: pinned upstream dashboard.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Service `prometheus` | Image `prom/prometheus:v3.16.0@sha256:...`, network `lab-backend`, `--config.file=/etc/prometheus/prometheus.yml`, `--storage.tsdb.path=/prometheus`, `--storage.tsdb.retention.time=2d`, `--web.enable-remote-write-receiver` (accepts pushes on `/api/v1/write`), env `CONF_HASH=${PROMETHEUS_CONF_HASH:-}`, `files/prometheus` read-only, volume `prometheus-data`, `cap_drop: [ALL]`, no published port (`services/monitoring/compose.yaml:4-19`) | `compose("monitoring", ...)` | container `prometheus` |
| 2 | `prometheus.yml` | `global.evaluation_interval: 15s` and `rule_files: [/etc/prometheus/rules.yml]`. No `scrape_configs`: every sample, `up` included, arrives by remote write from Alloy (`services/monitoring/files/prometheus/prometheus.yml:1-5`) | Prometheus | none |
| 3 | `rules.yml` | `groups: []`: no recording or alerting rules (`services/monitoring/files/prometheus/rules.yml:1`) | Prometheus | none |
| 4 | Service `loki` | Image `grafana/loki:3.7.10@sha256:...`, `lab-backend`, `-config.file=/etc/loki/loki.yml`, `CONF_HASH=${LOKI_CONF_HASH:-}`, `files/loki` read-only, volume `loki-data`, `cap_drop: [ALL]` (`services/monitoring/compose.yaml:21-32`) | compose | container `loki` |
| 5 | `loki.yml` server and common | `auth_enabled: false` (`:1`). HTTP on 3100, gRPC only on 127.0.0.1:9095, log level warn (`:3-7`). `common`: one instance at 127.0.0.1, `path_prefix /loki`, replication 1, in-memory ring, filesystem chunk and rule folders (`:9-19`) | Loki | the volume |
| 6 | `loki.yml` `schema_config` | From 2026-11-01: store `tsdb`, object store `filesystem`, schema `v13`, index prefix `index_`, period 24h (`services/monitoring/files/loki/loki.yml:21-29`) | Loki | none |
| 7 | `loki.yml` limits, compactor, analytics | `retention_period: 48h`. `deletion_mode: disabled`: no delete API, which `retention_enabled` would otherwise turn on, while logs still expire after 48 h (`:31-33`). The compactor has `working_directory: /loki/compactor` (inside the `loki-data` volume, `compose.yaml:31`), `retention_enabled: true` and `delete_request_store: filesystem` (Loki requires one when retention is on) (`:35-38`). Usage reporting off (`:40-41`) | Loki | deletes old chunks |
| 8 | Service `grafana` | Image `grafana/grafana:13.3.1@sha256:...`, `lab-backend`. Env `GF_SERVER_ROOT_URL=https://grafana.lab.test/`, `GF_SECURITY_ADMIN_USER/PASSWORD` from `${GRAFANA_ADMIN_*}`, `CONF_HASH=${GRAFANA_CONF_HASH:-}`. Mounts provisioning/datasources, provisioning/dashboards and dashboards read-only, volume `grafana-data`, `cap_drop: [ALL]` (`services/monitoring/compose.yaml:34-49`) | compose | container `grafana` |
| 9 | `datasources.yml` | `Prometheus` (uid `prometheus`, `http://prometheus:9090`, proxy access, default) and `Loki` (uid `loki`, `http://loki:3100`, proxy access). Both are reached directly over `lab-backend`, not through Traefik (`services/monitoring/files/grafana/provisioning/datasources/datasources.yml:1-15`) | Grafana at start | none |
| 10 | `dashboard.yml` | Provider `lab`, type `file`, `path /etc/grafana/dashboards`, polled every 30 s, `disableDeletion: false` (a JSON removed from the folder is deleted from Grafana), `allowUiUpdates: false`, `foldersFromFilesStructure: true` (`services/monitoring/files/grafana/provisioning/dashboards/dashboard.yml:1-12`) | Grafana | none |
| 11 | `node-exporter-full.json` | Pinned upstream dashboard "Node Exporter Full" (uid `rYdddlPWk`): node metrics of the host and the VMs. Contents not reviewed | Grafana file provider | none |
| 12 | `k8s-views-namespaces.json` | Pinned upstream dashboard "Kubernetes / Views / Namespaces" (uid `k8s_views_ns`): the cluster metrics k8s-monitoring pushes from be-1. Contents not reviewed | Grafana file provider | none |
| 13 | Volumes and network | Volumes `prometheus-data`, `loki-data`, `grafana-data`, `alloy-data` (`services/monitoring/compose.yaml:75-79`). Network `backend` named `lab-backend`, declared without `external: true` (`:81-83`), unlike Gitea's | compose | `lab-monitoring_*-data` volumes |

**Why here:** The code runs monitoring as step 14, after `gitea.up` (`main.py:44-45`). Neither depends on the other, so this walk reads it with the other host services. It needs `lab-backend` and the routes from Step 3.8, Vault for the Grafana admin (Steps 3.6, 3.10), and the names from Step 3.1. It must be up before the pipeline starts any VM agent (Phase 10).

**How it connects:**
- The push routers of Step 3.8 are the only way in. Host Alloy (Step 3.10), VM Alloy (Step 10.1) and k8s-monitoring (Step 10.2) all push to the same two URLs.
- Grafana's datasource uids and the two dashboards are what the operator uses to see host, VM and cluster data (Step 10.3).
- The `CONF_HASH` variables are filled by `monitoring.up` from `CONF_HASHES` (Step 3.10).

**Re-run and removal:** An unchanged folder hash leaves its container alone. An edit in one folder recreates only that container. Prometheus and Loki keep their data in the volumes across recreates. Grafana applies `GF_SECURITY_ADMIN_*` only when its database is new (empty `grafana-data`). `monitoring.down` (Step 3.10) runs `compose down --volumes`: metrics, logs and Grafana's database are gone.

**Check it yourself:**
- `curl -s --cacert state/pki/ca.pem https://loki.lab.test/ready` prints `ready`.
- `curl -s --cacert state/pki/ca.pem https://prometheus.lab.test/api/v1/status/flags | jq -r '.data["storage.tsdb.retention.time"]'` prints `2d`.
- `curl -s --cacert state/pki/ca.pem https://grafana.lab.test/api/health | jq -r .database` prints `ok`.

**Watch out:** This file declares `lab-backend` without `external: true` (`services/monitoring/compose.yaml:81-83`), so two compose projects claim the network: Traefik's, which created it in Step 3.8, and this one. Compose would create the network itself if it were missing; because Traefik's project made it first, the monitoring containers join that one. Declaring it `external: true`, as Gitea does, would make Traefik the single owner in the file (see also Step 12.2, row 10). History is short: 2 days of metrics and 48 h of logs, all deleted by `destroy`. There are no alerts (`rules.yml` is empty). The dashboard JSON sits in the hashed `files/grafana` folder, so editing a dashboard recreates Grafana. Editing in the UI is blocked (`allowUiUpdates: false`).

> **Marked change (not applied), C5:** Declare `lab-backend` as `external: true` in `services/monitoring/compose.yaml:81-83`, as `services/gitea/compose.yaml:28-31` does, so Traefik's project is its only owner. See Appendix C.

### Step 3.10: Host Alloy and the monitoring lifecycle (platform_up step 14, part 2)

**Files:**
- `services/monitoring/files/alloy/host.alloy`: the host's agent pipeline: node metrics and the host journal, pushed through Traefik.
- `services/monitoring/config/config.py`: monitoring settings: hashed folders, ready URLs, the Grafana KV path, the retry count. (Its `__init__.py` is covered in Step 1.6.)
- `services/monitoring/monitoring.py`: Grafana admin from Vault, config hashes, compose, readiness wait, removal.
- `services/monitoring/compose.yaml`: this step covers the `alloy` service.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Service `alloy` | Image `grafana/alloy:v1.22.0@sha256:...`, `network_mode: host`. Runs `run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/data /etc/alloy/host.alloy`, env `CONF_HASH=${ALLOY_CONF_HASH:-}`. Mounts: `files/alloy`, volume `alloy-data`, `/proc`, `/sys` and `/` as `/host/...`, `/var/log/journal`, `/run/udev/data`, `/etc/machine-id`, and `state/pki/ca.pem` as `/etc/lab-ca.pem`. `cap_drop: [ALL]` (`services/monitoring/compose.yaml:51-73`) | compose | container `alloy`; UI on 127.0.0.1:12345 |
| 2 | `prometheus.exporter.unix "node"` | The embedded node exporter, reading the host's `/proc`, `/sys` and `/` through the `/host` mounts (`services/monitoring/files/alloy/host.alloy:5-9`) | `discovery.relabel` | reads host proc/sys |
| 3 | `discovery.relabel "node"` | Sets `instance="host"` and `job="node"` on the exporter's target (`:11-23`) | `prometheus.scrape` | none |
| 4 | `prometheus.scrape "node"` | Scrapes every 15 s and forwards to the remote write (`:25-29`) | `prometheus.remote_write` | none |
| 5 | `prometheus.remote_write "hub"` | Pushes to `https://prometheus.lab.test/api/v1/write`, trusting `ca_file = /etc/lab-ca.pem` (`:31-39`) | router `prometheus-write` (Step 3.8) | WAL in `alloy-data` |
| 6 | `loki.relabel "journal"` | A rules-only component (`forward_to = []`). It drops entries from `libpod-healthcheck-*` units, the Podman healthcheck noise of Vault and Gitea. It copies the systemd unit into `unit` and `service_name`, and the priority keyword into `level` (`:43-66`) | `loki.source.journal` | none |
| 7 | `loki.source.journal "host"` | Reads the host journal (`max_age` 12h), label `instance="host"`, applies the rules above, and forwards to `loki.write` (`:68-73`) | `loki.write` | reads `/var/log/journal` |
| 8 | `loki.write "hub"` | Pushes to `https://loki.lab.test/loki/api/v1/push` with the lab CA (`:75-83`) | router `loki-push` (Step 3.8) | none |
| 9 | `FILES_DIR`, `CONF_HASHES` | `FILES_DIR = services/monitoring/files` (`services/monitoring/config/config.py:6`). `CONF_HASHES` maps a compose variable to a folder: `PROMETHEUS_`, `LOKI_`, `ALLOY_` and `GRAFANA_CONF_HASH` -> `files/prometheus`, `loki`, `alloy`, `grafana` (`:9-14`) | `up` | none |
| 10 | `READY_URLS`, `READY_TRIES` | `https://prometheus.lab.test/-/ready` and `https://loki.lab.test/ready`, checked through Traefik like the agents (`:16-20`). `READY_TRIES = 60`, 2 s apart, about two minutes (`:23`) | `wait_ready` | none |
| 11 | `GRAFANA_ADMIN_KV` | `kv/data/lab/bootstrap/grafana-admin` (`:21`) | `grafana_admin` | none |
| 12 | `conf_hash(folder: Path) -> str` | sha256 over the bytes of every file under `folder`, in sorted path order. Editing any file changes it (`services/monitoring/monitoring.py:22-26`) | `up` | reads `files/<x>/**` |
| 13 | `grafana_admin(token: str) -> dict` | Returns `{username, password}` from Vault. If missing, it creates `labadmin` (`LAB_ADMIN`) with `token_urlsafe(24)` and stores it. It never replaces an existing entry (`services/monitoring/monitoring.py:29-37`) | `up` -> `vault.vault_api` | KV `lab/bootstrap/grafana-admin` |
| 14 | `wait_ready() -> None` | Up to 60 rounds: open both ready URLs over HTTPS with the lab CA. Any `URLError`, which includes HTTP 403/502/503, waits 2 s and retries. On success it returns. After the last round: error, exit 1 (`services/monitoring/monitoring.py:40-51`) | `up` -> `urllib` | network through Traefik |
| 15 | `up() -> None` | `grafana_admin(vault.login())`, then one hash per folder, plus `GRAFANA_ADMIN_USER/PASSWORD` in the env. Then `compose monitoring up -d`, then `wait_ready()` (`services/monitoring/monitoring.py:54-61`) | `platform_up` step 14 (`main.py:45`) -> `vault.login`, `grafana_admin`, `conf_hash`, `compose`, `wait_ready` | four containers, four volumes |
| 16 | `down() -> None` | Returns early if `podman.check()` fails. Otherwise runs `compose monitoring down --volumes` (`services/monitoring/monitoring.py:64-70`) | `platform_down` (`main.py:57`) -> `podman.check`, `compose` | removes the containers and all monitoring data |

**Why here:** This is the last host service, and it needs all the others: names (Step 3.1), `ca.pem` (Step 3.3), a lab-bootstrap login (Step 3.6), and `lab-backend` plus the routes (Step 3.8). Inside `up()`, the Grafana credentials must be known before `compose up` (they go into the env), and `wait_ready` comes last. The host Alloy is the first real client of the push routes, so the telemetry path is tested before any VM exists. `wait_ready` makes sure the push targets answer before the pipeline starts the VM agents.

**How it connects:**
- `conf_hash` values reach each container as `CONF_HASH` (`services/monitoring/compose.yaml:15,28,43,62`), which is rule 5(a) of Step 3.0.
- `grafana_admin` adds the `kv/data/lab/bootstrap/grafana-admin` entry to the KV table in Step 3.7. Grafana gets it as `GF_SECURITY_ADMIN_*` (`services/monitoring/compose.yaml:41-42`).
- `wait_ready` goes through DNS (Step 3.1) and Traefik's `host-only` catch-alls (Step 3.8), with `ca.pem` (Step 3.3).
- The VMs run the same pipeline from `ansible/roles/alloy/templates/config.alloy.j2`, minus the `/host` paths, the CA file and the `libpod-healthcheck-*` drop rule (only the host has Podman healthchecks: Vault and Gitea, `services/vault/compose.yaml:24`, `services/gitea/compose.yaml:22`; fe-1's Quadlet defines none, `ansible/roles/frontend/templates/frontend.container.j2:6-10`) (Step 10.1). The host journal it ships includes CoreDNS's refused-query log (`services/coredns/conf/Corefile:17`).

**Re-run and removal:** A re-run makes one login, reads the Grafana entry, computes four hashes, and runs `compose up -d`, which changes nothing unless a folder changed. Then it runs `wait_ready`, which returns at once when everything is up. `monitoring.down` is the first of this phase's removals (`main.py:57`). It runs before `traefik.down`, so `lab-backend` is free when Traefik removes it. The Grafana KV entry stays until `vault.down`.

**Check it yourself:**
- `curl -s --cacert state/pki/ca.pem -G --data-urlencode 'query=up{instance="host"}' https://prometheus.lab.test/api/v1/query | jq -r '.data.result[0].value[1]'` prints `1`: the host Alloy's scrape arrives by remote write.
- `curl -s --cacert state/pki/ca.pem https://loki.lab.test/loki/api/v1/label/instance/values | jq -c .data` includes `"host"`: the journal arrives.
- (sudo) Grafana login, from the repo root (prints the password): `sudo python3 -B -c 'from services.vault import vault; print(vault.vault_api("GET", "kv/data/lab/bootstrap/grafana-admin", token=vault.login())["data"]["data"]["password"])'`; the user is `labadmin`.

**Watch out:** The host Alloy bind-mounts `state/pki/ca.pem` as a single file. A new root CA is a new file, and nothing recreates Alloy: its hash covers only `files/alloy`, and `monitoring.up` gets no `certs_changed`. After a CA rebuild it keeps the old CA and its pushes fail until it is recreated by hand. Grafana applies the admin env only to a new database. Changing or deleting the KV entry later does not change the running admin password. `wait_ready` retries only `URLError`. A connection reset raised while reading the response is a plain `OSError`, and it ends the run instead of being retried.

## Phase 4: CI platform

Phase 4 builds the CI platform the pipeline runs on: a Gitea server, the credentials Gitea hands to the runner, the pipeline and Flux, the operator's SSH access to the VMs, and a Gitea Actions runner that runs jobs directly on the host. It runs as `platform_up` step 13 (`gitea.up`, `main.py:44`), step 15 (`ssh_access.up`, `main.py:46`) and step 16 (`runner.up`, `main.py:47`) on every `up`, `update` and `teardown`. Step 14 (monitoring, `main.py:45`) sits between them in the code but does not depend on Gitea, and Gitea does not depend on it, so it is walked in Phase 3 (Steps 3.9-3.10). Every unit is find-or-create, so a re-run only logs "already exists" lines. When the phase ends, Gitea answers at `https://gitea.lab.test`, but only through Traefik and only for the host (plus `/lab/lab.git/` for be-1). It holds the admin `labadmin`, the public org `lab` and an empty private repo `lab/lab` with two Actions secrets. Vault holds the admin password, the runner registration token and Flux's read-only Gitea token. The operator owns `~/.ssh/lab_operator`, and `ssh fe-1` style aliases are installed, though no VM exists yet. `lab-runner.service` is active and registered as `lab-host` with the label `host`, and is waiting for jobs. No pipeline run exists yet: the command tail starts one in Phase 5.

**Needs from earlier phases:**
- A root process with `SUDO_UID`/`SUDO_GID` (Step 1.1), used by `ssh_access` to create the key as the operator.
- `lib/config.py` (Step 1.4): `LAB_ADMIN = "labadmin"` (`:8`), `BASE_DIR` (`:11`), `LAB_CA_CERT = state/pki/ca.pem` (`:31`). `lib/system.py` (Step 1.5): `compose`, `install_file`, `write_file`, `systemctl_ok`.
- The settings group for ssh_access in `host/config/config.py:65-68` (Step 2.0).
- Rootful Podman with its API socket and the `podman` CLI (Step 2.4). Compose drives the Gitea container, `podman exec` creates the admin, and `podman.check()` guards `down()`.
- Bridge `mgmtbr1` with 10.250.0.1, and the host resolver sending `~lab.test` to 10.250.0.1 (Step 2.2). `/usr/local/bin` on PATH (Step 2.7), which is where the runner binary goes too.
- CoreDNS answering `gitea.lab.test` with 10.250.0.1 (`services/coredns/conf/Corefile:5`, Step 3.1).
- `state/pki/ca.pem` and the `gateway` leaf, whose SANs include `gitea.lab.test` (`lib/config.py:37`, Step 3.3).
- Vault unsealed, with `vault.login()` (1 h token), the `lab-pipeline` policy, AppRole auth enabled and `approle_credentials()` (Steps 3.5-3.6). Also the `kv/` mount and the pipeline SSH key pair at `kv/data/lab/pipeline/ssh` (Step 3.7).
- Traefik (Step 3.8): the Podman network `lab-backend` (`services/traefik/compose.yaml:23-25`), the `websecure` entrypoint published on 10.250.0.1:443 (`:14-15`), the routers `gitea` and `gitea-flux` (`services/traefik/dynamic/gitea.yml:1-20`), and the allowlists `host-only` and `flux-and-host` (`services/traefik/dynamic/allowlists.yml:5-13`).
- Host internet: docker.io for the Gitea image and gitea.com for the runner binary.

**Hands on:**
- Container `gitea` on `lab-backend` (no published port), with volumes `lab-gitea_gitea-data` and `lab-gitea_gitea-config`, reachable as `https://gitea.lab.test` (host only).
- Vault `kv/data/lab/bootstrap/gitea-admin` `{username, password}`. The admin's Basic credentials are used for every Gitea call in Phase 5.
- Org `lab` (public) and repo `lab/lab` (private, empty; `main` appears with the first push in Step 5.2).
- Vault `kv/data/lab/bootstrap/gitea-runner` `{token}`: the instance-wide runner registration token.
- Gitea Actions secrets `VAULT_ROLE_ID` and `VAULT_SECRET_ID` on `lab/lab` (AppRole `lab-pipeline`), used by `ansible.yml` (Step 7.1).
- Vault `kv/data/lab/pipeline/gitea-flux` `{username, token}`, a `read:repository` token named `flux`, for Flux (Step 8.2).
- `~/.ssh/lab_operator` (owned by the operator) and `/etc/ssh/ssh_config.d/60-lab-ssh.conf` (aliases fe-1, tun-1, be-1).
- `/usr/local/bin/gitea-runner` 6.0.0. `/etc/lab-runner/config.yaml`, `/etc/lab-runner/ca.pem`, `/etc/lab-runner/ssh.pub` (pipeline key + operator key, read by Terraform in Step 6.2). `/var/lib/lab/runner/.runner`.
- `lab-runner.service` (enabled, active, runs as root), and through its `StateDirectory`, `/var/lib/lab/tfstate` and `/var/lib/lab/images` (0700).
- Runner `lab-host` with label `host`, which matches `runs-on: host` in every job.

### Step 4.1: Gitea container and how it is reached (platform_up step 13, part 1)

**Files:**
- `services/gitea/compose.yaml`: the Gitea service. It uses a rootless image pinned by digest and SQLite, has Actions enabled and no published port, and joins the external network `lab-backend`.
- `services/gitea/config/config.py`: Gitea settings (Vault paths, URLs, org/repo, workflow names, run polling). `COMMIT_IDENTITY` (`:23`) is Step 1.7.
- Read alongside, built in Step 3.8: `services/traefik/dynamic/gitea.yml` and `allowlists.yml`, the only way in. The empty package markers `services/gitea/__init__.py` and `services/gitea/config/__init__.py` are Step 1.6.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Compose project `lab-gitea` | `name: lab-gitea` (`compose.yaml:1`) sets the project name, so the volumes are `lab-gitea_gitea-data` and `lab-gitea_gitea-config` | `compose("gitea", ...)` (`lib/system.py:73-80`) | Podman project |
| 2 | Service `gitea`: image, name, restart | Image `docker.io/gitea/gitea:28.3.0-rootless@sha256:40c5...` (`:5`). `container_name: gitea` (`:6`), the name used by `podman exec` and by Traefik's backend `http://gitea:3000` (`services/traefik/dynamic/gitea.yml:20`). `restart: unless-stopped` (`:7`) restarts it after a crash. The repo sets up no boot unit for it (`podman/podman.py:44-48` enables only `podman.socket`), so whether it runs after a host reboot is decided outside the repo. The next `platform_up` starts it in any case (Step 12.3, row 5) | `gitea.up` (Step 4.5) | Pulls the image from docker.io |
| 3 | Environment | `DOMAIN gitea.lab.test`, `ROOT_URL https://gitea.lab.test/` (the URL Gitea puts in clone URLs and in a run's `html_url`), `HTTP_PORT 3000`, `DISABLE_SSH true` (git over HTTPS only), `DB_TYPE sqlite3`, `INSTALL_LOCK true` (no web installer), `DISABLE_REGISTRATION true`, `actions ENABLED true` (`compose.yaml:9-17`). `DEFAULT_ACTIONS_URL` is not set, so `uses:` actions are fetched from Gitea's default host, github.com | Gitea at start | `app.ini` in `/etc/gitea` |
| 4 | Volumes | `gitea-data:/var/lib/gitea` (repos, SQLite DB, Actions logs and artifacts) and `gitea-config:/etc/gitea` (`compose.yaml:18-20`, `:33-35`) | compose | Two named volumes |
| 5 | Hardening | `cap_drop: [ALL]` (`:21`). There is no `ports:` key, so nothing is published on the host | compose | None |
| 6 | Healthcheck | `curl -fsS http://127.0.0.1:3000/api/healthz` every 10 s, timeout 5 s, 3 retries (`compose.yaml:22-26`). `compose up --wait` blocks on it. It runs inside the container, not through Traefik | `gitea.up` `--wait` (`gitea.py:285`) | None |
| 7 | Network | `networks: [backend]` (`:8`) maps to `lab-backend` with `external: true` (`:28-31`). Traefik's compose creates and owns the network (`services/traefik/compose.yaml:23-25`), so Gitea's `up` fails if Traefik has not run | compose | Joins `lab-backend` |
| 8 | Vault paths | `GITEA_ADMIN_KV = kv/data/lab/bootstrap/gitea-admin`, `GITEA_RUNNER_KV = kv/data/lab/bootstrap/gitea-runner`, `GITEA_FLUX_KV = kv/data/lab/pipeline/gitea-flux` (`config.py:4-6`). These are KV v2 API paths, so they include `data/` | `gitea_admin` (Step 4.2); `runner_registration_token`, `flux_token` (Step 4.4); `runner.ensure_registered` (Step 4.10) | None |
| 9 | URLs | `GITEA_URL = https://gitea.lab.test` and `GITEA_API = <GITEA_URL>/api/v1` (`config.py:9-10`) | `gitea_api` (Step 4.2) | None |
| 10 | Org, repo, workflows | `GITEA_ORG = "lab"`, `GITEA_REPO = "lab"`, `GITEA_REPO_URL = https://gitea.lab.test/lab/lab.git` (`config.py:13-15`). `GITEA_WORKFLOW = "deploy.yml"` and `GITEA_TEARDOWN_WORKFLOW = "teardown.yml"` (dispatch only) (`:16-17`) | `ensure_org`/`ensure_repo` (Step 4.3), `pipeline_secrets` (Step 4.4), `main_differs`/`push`/`dispatch`/`wait_for_run` (Step 5.2), `follow_run` (Step 5.3), `cmd_teardown` (Step 5.1) | None |
| 11 | Run polling | `RUN_POLL_SECONDS = 10`, `RUN_START_TIMEOUT = 60`, `RUN_TIMEOUT = 70 * 60`, `RUN_LOG_LINES = 30` (`config.py:19-22`) | `wait_for_run` (Step 5.2), `follow_run` (Step 5.3) | None |
| 12 | Traefik routes to Gitea (Step 3.8, read here) | Router `gitea-flux`: ``Host(`gitea.lab.test`) && PathPrefix(`/lab/lab.git/`)``, priority 100, middleware `flux-and-host` (10.250.0.1 and be-1 10.250.0.112). Router `gitea`: everything else on that host, priority 1, middleware `host-only` (10.250.0.1 only) (`services/traefik/dynamic/gitea.yml:3-14`; `allowlists.yml:5-13`) | Every host HTTPS call to Gitea; Flux on be-1 | None |

**Why here:** Gitea is the first service that consumes nearly all of Phase 3. It joins Traefik's network. It is reached by name (CoreDNS) over TLS (lab CA, gateway leaf) through a Traefik router, and it keeps its credentials in Vault. Everything after it in Phase 4 needs it: the runner needs a registration token and a server to register with. Phase 5 needs a repo to push to.

**How it connects:**
- The container name `gitea` is used by `podman exec gitea gitea admin ...` (Step 4.2) and by Traefik's backend URL (Step 3.8).
- `ROOT_URL` is the base of the run URL that `follow_run` prints (Step 5.3), and of the clone URL that every job's `actions/checkout` uses (Step 5.4).
- `GITEA_REPO_URL` is the push target (Step 5.2). The same URL is typed again in `ansible/roles/fluxcd/files/flux-sync.yaml:9` (Step 8.2), and its path must stay under the `gitea-flux` route's `PathPrefix(/lab/lab.git/)`.
- The run-polling constants are read by Steps 5.2-5.3. The per-job limit lives in the runner config (`timeout: 1h`, Step 4.7).

**Re-run and removal:** `compose up -d` on an unchanged file leaves the container alone. A changed `compose.yaml` (new digest, new env) recreates the container, and the repo and DB survive in the two named volumes. `gitea.down` removes the container and both volumes (Step 4.5).

**Check it yourself:**
- From the repo root: `curl -sS --cacert state/pki/ca.pem https://gitea.lab.test/api/healthz` returns JSON with `"status": "pass"`.
- (sudo) `sudo podman ps --filter name=gitea --format '{{.Names}} {{.Status}}'` shows `(healthy)`. `sudo podman port gitea` prints nothing, because no port is published.

**Watch out:**
- Values copied by hand: `GITEA_URL` = the runner's `INSTANCE` (`services/gitea/runner/config/config.py:23`). The repo path = the `gitea-flux` `PathPrefix` = `flux-sync.yaml:9`. `GITEA_FLUX_KV` = `.gitea/workflows/ansible.yml:27`.
- Gitea answers the host only because the host's packets to 10.250.0.1 carry source 10.250.0.1, which passes `host-only` (Step 3.8). Any request from another address gets a 403 from Traefik, except be-1 (10.250.0.112) on paths under `/lab/lab.git/` (router `gitea-flux`, middleware `flux-and-host`).

### Step 4.2: API client and admin (platform_up step 13, part 2)

**Files:**
- `services/gitea/gitea.py`: the imports, `gitea_api` and `gitea_admin`. The other parts of this file are Step 1.7 (`git`, `commit_changes`), Steps 4.3-4.5 and Steps 5.2-5.3.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Module header | Docstring (`:1`). Imports `lib.config` as `lab_config` (`LAB_CA_CERT`, `LAB_ADMIN`, `BASE_DIR`), `lib.system.compose`, the Gitea `config`, `podman.podman` (only `check()` in `down`) and `services.vault.vault` (`:16-20`). Logger (`:22`) | `main.py:19` imports it | None |
| 2 | `gitea_api(creds: dict, method: str, path: str, body: dict \| None = None, raw: bool = False) -> dict \| str` | Builds a Basic auth header from `creds` (`:27-29`) and sends `method` to `https://gitea.lab.test/api/v1/<path>` with a JSON body, verifying TLS against `state/pki/ca.pem` and using a 10 s timeout (`:31-42`). A GET that returns 404 gives `{}` (`:44-46`). Every other HTTP error raises. `raw=True` returns the body as text, which is used for job logs (`:48-49`). Otherwise it returns parsed JSON, or `{}` for an empty body (`:50`) | Every Gitea helper in Steps 4.3-4.4 and 5.2-5.3 -> `urllib`, `ssl` | HTTPS through CoreDNS -> Traefik 10.250.0.1:443 -> router `gitea` (`host-only`) -> `gitea:3000` |
| 3 | `gitea_admin(token: str) -> dict` | If Vault has `GITEA_ADMIN_KV`, it returns `{username, password}` and logs `Gitea admin labadmin already exists` (`:55-58`). Otherwise it runs `podman exec gitea gitea admin user create --admin --username labadmin --email labadmin@lab.test --random-password --must-change-password=false` (`:60-65`). It parses `generated random password is '...'` from stdout (`:66`). If the regex misses, it logs a recovery hint and exits 1 (`:67-71`). Then it stores the creds in Vault and returns them (`:73-76`) | `up` (Step 4.5); `cmd_up`, `cmd_update`, `cmd_teardown` (`main.py:75,87,96`, Step 5.1) -> `vault.vault_api`, `podman exec` | Reads, and once writes, Vault `kv/data/lab/bootstrap/gitea-admin`. Creates the user in Gitea's DB |

**Why here:** Every later call to Gitea authenticates as the admin, so the admin comes first. `gitea_admin` needs only the running container (`podman exec`), not Traefik. The API client then carries everything else. Basic auth with the password, rather than an API token, is what lets `flux_token` create tokens (Step 4.4): Gitea's token-creation endpoint accepts Basic auth.

**How it connects:**
- The returned `creds` feed Steps 4.3-4.4 in the same `gitea.up` call. The command tails get them again with `gitea_admin(vault.login())` (Step 5.1).
- `LAB_ADMIN` (`lib/config.py:8`) is also the Grafana admin name (Step 3.10). `labadmin` is typed again as `flux_git_user` in `ansible/roles/fluxcd/defaults/main.yml:2` (Step 8.2).
- Every `gitea_api` call needs DNS (Step 3.1), the CA (Step 3.3) and the `host-only` router (Step 3.8). Only `gitea_admin`'s `podman exec` bypasses them.

**Re-run and removal:** On a re-run `gitea_admin` returns the Vault copy without checking that the user still exists in Gitea. `gitea_api` keeps no state. `gitea.down` deletes the user together with the volumes (Step 4.5), and `vault.down` deletes the Vault copy (Step 12.2).

**Check it yourself:**
- `grep 'Gitea admin' state/bootstrap.log | tail -n 2` (the log is world-readable) shows `Created Gitea admin ...` from the first run, and `... already exists` on later runs.
- (sudo) `sudo podman exec gitea gitea admin user list --admin` lists `labadmin`.

**Watch out:**
- There is a crash window. If the Vault write (`:74`) fails after the user was created, the next run finds nothing in Vault and runs `user create` again. Gitea refuses (the user exists), and every run stops with a CalledProcessError until you run `sudo podman exec gitea gitea admin user delete --username labadmin`. The hint at `:68-70` prints only when the regex misses.
- Gitea's user DB and Vault's copy must be reset together. If one is lost without the other, every API call fails with 401. `destroy` removes both (Step 12.2).
- "404 means missing" applies only to GET. A 401, a 403 from the allowlist or a 5xx raises and stops the run.

### Step 4.3: Org and repo (platform_up step 13, part 3)

**Files:**
- `services/gitea/gitea.py`: `ensure_org`, `ensure_repo`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `ensure_org(creds: dict) -> None` | `GET orgs/lab`. If that finds nothing, `POST orgs` with `{"username": "lab", "visibility": "public"}` (`:79-87`) | `up` (`:288`) -> `gitea_api` | Gitea org `lab` |
| 2 | `ensure_repo(creds: dict) -> None` | `GET repos/lab/lab`. If that finds nothing, `POST orgs/lab/repos` with `private: True`, `auto_init: False` and `default_branch: "main"` (`:90-104`). No auto-init means the repo starts empty: it has no `main` until the first push | `up` (`:289`) -> `gitea_api` | Gitea repo `lab/lab` |

**Why here:** The repo is created under the org, so the org comes first. The repo's Actions secrets (Step 4.4) and the push (Step 5.2) both need `lab/lab`.

**How it connects:**
- `lab/lab` is the repo that `push` targets (Step 5.2), that Flux pulls (Step 8.2), and that holds the Actions secrets (Step 4.4).
- The empty repo is why `main_differs` returns True on the first run: `GET branches/main` returns 404, which becomes `{}` (Step 5.2).
- The org is public but the repo is private, so Flux needs the token from Step 4.4.

**Re-run and removal:** Both GETs find their object and log `already exists`. This is find-or-create only, so a setting changed in the UI (for example the private flag) is not put back. `gitea.down` removes both with the volumes.

**Check it yourself:**
- `curl -sS --cacert state/pki/ca.pem https://gitea.lab.test/api/v1/orgs/lab` returns the org with `"visibility":"public"`. The org is visible without login.
- `curl -s -o /dev/null -w '%{http_code}\n' --cacert state/pki/ca.pem https://gitea.lab.test/api/v1/repos/lab/lab` prints `404` without credentials, because the repo is private.

### Step 4.4: Credentials Gitea hands on (platform_up step 13, part 4)

**Files:**
- `services/gitea/gitea.py`: `runner_registration_token`, `pipeline_secrets`, `flux_token`.
- `services/vault/vault.py`: `approle_credentials` only, built in Step 3.6 and listed here as the callee. The rest of the file is Steps 3.4-3.7.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `runner_registration_token(token: str, creds: dict) -> None` | If Vault already has `GITEA_RUNNER_KV`, it logs and returns (`:109-111`). Otherwise `POST admin/actions/runners/registration-token` (an instance-wide token) and store `{token}` in Vault (`:113-116`) | `up` (`:290`) -> `vault.vault_api`, `gitea_api` | Vault `kv/data/lab/bootstrap/gitea-runner` |
| 2 | `pipeline_secrets(token: str, creds: dict) -> None` | Lists the names in `repos/lab/lab/actions/secrets` (`:121-125`). If both `VAULT_ROLE_ID` and `VAULT_SECRET_ID` are there, it logs and returns (`:127-129`). Otherwise it calls `vault.approle_credentials(token, "lab-pipeline")` and PUTs the role_id and the new secret_id as repo secrets (`:131-135`) | `up` (`:291`) -> `gitea_api`, `vault.approle_credentials` | Gitea Actions secrets on `lab/lab`; Vault AppRole `lab-pipeline` |
| 3 | `approle_credentials(token: str, role: str) -> dict` (Step 3.6) | Creates or updates role `auth/approle/role/lab-pipeline` with policy `lab-pipeline`, `token_ttl 1h` and `secret_id_ttl 8760h`. Reads the role_id, issues a new secret_id, and returns both (`services/vault/vault.py:173-180`) | `pipeline_secrets` (and `approle`, Step 3.6) -> `vault_api` | Vault `auth/approle/role/lab-pipeline` |
| 4 | `flux_token(token: str, creds: dict) -> None` | If Vault already has `GITEA_FLUX_KV`, it logs and returns (`:140-142`). Otherwise `POST users/labadmin/tokens` with `{"name": "flux", "scopes": ["read:repository"]}` and store `{username: labadmin, token: <sha1>}` in Vault (`:144-149`) | `up` (`:292`) -> `vault.vault_api`, `gitea_api` | Vault `kv/data/lab/pipeline/gitea-flux`; Gitea access token `flux` |

**Why here:** All three need the admin (Step 4.2). `pipeline_secrets` also needs the repo (Step 4.3), plus the `lab-pipeline` policy and AppRole auth from Step 3.6. Each one feeds a later consumer: the runner reads its token a few seconds later in the same `platform_up` (Step 4.10), and the ansible job reads the secrets and the Flux token (Step 7.1).

**How it connects:**
- `kv/data/lab/bootstrap/gitea-runner` -> `runner.ensure_registered` (Step 4.10).
- `VAULT_ROLE_ID`/`VAULT_SECRET_ID` -> `deploy.yml` `secrets: inherit` (Step 5.4) -> `hashicorp/vault-action` in `ansible.yml:21-23` (Step 7.1) -> a 1 h `lab-pipeline` token limited to `kv/data/lab/pipeline/*` (`services/vault/policies/lab-pipeline.hcl:5-8`).
- The `kv/data/lab/pipeline/gitea-flux` token -> `ansible.yml:27` as `FLUX_GIT_TOKEN` -> Secret `flux-system/flux-git-auth` -> GitRepository `lab-repo` through the `gitea-flux` route (Steps 8.2, 3.8).
- The Flux token sits under `kv/data/lab/pipeline/`, so the pipeline policy can read it. The admin password and the runner token sit under `kv/data/lab/bootstrap/`, which the pipeline cannot read.

**Re-run and removal:** The runner token and the Flux token are checked in Vault only, never in Gitea. The secrets are checked by name in Gitea. If either secret is missing, both are written again with a new secret_id, and the old secret_ids stay valid until their TTL ends. There is no removal per item: `gitea.down` and `vault.down` remove everything (Step 12.2).

**Check it yourself:**
- `grep -iE 'runner.*token|secrets|flux' state/bootstrap.log | tail -n 4` shows either the first-run lines (`Stored the runner registration token in Vault`, `Gitea Action Secrets stored`, `Stored Flux's read-only Gitea token in Vault`) or the `already ...` lines of later runs.
- Gitea UI (logged in as labadmin, from the host): `lab/lab` -> Settings -> Actions -> Secrets lists `VAULT_ROLE_ID` and `VAULT_SECRET_ID`. User settings -> Applications lists the token `flux`.

**Watch out:**
- Gitea shows a new token's value only once, in the POST response. If the Vault write in `flux_token` fails, the next run tries to create a second token named `flux`, and Gitea refuses. Delete the token in the UI, then run `update`.
- The secret_id expires after 8760 h (one year). The pipeline's Vault login then fails. Deleting one of the two Gitea secrets makes the next `update` issue new ones.
- The `username` field in `gitea-flux` is written but never read. `ansible.yml:27` reads only `token`, and the fluxcd role has its own `flux_git_user`.
- The registration token stays in Vault after use. It is instance-wide, so anyone holding it could register another runner.

### Step 4.5: Gitea lifecycle (platform_up step 13, part 5)

**Files:**
- `services/gitea/gitea.py`: `up`, `down`.
- `main.py`: `gitea.up()` as `platform_up` step 13 (`:44`), and `gitea.down()` in `platform_down` (`:58`).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `up() -> None` | `compose gitea up -d --wait --wait-timeout 120` (`:285`), one `vault.login()` (`:286`), then `gitea_admin`, `ensure_org`, `ensure_repo`, `runner_registration_token`, `pipeline_secrets`, `flux_token` (`:287-292`), and logs `Gitea ready at https://gitea.lab.test` | `platform_up` (`main.py:44`) -> `compose`, `vault.login`, Steps 4.2-4.4 | Container, volumes, Vault paths, Gitea objects |
| 2 | `down() -> None` | If `podman.check()` fails, it logs and returns (`:298-300`). Otherwise `compose gitea down --volumes` (`:301`), which removes the container and both volumes: repo, DB, users, tokens, secrets, runner registrations, run history and artifacts | `platform_down` (`main.py:58`) -> `podman.check`, `compose` | Removes all Gitea data |
| 3 | Position in `main.py` | Up: after `vault.up` (`:42`) and `traefik.up` (`:43`), before `monitoring.up` (`:45`), `ssh_access.up` (`:46`) and `runner.up` (`:47`). Down: after `monitoring.down` (`:57`), before `traefik.down` (`:59`) and `vault.down` (`:60`) | `platform_up`, `platform_down` | None |

**Why here:** Up needs Vault (credentials) and Traefik (the network that compose expects to exist, and the API path), and it must finish before the runner, which reads the registration token. Down runs before `traefik.down` because Gitea is a member of Traefik's `lab-backend` network.

**How it connects:**
- `--wait` relies on the in-container healthcheck (Step 4.1). The first call through Traefik is `ensure_org` (Step 4.3).
- One 1 h Vault token covers all writes in this step (Step 3.6).
- `up()` returns nothing, so the command tails call `gitea_admin(vault.login())` again (Step 5.1).

**Re-run and removal:** On a re-run every call is a lookup and the log shows one `already ...` line per item (`already exists` for five of them, `Gitea Actions secrets for vault already set` for the secrets). Removal is `down()`, called only by `destroy`. Vault's copies of the admin password and tokens last two more steps, until `vault.down` (Step 12.2).

**Check it yourself:**
- `grep 'Gitea ready' state/bootstrap.log | tail -n 1`
- (sudo) `sudo podman volume ls --filter name=lab-gitea` lists the two volumes.

### Step 4.6: Operator SSH access (platform_up step 15)

**Files:**
- `host/ssh_access.py`: a personal SSH key for the operator who ran sudo, and the host aliases. Its settings (`SSH_CONFIG_SRC`, `SSH_CONFIG_FILE`, `OPERATOR_KEY_NAME`) are in `host/config/config.py:65-68` (Step 2.0).
- `host/files/60-lab-ssh.conf`: the ssh client drop-in for `ssh fe-1`, `ssh tun-1` and `ssh be-1`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Module header | Docstring (`ssh_access.py:1-4`): a personal key for the user who ran sudo plus the aliases fe-1, tun-1, be-1; the VMs trust it next to the pipeline key (`runner.ensure_ssh_key`), whose private half stays in Vault. Imports `host.config.config` and `lib.system.install_file` (`:12-13`). Logger (`:15`) | `main.py:11` imports it | None |
| 2 | `operator_key() -> Path` | The home of `SUDO_UID` (from `pwd`) + `/.ssh/lab_operator` (`ssh_access.py:18-21`) | `public_key`, `up`, `down` | None |
| 3 | `public_key() -> str` | `ssh-keygen -y -f <key>`: derives the public line from the private key, so a missing or stale `.pub` cannot matter (`:24-27`) | `runner.ensure_ssh_key` (Step 4.9) -> `ssh-keygen` | Reads the private key (as root) |
| 4 | `up() -> None` | If the key is missing: create `~/.ssh` 0700 owned by the operator if needed (`:37-39`), then run `ssh-keygen -t ed25519 -N "" -q -C lab-operator` **as** `SUDO_UID:SUDO_GID` (`:40-42`). Then `install_file` the drop-in to `/etc/ssh/ssh_config.d/60-lab-ssh.conf`, 0644 (`:45-48`) | `platform_up` step 15 (`main.py:46`) -> `ssh-keygen`, `install_file` | `~/.ssh/lab_operator{,.pub}`; `/etc/ssh/ssh_config.d/60-lab-ssh.conf` |
| 5 | `down() -> None` | Removes the drop-in. **Keeps** the key, a personal key that the next `up` reuses (`:51-54`) | `platform_down` (`main.py:53`) | Deletes the drop-in |
| 6 | Drop-in, common block | `Host fe-1 tun-1 be-1`: `User user`, `IdentityFile ~/.ssh/lab_operator`, `IdentitiesOnly yes`, `StrictHostKeyChecking no`, `UserKnownHostsFile /dev/null`, `LogLevel ERROR` (`60-lab-ssh.conf:6-12`). Host keys are not checked because every rebuild gives the VMs new host keys (comment `:4`) | the operator's `ssh` | None |
| 7 | Drop-in, addresses | `fe-1` -> 10.250.0.110, `tun-1` -> 10.250.0.111, `be-1` -> 10.250.0.112, over `mgmtbr1` (`:14-21`) | the operator's `ssh`; `demo/load.sh:6` (`ssh fe-1 ...`) | None |

**Why here:** Its only build-time consumer is `runner.ensure_ssh_key` (Step 4.9), which runs next and needs the operator's public key. The step needs nothing from Gitea. It sits right before the runner because the runner reads it.

**How it connects:**
- The operator public key becomes the second line of `/etc/lab-runner/ssh.pub` (Step 4.9) -> `var.ssh_public_key_file` -> cloud-init `ssh_authorized_keys` of user `user` (Steps 6.2, 6.6).
- `User user` must match the cloud-init user (`terraform/cloud-init/user-data.yaml.tftpl:3`) and `ansible_user` (`terraform/inventory.tf:7`). The HostNames must match `mgmt_ip` in `terraform/compute.tf:11,24,37` (Step 6.5).
- Ansible is not affected by the drop-in. It connects by IP (`ansible_host = mgmt_ip`, `terraform/inventory.tf:6`) with the pipeline key from ssh-agent (Step 7.1), and the drop-in's `Host` patterns match only the alias names.

**Re-run and removal:** An existing key is kept and logged. The drop-in is rewritten only if its bytes differ. `down()` removes only the drop-in.

**Check it yourself:**
- `ssh -G fe-1 | grep -E '^(hostname|user|identityfile) '` prints `hostname 10.250.0.110`, `user user` and `identityfile ~/.ssh/lab_operator`.
- `ls -l ~/.ssh/lab_operator`: mode `-rw-------`, owned by you. After Phase 6, `ssh fe-1 hostname` prints `fe-1`.

**Watch out:**
- If you delete `~/.ssh/lab_operator`, the next run creates a new key. `ssh.pub` then changes, and the next Terraform apply rebuilds every VM (Step 6.7).
- The aliases skip host-key checks on purpose. That is acceptable only because `mgmtbr1` is a host-only bridge.

### Step 4.7: Runner definitions (platform_up step 16, part 1)

**Files:**
- `services/gitea/runner/config/config.py`: runner constants: release pin, host paths, Vault path, unit name, registration identity. It has no docstring. Its package marker `services/gitea/runner/config/__init__.py` (and `services/gitea/runner/__init__.py`) is Step 1.6.
- `services/gitea/runner/files/config.yaml`: the gitea-runner daemon config, installed as `/etc/lab-runner/config.yaml`.
- `services/gitea/runner/files/lab-runner.service`: the systemd unit.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `FILES` | `services/gitea/runner/files` (`config.py:3`) | `ensure_config`, `ensure_service` | None |
| 2 | Release pin | `VERSION = "6.0.0"`, `BINARY_URL` (gitea.com release `.xz`), `BINARY_SHA256` (of the `.xz`, the only file with a published checksum, comment `:5`), `BINARY = /usr/local/bin/gitea-runner` (`config.py:6-9`) | `ensure_binary`, `ensure_registered`, `down` | None |
| 3 | `OLD_USER` | `"lab-runner"`: the user an older version of the runner ran as. Only `down()` uses it, and only to remove the user if it still exists (`config.py:12`) | `down` | None |
| 4 | Host paths | `HOME = /var/lib/lab/runner`, `CONFIG_DIR = /etc/lab-runner`, `CONFIG = .../config.yaml`, `CA = .../ca.pem`, `SSH_PUB = .../ssh.pub` (`config.py:13-17`) | `ensure_home`, `ensure_config`, `ensure_ssh_key`, `ensure_registered`, `down` | None |
| 5 | `SSH_KV` | `kv/data/lab/pipeline/ssh` (`config.py:18`), the same path as `vault.ssh_key` (`services/vault/vault.py:99`) | `ensure_ssh_key` | None |
| 6 | Unit names | `SERVICE = "lab-runner"`, `SERVICE_FILE = /etc/systemd/system/lab-runner.service` (`config.py:19-20`) | `ensure_service`, `down` | None |
| 7 | Registration identity | `INSTANCE = "https://gitea.lab.test"` (a copy of `GITEA_URL`), `NAME = "lab-host"` (`config.py:22-24`) | `ensure_registered` | None |
| 8 | `config.yaml` `log` | `level: info` (`config.yaml:2-3`) | daemon | journal of `lab-runner` |
| 9 | `config.yaml` `runner` core | `file: /var/lib/lab/runner/.runner` (where `register` writes and `daemon` reads the identity), `capacity: 1` (one job at a time), `timeout: 1h` (per job) (`config.yaml:5-8`) | `register`, daemon | `.runner` |
| 10 | `config.yaml` trust, labels, env | `ca_file: /etc/lab-runner/ca.pem` (the daemon trusts the lab CA for `https://gitea.lab.test`). `labels: ["host:host"]` means label `host` with the host executor: jobs run as plain processes on the host, with no container. `envs: GIT_SSL_CAINFO: /etc/lab-runner/ca.pem` is passed to every job so that host git (checkout) trusts Gitea (`config.yaml:9-13`) | daemon; every job | None |
| 11 | `config.yaml` cache, workdir | `cache.enabled: false` (no cache server). `host.workdir_parent: /var/lib/lab/runner/work`, under the runner home (`config.yaml:15-19`) | daemon | Job checkouts under `/var/lib/lab/runner/work` |
| 12 | Unit `[Unit]` | `After=` and `Wants=network-online.target` (`lab-runner.service:1-4`) | systemd | None |
| 13 | Unit identity and folder | `User=root`, `Group=root`, `WorkingDirectory=/var/lib/lab/runner` (`:6-9`). Every job runs as root | systemd | None |
| 14 | Unit `StateDirectory` | `StateDirectory=lab/tfstate lab/images` with `StateDirectoryMode=0700` (`:10-13`). systemd creates `/var/lib/lab/tfstate` (Terraform state and TMPDIR) and `/var/lib/lab/images` (the frontend tar) when the unit starts | systemd | The two folders |
| 15 | Unit process | `ExecStart=/usr/local/bin/gitea-runner daemon --config /etc/lab-runner/config.yaml`, `Restart=on-failure`, `TimeoutStopSec=60` (`:14-16`) | systemd | Runs the daemon |
| 16 | Unit `[Install]` | `WantedBy=multi-user.target` (`:18-19`): starts at boot once enabled | `systemctl enable` | None |

**Why here:** These are constants and files only. They name everything that Steps 4.8-4.10 install, so read them before the install functions.

**How it connects:**
- Label `host` (`config.yaml:11`) <-> `runs-on: host` in `check.yml:8`, `image.yml:8` (Steps 5.5-5.6), `terraform.yml:8` (Step 6.1), `ansible.yml:8` (Step 7.1) and `teardown.yml:14` (Step 12.1).
- `/var/lib/lab/tfstate` -> the local backend (`terraform/provider.tf:15-17`) and TMPDIR (`terraform.yml:9-10`, `teardown.yml:15-16`) (Steps 6.1-6.2). `/var/lib/lab/images` -> `image.yml:19-20` (Step 5.6) -> the frontend role (`ansible/roles/frontend/tasks/main.yml:49-56`, Step 9.1).
- `CA` and `SSH_PUB` are the defaults of `var.lab_ca_cert_file` and `var.ssh_public_key_file` (`terraform/variables.tf:10,16`, Step 6.2).

**Re-run and removal:** There is no runtime state here. An edited `config.yaml` or unit is installed by `ensure_config`/`ensure_service`, which then restart the daemon (Steps 4.8, 4.10). A new `VERSION` alone does nothing (see Step 4.8).

**Check it yourself:**
- `systemctl cat lab-runner` shows the installed unit (no sudo needed).
- `diff services/gitea/runner/files/config.yaml /etc/lab-runner/config.yaml` prints nothing.

**Watch out:**
- Paths are repeated by hand. `HOME` appears in `config.yaml:6,19` and in the unit (`:9`). `BINARY` and `CONFIG` appear in `ExecStart` (`:14`). `CA` appears in `config.yaml:9,13`. If you change one, change all of them.
- `timeout: 1h` is per job. Bootstrap waits at most 70 min for the whole four-job run (`RUN_TIMEOUT`, Step 5.3).

> **Marked change (not applied), C7:** Remove the leftover migration from the old `lab-runner` user: `OLD_USER` (`services/gitea/runner/config/config.py:12`), the `chown` in `ensure_home` (`runner.py:22-26`, Step 4.8) and the `userdel` block in `down` (`runner.py:123-128`, Step 4.10). The host was rebuilt after the runner moved to root. See Appendix C.

### Step 4.8: Runner install (platform_up step 16, part 2)

**Files:**
- `services/gitea/runner/runner.py`: the module header, `ensure_home`, `ensure_binary`, `ensure_config`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Module header | Docstring (`:1`). Imports `host.ssh_access`, `lib.config` as `lab_config`, `install_file`/`systemctl_ok`/`write_file`, the Gitea config as `gitea_config`, the runner `config` and `services.vault.vault` (`:3-17`). Logger (`:19`) | `main.py:21` | None |
| 2 | `ensure_home() -> None` | `mkdir /var/lib/lab/runner` 0700 (parents included), then `chown 0:0` and `chmod 0700` on every run. Per its docstring, this is the folder for the registration file and job workdirs, and jobs run as root (`:22-26`) | `up` (`:105`) | `/var/lib/lab/runner` |
| 3 | `ensure_binary() -> bool` | If `/usr/local/bin/gitea-runner` exists (any version), it returns False (`:31-33`). Otherwise it downloads the `.xz` (60 s timeout), checks the sha256 and raises `RuntimeError` on a mismatch, decompresses it with `lzma` and writes it 0755 (`:36-45`). Returns whether the file changed | `up` (`:106`) -> `urllib`, `hashlib`, `lzma`, `write_file` | `/usr/local/bin/gitea-runner` |
| 4 | `ensure_config() -> bool` | `mkdir /etc/lab-runner` 0755. Installs `files/config.yaml` as `/etc/lab-runner/config.yaml` and copies `state/pki/ca.pem` to `/etc/lab-runner/ca.pem`, both 0644. Returns True if either changed (`:48-58`) | `up` (`:107`) -> `install_file` | `/etc/lab-runner/{config.yaml,ca.pem}` |

**Why here:** The binary and its config must exist before registration. `register` reads `--config` for `runner.file` and for `ca_file`, which it needs for TLS to `gitea.lab.test`. `ensure_config` also creates `/etc/lab-runner`, which `ensure_ssh_key` writes into next, and `write_file` does not create parent folders (`lib/system.py:57-65`). `ensure_home` must run before registration (location of `.runner`) and before the unit starts (`WorkingDirectory`).

**How it connects:**
- `/etc/lab-runner/ca.pem` is used by the daemon's TLS (`config.yaml:9`), by the jobs' `GIT_SSL_CAINFO` (`config.yaml:13`), by `NODE_EXTRA_CA_CERTS` in `ansible.yml:9-10` (Step 7.1), by Terraform's `lab_ca_cert_file` for the VM trust store (Step 6.6), and by the fluxcd Secret `flux-git-auth` `ca.crt` (`ansible/roles/fluxcd/templates/flux-git-auth.yaml.j2:10-11`, Step 8.2).
- The two `changed` flags feed `ensure_service`, which restarts the daemon (Step 4.10). A new root CA (Step 3.3) therefore restarts the runner.
- The binary goes into the same `/usr/local/bin` as the toolchain (Step 2.7).

**Re-run and removal:** `ensure_home` re-applies root:root 0700 on every run. `ensure_binary` returns False as long as any binary is present. `ensure_config` compares bytes and returns True only on a change. Removal is `runner.down` (Step 4.10).

**Check it yourself:**
- `/usr/local/bin/gitea-runner --version` prints the installed version.
- `cmp state/pki/ca.pem /etc/lab-runner/ca.pem && echo same`; `ls -ld /var/lib/lab/runner` shows `drwx------ root root`.

**Watch out:**
- A `VERSION` bump is ignored, because any existing binary counts as installed (`:31-33`). Even with a version check, `write_file` writes in place, which fails with "Text file busy" while the daemon runs the binary. A real upgrade needs a temp file and a rename, or a stop first.
- The first install needs internet access to gitea.com.

### Step 4.9: Runner: Terraform inputs (platform_up step 16, part 3)

**Files:**
- `services/gitea/runner/runner.py`: `ensure_ssh_key`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `ensure_ssh_key(token: str) -> None` | Reads `public_key` from Vault `kv/data/lab/pipeline/ssh` (the private half stays in Vault) and the operator's line from `ssh_access.public_key()`. Writes both, one per line, to `/etc/lab-runner/ssh.pub` with mode 0644 (`:61-69`) | `up` (`:109`) -> `vault.vault_api`, `ssh_access.public_key`, `write_file` | Reads Vault; writes `/etc/lab-runner/ssh.pub` |

**Why here:** It needs the pipeline key pair in Vault (`vault.ssh_key`, Step 3.7), the operator key (Step 4.6, which runs right before `runner.up`) and the folder from `ensure_config` (Step 4.8). It runs at bootstrap time, not in a job, so the file is ready when the terraform job reads it (Step 6.2).

**How it connects:**
- `ssh.pub` -> `var.ssh_public_key_file` (`terraform/variables.tf:7-11`) -> `split("\n", trimspace(file(...)))` (`terraform/compute.tf:74`) -> `ssh_authorized_keys` of user `user` (`terraform/cloud-init/user-data.yaml.tftpl:8-11`) (Step 6.6).
- The pipeline's private key reaches Ansible through `vault-action` and `ssh-agent` (`ansible.yml:26,32-35`, Step 7.1). The operator uses the aliases (Step 4.6).

**Re-run and removal:** `write_file` compares bytes, so an unchanged file only logs `already at`. The daemon does not read this file, so a change does not restart it. `runner.down` removes it along with `/etc/lab-runner` (Step 4.10).

**Check it yourself:**
- `wc -l /etc/lab-runner/ssh.pub` prints 2.
- `diff <(ssh-keygen -y -f ~/.ssh/lab_operator) <(sed -n 2p /etc/lab-runner/ssh.pub)` prints nothing.

**Watch out:**
- This file decides who can log in to every VM. If either key changes, every VM is rebuilt on the next `update` (`terraform/compute.tf:64-66,184-186`; the full chain is in Step 6.7, "What rebuilds a VM").

### Step 4.10: Runner registration, service, lifecycle (platform_up step 16, part 4)

**Files:**
- `services/gitea/runner/runner.py`: `ensure_registered`, `ensure_service`, `up`, `down`.
- `main.py`: `runner.up()` as `platform_up` step 16, the last step (`:47`), and `runner.down()` as the first step of `platform_down` (`:52`).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `ensure_registered(token: str) -> None` | If `/var/lib/lab/runner/.runner` exists, it logs and skips. Otherwise it reads the registration token from Vault `GITEA_RUNNER_KV` and runs `gitea-runner register --no-interactive --config /etc/lab-runner/config.yaml --instance https://gitea.lab.test --name lab-host --token-file /dev/stdin`, with the token on stdin so it never appears in argv (`:74-85`). The labels come from `config.yaml`. In both cases it then runs `chmod 0600` on `.runner` (`:86`) | `up` (`:110`) -> `vault.vault_api`, `gitea-runner register` | Reads Vault; writes `.runner`; adds runner `lab-host` in Gitea |
| 2 | `ensure_service(changed: bool) -> None` | Installs the unit. If the unit changed, it runs `daemon-reload` and sets `changed` (`:91-93`). Then `systemctl enable lab-runner` (`:95`), and `restart` if anything changed or the unit is not active (`:96-100`) | `up` (`:111`) -> `install_file`, `systemctl`, `systemctl_ok` | `/etc/systemd/system/lab-runner.service`; the running daemon; the two `StateDirectory` folders |
| 3 | `up() -> None` | `ensure_home`, `changed = ensure_binary()`, `changed \|= ensure_config()`, one `vault.login()`, `ensure_ssh_key`, `ensure_registered`, `ensure_service(changed)` (`:103-111`) | `platform_up` (`main.py:47`) -> `ensure_home`, `ensure_binary`, `ensure_config`, `vault.login`, `ensure_ssh_key`, `ensure_registered`, `ensure_service` | See the rows above |
| 4 | `down() -> None` | If the unit file exists: `systemctl disable --now lab-runner` (this stops a running job, within `TimeoutStopSec=60`), delete the unit, `daemon-reload` (`:116-119`). Then remove `/etc/lab-runner`, the binary and `/var/lib/lab/runner` (`:120-122`). If the legacy user `lab-runner` exists, `userdel` it (`:123-128`) | `platform_down` (`main.py:52`) -> `systemctl`, `shutil`, `userdel` | Removes all of the above. `/var/lib/lab/tfstate` and `images` go with `cmd_destroy`'s `rmtree(/var/lib/lab)` (`main.py:103`) |

**Why here:** This is the last `platform_up` step. It needs the registration token (Step 4.4), the binary, config and CA (Step 4.8), Vault (Step 3.6), and Gitea reachable through Traefik (Steps 3.1, 3.8). The runner must be active before the command tail starts a run (Step 5.1); otherwise the run would just sit in the queue. In `platform_down` it goes first, so no job can run while the toolchain, libvirt and services are removed.

**How it connects:**
- Registration and the daemon's job polling both use `https://gitea.lab.test`, through the `host-only` router, trusting `ca_file` (Steps 3.8, 4.7).
- Runner `lab-host` with label `host` takes every job of `deploy.yml` (Steps 5.4-5.6, 6.1, 7.1) and of `teardown.yml` (Step 12.1).
- Starting the unit creates `/var/lib/lab/tfstate` (Step 6.1) and `/var/lib/lab/images` (Step 5.6).
- When `follow_run` times out, its message "is lab-runner running?" points here (Step 5.3).

**Re-run and removal:** With `.runner` present, registration is skipped and only the chmod runs. `enable` is idempotent. The daemon is restarted only when the binary, config, CA or unit changed, or when it is not active. After a host reboot the unit starts at boot, but nothing in the repo starts the Gitea and Traefik containers at boot (Step 12.3, row 5), and Vault comes back sealed. That is why `teardown` and `update` run `platform_up` first, and `ensure_service` restarts the runner if it is not active (`runner.py:96-98`). The comment at `main.py:95` says the runner is stopped after a reboot, although the unit is enabled (`lab-runner.service:19`, `runner.py:95`). Either way, the restart covers it. Removal is `down()`.

**Check it yourself:**
- `systemctl is-enabled lab-runner; systemctl is-active lab-runner` prints `enabled` and `active`.
- Gitea UI -> Site Administration -> Actions -> Runners shows `lab-host` with label `host`, idle.
- `ls -ld /var/lib/lab/tfstate /var/lib/lab/images`: both are `drwx------ root root`.

**Watch out:**
- If you delete `.runner` by hand, the next run registers again but does not set `changed`. A daemon that is already active keeps its old identity until it restarts.
- `runner.up` touches neither libvirt nor the toolchain. Those are needed by the jobs (Phase 5 onward), not by the runner itself.
- Jobs run as root on the host. Any commit that reaches Gitea's `main` runs with root rights.

## Phase 5: Trigger and first pipeline jobs

Phase 5 hands the committed tree to the pipeline and follows it. It runs as the command tail right after `platform_up`: in `cmd_up` (`main.py:75-78`) and `cmd_update` (`main.py:87-88`) it pushes the local commit to Gitea's `main`, or dispatches `deploy.yml` when `main` already holds it. `cmd_teardown` (`main.py:96-97`) dispatches `teardown.yml` instead. Then bootstrap waits for the run to finish. On the host, the runner takes the jobs of `deploy.yml` in order. This phase walks the first two: `check` (Terraform format and validation, plus an IaC scan) and `image` (build, save and scan the frontend image). After this phase, Gitea's `main` equals the local `HEAD` and a `deploy` run is in progress. `check` has passed. The host Podman store holds `localhost/frontend:<sha>`, `/var/lib/lab/images/frontend.tar` holds the same image for fe-1, and the run has a Trivy report attached. The `terraform` job (Phase 6) is next, and `bootstrap.sh` is still waiting in `follow_run` until the whole run ends.

**Needs from earlier phases:**
- A local commit `HEAD` equal to the tree `platform_up` applied, and the marker gate (Step 1.7). `git()` runs git as the operator (Step 1.7).
- The `state/run.lock` held by `main()`, and its exit-code handling (Step 1.2).
- A complete `platform_up`: Vault unsealed for `vault.login()` (Step 3.5), Gitea seeded (Steps 4.2-4.4), and `lab-runner` active with label `host` (Step 4.10).
- The Gitea constants `GITEA_WORKFLOW`, `GITEA_TEARDOWN_WORKFLOW` and `RUN_*` (Step 4.1).
- Host tools for the jobs: `terraform` 1.17.2, `trivy` and `node` (for JavaScript actions) in `/usr/local/bin` (Step 2.7), and rootful Podman for `podman build` (Step 2.4). `/var/lib/lab/images` (Step 4.10).
- Host internet: github.com (the `uses:` actions), the Terraform registry (providers), cgr.dev (base images), PyPI (`pip install` in the build stage), and Trivy's database and checks.

**Hands on:**
- Gitea `main` = the pushed commit. In every job of the run that sha is `GITHUB_SHA` / `${{ github.sha }}`.
- A `deploy` run (its run id and run number) in the concurrency group `lab-deploy`.
- `/var/lib/lab/images/frontend.tar` holding `localhost/frontend:<GITHUB_SHA>`, read by the frontend role (Step 9.1).
- The image `localhost/frontend:<sha>` in the host's Podman store (old tags are never pruned).
- Run artifact `trivy-image-report` (`trivy-image.json`, `trivy-image.txt`), kept 7 days.
- `state/initialized`, after the first `up`.
- The exit code of `bootstrap.sh`: 0 only if the run concluded `success`.

### Step 5.1: Command tails (after platform_up)

**Files:**
- `main.py`: what each command does after `platform_up()`. The marker gates and `commit_changes()` are Step 1.7. The `teardown.yml` workflow is Step 12.1.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `cmd_up() -> None`, tail | After `platform_up()` (`:74`): `creds = gitea.gitea_admin(vault.login())` (`:75`), `run_id = gitea.start_run(creds)` (`:76`), **`INITIALIZED_MARKER.touch()`** (`:77`), `gitea.follow_run(creds, run_id)` (`:78`) | `COMMANDS["up"]` -> `vault.login`, `gitea_admin`, `start_run`, `follow_run` | Writes `state/initialized` |
| 2 | `cmd_update() -> None`, tail | After `platform_up()` (`:86`): the same `creds` line (`:87`), then `gitea.follow_run(creds, gitea.start_run(creds))` (`:88`) | `COMMANDS["update"]` -> same | None |
| 3 | `cmd_teardown() -> None`, tail | Runs no `commit_changes`. `platform_up()` (`:95`; comment: after a reboot Vault is sealed and the runner is stopped), the same `creds` line (`:96`), then `follow_run(creds, dispatch(creds, GITEA_TEARDOWN_WORKFLOW))` (`:97`). If the run succeeds, it logs `teardown complete: ...` (`:98`) | `COMMANDS["teardown"]` -> `vault.login`, `gitea_admin`, `dispatch("teardown.yml")`, `follow_run` | None (the marker is kept) |

**Why here:** A tail can start a run only once `platform_up` has finished: Gitea is seeded and the runner is active. It then fetches the admin creds again (`gitea.up` returns nothing). This is the run's fifth AppRole login, after `vault.up`, `gitea.up`, `monitoring.up` and `runner.up`, and its second `gitea_admin` read.

**Why `cmd_up` touches `state/initialized` before `follow_run`:** The marker means "the host platform is built and Gitea's `main` holds the code". It does not mean "the pipeline is green". When `start_run` returns, `platform_up` has finished and the commit, including `deploy.yml` and `teardown.yml`, is on Gitea's `main`. From then on the lab should be driven by `update`, which repeats everything idempotently. If the marker were written only after a green run, a red first pipeline (an Ansible error, or a slow first image pull) would leave a lab that `update` refuses ("run up first", `main.py:82-84`) and that `teardown` refuses even when VMs already exist (`main.py:92-94`). The only way forward would be `up` again, the command meant to run once. Writing it before the wait also covers a Ctrl-C or a timeout during the up-to-70-minute wait, because the run keeps going on the runner. Writing it after `start_run`, not earlier, means that if `platform_up`, the push or `wait_for_run` fails, there is no marker, and the right retry is `up`. It also guarantees that `cmd_teardown`'s dispatch of `teardown.yml` will find the file on `main`.

**How it connects:**
- `start_run`/`dispatch` (Step 5.2) and `follow_run` (Step 5.3) do the work. The exit code reaches `bootstrap.sh` through `main()` (Step 1.2): `follow_run`'s `sys.exit(1)` gives exit 1 without `main()`'s `<command> failed: ...` line (SystemExit is not caught there); follow_run has already logged `run #N failed` or `run #N timed out; is lab-runner running?`.
- The marker is read by the gates (Step 1.7) and removed by `cmd_destroy` (Step 12.2). `teardown` keeps it (Step 12.1).
- `teardown` runs `teardown.yml` exactly as it is on Gitea's `main`. A local edit to that file takes effect only after an `update` pushes it.

**Re-run and removal:** `update` with no edits dispatches the same commit again (Step 5.2), which is a full, idempotent re-run. A second `up` stops at the gate. Nothing here is removed except the marker, by `destroy`.

**Check it yourself:**
- `ls -l state/initialized` exists after the first `up`.
- `tail -n 5 state/bootstrap.log` shows `run #N succeeded` (or `failed`, or `timed out; is lab-runner running?`) for the last command. After a successful `teardown`, a `teardown complete: ...` line follows it.

**Watch out:**
- `teardown` runs the full `platform_up`, which applies any uncommitted host-side edits in the working tree (nft rules, compose files) without committing them. The next `update` commits them.
- If `follow_run` times out, `up` has already written the marker and exits 1 while the run continues (Step 5.3).

### Step 5.2: Push or dispatch

**Files:**
- `services/gitea/gitea.py`: `main_differs`, `push`, `wait_for_run`, `dispatch`, `start_run`. They reuse `git()` from Step 1.7.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `main_differs(creds: dict) -> bool` | `GET repos/lab/lab/branches/main` and compare its `commit.id` with `git rev-parse HEAD` (`:199-206`). On the empty first-run repo the GET returns 404, so `{}` and an id of `None`, which counts as "differs" | `start_run` -> `gitea_api`, `git` | Read only |
| 2 | `push(creds: dict) -> str` | Runs `git -C <repo> push https://gitea.lab.test/lab/lab.git HEAD:refs/heads/main` **as root**, not through `git()` (`:166-170`). Its env adds `GIT_SSL_CAINFO=state/pki/ca.pem`, `GIT_TERMINAL_PROMPT=0` and the Basic header as `http.extraHeader` via `GIT_CONFIG_COUNT/KEY_0/VALUE_0`, so the password never appears in argv (`:154-165`). There is no `--force`. Returns `git rev-parse HEAD` (run as the operator) and logs `pushed <sha7> to Gitea's main; the push starts deploy.yml` (`:171-173`) | `start_run` -> `git push`, `git` | Gitea `lab/lab` branch `main` |
| 3 | `wait_for_run(creds: dict, sha: str) -> int` | Polls `actions/runs?head_sha=<sha>&event=push&branch=main&limit=1`: 6 tries 10 s apart (`RUN_START_TIMEOUT // RUN_POLL_SECONDS`). Returns the first run's id, or exits 1 with "does deploy.yml trigger on push to main?" (`:229-242`). Per its docstring, the run with this sha and event must be ours, because only `deploy.yml` triggers on push and `main` never held this sha before | `start_run` -> `gitea_api` | Read only |
| 4 | `dispatch(creds: dict, workflow: str = GITEA_WORKFLOW) -> int` | `POST repos/lab/lab/actions/workflows/<workflow>/dispatches?return_run_details=true` with `{"ref": "main"}`. Returns `workflow_run_id` (`:214-226`). A 404 logs "<workflow> is not on Gitea's main yet; run update first" and exits 1 (`:220-224`). Any other HTTP error raises | `start_run` (deploy.yml); `cmd_teardown` (teardown.yml) -> `gitea_api` | Starts a run of the file as it is on `main` |
| 5 | `start_run(creds: dict) -> int` | If `main_differs`: `wait_for_run(creds, push(creds))`. Otherwise it logs `nothing new to push` and calls `dispatch(creds)` (`:275-280`) | `cmd_up`, `cmd_update` (Step 5.1) -> `main_differs`, `push`, `wait_for_run`, `dispatch` | See above |

**Why here:** These functions need the repo (Step 4.3), the admin creds (Step 4.2) and an active runner (Step 4.10), so they run only after `platform_up`. They send the commit made in Step 1.7.

**How it connects:**
- The push is a Gitea push event on `main`, which starts `deploy.yml` (`on: push: branches: [main]`, Step 5.4). The pushed sha becomes `GITHUB_SHA`.
- `wait_for_run` depends on a fact in the workflow files: only `deploy.yml` has `on: push`. `check`, `image`, `terraform` and `ansible` are `workflow_call` only, and `teardown.yml` is `workflow_dispatch` only (Steps 5.4-5.6, 12.1).
- `dispatch` needs `workflow_dispatch` under `on:` in the file on `main`: `deploy.yml:6` and `teardown.yml:5-6`.
- The same `main` is what Flux's GitRepository follows (Step 8.2).

**Re-run and removal:** With a clean tree and `main == HEAD`, `start_run` dispatches `deploy.yml` on the same commit. That is how `update` re-runs the pipeline without an edit. Nothing is removed. `destroy` deletes the Gitea repo (Step 12.2), and your local history stays.

**Check it yourself:**
- `grep -E "pushed|nothing new to push|started deploy.yml" state/bootstrap.log | tail -n 3`, then compare the short sha with `git log --oneline -1`.

**Watch out:**
- `push` runs git as root inside a repo the operator owns. Git's ownership check (`safe.directory`) accepts this because the push keeps `SUDO_UID` in its environment (`**os.environ`, `:159`). A URL push updates no remote-tracking refs, so root writes nothing into `.git`.
- There is no `--force`. If Gitea's `main` is ahead or has diverged, for example after an edit in the Gitea web UI, the push is rejected and the command stops with `update failed: git exited with 1`.
- The push sends `HEAD`, not a branch. Whatever is checked out locally becomes Gitea's `main`.

### Step 5.3: Follow the run

**Files:**
- `services/gitea/gitea.py`: `follow_run`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `follow_run(creds: dict, run_id: int) -> None` | `GET actions/runs/<id>` and log `run #N started; waiting for it to finish: <html_url>` (`:247-249`). Poll every 10 s until `status == "completed"`. After `RUN_TIMEOUT` (70 min) it logs "run #N timed out; is lab-runner running?" and exits 1 (`:250-256`). Then list `/jobs` and log `name: conclusion` for each job. For each `failure`, fetch `actions/jobs/<id>/logs` (raw) and print the last 30 lines to stderr, indented. An `OSError` while fetching gives `(log not available)` (`:258-267`). Exits 1 unless the run's conclusion is `success`; otherwise logs `run #N succeeded` (`:269-272`) | `cmd_up`, `cmd_update`, `cmd_teardown` -> `gitea_api` | Read only |

**Why here:** This is the last thing a command does. `main()` holds `state/run.lock` for the whole wait (Step 1.2), so no second `bootstrap.sh` can start while a run is followed.

**How it connects:**
- It follows the run id from Step 5.2. The poll and timeout values are from Step 4.1. The per-job limit (1 h) is in the runner config (Step 4.7).
- The failed-job tail goes to stderr through `print`, not to `state/bootstrap.log` (`lib/log.py` handles only log records).

**Re-run and removal:** Read only. A new command follows its own new run.

**Check it yourself:**
- `grep -E 'run #[0-9]+ (started|succeeded|failed)' state/bootstrap.log | tail -n 3`
- `echo $?` right after `sudo ./bootstrap.sh update`: 0 means the run concluded `success`.

**Watch out:**
- 70 min for the whole run against up to 1 h per job, four jobs in a row. A slow but healthy first build can make bootstrap exit 1 while the run continues on the runner. A retried `update` then queues behind it in `lab-deploy`.
- Every poll is a fresh HTTPS call with a 10 s timeout. A network error during the wait raises out of `follow_run` (`update failed: ...`), and the run still continues.
- Any conclusion other than `success` exits 1, including `cancelled`. Jobs skipped after a failure are listed as `skipped`.

### Step 5.4: deploy.yml and runner pickup

**Files:**
- `.gitea/workflows/deploy.yml`: the only pipeline entry point. It chains four reusable workflows.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `name` and `on` | `name: deploy`. Triggers: `push` to `branches: [main]` and `workflow_dispatch` (`deploy.yml:1-6`) | Gitea, on `push` (Step 5.2) or `dispatch` | None |
| 2 | `concurrency` | `group: lab-deploy`, `cancel-in-progress: false` (`:8-10`). A second run waits and never cancels the first. `teardown.yml:8-10` uses the same group | Gitea scheduler | None |
| 3 | Job `check` | `uses: ./.gitea/workflows/check.yml` (`:13-14`), read from the same commit | Run start -> Step 5.5 | None |
| 4 | Job `image` | `needs: check`, `uses: ./.gitea/workflows/image.yml` (`:15-17`) | -> Step 5.6 | None |
| 5 | Job `terraform` | `needs: image`, `uses: ./.gitea/workflows/terraform.yml` (`:18-20`) | -> Step 6.1 | None |
| 6 | Job `ansible` | `needs: terraform`, `uses: ./.gitea/workflows/ansible.yml`, `secrets: inherit` (`:21-24`). This is the only job that receives `VAULT_ROLE_ID`/`VAULT_SECRET_ID` | -> Step 7.1 | None |
| 7 | Runner pickup (no file) | Each called job says `runs-on: host`. Runner `lab-host` (label `host:host`, Step 4.7) runs it as root directly on the host, one job at a time (`capacity: 1`), with its checkout under `/var/lib/lab/runner/work`. Every job starts with `actions/checkout@v4` and `persist-credentials: false` (for example `check.yml:10-12`), which leaves no job token in `.git/config`. The runner sets `GITHUB_SHA` (`${{ github.sha }}`) to the run's commit in every job | `lab-runner` daemon (Step 4.10) | `/var/lib/lab/runner/work`; host tools |

**Why here:** The push or dispatch from Step 5.2 lands here. The order of the chain is the order of risk: cheap checks first, then the image (nothing on the VMs changes yet), then Terraform, then Ansible.

**How it connects:**
- The commit flow, end to end:
  1. The operator edits files in the checkout and runs `sudo ./bootstrap.sh update`.
  2. `commit_changes()` commits the edits as the operator, with the message `update YYYY-MM-DD HH:MM` (Step 1.7).
  3. `platform_up()` applies the host side of the same tree (Phases 2-4).
  4. `start_run` -> `main_differs` -> `push`: root pushes `HEAD` to `https://gitea.lab.test/lab/lab.git` `main`. The push paths sit under `/lab/lab.git/`, so they match router `gitea-flux` (priority 100, middleware `flux-and-host`, which also admits 10.250.0.1), not `host-only` (Step 5.2).
  5. Gitea records the push. `deploy.yml` `on: push: branches: [main]` creates a run whose `head_sha` is the pushed commit. `wait_for_run` finds it by sha and event, and `follow_run` waits (Steps 5.2-5.3).
  6. `lab-host` runs `check` -> `image` -> `terraform` -> `ansible`, and each job checks out `GITHUB_SHA`.
  7. `image.yml` tags `localhost/frontend:${{ github.sha }}` and saves it into `/var/lib/lab/images/frontend.tar` (Step 5.6).
  8. In the ansible job, the frontend role sets `frontend_tag` from the `GITHUB_SHA` environment variable (`ansible/roles/frontend/defaults/main.yml:1`) and writes `Image=localhost/frontend:<sha>` into the Quadlet (`ansible/roles/frontend/templates/frontend.container.j2:7`). The tag inside the tar and the tag the unit starts are the same commit (Step 9.1).
  9. Flux's GitRepository `lab-repo` follows the same Gitea `main` (`ansible/roles/fluxcd/files/flux-sync.yaml:9-11`). `app_deployed` waits until Kustomization `lab-apps` reports `lastAppliedRevision = main@sha1:<GITHUB_SHA>` (`ansible/roles/app_deployed/tasks/main.yml:7-9`), so the pipeline and Flux finish on the same commit (Steps 8.2, 8.7).
  10. `follow_run` sees `completed`/`success`, and `bootstrap.sh` exits 0.
- `secrets: inherit` -> `ansible.yml:22-23` (Step 7.1). These are the secrets that Step 4.4 wrote.
- `concurrency: lab-deploy` is shared with `teardown.yml` (Step 12.1): a destroy never overlaps a deploy.

**Re-run and removal:** Each push or dispatch makes a new run, and queued runs never cancel each other. There is no path filter, so every commit, even a doc edit, runs all four jobs. Terraform and Ansible then find nothing to change. Nothing is removed. Run history lives in Gitea until `destroy`.

**Check it yourself:**
- `grep -n -A3 '^on:' .gitea/workflows/*.yml` shows `push` only in `deploy.yml`, `workflow_call` in the four job files, and `workflow_dispatch` in `deploy.yml` and `teardown.yml`.
- Gitea UI -> `lab/lab` -> Actions -> the latest run shows four jobs in the order check, image, terraform, ansible.

**Watch out:**
- If you add `on: push` to any other workflow, `wait_for_run` may pick that workflow's run for the same sha.
- The `uses:` actions are pinned by tag, not by commit SHA, and are downloaded from github.com when each job starts (no `DEFAULT_ACTIONS_URL`, Step 4.1). They run as root.
- If a newer push arrives while a run is still going, Flux applies the newer commit. The older run's exact-revision wait in `app_deployed` then times out, even though the app is healthy (Step 8.7).

### Step 5.5: check.yml

**Files:**
- `.gitea/workflows/check.yml`: job `validate`. It checks that Terraform is formatted and valid and scans the repo's IaC (report only).
- `terraform/.terraform.lock.hcl`: the provider lock file (selected versions and hashes for `ansible/ansible` 1.5.0 and `dmacvicar/libvirt` 0.9.9). Its contents are not reviewed here.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `on: workflow_call` | Runs only when `deploy.yml` calls it (`check.yml:1-4`) | `deploy.yml:13-14` | None |
| 2 | Job `validate` | `runs-on: host` (`:7-8`) | `lab-host` | None |
| 3 | Checkout | `actions/checkout@v4` with `persist-credentials: false` (`:10-12`). Host git trusts Gitea through `GIT_SSL_CAINFO` from the runner config | runner -> node, git | Job workdir |
| 4 | `terraform init` | `terraform -chdir=terraform init -backend=false -input=false -lockfile=readonly` (`:13`). Downloads the providers named in the lock file into `terraform/.terraform` in the workdir. `-backend=false` never touches `/var/lib/lab/tfstate`. `-lockfile=readonly` fails rather than change the lock file | -> Terraform registry | Workdir only |
| 5 | `terraform fmt` | `fmt -check -recursive` (`:14`): fails on any unformatted `.tf` | | None |
| 6 | `terraform validate` | `validate` (`:15`): schema and reference errors | providers | None |
| 7 | Trivy IaC scan | `trivy config --skip-dirs terraform/.terraform .` (`:16-17`): misconfiguration report over the whole repo (Terraform, Dockerfile, Kubernetes manifests). There is no `--exit-code`, so it reports and never fails the job | -> Trivy checks download | Job log |
| 8 | `terraform/.terraform.lock.hcl` | Provider selections and hashes (`:4`, `:26` start the two `provider` blocks). One row only; contents not reviewed | `init` in `check.yml:13`, `terraform.yml:19`, `ansible.yml:38`, `teardown.yml:23` | None |

**Why here:** It is the cheapest gate, so it goes first. A formatting or syntax error stops the run before an image is built or any VM changes. It needs no state, so it cannot interfere with the real Terraform run (Step 6.1).

**How it connects:**
- The same lock file and the same `-lockfile=readonly` are used by the terraform job (Step 6.1), the ansible job's `init` (Step 7.1) and teardown (Step 12.1). Its versions must satisfy `terraform/provider.tf:5-12` (Step 6.2).
- It needs `terraform` 1.17.2 and `trivy` from Step 2.7, and `node` for `actions/checkout`.

**Re-run and removal:** Stateless. Every run downloads the providers again into a fresh workdir.

**Check it yourself:**
- From the repo root: `terraform -chdir=terraform fmt -check -recursive; echo $?` prints 0 (works offline).
- `grep -n 'version ' terraform/.terraform.lock.hcl` and `grep -n version terraform/provider.tf` show the same two provider versions.

**Watch out:**
- When you bump a provider in `provider.tf`, regenerate and commit the lock file (`terraform init -upgrade` locally). With `-lockfile=readonly`, the old lock file makes `init` fail in this job.
- Trivy findings never turn the run red. Read them in the job log.

### Step 5.6: image.yml and the frontend source

**Files:**
- `frontend/requirements.txt`: pinned Python dependencies of the frontend.
- `frontend/Dockerfile`: a two-stage Chainguard build, which runs gunicorn with TLS on 443 as uid 65532.
- `frontend/app.py`: the Flask "Lab Todo" app, which calls PostgREST on be-1.
- `frontend/templates/items.html`: the single page (list, add, edit, delete).
- `.gitea/workflows/image.yml`: job `build`. It builds the image tagged with the commit, saves it for fe-1, scans it and uploads the report.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `requirements.txt` | Eight pins: Flask 3.1.3 and its dependencies (blinker, click, itsdangerous, Jinja2, MarkupSafe, Werkzeug), plus gunicorn 27.0.1 (`requirements.txt:1-8`). Versions only, no hashes | Dockerfile `:4-5` | None |
| 2 | Dockerfile build stage | `cgr.dev/chainguard/python:latest-dev@sha256:88d8...` `AS build`, `USER root`, `pip install --no-cache-dir --target /app/packages -r requirements.txt` (`Dockerfile:1-5`). The `-dev` image has pip and a shell | `podman build` -> cgr.dev, PyPI | Build cache |
| 3 | Dockerfile runtime stage | `cgr.dev/chainguard/python:latest@sha256:d914...` (minimal, no pip). Copies `/app/packages`, `app.py` and `templates`, sets `PYTHONPATH=/app/packages`, `USER 65532` (`:7-13`) | `podman build` | Image layers |
| 4 | Dockerfile `ENTRYPOINT` | `python -m gunicorn --bind 0.0.0.0:443 --workers 2 --access-logfile - --certfile /etc/app/tls/tls.crt --keyfile /etc/app/tls/tls.key app:app` (`:14`). TLS ends in the app. The cert and key come from a volume at run time | container start on fe-1 (Step 9.1) | Reads `/etc/app/tls` |
| 5 | `app.py` and `templates/items.html` | Copied into the runtime stage (row 3) and run by the `ENTRYPOINT` (row 4). Their units (`API`, `app`, `api`, `index`, `add`, `update`, `delete`, `api_error`, and the page) are walked one by one in Step 9.2 | `podman build` | Image layers |
| 6 | `image.yml` `on`, job | `on: workflow_call`, job `build`, `runs-on: host` (`image.yml:1-8`) | `deploy.yml:15-17` | None |
| 7 | Checkout | `actions/checkout@v4`, `persist-credentials: false` (`:10-12`) | runner | Job workdir |
| 8 | Build | `podman build -t localhost/frontend:${{ github.sha }} frontend/` (`:14-15`), run by host rootful Podman as root | -> Dockerfile | Host image store `/var/lib/containers` |
| 9 | Save | `rm -f /var/lib/lab/images/frontend.tar`, then `podman save -o /var/lib/lab/images/frontend.tar localhost/frontend:<sha>` (`:17-20`). The `rm` is needed because Podman's docker-archive writer will not write into an existing archive | -> podman | `/var/lib/lab/images/frontend.tar` |
| 10 | Scan | `trivy image --input <tar> --format table \| tee trivy-image.txt`, then a second scan with `--format json --output trivy-image.json` (`:22-25`). No `--exit-code`, so report only | -> Trivy DB download | Two report files in the workdir |
| 11 | Upload | `actions/upload-artifact@v4`, name `trivy-image-report`, both files, `retention-days: 7` (`:27-34`) | -> Gitea artifact API | Run artifact in Gitea |

**Why here:** `needs: check` and is needed by `terraform` (`deploy.yml:15-20`). A broken Dockerfile or a failed build stops the run before any VM changes. The tar must exist before the frontend role copies it in play 4 (Step 9.1). The source files are listed here because this is where they become an artifact. What they do at run time is walked unit by unit in Step 9.2, and the request path in Step 11.1.

**How it connects:**
- Tag `${{ github.sha }}` = `GITHUB_SHA` -> `frontend_tag` (`ansible/roles/frontend/defaults/main.yml:1`) -> Quadlet `Image=` (`frontend.container.j2:7`). The role copies the tar and runs `podman load` only when the tar changed (`ansible/roles/frontend/tasks/main.yml:49-60`) (Step 9.1).
- `/var/lib/lab/images` is created by the runner unit's `StateDirectory` (Step 4.7).
- `/etc/app/tls` is mounted from fe-1's `/etc/frontend/tls` (`frontend.container.j2:10`), filled from Vault `app-edge` (Steps 3.7, 7.1, 9.1). uid 65532 can bind 443 because the role sets `net.ipv4.ip_unprivileged_port_start = 443` (`ansible/roles/frontend/tasks/main.yml:8-16`). `Network=host` (`frontend.container.j2:9`) puts the app straight on fe-1's addresses.
- `10.3.1.10:8000` is be-1's site-c address and the k3s Traefik `web` entrypoint moved to 8000 (`ansible/roles/k3s/files/traefik-config.yaml:10-12`). The hub filter on tun-1 allows only that port (`ansible/roles/wireguard/files/hub-forward.nft:13`) (Steps 7.5, 8.1, 11.1). The Quadlet sets no `API_URL`, so the default in `app.py:10` is the one used.

**Re-run and removal:** Every run builds again (the layer cache makes an unchanged build quick), replaces the tar and scans again. A dispatch of the same commit reuses the same tag. Old `localhost/frontend:<sha>` images pile up in the host store, because nothing prunes them. `podman.down` removes all images on `destroy` (Steps 2.4, 12.2), and `rmtree(/var/lib/lab)` removes the tar.

**Check it yourself:**
- (sudo) `sudo podman images localhost/frontend` lists one tag per built commit. The newest tag equals `git rev-parse HEAD` after a green run.
- (sudo) `sudo tar -xOf /var/lib/lab/images/frontend.tar manifest.json` shows `RepoTags` `localhost/frontend:<sha>`.
- Gitea UI -> the run page -> Artifacts lists `trivy-image-report`.

**Watch out:**
- Both base images say `latest` but are pinned by digest. Bump the two digests together: packages that `pip` installed under the `-dev` image's Python must match the runtime image's Python.
- The runtime pitfalls (no login or CSRF protection, an empty image tag when the role runs outside the pipeline) are in Steps 9.1 and 9.2.

## Phase 6: Terraform

Phase 6 turns the host into a small private cloud: one storage pool with an Ubuntu base image, four libvirt networks, and three KVM guests (fe-1, tun-1, be-1) with fixed addresses, the lab's SSH keys and the lab CA written in at first boot. It runs as the third job of every deploy run. `deploy.yml` job `terraform` (`needs: image`, `.gitea/workflows/deploy.yml:18-20`) calls `terraform.yml` job `apply`, which the host runner executes directly on the host as root. Terraform keeps its state in a local file in `/var/lib/lab/tfstate`. When the phase ends, the three VMs are running and cloud-init is doing (or has done) its first-boot work. They answer SSH over `mgmtbr1` at 10.250.0.110-112 with the pipeline key or the operator key. They have no tunnels, no clock or apt settings and no software beyond the cloud image. The Terraform state also holds three `ansible_host` rows that tell Ansible (Phase 7) which VM is which.

**Needs from earlier phases:**
- The runner `lab-host` with label `host`, running as root (`services/gitea/runner/files/lab-runner.service:7`; Steps 4.7, 4.10), and the deploy chain check -> image -> terraform (Step 5.4).
- `/usr/local/bin/terraform` 1.17.2 (Step 2.7). `virsh` and libvirtd at `qemu:///system` (Step 2.5).
- Bridge `mgmtbr1` with 10.250.0.1/24 (Step 2.2). Each domain's third NIC attaches to it by name.
- The VM firewall loaded since the last boot: tables `bridge lab_sg` and `inet lab_vmfw` plus the marker `/run/lab/vmfw.loaded` (Step 2.6).
- `/var/lib/lab/tfstate` (0700, root), created by the runner unit's `StateDirectory` (Steps 4.7, 4.10).
- `/etc/lab-runner/ca.pem` (Step 4.8) and `/etc/lab-runner/ssh.pub`, which holds the pipeline and operator public keys, one per line (Step 4.9).
- `terraform/.terraform.lock.hcl` (Step 5.5).
- Host internet: registry.terraform.io for the providers, cloud-images.ubuntu.com for the base image, github.com for `actions/checkout`.

**Hands on:**
- `/var/lib/lab/tfstate/terraform.tfstate`, with three `ansible_host` resources (name, group, `ansible_host`, `ansible_user`, `vpc_ip`, `wan_ip`) that the inventory plugin reads (Step 7.2).
- libvirt pool `lab` at `/var/lib/lab/pool`: `ubuntu-24.04-20261017.qcow2` (base), the overlays `fe-1-10g.qcow2`, `tun-1-10g.qcow2` and `be-1-40g.qcow2`, and `<vm>-seed.iso`.
- libvirt networks, each with a Linux bridge of the same name: `site-a`, `site-hub`, `site-c` (isolated, no host address) and `wan` (host 198.51.100.1/24, route mode).
- Domains `fe-1`, `tun-1`, `be-1`: running, autostart off, with taps `<vm>-vpc`, `<vm>-wan` and `<vm>-mgmt`. The host firewall's sets name only the `-wan` and `-mgmt` taps (`host/files/nftables-vmfw.nft:15-41`); no set names the `-vpc` tap (Step 6.7).
- Inside each VM after cloud-init: user `user` (passwordless sudo, keys only), the lab CA in the trust store, hostname = VM name, static addresses on eth0/eth1/eth2, default route via 198.51.100.1, DNS 10.250.0.1.

### Step 6.1: Job preconditions

**Files:**
- `.gitea/workflows/terraform.yml`: a reusable workflow with one job, `apply`. It runs two guards, then `terraform init` and `terraform apply`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Trigger `on: workflow_call` | The workflow only runs when `deploy.yml` calls it, after `image` succeeded (`terraform.yml:3-4`; `deploy.yml:18-20`). A push never starts it on its own, so one push gives exactly one deploy run | `deploy.yml` job `terraform` -> job `apply` | None |
| 2 | Job `apply`, `runs-on: host` | Label `host` means no container: the steps run in a shell on the host as root, in a workdir under `/var/lib/lab/runner/work` (`terraform.yml:7-8`; `services/gitea/runner/files/config.yaml:10-11,18-19`) | runner -> steps 3-8 | Host shell |
| 3 | `env: TMPDIR: /var/lib/lab/tfstate` | Points every step's temp folder at the root-only state folder (`terraform.yml:9-10`). The workflow does not say why. The unit file says only that the folder is "Terraform's state ... and TMPDIR" (`lab-runner.service:10`). The likely reason (inferred, not stated in the code): the provider writes the cloud-init ISO under TMPDIR and keeps its path in state, and `libvirt_volume.seed` reads that path (`terraform/compute.tf:87`). `/tmp` is emptied at boot. If the ISO vanished, Terraform could plan a new one, and a new seed rebuilds every VM through the replace chain (Step 6.7). A root-only folder that survives reboots avoids both problems | job -> terraform | Temp files in `/var/lib/lab/tfstate` |
| 4 | `actions/checkout@v4`, `persist-credentials: false` | Checks out the run's commit and leaves no Gitea token in `.git/config` (`terraform.yml:12-14`) | runner -> Gitea | Job workdir |
| 5 | Step "VM firewall is loaded" | `test -f /run/lab/vmfw.loaded` (`terraform.yml:15-16`). The marker is written by `vmfw.up` after it loads the rules (`host/vmfw.py:34-35`). It lives in `/run`, which empties on reboot just as the nft rules vanish (`host/config/config.py:63`). The job fails rather than start VMs without the firewall | job -> `test` | Reads `/run/lab/vmfw.loaded` |
| 6 | Step "libvirt answers" | `virsh --connect qemu:///system list` (`terraform.yml:17-18`): fails early with a readable error if libvirtd is down | job -> `virsh` | libvirt socket |
| 7 | `terraform -chdir=terraform init -input=false -lockfile=readonly` | Downloads the providers selected in the lock file into `terraform/.terraform` and configures the local backend (`terraform.yml:19`; `terraform/provider.tf:15-17`). `-lockfile=readonly` makes a pin/lock mismatch fail instead of silently rewriting the lock | job -> registry.terraform.io | `terraform/.terraform` in the workdir |
| 8 | `terraform -chdir=terraform apply -auto-approve -input=false` | Plans and applies everything in Steps 6.2-6.8 without a prompt (`terraform.yml:20`) | job -> libvirt provider, ansible provider | libvirt objects; `/var/lib/lab/tfstate/terraform.tfstate` |

**Why here:** The job follows `image` (`deploy.yml:18-20`), so a broken Dockerfile stops the run before any VM changes. The two guards come before `init` and `apply` so that the most likely host-side failures (a reboot since the last `update`, libvirtd down) show up as one clear red step. Without them they would surface as a provider error.

**How it connects:**
- The marker comes from `vmfw.up`, `platform_up` step 6 (`main.py:37`, Step 2.6). After a host reboot the job refuses to run until `bootstrap.sh update` has run `platform_up` again.
- TMPDIR and the backend both live in `/var/lib/lab/tfstate`, which the runner unit's `StateDirectory=lab/tfstate lab/images` creates (`lab-runner.service:12-13`, Steps 4.7 and 4.10).
- The state written here is read by the ansible job: `terraform init` plus the inventory plugin (Steps 7.1-7.2). `teardown.yml` reads it for `terraform destroy` (Step 12.1).
- The same `init -lockfile=readonly` runs in `check.yml` (Step 5.5), `ansible.yml` (Step 7.1) and `teardown.yml` (Step 12.1).

**Re-run and removal:** A second run re-inits (cheap) and `apply` reports no changes unless an input changed (see "What rebuilds a VM" in Step 6.7). If the domains were shut off by a host reboot, the apply starts them again (`running = true`, Step 6.7). There is no `down()`. `bootstrap.sh teardown` dispatches `teardown.yml`, whose job `destroy` runs the same steps without the marker check and ends with `terraform destroy` (`.gitea/workflows/teardown.yml:13-24`, Step 12.1). `bootstrap.sh destroy` removes the libvirt objects by name with `virsh` and then deletes `/var/lib/lab`, state included (`host/kvm.py:33-40`, `main.py:101-105`, Step 12.2).

**Check it yourself:**
- `test -f /run/lab/vmfw.loaded && echo marker present` (no sudo: `/run/lab` is world-readable).
- In Gitea (`https://gitea.lab.test/lab/lab/actions`), the run's `terraform / apply` job ends with `Apply complete!` and a count of resources added, changed and destroyed.
- `virsh -r -c qemu:///system list --all` (a read-only connection, no sudo) lists fe-1, tun-1 and be-1 as running.

**Watch out:**
- The marker is a file, not a live check of the rules. A hand-run `nft flush ruleset` on the host removes the rules and leaves the marker in place, and the guard still passes.
- One deploy or teardown runs at a time, because both workflows use the concurrency group `lab-deploy` with `cancel-in-progress: false` (`deploy.yml:8-10`, `.gitea/workflows/teardown.yml:8-10`).

> **Marked change (not applied), C9:** Add a one-line comment to `terraform.yml:9-10` and `teardown.yml:15-16` saying why `TMPDIR` is `/var/lib/lab/tfstate` (the cloud-init seed is built under it and its path is kept in the Terraform state, Step 6.6). See Appendix C.

### Step 6.2: Pins and inputs

**Files:**
- `terraform/provider.tf`: pins Terraform and both providers, puts state on the host's disk, points libvirt at the system daemon.
- `terraform/variables.tf`: the three host-supplied inputs (base image URL, authorized keys file, lab CA file).
- Read alongside (its row is in Step 5.5): `terraform/.terraform.lock.hcl`, the provider selections and hashes that `init -lockfile=readonly` enforces.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `terraform { required_version = "= 1.17.2" }` | Refuses to run with any other Terraform CLI (`provider.tf:2`). It must equal `TERRAFORM_VERSION = "1.17.2"` (`host/config/config.py:35`), which `toolchain.ensure_terraform` installs | every `terraform` command | None |
| 2 | `required_providers.libvirt` | `dmacvicar/libvirt` exactly `0.9.9` (`provider.tf:5-8`): pool, volume, network, cloud-init disk and domain resources. The 0.9.x schema uses nested objects (`target = {...}`, `create = {...}`), which is why the `.tf` files look like that | `init` -> registry | Provider binary in `terraform/.terraform` |
| 3 | `required_providers.ansible` | `ansible/ansible` exactly `1.5.0` (`provider.tf:9-12`): supplies the `ansible_host` resource (Step 6.8) | `init` -> registry | Provider binary |
| 4 | `backend "local"` | State file at `/var/lib/lab/tfstate/terraform.tfstate` (`provider.tf:15-17`), on the host, outside the repo and the job workdir, so every job and run sees the same state | `init`, `apply`, `destroy`, the inventory plugin | `/var/lib/lab/tfstate/terraform.tfstate` |
| 5 | `provider "libvirt"` | `uri = "qemu:///system"` (`provider.tf:20-22`): the system libvirtd, the same URI as `LIBVIRT_URI` (`host/config/config.py:29`) that `kvm.up` checks | every libvirt resource | libvirt socket |
| 6 | `var.base_image_url` | Ubuntu 24.04 cloud image, `noble/release-20261017` amd64 (`variables.tf:1-5`) | `libvirt_volume.base` (`terraform/storage.tf:19`, Step 6.3) | None (read at plan) |
| 7 | `var.ssh_public_key_file` | Default `/etc/lab-runner/ssh.pub`: "the VMs' authorized SSH public keys, one per line: pipeline and operator" (`variables.tf:7-11`) | `file()` in `compute.tf:74` (Step 6.6) | Reads `/etc/lab-runner/ssh.pub` |
| 8 | `var.lab_ca_cert_file` | Default `/etc/lab-runner/ca.pem`, the lab CA the VMs trust (`variables.tf:13-17`) | `file()` in `compute.tf:75` (Step 6.6) | Reads `/etc/lab-runner/ca.pem` |

**Why here:** `init` (Step 6.1) reads the pins before anything else happens. The two files are read by `file()` while Terraform plans, so they must exist before the first plan. Bootstrap writes them in `runner.up` before it starts the runner (`services/gitea/runner/runner.py:103-111`), so no job can run without them.

**How it connects:**
- `/etc/lab-runner/ssh.pub` is written by `runner.ensure_ssh_key` on every `platform_up` (`runner.py:61-69`, Step 4.9). `/etc/lab-runner/ca.pem` is a copy of `state/pki/ca.pem` made by `runner.ensure_config` (`runner.py:48-58`, Step 4.8; the CA itself is Step 3.3).
- `TERRAFORM_VERSION` is installed by `toolchain.ensure_terraform` (Step 2.7). The lock file (Step 5.5) must list the same provider versions as items 2-3.
- The local state file is read again by the ansible job's inventory plugin (Step 7.2) and by `teardown.yml` (Step 12.1).

**Re-run and removal:** Nothing here changes on a re-run. The state file stays until `destroy` deletes `/var/lib/lab` (`main.py:103`). After a `teardown` it is still there, with no resources in it.

**Check it yourself:**
- `terraform version` prints `Terraform v1.17.2` (the binary is in `/usr/local/bin`, no sudo).
- `grep -n version terraform/provider.tf terraform/.terraform.lock.hcl` shows the same two provider versions in both files.
- `wc -l /etc/lab-runner/ssh.pub` prints 2.

**Watch out:**
- There is no `-var`, `TF_VAR_` or `.tfvars` anywhere in the repo (`git grep`), so the variable defaults act as constants.
- Two-place couplings, each edited by hand: `required_version` and `TERRAFORM_VERSION`; the provider pins and the lock file (a bump needs a local `terraform init -upgrade` and a committed lock file, because every job uses `-lockfile=readonly`); the image date in `variables.tf:4` and in the base volume name (`storage.tf:10`).
- `file()` also runs during `terraform destroy`, so even a teardown needs both files. They persist in /etc, and `platform_up` (which `cmd_teardown` runs first because "after a reboot Vault is sealed and the runner is stopped", `main.py:95`) puts them back in any case if they are missing or stale.

### Step 6.3: Storage

**Files:**
- `terraform/storage.tf`: the libvirt storage pool and the shared base image.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `libvirt_pool.lab` | Directory pool named `lab` at `/var/lib/lab/pool` (`storage.tf:1-7`). Every volume in the lab lives here. The name must equal `LAB_POOL = "lab"` (`host/config/config.py:27`) so that `destroy` can remove it without Terraform | `apply` -> libvirt | Pool definition; `/var/lib/lab/pool` |
| 2 | `libvirt_volume.base` | Downloads `var.base_image_url` into the pool as `ubuntu-24.04-20261017.qcow2`, format qcow2 (`storage.tf:9-22`). It is never booted directly. It is the read-only backing file of every VM disk | `apply` -> cloud-images.ubuntu.com; referenced by `libvirt_volume.disk` (Step 6.7) | `/var/lib/lab/pool/ubuntu-24.04-20261017.qcow2` |

**Why here:** Every later volume (seed ISOs in Step 6.6, overlays in Step 6.7) names `libvirt_pool.lab.name`, and the overlays name `libvirt_volume.base.path`. Storage depends on nothing but the provider.

**How it connects:**
- `libvirt_volume.base.path` is the `backing_store` of each overlay (`compute.tf:57-62`, Step 6.7). Because each disk has `replace_triggered_by` on the base, replacing the base replaces every disk and every VM (`compute.tf:65`, `:185`).
- `kvm.remove_lab_vms` runs `virsh pool-destroy lab` and `pool-undefine lab` by name during `destroy` (`host/kvm.py:37`, Step 12.2).

**Re-run and removal:** The image is downloaded once and reused by every later apply. `teardown` destroys the pool and the base image too, so the next build downloads it again. `destroy` undefines the pool with `virsh`, and the files go with `/var/lib/lab`.

**Check it yourself:**
- `virsh -r -c qemu:///system vol-list lab` lists the base, the three overlays and the three seed ISOs with their paths.
- `virsh -r -c qemu:///system pool-info lab` shows the pool `running`.

**Watch out:** The base volume's name hard-codes the image date (`storage.tf:10`), and the URL has the same date (`variables.tf:4`). Bumping the image means editing both, and any change to the base volume rebuilds all three VMs.

### Step 6.4: Networks

**Files:**
- `terraform/network.tf`: the three per-site VPC networks and the shared `wan`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `libvirt_network.site_a` | Network and bridge `site-a`, `autostart = true`, DNS off (`network.tf:1-12`). No `forward`, no `ips`: an isolated L2 segment with no host address and no DHCP. It is fe-1's VPC (eth0) | `apply` -> libvirt; named in `local.vms` (`compute.tf:8`) | Bridge `site-a` |
| 2 | `libvirt_network.site_hub` | The same for tun-1's VPC, bridge `site-hub` (`network.tf:14-25`) | `compute.tf:21` | Bridge `site-hub` |
| 3 | `libvirt_network.site_c` | The same for be-1's VPC, bridge `site-c` (`network.tf:27-38`) | `compute.tf:34` | Bridge `site-c` |
| 4 | `libvirt_network.wan` | Network and bridge `wan`, `forward.mode = "route"`, host address 198.51.100.1/24, DNS off, autostart (`network.tf:40-62`). It plays the internet: every VM's eth1, the WireGuard underlay, and the network the LAN's HTTPS is DNATed into. 198.51.100.0/24 is a documentation range (TEST-NET-2), so it can never collide with a real network | `apply` -> libvirt; domain eth1 (`compute.tf:156`) | Bridge `wan` with 198.51.100.1/24; a host route to 198.51.100.0/24 |

**Why here:** `local.vms` (Step 6.5) and each domain's NICs (Step 6.7) name these networks, so they must exist first. They depend only on the provider.

**How it connects:**
- Bridge name = network name, and the host firewall matches the bridge names as interfaces. `inet lab_vmfw` drops everything routed in or out of `wan` (except the LAN DNAT to fe-1:443) and anything to or from `site-*` (`host/files/nftables-vmfw.nft:147,150,152-153,156-157`, Step 2.6). `LAB_NETWORKS` (`host/config/config.py:26`) lists the same four names for `destroy`.
- The `wan` host address 198.51.100.1 is the VMs' default gateway in cloud-init (`terraform/cloud-init/network-config.yaml.tftpl:15`, Step 6.6). In practice that route serves only replies to LAN clients of fe-1:443 (`nftables-vmfw.nft:121,128,150`, Step 11.1).
- `wan` carries WireGuard between the spokes and the hub (Step 7.5). That traffic is bridged, not routed, so the `bridge lab_sg` security groups filter it (`nftables-vmfw.nft:62-101`).
- The management network is not here: `mgmtbr1` is a host bridge made from netplan (Step 2.2), and the domain attaches to it by name (`compute.tf:162`).

**Re-run and removal:** The networks are persistent and autostarted, so libvirt brings them back when it starts after a host reboot. `teardown` destroys them. `destroy` runs `virsh net-destroy` and `net-undefine` for each name in `LAB_NETWORKS` (`host/kvm.py:36`).

**Check it yourself:**
- `virsh -r -c qemu:///system net-list --all` shows `site-a`, `site-hub`, `site-c`, `wan` active with autostart yes.
- `ip -br addr show wan` shows 198.51.100.1/24. `ip -br addr show site-a` shows no IPv4 address.

**Watch out:** Route mode means the host would forward traffic from `wan` if nothing stopped it. Only `inet lab_vmfw` stops it. That is why the job checks the vmfw marker (Step 6.1) and why the domains do not autostart (Step 6.7): no VM should run while those rules are missing.

### Step 6.5: Address plan

**Files:**
- `terraform/compute.tf`: `locals.vms`, the single map every VM resource iterates over (`compute.tf:1-43`).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `locals { vms = {...} }` | A map keyed by VM name with one entry per VM (`compute.tf:1-43`). Every per-VM resource uses `for_each = local.vms`, so the key (`fe-1`, `tun-1`, `be-1`) becomes the domain name, the volume name prefix, the hostname and the Ansible host name | `for_each` in Steps 6.6-6.8 | None |
| 2 | Entry `fe-1` | Group `frontend`, 1 vCPU, 1024 MiB, 10 GiB, network `site_a`, the addresses and three MACs (`compute.tf:3-15`) | as above | None |
| 3 | Entry `tun-1` | Group `hub`, 1 vCPU, 512 MiB ("WireGuard only"), 10 GiB, network `site_hub` (`compute.tf:16-28`) | as above | None |
| 4 | Entry `be-1` | Group `backend`, 2 vCPU ("k3s minimum; the host has 4 cores"), 4096 MiB, 40 GiB, network `site_c` (`compute.tf:29-41`) | as above | None |
| 5 | Fields `vcpu`, `memory`, `disk_gb` | Sizing: the domain's `vcpu` and `memory` in MiB (`compute.tf:94-96`); the overlay's name and capacity (`:48,50-51`) | Step 6.7 | None |
| 6 | Field `network` | `libvirt_network.<site>.name` (`compute.tf:8,21,34`): the network for the VM's eth0 (`:150`) | Step 6.7 | None |
| 7 | Fields `vpc_ip`, `wan_ip`, `mgmt_ip` | The three static addresses. They are rendered into network-config (`compute.tf:78`) and exported to Ansible (`terraform/inventory.tf:6,8-9`) | Steps 6.6, 6.8 | None |
| 8 | Fields `vpc_mac`, `wan_mac`, `mgmt_mac` | Fixed MACs: on the domain NICs (`compute.tf:149,155,161`) and matched by cloud-init to name the cards eth0/eth1/eth2 (`network-config.yaml.tftpl:5,10,18`). The pattern is 52:54:00 (the QEMU prefix), then `0<site>:00:10` for vpc, `fb:0<site>:10` for wan and `fa:0<site>:10` for mgmt | Steps 6.6, 6.7 | None |
| 9 | Field `group` | `frontend`, `hub` or `backend`: the Ansible group (`inventory.tf:4`) | Step 6.8 | None |

**The VM table** (all values from `compute.tf:3-41`; taps from `:151,157,163`):

| VM | Group | vCPU / RAM / disk | VPC network, vpc_ip (eth0) | wan_ip (eth1, bridge `wan`) | mgmt_ip (eth2, bridge `mgmtbr1`) | MACs vpc / wan / mgmt | Taps |
|---|---|---|---|---|---|---|---|
| fe-1 | frontend | 1 / 1024 MiB / 10 GiB (`fe-1-10g.qcow2`) | `site-a`, 10.1.1.10/24 | 198.51.100.11/24 | 10.250.0.110/24 | 52:54:00:01:00:10 / 52:54:00:fb:01:10 / 52:54:00:fa:01:10 | `fe-1-vpc`, `fe-1-wan`, `fe-1-mgmt` |
| tun-1 | hub | 1 / 512 MiB / 10 GiB (`tun-1-10g.qcow2`) | `site-hub`, 10.2.1.10/24 | 198.51.100.12/24 | 10.250.0.111/24 | 52:54:00:02:00:10 / 52:54:00:fb:02:10 / 52:54:00:fa:02:10 | `tun-1-vpc`, `tun-1-wan`, `tun-1-mgmt` |
| be-1 | backend | 2 / 4096 MiB / 40 GiB (`be-1-40g.qcow2`) | `site-c`, 10.3.1.10/24 | 198.51.100.13/24 | 10.250.0.112/24 | 52:54:00:03:00:10 / 52:54:00:fb:03:10 / 52:54:00:fa:03:10 | `be-1-vpc`, `be-1-wan`, `be-1-mgmt` |

Total: 4 vCPU and 5.5 GiB of RAM, on a target host of 4 cores and 16 GB (`README.md:23`). What each network is for:
- **VPC (eth0, 10.<site>.1.10):** each VM's own address on a segment no other VM is on. Another site's VPC address is reachable only through WireGuard (Step 7.5). On be-1 it is also the k3s node IP (`ansible/roles/k3s/tasks/main.yml:13`, Step 8.1).
- **wan (eth1, 198.51.100.x):** the underlay. It carries WireGuard between the spokes and the hub, and the LAN's HTTPS DNATed to fe-1. Each VM's default route points here, but the host forwards nothing from it except fe-1's replies to LAN clients of its HTTPS port (`nftables-vmfw.nft:149-153`).
- **mgmt (eth2, 10.250.0.11x):** host <-> VM only. It carries the host's SSH and Ansible, the VMs' DNS, NTP and Squid on 10.250.0.1, and Traefik for Flux and Alloy. lab_sg drops every mgmt frame from one VM to another (`nftables-vmfw.nft:69`).
- **Tunnels (10.99.0.0/24 and 10.99.1.0/24):** not in Terraform. They come from `ansible/host_vars` (Step 7.5).

**Why here:** The map references the network resources by name (`compute.tf:8,21,34`), so it reads after Step 6.4. Everything after it (seed, disk, domain, inventory) iterates over it.

**How it connects:**
- `network` and the MACs go to the domain (Step 6.7). The addresses and MACs go to network-config (Step 6.6). `group`, `mgmt_ip`, `vpc_ip` and `wan_ip` go to `ansible_host` (Step 6.8).
- The same values are copied by hand into other files (see Watch out). The host firewall, the SSH aliases, Squid, CoreDNS, Traefik, the hub filter, the frontend and a NetworkPolicy all repeat them.

**Re-run and removal:** A local has no state of its own. Changing an address or MAC changes that VM's network-config and so rebuilds the VM (Step 6.7). Changing `vcpu` or `memory` touches only the domain.

**Check it yourself:**
- `ssh fe-1 ip -br addr` shows eth0 10.1.1.10/24, eth1 198.51.100.11/24 and eth2 10.250.0.110/24 (no `wg0` until Step 7.5).
- `ip -br link show master mgmtbr1` (on the host, no sudo) lists `mgmtbr1-anchor` (the bridge's always-up dummy port) plus `fe-1-mgmt`, `tun-1-mgmt`, `be-1-mgmt`.

**Watch out:** No code checks the copies of these values in other files (the host firewall, the SSH aliases, Squid, CoreDNS, Traefik's allowlists, `reattach_taps`, `LAB_DOMAINS`, the hub filter, the frontend, a NetworkPolicy, `demo/load.sh` and the WireGuard `allowed_ips`). R1 lists every copy with its line, in the rows "VM names", "Tap names", "VM mgmt IPs", "VM wan IPs" and "VPC IPs". Change them together.

### Step 6.6: First-boot seed

**Files:**
- `terraform/compute.tf`: `libvirt_cloudinit_disk.seed` and `libvirt_volume.seed` (`:69-88`).
- `terraform/cloud-init/user-data.yaml.tftpl`: first-boot account, SSH keys and CA trust.
- `terraform/cloud-init/network-config.yaml.tftpl`: static addressing of eth0/eth1/eth2, matched by MAC.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `libvirt_cloudinit_disk.seed` | One NoCloud seed per VM named `<vm>-seed` (`compute.tf:70-79`). `user_data` renders the user-data template with `ssh_public_keys = split("\n", trimspace(file(var.ssh_public_key_file)))` and `lab_ca_cert = file(var.lab_ca_cert_file)` (`:73-76`). `meta_data` is `instance-id` = `local-hostname` = VM name (`:77`). `network_config` renders the network template with the VM's whole map entry (`:78`) | `apply`; read by `libvirt_volume.seed` | Reads `ssh.pub` and `ca.pem`; builds the ISO locally (under TMPDIR, see Step 6.1) |
| 2 | user-data `users` | One user `user`: group `sudo`, `/bin/bash`, `sudo: "ALL=(ALL) NOPASSWD: ALL"`, `lock_passwd: true` (no password at all), and one `ssh_authorized_keys` line per key in `ssh.pub` (`user-data.yaml.tftpl:2-11`) | cloud-init on first boot | `/home/user/.ssh/authorized_keys`, sudoers |
| 3 | user-data SSH hardening | `ssh_pwauth: false` (no password logins), `disable_root: true` (`user-data.yaml.tftpl:13-14`) | cloud-init | sshd config |
| 4 | user-data `ca_certs.trusted` | Adds the lab CA to the VM's system trust store (`user-data.yaml.tftpl:16-19`). `indent(10, ...)` keeps every PEM line inside the YAML block scalar | cloud-init | System CA bundle |
| 5 | network-config eth0 | `match.macaddress: vpc_mac`, `set-name: eth0`, `vpc_ip/24`, no gateway (`network-config.yaml.tftpl:3-7`) | cloud-init -> netplan | VM netplan |
| 6 | network-config eth1 | `wan_mac` -> `eth1`, `wan_ip/24`, default route via 198.51.100.1 (`network-config.yaml.tftpl:8-15`) | cloud-init -> netplan | VM netplan |
| 7 | network-config eth2 | `mgmt_mac` -> `eth2`, `mgmt_ip/24`, nameserver 10.250.0.1 (`network-config.yaml.tftpl:16-22`). There is no DHCP on any lab network, so these static addresses are the only ones | cloud-init -> netplan | VM netplan, resolver |
| 8 | `libvirt_volume.seed` | Copies the ISO into pool `lab` as `<vm>-seed.iso`, format `iso` (`compute.tf:82-88`), taking its content from `libvirt_cloudinit_disk.seed[each.key].path` (`:87`). The domain then attaches it by file path from the pool (Step 6.7) | `apply`; referenced by `libvirt_volume.disk` (lifecycle) and the domain cdrom | `/var/lib/lab/pool/<vm>-seed.iso` |

**Why here:** The seed needs the inputs (Step 6.2), the pool (Step 6.3) and the address plan (Step 6.5). The disk's `replace_triggered_by` and the domain's cdrom both reference the seed volume, so Step 6.7 comes after it.

**How it connects:**
- `ssh_authorized_keys` holds the pipeline key, whose private half reaches Ansible through Vault and ssh-agent (Step 7.1), and the operator key behind `ssh fe-1` (`host/files/60-lab-ssh.conf:6-12`, Step 4.6).
- User `user` = `ansible_user` (`terraform/inventory.tf:7`, Step 6.8) = `User user` in the SSH aliases (`60-lab-ssh.conf:7`). Passwordless sudo is what makes `become: true` work in plays 2-5 (`ansible/site.yml:15,21,27,33`; play 1 runs on localhost without become) (Step 7.2).
- The CA trust lets VM Alloy push to `https://prometheus.lab.test` and `https://loki.lab.test` with no TLS settings (`ansible/roles/alloy/templates/config.alloy.j2:2,30,64`, Step 10.1).
- The eth2 nameserver 10.250.0.1 is CoreDNS (Step 3.1). It gives the VMs `proxy.lab.test` for apt (Step 7.4) and the `lab.test` names for Flux and Alloy (Steps 8.2, 10.1).
- The eth1 default route via 198.51.100.1 carries fe-1's replies to LAN clients that the host DNATed to it (`nftables-vmfw.nft:121,150`). Anything else a VM sends to it is dropped by `inet lab_vmfw` (`:152-153`).

**Re-run and removal:** Terraform renders the seed on every plan. If the rendered output is the same, nothing changes. If it differs, the seed is rebuilt and the VM is rebuilt with it (Step 6.7). cloud-init itself runs once per `instance-id`, so a new seed on the old disk would be ignored, and that is why the disk is replaced too. `teardown`/`destroy` remove the seed volumes with the pool.

**Check it yourself:**
- `ssh fe-1 cloud-init status` prints `status: done`. `ssh fe-1 hostname` prints `fe-1`.
- `ssh fe-1 ip route` shows `default via 198.51.100.1 dev eth1`. `ssh fe-1 resolvectl dns eth2` shows 10.250.0.1.
- `ssh fe-1 sudo -n true && echo sudo ok` (sudo on the VM, passwordless; nothing on the host).

**Watch out:**
- Anyone holding either private key is root on all three VMs (keys plus `NOPASSWD: ALL`). The pipeline key is in Vault (`kv/data/lab/pipeline/ssh`). The operator key is in the home of whoever ran `sudo ./bootstrap.sh` (`host/ssh_access.py:18-21`).
- The operator key depends on `SUDO_UID`. Running bootstrap as a different sudo user creates a different key, a different `ssh.pub`, and so a rebuild of every VM.
- No one can log in on the serial console: the only user has no password and root is disabled. The console is useful only to watch boot and cloud-init output.
- The network template receives the whole map entry (`compute.tf:78`) but uses only the six address and MAC fields. Matching by MAC plus `set-name` makes the eth0/eth1/eth2 names independent of PCI order.

### Step 6.7: Disks and domains

**Files:**
- `terraform/compute.tf`: `libvirt_volume.disk` (`:45-67`) and `libvirt_domain.vm` (`:90-187`).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `libvirt_volume.disk` | Each VM's own disk: a qcow2 overlay named `<vm>-<disk_gb>g.qcow2` with capacity `disk_gb` and `capacity_unit = "GiB"` (`compute.tf:50-51`), backed by the base volume (`compute.tf:46-63`). Thin: it stores only what the VM changes | `apply`; referenced by the domain's vda | `/var/lib/lab/pool/<vm>-<gb>g.qcow2` |
| 2 | Disk `lifecycle.replace_triggered_by` | `[libvirt_volume.base, libvirt_volume.seed[each.key]]` (`compute.tf:64-66`): a new base image or a new seed gives a fresh, empty overlay, so cloud-init runs again on first boot | Terraform planner | None |
| 3 | `libvirt_domain.vm`: identity and size | `name` = VM name, `type = "kvm"`, `vcpu`, `memory` in MiB (`compute.tf:90-96`) | `apply` -> libvirt | Domain definition |
| 4 | `running = true`, `autostart = false` | Terraform keeps the domain started (`compute.tf:97`). libvirt never starts it at host boot (`:98`): the vmfw rules vanish on reboot, and no VM may run before they are reloaded | Terraform; libvirt at boot | Domain state, autostart flag |
| 5 | CPU and machine | `cpu.mode = "host-passthrough"`: the guest sees the host CPU model and all its features (`compute.tf:100-102`). `os`: `hvm`, `x86_64`, machine `q35`, boot from `hd` (`:104-113`) | libvirt | None |
| 6 | Disks | vda = the overlay, virtio, qcow2. sda = the seed ISO as a SATA cdrom (q35 has no IDE bus) (`compute.tf:117-145`). Both are given as file paths, not pool volume references, because "libvirt's AppArmor helper only allows disks it sees as files" (`:116`) | libvirt | Opens the overlay and the ISO |
| 7 | NIC eth0 (vpc) | virtio, `mac = vpc_mac`, `source.network = <site>`, tap `<vm>-vpc` (`compute.tf:147-152`) | libvirt | Tap on bridge `site-a`/`site-hub`/`site-c` |
| 8 | NIC eth1 (wan) | virtio, `mac = wan_mac`, `source.network = wan`, tap `<vm>-wan` (`compute.tf:153-158`) | libvirt | Tap on bridge `wan` |
| 9 | NIC eth2 (mgmt) | virtio, `mac = mgmt_mac`, `source.bridge = "mgmtbr1"` (a host bridge, not a libvirt network), tap `<vm>-mgmt` (`compute.tf:159-164`) | libvirt | Tap on `mgmtbr1` |
| 10 | Serial and console | One serial port and a serial console on port 0 (`compute.tf:166-180`), so `virsh console <vm>` shows the boot output | libvirt | PTY |
| 11 | Domain `lifecycle.replace_triggered_by` | `[libvirt_volume.disk[each.key]]` (`compute.tf:183-186`). The comment explains why: "A new overlay means a new VM (the overlay keeps its name, so nothing else would tell Terraform)" | Terraform planner | None |

**What rebuilds a VM (the `replace_triggered_by` chain):** inputs -> `libvirt_cloudinit_disk.seed[vm]` -> `libvirt_volume.seed[vm]` (its content is the ISO, `compute.tf:87`) -> `libvirt_volume.disk[vm]` (`:65`) -> `libvirt_domain.vm[vm]` (`:185`). A rebuild means an empty overlay and a first boot from scratch. These changes trigger it:
1. **`/etc/lab-runner/ssh.pub` changes: all three VMs.** This happens when the operator key is recreated (deleted `~/.ssh/lab_operator`, `host/ssh_access.py:32-43`), when bootstrap is run by a different sudo user (`:18-21`), or when the pipeline key in Vault is regenerated, which `vault.ssh_key` does only if `kv/data/lab/pipeline/ssh` is missing (`services/vault/vault.py:97-113`).
2. **`/etc/lab-runner/ca.pem` changes: all three.** A new lab CA is made only when `state/pki/ca.pem` is missing (`lib/pki.py:23-32`). `ensure_config` copies it (Step 4.8).
3. **Either cloud-init template changes its rendered output: all three.** Even a whitespace edit in user-data counts.
4. **A VM's `vpc_ip`, `wan_ip`, `mgmt_ip` or a MAC changes: that VM only** (its network-config differs).
5. **The base volume changes (its name or URL, `storage.tf:10,19`): all three**, through the disks' trigger on `libvirt_volume.base`.
6. **`disk_gb` changes: that VM.** The overlay's name and capacity change.
7. **A VM key is renamed: a new VM under the new name**, and the old one is destroyed. Every resource is keyed by the name.

What does not rebuild: `vcpu` or `memory` (domain attributes only, so the overlay and its data stay), `group` (only the inventory row changes), and anything under `ansible/`.

What a rebuild costs: new SSH host keys (which is why `ansible/ansible.cfg:3,10` and `60-lab-ssh.conf:10-11` skip host-key checks). A new WireGuard private key, after which the peers restart their tunnels (Step 7.5). On be-1, a new k3s cluster, Flux and an empty CNPG database (Phase 8). On fe-1, the image is loaded again (Step 9.1).

**Why here:** The domain is the last libvirt object and references everything before it: networks (Step 6.4), the seed volume (Step 6.6) and the overlay. Two host prerequisites must hold at define/start time. `mgmtbr1` must exist (Step 2.2), or the domain cannot attach eth2. The vmfw rules must be loaded (Step 2.6, guarded in Step 6.1), because the VM starts sending as soon as it boots.

**How it connects:**
- The tap names are a contract with the host. The `bridge lab_sg` sets (`sg_frontend`, `sg_hub`, `sg_backend`, `mgmt_taps`, `lab_taps`, and `lab_addrs` pairing each tap with its address: `nftables-vmfw.nft:15-41`, Step 2.6) and `network.reattach_taps` (`host/network.py:38-44`, Step 2.2) both use them. The `<vm>-vpc` taps are in no set: each site bridge holds one VM, so there is nothing to filter between VMs there.
- eth2 on `mgmtbr1` reaches the host services on 10.250.0.1 (Phase 3) and carries the pipeline's SSH (Step 7.3).
- eth1 on `wan` carries WireGuard (Step 7.5). eth0's `vpc_ip` is the source address the spokes pin on traffic sent through the tunnel (the `src` of the tunnel routes, Step 7.5), and it is be-1's k3s node IP (Step 8.1).
- `autostart = false` plus the `/run` marker is the reboot story: after a host reboot the domains stay off until `update` reloads vmfw and this apply starts them (Step 12.3).

**Re-run and removal:** A second apply changes nothing. After a host reboot the domains are shut off. `bootstrap.sh update` runs `platform_up` (vmfw at step 6, `main.py:37`), then the pipeline, and this apply's `running = true` starts them. `teardown` destroys domains and overlays. `destroy` runs `virsh destroy` and `undefine` for each name in `LAB_DOMAINS` (`host/kvm.py:35`), then deletes `/var/lib/lab`.

**Check it yourself:**
- `virsh -r -c qemu:///system list --all` shows the three domains running. `virsh -r -c qemu:///system dominfo fe-1` shows `Autostart: disable`.
- `virsh -r -c qemu:///system domiflist be-1` lists `be-1-vpc` on `site-c`, `be-1-wan` on `wan` and `be-1-mgmt` on `mgmtbr1`, with the MACs from Step 6.5.

**Watch out:**
- The comment at `compute.tf:98` says no VM boots "before `bootstrap up` reloads them". After the first run, `up` returns at once ("already initialized; use update", `main.py:70-72`). The command that reloads vmfw and restarts the VMs is `update` (or `teardown`, which then removes them).
- `netplan apply` on the host rebuilds `mgmtbr1` without the running VMs' mgmt taps. `network.up` reattaches them on every run (`host/network.py:66,71`). A hand-run `netplan apply` leaves them detached until the next `update`.
- A rebuild is silent: the apply log shows "replace" lines and nothing else warns that be-1's database is gone.

> **Marked change (not applied), C9:** The `autostart` comment (`terraform/compute.tf:98`) says `bootstrap up`. On an initialized lab `up` returns early; the command that reloads the rules after a reboot is `update` (Step 12.3). See Appendix C.

### Step 6.8: Handoff to Ansible

**Files:**
- `terraform/inventory.tf`: one `ansible_host` resource per VM, the inventory rows in state.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `ansible_host.vm` | `for_each = local.vms` (`inventory.tf:1-2`). `name` = VM name (`:3`), `groups = [group]` (`:4`), and `variables`: `ansible_host = mgmt_ip` (`:6`, so Ansible connects over mgmtbr1), `ansible_user = "user"` (`:7`), `vpc_ip` (`:8`), `wan_ip` (`:9`). It creates nothing in libvirt. It is a row in state for the `cloud.terraform` inventory plugin | `apply` (ansible provider); read by the plugin (Step 7.2) | Rows in `terraform.tfstate` |

**Why here:** It depends only on `local.vms`, so Terraform may create it in parallel with the domains. It is last in the walk because it is the output of the phase: the only thing Ansible learns from Terraform. If any libvirt resource fails, the apply fails, the job is red, and the ansible job never starts (`needs: terraform`, `deploy.yml:22`).

**How it connects:**
- Groups `frontend`, `hub`, `backend` match play 1's assert loop (`ansible/site.yml:9`) and the `hosts:` of plays 3 and 4 (`:18` backend, `:24` frontend). Plays 2 and 5 use `hosts: all` (`:12,30`). `hub` is in no `hosts:` line: only `:9` and the wireguard role's `'hub' in group_names` (`ansible/roles/wireguard/tasks/main.yml:33,47,58,66`) name it (Steps 7.2, 7.5).
- `ansible_host` (mgmt IP) plus `ansible_user` is where `wait_for_connection` and every task connect (Step 7.3).
- `vpc_ip` feeds the spoke routes' `src` (`ansible/roles/wireguard/templates/wg.conf.j2:10`, Step 7.5) and the k3s `node-ip` (`ansible/roles/k3s/tasks/main.yml:13`, Step 8.1). `wan_ip` feeds the WireGuard `Endpoint` (`wg.conf.j2:18`, Step 7.5).

**Re-run and removal:** No change on a re-run. `teardown` removes the rows with everything else. An empty state then fails play 1 in the next ansible job, unless the terraform job rebuilt it first, which it does in every deploy run.

**Check it yourself:**
- (sudo) `sudo jq -c '.resources[] | select(.type=="ansible_host") | .instances[].attributes | {name, groups, variables}' /var/lib/lab/tfstate/terraform.tfstate` prints the three rows. The state folder is root-only (0700).
- Without sudo: the ansible job log in Gitea shows `ok:` lines for fe-1, tun-1 and be-1, which come only from these rows.

**Watch out:** `"user"` here is a third hand copy of the account name (`user-data.yaml.tftpl:3`, `60-lab-ssh.conf:7`). The group strings are a contract with `site.yml` and the wireguard role. Rename one and play 1 fails, or worse, the hub tasks silently skip.

## Phase 7: Ansible VM base

Phase 7 turns three bare VMs into a connected, minimal base. It waits for first boot to finish, points each VM's clock at the host and its apt at Squid, and installs nftables and wireguard-tools. Then it builds the WireGuard hub-and-spoke (fe-1 <-> tun-1 <-> be-1), with a filter on tun-1 that forwards exactly one flow. It runs as the fourth and last job of every deploy run. `deploy.yml` job `ansible` (`needs: terraform`, `secrets: inherit`, `.gitea/workflows/deploy.yml:21-24`) calls `ansible.yml` job `configure`. That job reads five secrets from Vault, loads the SSH key into an agent, initializes Terraform so the inventory can read the state, and runs `ansible-playbook site.yml`. This phase covers the job and plays 1-2. Plays 3-5 continue in the same playbook run (Phases 8-10). After play 2 every VM has the same base and both tunnels are up. fe-1 can already send TCP to 10.3.1.10:8000 through tun-1, but nothing listens there until k3s brings up Traefik (Step 8.1).

**Needs from earlier phases:**
- The running VMs and the Terraform state with three `ansible_host` rows (Steps 6.1-6.8). cloud-init's user, keys, CA and network (Step 6.6).
- Gitea Actions secrets `VAULT_ROLE_ID`/`VAULT_SECRET_ID` (Step 4.4), handed to this job by `secrets: inherit` (Step 5.4).
- Vault unsealed, with AppRole and policy `lab-pipeline` (Step 3.6). The KV entries `kv/data/lab/pipeline/ssh`, `app-db` and `app-edge` (Step 3.7) and `gitea-flux` (Step 4.4).
- Vault reachable as `https://vault.lab.test:8200`. It is published on 10.250.0.1:8200 (`services/vault/compose.yaml:10`). Its certificate has the SAN `vault.lab.test` (`lib/config.py:36`, Step 3.3). The host resolves the name through mgmtbr1's `~lab.test` DNS route (`host/files/60-lab-mgmtbr1.yaml:11-13`, Step 2.2) to CoreDNS (`services/coredns/conf/Corefile:5`, Step 3.1).
- `/etc/lab-runner/ca.pem` (Step 4.8).
- On the host: `node` for the JavaScript actions, `ansible-core`, the `cloud.terraform` 4.0.0 collection and `terraform` (Step 2.7).
- Host chrony serving 10.250.0.0/24 on 10.250.0.1 (Step 2.3), CoreDNS `proxy.lab.test` (Step 3.1) and Squid allowing the VMs to reach the Ubuntu archive (Step 3.2).
- vmfw: on `mgmtbr1`, input for udp 53/123, tcp 53/3128 and replies to the host's own connections (`host/files/nftables-vmfw.nft:174-176`). In `lab_sg`, `sg_hub_in` for udp 51820 from fe-1 and udp 51821 from be-1 (`:98-101`) (Step 2.6).
- Host internet: github.com for `actions/checkout`, `hashicorp/vault-action` and `webfactory/ssh-agent`; registry.terraform.io for `terraform init`.

**Hands on:**
- For plays 3-5 in the same run: an ssh-agent holding the pipeline key; env `FLUX_GIT_TOKEN` (Step 8.2), `APP_DB_AUTHENTICATOR_PASSWORD` (Step 8.5), `APP_EDGE_CERT` and `APP_EDGE_KEY` (Step 9.1), and the runner's `GITHUB_SHA` (Steps 8.7, 9.1). Host vars `vpc_ip` and `wan_ip`; group var `proxy_url` (Steps 8.1-8.2).
- On every VM: `/etc/systemd/timesyncd.conf.d/lab.conf` (NTP 10.250.0.1), `/etc/apt/apt.conf.d/90lab-proxy` (`http://proxy.lab.test:3128`), packages `nftables` and `wireguard-tools`, `/etc/wireguard/private.key` (0600), `/etc/wireguard/wg<N>.conf` (0600), and `wg-quick@wg<N>` enabled and running.
- Tunnels: wg0 between fe-1 10.99.0.2 and tun-1 10.99.0.1 (udp 51820), and wg1 between be-1 10.99.1.2 and tun-1 10.99.1.1 (udp 51821).
- Spoke routes to the other sites' VPCs through the tunnel, with source = the spoke's own `vpc_ip`.
- On tun-1: `/etc/modules-load.d/lab-conntrack.conf`, `/etc/sysctl.d/90-lab-forward.conf` (forwarding on, conntrack 65536 entries, TIME_WAIT 30 s), `/etc/nftables.conf` (table `inet lab_hub`) and `nftables.service` enabled.
- The one forwarded flow: 10.1.1.10 -> 10.3.1.10 tcp 8000. fe-1's frontend uses it (Step 9.1) once be-1 serves :8000 (Step 8.1).

### Step 7.1: Job: secrets, agent, playbook

**Files:**
- `.gitea/workflows/ansible.yml`: the reusable workflow with one job, `configure`. It reads the secrets, starts the agent, runs `terraform init`, then the playbook.
- Read alongside (built in Step 3.6): `services/vault/policies/lab-pipeline.hcl`, the policy that limits what this job's Vault token can touch.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Trigger `on: workflow_call` | Runs only when `deploy.yml` calls it, after `terraform` succeeded (`ansible.yml:3-4`; `deploy.yml:21-24`). `secrets: inherit` (`deploy.yml:24`) makes it the only job that sees `VAULT_ROLE_ID`/`VAULT_SECRET_ID` | `deploy.yml` job `ansible` -> job `configure` | None |
| 2 | Job `configure`, `runs-on: host` | Runs on the host as root, like Step 6.1 (`ansible.yml:7-8`) | runner -> steps 3-9 | Host shell |
| 3 | `env: NODE_EXTRA_CA_CERTS: /etc/lab-runner/ca.pem` | Makes Node trust the lab CA for every JavaScript action in the job (`ansible.yml:9-10`). vault-action talks HTTPS to `vault.lab.test`, whose certificate the lab CA signed | job -> Node actions | Reads `/etc/lab-runner/ca.pem` |
| 4 | `actions/checkout@v4`, `persist-credentials: false` | Checks out the commit: `ansible/` and `terraform/` (`ansible.yml:12-14`) | runner -> Gitea | Job workdir |
| 5 | Step `vault`: `hashicorp/vault-action@v4` | Logs in to `https://vault.lab.test:8200` with `method: approle`, using the inherited role and secret IDs (`ansible.yml:16-23`). `exportEnv: false` (`:24`): the values become step outputs only, not job-wide env. Reads five KV v2 values (`:25-30`): `ssh private_key` -> `SSH_PRIVATE_KEY`, `gitea-flux token` -> `FLUX_GIT_TOKEN`, `app-db authenticator_password` -> `APP_DB_AUTHENTICATOR_PASSWORD`, `app-edge cert` -> `APP_EDGE_CERT`, `app-edge key` -> `APP_EDGE_KEY`, all under `kv/data/lab/pipeline/` | job -> Vault API (AppRole login, KV reads) | Reads Vault; step outputs in the runner |
| 6 | Policy `lab-pipeline` (Step 3.6) | `path "kv/data/lab/pipeline/*"` with `create`, `read`, `update` (`lab-pipeline.hcl:6-8`). Anything else is denied, including `sys/*` and `auth/*` (`:1-3`). The login token lives 1 h (`token_ttl`, `services/vault/vault.py:176`) | Vault, on each read in item 5 | None |
| 7 | Step "Load the key into ssh-agent": `webfactory/ssh-agent@v0.10.0` | Starts an ssh-agent with `SSH_PRIVATE_KEY` from item 5 and points later steps at it (`ansible.yml:32-35`). The private key never lands in the repo or in Ansible's files | job -> ssh-agent | Agent socket for the job |
| 8 | Step "Terraform init (the inventory reads state)" | `terraform -chdir=terraform init -input=false -lockfile=readonly` (`ansible.yml:37-38`). It configures the local backend so the inventory plugin can run Terraform against `/var/lib/lab/tfstate/terraform.tfstate` | job -> registry.terraform.io | `terraform/.terraform` in the workdir |
| 9 | Step "Run the playbook" | `ansible-playbook site.yml` with `working-directory: ansible` (`ansible.yml:40-47`), so `ansible/ansible.cfg` is the config Ansible picks up. Env (`:42-46`): `FLUX_GIT_TOKEN`, `APP_DB_AUTHENTICATOR_PASSWORD`, `APP_EDGE_CERT`, `APP_EDGE_KEY` from item 5. The runner adds `GITHUB_SHA` | job -> Ansible (Step 7.2) | SSH to the VMs |

**Why here:** Nothing in the playbook can reach a VM without the key, so the Vault read and the agent come first. `terraform init` must come before `ansible-playbook`, because the inventory is built from state at start-up (Step 7.2). The job itself waits for the terraform job (`needs: terraform`), which wrote that state.

**How it connects:**
- `VAULT_ROLE_ID`/`VAULT_SECRET_ID` are written by `gitea.pipeline_secrets` from `vault.approle_credentials(token, "lab-pipeline")` (`services/gitea/gitea.py:119-135`, Step 4.4). The AppRole's policy has the same name as the file (`vault.py:173-180`).
- `ssh private_key` is made once by `vault.ssh_key` (`vault.py:97-113`, Step 3.7). Its public half goes through `/etc/lab-runner/ssh.pub` (Step 4.9) into cloud-init (Step 6.6).
- `gitea-flux token` (Step 4.4) feeds the `flux-git-auth` Secret (Step 8.2). `app-db authenticator_password` (`vault.app_db_passwords`, Step 3.7) feeds the `db-authenticator` Secret (Step 8.5). `app-edge cert`/`key` (`vault.app_edge_cert` from `state/pki/app-edge*.pem`, Steps 3.3 and 3.7) go to `/etc/frontend/tls` on fe-1 (Step 9.1).
- `GITHUB_SHA` binds this run to the image tag built in Step 5.6. It is read by `frontend_tag` (Step 9.1) and by the `app_deployed` revision wait (Step 8.7).

**Re-run and removal:** Every run reads the secrets fresh and starts a new agent. Nothing persists after the job except `terraform/.terraform` in the runner workdir. There is no removal: the secrets stay in Vault until `destroy` removes Vault (Step 12.2).

**Check it yourself:**
- In Gitea, the run's `ansible / configure` job shows the steps in this order and ends with a `PLAY RECAP` where localhost, fe-1, tun-1 and be-1 all have `failed=0`.
- `ssh fe-1 true && echo ok`: the operator key works, so cloud-init installed `ssh.pub`. The pipeline key is proven by the job's `ok:` lines.

**Watch out:**
- The step name "Read the lab SSH key and flux token from Vault" (`ansible.yml:16`) understates it: it reads five values.
- The four env names in `ansible.yml:43-46` must equal the `lookup('env', ...)` names in the roles (`fluxcd/templates/flux-git-auth.yaml.j2:9`, `app_secrets/templates/db-authenticator.yaml.j2:9`, `frontend/tasks/main.yml:32,41`). They are copied by hand, and a typo renders an empty value instead of failing.
- `lab-pipeline` grants more than this job uses (Step 3.6, Watch out): the job only reads. The WireGuard public keys that the policy comment expects in Vault (`lab-pipeline.hcl:5`) travel through `hostvars` instead (Step 7.5).

### Step 7.2: Config, inventory, plays, variables, play 1

**Files:**
- `ansible/ansible.cfg`: the playbook's settings (inventory source, SSH options, inventory strictness).
- `ansible/inventory.yml`: tells Ansible to build the inventory from Terraform state.
- `ansible/site.yml`: the five plays, in order.
- `ansible/group_vars/all.yml`: lab-wide values for every VM (proxy, NTP server, base packages).
- `ansible/host_vars/fe-1.yml`: fe-1's WireGuard interface (spoke wg0).
- `ansible/host_vars/tun-1.yml`: tun-1's two WireGuard interfaces (hub wg0 and wg1).
- `ansible/host_vars/be-1.yml`: be-1's WireGuard interface (spoke wg1).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `[defaults] inventory = inventory.yml` | The inventory source, relative to `ansible.cfg` (`ansible.cfg:2`) | `ansible-playbook` at start | Reads `inventory.yml` |
| 2 | `host_key_checking = False` with `UserKnownHostsFile=/dev/null` | No host-key prompt or check, and no known_hosts file kept (`ansible.cfg:3,10`). Rebuilt VMs get new host keys (Step 6.7). The mgmt network is a host-only bridge | Ansible SSH | None |
| 3 | `interpreter_python = auto_silent` | Finds `python3` on the VMs without a warning (`ansible.cfg:4`) | Ansible module runs | None |
| 4 | `[inventory] unparsed_is_failed = True` | An inventory source that fails to parse (no `terraform init`, plugin error) is a hard error, not a warning followed by a localhost-only run (`ansible.cfg:6-7`) | inventory loading | None |
| 5 | `[ssh_connection] ssh_args` | `-C -o ControlMaster=auto -o ControlPersist=60s -o UserKnownHostsFile=/dev/null` (`ansible.cfg:9-10`): compression, and one SSH connection reused across tasks for 60 s | Ansible SSH | Control sockets in root's home |
| 6 | `inventory.yml`: `plugin: cloud.terraform.terraform_provider` | Runs `terraform show` in `project_path: ../terraform` to read the state, and turns each `ansible_host` resource into a host with its groups and variables (`inventory.yml:2-3`). The plugin passes the relative path to Terraform unchanged, so it resolves against the process's working directory, `ansible/` (set by `working-directory` in `ansible.yml:41`). The collection is version 4.0.0 in `/usr/share/ansible/collections` (`host/config/config.py:42-43`; `host/toolchain.py:66-85`) | inventory loading -> `terraform` | Reads `/var/lib/lab/tfstate/terraform.tfstate` (needs Step 7.1 item 8) |
| 7 | `group_vars/all.yml`: `proxy_url` | `http://proxy.lab.test:3128` (`all.yml:3`) | `common` (Step 7.4), `k3s` and `fluxcd` (Steps 8.1-8.2) | None |
| 8 | `group_vars/all.yml`: `ntp_server` | `10.250.0.1`, the host's chrony on mgmtbr1 (`all.yml:4`) | `common` (Step 7.4) | None |
| 9 | `group_vars/all.yml`: `common_packages` | `[nftables, wireguard-tools]` (`all.yml:5`) | `common` (Step 7.4) | None |
| 10 | `host_vars/fe-1.yml`: `wg_interfaces` | One spoke interface `wg0`: address 10.99.0.2/24, peer `tun-1`, `endpoint_port: 51820`, `allowed_ips` 10.99.0.1/32 (hub tunnel IP), 10.2.0.0/16 (hub VPC), 10.3.0.0/16 (backend VPC through the hub) (`fe-1.yml:2-10`) | `wireguard` (Step 7.5) | None |
| 11 | `host_vars/tun-1.yml`: `wg_interfaces` | Two hub interfaces. `wg0`: 10.99.0.1/24, `listen_port: 51820`, peer `fe-1`, `allowed_ips` 10.99.0.2/32 and 10.1.0.0/16 (`tun-1.yml:3-9`). `wg1`: 10.99.1.1/24, `listen_port: 51821`, peer `be-1`, `allowed_ips` 10.99.1.2/32 and 10.3.0.0/16 (`:11-17`). No endpoint: the hub learns each spoke's endpoint from incoming traffic (`:1`) | `wireguard` (Step 7.5) | None |
| 12 | `host_vars/be-1.yml`: `wg_interfaces` | One spoke interface `wg1`: 10.99.1.2/24, peer `tun-1`, `endpoint_port: 51821`, `allowed_ips` 10.99.1.1/32, 10.1.0.0/16 (frontend VPC through the hub), 10.2.0.0/16 (`be-1.yml:2-10`) | `wireguard` (Step 7.5) | None |
| 13 | Play 1: "Terraform's inventory has all three VMs" | `hosts: localhost`, no facts. Asserts `groups[item] \| default([]) \| length == 1` for `frontend`, `hub`, `backend`, with the message "group X has no VM; is the Terraform state there?" (`site.yml:1-9`). An empty but valid state parses fine, so without this play the later plays would match no hosts and "succeed" | `ansible-playbook` | None (no SSH) |
| 14 | Play 2: "Every VM is ready, has the common setup and its WireGuard tunnels" | `hosts: all`, `gather_facts: false`, `become: true`, roles `[vm_ready, common, wireguard]` (`site.yml:11-15`). One play for all three VMs on purpose: each WireGuard config needs the peer's public key from `hostvars`, registered earlier in the same play | `ansible-playbook` -> Steps 7.3-7.5 | SSH to all VMs |
| 15 | Play 3: backend | `hosts: backend`, roles `[k3s, fluxcd, app_secrets, app_deployed]`, `app_deployed` last (`site.yml:17-21`) | -> Phase 8 (Steps 8.1-8.7) | SSH to be-1 |
| 16 | Play 4: frontend | `hosts: frontend`, role `[frontend]` (`site.yml:23-27`). It follows play 3 because its health check calls the API on be-1 | -> Phase 9 (Step 9.1) | SSH to fe-1 |
| 17 | Play 5: Alloy | `hosts: all`, role `[alloy]` (`site.yml:29-33`). Last, so a monitoring failure cannot block the app deploy | -> Phase 10 (Step 10.1) | SSH to all VMs |

**Why here:** `ansible-playbook` reads `ansible.cfg` from its working directory (`ansible.yml:41`), builds the inventory from state through the plugin, loads `group_vars`/`host_vars`, and only then runs plays. Play 1 runs on localhost before any SSH, so a missing state fails in seconds with a clear message.

**How it connects:**
- Hosts, groups, `ansible_host`, `ansible_user`, `vpc_ip` and `wan_ip` all come from `ansible_host.vm` (Step 6.8). Nothing in `ansible/` names a VM's address except the tunnel plan in `host_vars` and the hub filter's two VPC IPs (Step 7.5).
- The `listen_port`/`endpoint_port` values must equal `sg_hub_in` on the host (`nftables-vmfw.nft:99-100`, Step 2.6). `proxy_url` depends on CoreDNS (`Corefile:5`) and Squid (`squid.conf:4`). `ntp_server` depends on chrony (`host/files/chrony-lab.conf:4,7`).
- The `wg_interfaces` names `wg0`/`wg1` must equal the interface names in the hub filter (`hub-forward.nft:13,26-28`, Step 7.5).

**Re-run and removal:** Play 1 passes on every run while the state holds three VMs. Plays and variables have no state of their own and nothing to remove.

**Check it yourself:**
- `cd ansible && ansible-playbook -i localhost, --syntax-check site.yml` parses all five plays and every role without SSH or state (`-i` replaces the Terraform inventory; no sudo). It warns that `backend` and `frontend` match no host, which is expected here.
- `grep -n 5182 ansible/host_vars/*.yml host/files/nftables-vmfw.nft` shows 51820/51821 on both sides.

**Watch out:**
- The plugin needs `terraform` on PATH and an initialized `../terraform` (`terraform show` needs an initialized working directory). That is why the job runs `terraform init` (Step 7.1) although it applies nothing. It also only works when started from `ansible/`: both `ansible.cfg` and `../terraform` are found relative to the working directory.
- `gather_facts: false` in every play means no `ansible_facts`. No role reads a fact. They use inventory and group/host variables, role defaults, registered results, env/file lookups and magic variables (`group_names`, `hostvars`, `inventory_hostname`).

### Step 7.3: vm_ready

**Files:**
- `ansible/roles/vm_ready/tasks/main.yml`: waits until SSH answers and cloud-init has finished, so no later role races the first boot.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Task "Wait until SSH answers" | `ansible.builtin.wait_for_connection` with `timeout: 300` (`vm_ready/tasks/main.yml:4-6`): retries the SSH connection (and a Python round trip) until it works or 5 minutes pass | play 2 -> SSH to `user@<mgmt_ip>` with the agent key | None on the VM |
| 2 | Task "Wait for cloud-init to finish" | `cloud-init status --wait`, `changed_when: false`, `failed_when: "'status: done' not in cloud_init.stdout"` (`:8-12`). It blocks until cloud-init ends, then passes only if it reports `done` | play 2 -> `cloud-init` on the VM | Reads cloud-init status |

**Why here:** `terraform apply` returns when the domains are started, not when they have booted. SSH may not be up yet, and cloud-init may still be installing the CA, writing netplan or finishing the user. Every later task needs those, so this role runs first in play 2 (`site.yml:14`).

**How it connects:**
- It connects as `ansible_user` (`user`, Step 6.8) to `ansible_host` (the mgmt IP) with the agent's key (Step 7.1), which cloud-init authorized (Step 6.6).
- The host's SSH goes out over `mgmtbr1`. The replies come back through vmfw's `iifname "mgmtbr1" ct state established,related accept` (`nftables-vmfw.nft:174`), and the VM -> VM mgmt drop does not apply to host traffic (`:69`).

**Re-run and removal:** On a running VM both tasks pass at once. Nothing to remove.

**Check it yourself:**
- `ssh be-1 cloud-init status --long` shows `status: done`, the datasource (`detail:`) and any `errors`/`recoverable_errors`. (`ssh be-1 cloud-init analyze show` lists the boot stages.)

**Watch out:** `failed_when` replaces Ansible's exit-code check, so a run where cloud-init exits 2 (finished with recoverable warnings) but prints `status: done` passes on purpose. A first boot that takes longer than 300 s to bring up SSH fails the play.

### Step 7.4: common

**Files:**
- `ansible/roles/common/tasks/main.yml`: clock from the host, apt through Squid, base packages.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Task "timesyncd drop-in directory exists" | `/etc/systemd/timesyncd.conf.d`, root, 0755 (`common/tasks/main.yml:2-8`) | play 2 | VM directory |
| 2 | Task "timesyncd gets the time from the host" | Writes `/etc/systemd/timesyncd.conf.d/lab.conf`: `NTP={{ ntp_server }}`, `FallbackNTP=` (no fallback to public pools, which the VMs cannot reach anyway), `PollIntervalMaxSec=256` (polls at least every 256 s instead of the default 2048 s, so a jump after a host suspend is corrected within minutes). Registers `timesyncd_conf` (`:10-21`) | play 2 | `/etc/systemd/timesyncd.conf.d/lab.conf` |
| 3 | Task "timesyncd uses the new config now" | Restarts and enables `systemd-timesyncd` only `when: timesyncd_conf is changed` (`:23-28`). It is an inline task, not a handler, because a handler would run at the end of the play, after apt. The file's first line says why: a VM clock hours off makes apt reject the package lists (`:1`) | play 2 -> systemd | Restarts `systemd-timesyncd` |
| 4 | Task "apt uses the lab proxy" | Writes `/etc/apt/apt.conf.d/90lab-proxy` with `Acquire::http::Proxy` and `Acquire::https::Proxy` = `proxy_url` (`:30-38`) | play 2 | `/etc/apt/apt.conf.d/90lab-proxy` |
| 5 | Task "Ensure packages are installed" | `apt` with `name: "{{ common_packages }}"`, `update_cache: true`, `cache_valid_time: 3600` (`:40-45`): refreshes the lists if they are older than 1 h, then installs `nftables` and `wireguard-tools` | play 2 -> apt -> Squid | Package lists; packages |

**Why here:** The clock must be right before apt, the proxy must be set before any apt call, and `wireguard-tools` (`wg`, `wg-quick`, `wg-quick@.service`) and `nftables` must be installed before the wireguard role (Step 7.5). The role runs after `vm_ready`, because cloud-init's network and DNS must be in place.

**How it connects:**
- `ntp_server` -> host chrony, which allows 10.250.0.0/24 and binds 10.250.0.1 (`host/files/chrony-lab.conf:4,7`, Step 2.3), through vmfw `udp dport { 53, 123 }` on 10.250.0.1 (`nftables-vmfw.nft:175`).
- `proxy_url` -> `proxy.lab.test`, resolved by CoreDNS (`Corefile:5`, Step 3.1) through the eth2 nameserver (Step 6.6) -> Squid on 10.250.0.1:3128 (`services/squid/conf/squid.conf:4`) through vmfw `tcp dport { 53, 3128 }` (`nftables-vmfw.nft:176`). Squid allows `vms` (10.250.0.0/24) to `pkg_hosts` (`.archive.ubuntu.com`, `security.ubuntu.com`) only (`squid.conf:6-7,19`, Step 3.2).
- The same `proxy_url` is reused by the k3s installer and the Flux download on be-1 (Steps 8.1-8.2).

**Re-run and removal:** Every task is idempotent. A second run finds both files unchanged, skips the restart, and leaves the apt cache alone if it is under an hour old. Nothing removes these files. They go with the VM (teardown or rebuild).

**Check it yourself:**
- `ssh fe-1 timedatectl show -p NTPSynchronized` prints `NTPSynchronized=yes`. `ssh fe-1 timedatectl timesync-status` names server 10.250.0.1.
- `ssh fe-1 cat /etc/apt/apt.conf.d/90lab-proxy` shows the two proxy lines.

**Watch out:**
- After the restart the role goes straight to apt without waiting for the first sync. timesyncd usually steps the clock within seconds, but nothing guarantees it before `update_cache` runs.
- apt can reach only the Ubuntu archive hosts in Squid's `pkg_hosts`. A role that adds another apt repository gets 403 from Squid.
- `nftables` is installed on all three VMs but used only on tun-1 (Step 7.5). On fe-1 and be-1 the service stays as Ubuntu ships it (disabled).

### Step 7.5: wireguard hub-and-spoke

**Files:**
- `ansible/roles/wireguard/tasks/main.yml`: keys, configs, the hub's forwarding and filter, and the tunnel services.
- `ansible/roles/wireguard/handlers/main.yml`: apply the sysctl file, restart the tunnels, reload the filter.
- `ansible/roles/wireguard/templates/wg.conf.j2`: one `wg-quick` config per interface.
- `ansible/roles/wireguard/files/hub-forward.nft`: tun-1's whole nftables ruleset.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Task "The WireGuard private key exists" | `umask 077 && wg genkey > /etc/wireguard/private.key.tmp && mv ... private.key`, `creates: /etc/wireguard/private.key` (`wireguard/tasks/main.yml:1-7`). It is made once per VM and never leaves it. The tmp-then-move pattern means a crash cannot leave a half-written key that `creates` would then keep | play 2 (all) | `/etc/wireguard/private.key` (0600) |
| 2 | Task "Read this VM's WireGuard public key" | `wg pubkey < /etc/wireguard/private.key`, registered as `wg_public_key`, `changed_when: false` (`:9-12`). With the linear strategy it runs on all three VMs before the next task starts on any of them | play 2 (all) | Reads the key; fact in `hostvars` |
| 3 | Task "Wireguard interface has its config" | Renders `wg.conf.j2` to `/etc/wireguard/<name>.conf`, root, 0600, once per entry in `wg_interfaces`; notifies "Restart wireguard" (`:14-22`) | play 2 (all) -> template | `/etc/wireguard/wg0.conf` and/or `wg1.conf` |
| 4 | Template header and `Address` | `# Managed by Ansible ...` (`wg.conf.j2:1`). `[Interface]` `Address = {{ item.address }}` (`:2-3`) | task 3 | None |
| 5 | Template `ListenPort` | Only when `listen_port` is defined, so only on the hub (`wg.conf.j2:4-6`) | task 3 | None |
| 6 | Template `PostUp` private key | `PostUp = wg set %i private-key /etc/wireguard/private.key` (`wg.conf.j2:7`). The key is set when the interface comes up, so it is never in the config file and never passes through Ansible | task 3; `wg-quick` at runtime | None |
| 7 | Template spoke routes | Only when `endpoint_port` is defined, so only on the spokes: one `PostUp = ip route replace <net> dev %i src {{ vpc_ip }}` per `allowed_ips` entry (`wg.conf.j2:8-12`). `wg-quick` first adds a plain route for each AllowedIPs entry, then runs `PostUp`, which replaces each route with one that pins the source address (see "Why spokes route with `src vpc_ip`" below) | task 3; `wg-quick` | Spoke routing table at runtime |
| 8 | Template `[Peer]` | `PublicKey = {{ hostvars[item.peer].wg_public_key.stdout }}` (from task 2 on the peer), `AllowedIPs = <list>` (`wg.conf.j2:14-16`) | task 3 | None |
| 9 | Template `Endpoint` and keepalive | Spokes only: `Endpoint = {{ hostvars[item.peer].wan_ip }}:{{ item.endpoint_port }}` (tun-1's 198.51.100.12) and `PersistentKeepalive = 25` (`wg.conf.j2:17-20`). Both fe-1 and be-1 get the keepalive | task 3 | None |
| 10 | Task "Hub loads conntrack before sysctl runs at boot" | `/etc/modules-load.d/lab-conntrack.conf` = `nf_conntrack`, `when: "'hub' in group_names"` (`:24-33`). The `net.netfilter.*` keys exist only once the module is loaded. Loading it at boot lets the sysctl file apply after a reboot | play 2 (tun-1) | `/etc/modules-load.d/lab-conntrack.conf` |
| 11 | Task "Hub forwards traffic between tunnels" | `/etc/sysctl.d/90-lab-forward.conf`: `net.ipv4.ip_forward = 1`, `net.netfilter.nf_conntrack_max = 65536`, `net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30`. Hub only; notifies "Apply sysctl" (`:35-48`). The comment explains the sizing: a 512 MB VM defaults to 4096 entries with a 120 s TIME_WAIT, which fills at about 34 new connections/s. 65536 entries and 30 s hold about 2200/s (`:35-36`) | play 2 (tun-1) | `/etc/sysctl.d/90-lab-forward.conf` |
| 12 | Task "The hub's filter is installed" | Copies `hub-forward.nft` to `/etc/nftables.conf` with `validate: nft -c -f %s` (a syntax error never reaches the file). Hub only; notifies "Reload nftables" (`:50-59`) | play 2 (tun-1) | `/etc/nftables.conf` |
| 13 | Task "nftables loads the filter now and at boot" | `nftables` enabled and started. Hub only (`:61-66`). Starting it loads the ruleset, and its `ct` rules load `nf_conntrack` | play 2 (tun-1) -> systemd | `nftables.service` |
| 14 | Task "Each WireGuard tunnel is enabled and running" | `wg-quick@<name>` enabled and started, once per interface (`:68-73`) | play 2 (all) -> systemd | `wg-quick@wg0` / `wg-quick@wg1` |
| 15 | Handler "Apply sysctl" | `sysctl -p /etc/sysctl.d/90-lab-forward.conf` (`wireguard/handlers/main.yml:1-2`) | end of play 2, when notified by 11 | Kernel settings on tun-1 |
| 16 | Handler "Restart wireguard" | Restarts every `wg-quick@<name>` on that VM, looping over `wg_interfaces` (`handlers/main.yml:4-8`). A restart, not a reload, so `Address` and `PostUp` changes apply | end of play 2, when notified by 3 | Tunnels bounce |
| 17 | Handler "Reload nftables" | `nftables` reloaded (`handlers/main.yml:10-13`): reads `/etc/nftables.conf` again | end of play 2, when notified by 12 | tun-1 ruleset |
| 18 | `hub-forward.nft`: header, `flush ruleset`, table | The shebang and comments say it is tun-1 only and that its addresses must match `compute.tf` and `host_vars/tun-1.yml` (`hub-forward.nft:1-4`). `flush ruleset` (`:6`) makes every load a full, atomic replacement. Table `inet lab_hub` (`:8`) | `nftables` start/reload | tun-1 ruleset |
| 19 | `hub-forward.nft`: chain `forward` | `hook forward priority filter; policy drop` (`:10`). `ct state invalid drop` (`:11`), `ct state established,related accept` (`:12`). The one new flow: `iifname "wg0" oifname "wg1" ip saddr 10.1.1.10 ip daddr 10.3.1.10 tcp dport 8000 ct state new accept` (`:13`). Everything else is counted as "dropped forward" (`:14`), then dropped by the policy | kernel, for every packet tun-1 routes | None |
| 20 | `hub-forward.nft`: chain `input` | `policy accept` (`:25`), but for packets arriving on `wg0`/`wg1`: `ct state established` accept (`:26`), `icmp type echo-request` accept (`:27`), anything else counted and dropped as "spoke to the hub itself" (`:28`). Matching the tunnel interface instead of an address covers every tun-1 address, including 10.2.1.10, which the spokes route into the tunnel. "Established only, not related" stops a spoke from forging an ICMP error about another connection (`:17-23`). WireGuard itself (eth1) and the host's SSH (eth2) are unaffected | kernel, for packets to tun-1 itself | None |

**Hub-and-spoke addressing:**

```
 underlay: bridge "wan" 198.51.100.0/24 (bridged; host lab_sg allows only the two UDP flows below)
   fe-1 eth1 198.51.100.11 --udp--> 198.51.100.12:51820  tun-1 eth1  198.51.100.12:51821 <--udp-- be-1 eth1 198.51.100.13

 overlay:
   fe-1 wg0 10.99.0.2/24 ==== wg0 10.99.0.1/24 [ tun-1, forward: wg0->wg1 tcp 8000 only ] wg1 10.99.1.1/24 ==== wg1 10.99.1.2/24 be-1
   fe-1 eth0 10.1.1.10 (site-a)                tun-1 eth0 10.2.1.10 (site-hub)                       be-1 eth0 10.3.1.10 (site-c)
```

| Tunnel | Hub end (tun-1) | Spoke end | UDP port, who dials | Spoke AllowedIPs (= routes via the tunnel, src vpc_ip) | Hub AllowedIPs for that spoke (= what the hub accepts from it and routes to it) |
|---|---|---|---|---|---|
| wg0 | 10.99.0.1/24, `ListenPort 51820` (`host_vars/tun-1.yml:3-9`) | fe-1 10.99.0.2/24 (`host_vars/fe-1.yml:2-10`) | 51820; fe-1 dials 198.51.100.12:51820 | 10.99.0.1/32, 10.2.0.0/16, 10.3.0.0/16 | 10.99.0.2/32, 10.1.0.0/16 |
| wg1 | 10.99.1.1/24, `ListenPort 51821` (`host_vars/tun-1.yml:11-17`) | be-1 10.99.1.2/24 (`host_vars/be-1.yml:2-10`) | 51821; be-1 dials 198.51.100.12:51821 | 10.99.1.1/32, 10.1.0.0/16, 10.2.0.0/16 | 10.99.1.2/32, 10.3.0.0/16 |

The hub has one interface and one port per spoke rather than one `wg0` with two peers. That way the hub filter can name the direction by interface (`iifname "wg0" oifname "wg1"`), and the host's security group can tie each port to one spoke's card (`udp dport 51820` only from `fe-1-wan`, `51821` only from `be-1-wan`: `nftables-vmfw.nft:99-100`).

Only the spokes dial. The hub has no `Endpoint` and learns each spoke's address from its handshakes (`host_vars/tun-1.yml:1`). The host's security groups allow new UDP only toward the hub (`sg_hub_in`) and nothing toward the spokes (`sg_frontend_in` and `sg_backend_in` are empty, `nftables-vmfw.nft:103-108`). After the first packet, the hub's packets to a spoke pass only as replies in the host's bridge conntrack (`:84-87`). `PersistentKeepalive = 25` keeps that entry and the hub's endpoint fresh. This matters most for be-1, which never starts traffic of its own: without the keepalive, the hub could not deliver fe-1's request to be-1 after the entry expired.

Rendered example, fe-1 `/etc/wireguard/wg0.conf`:

```
[Interface]
Address = 10.99.0.2/24
PostUp = wg set %i private-key /etc/wireguard/private.key
PostUp = ip route replace 10.99.0.1/32 dev %i src 10.1.1.10
PostUp = ip route replace 10.2.0.0/16 dev %i src 10.1.1.10
PostUp = ip route replace 10.3.0.0/16 dev %i src 10.1.1.10

[Peer]
PublicKey = <tun-1's public key>
AllowedIPs = 10.99.0.1/32, 10.2.0.0/16, 10.3.0.0/16
Endpoint = 198.51.100.12:51820
PersistentKeepalive = 25
```

**Why spokes route with `src vpc_ip`:** Without `src`, Linux gives a packet routed out of `wg0` the address of `wg0` itself. fe-1's request to 10.3.1.10:8000 would then leave as 10.99.0.2. The hub filter forwards only `ip saddr 10.1.1.10` (`hub-forward.nft:13`), so it would be dropped. Even if it were allowed, be-1 has no route back to 10.99.0.0/24 (its AllowedIPs are 10.99.1.1/32, 10.1.0.0/16 and 10.2.0.0/16), so its reply would go to its default route on eth1, where the host drops it. Pinning `src` to the VPC address makes the VPC address each VM's identity on the overlay, and every other layer already uses it:
- the hub filter's `saddr 10.1.1.10` / `daddr 10.3.1.10`;
- WireGuard's own source check on the hub, which accepts 10.1.1.10 on wg0 because it is inside fe-1's AllowedIPs 10.1.0.0/16;
- be-1's route back, `10.1.0.0/16 dev wg1`;
- the k3s node IP 10.3.1.10 (Step 8.1) and the frontend's `API_URL` (`frontend/app.py:10`, Step 9.2).

fe-1 needs `src` most, because it starts the only allowed flow. On be-1, `src` covers what be-1 starts itself (only a ping to the hub would be answered). Replies always keep the address the request was sent to. tun-1 gets no `src` routes: it has no `endpoint_port` and starts nothing over the tunnels.

One request, end to end (once Step 8.1 serves :8000):
1. fe-1 connects to 10.3.1.10:8000. The route `10.3.0.0/16 dev wg0 src 10.1.1.10` picks wg0 and source 10.1.1.10.
2. wg0 encrypts the packet for tun-1 and sends UDP 198.51.100.11 -> 198.51.100.12:51820 on eth1. The host's `lab_sg` passes it (`sg_hub_in`, then established).
3. tun-1 decrypts on wg0, routes 10.3.1.10 to wg1 (from its AllowedIPs 10.3.0.0/16), and the forward chain accepts the new tcp 8000 flow (`hub-forward.nft:13`).
4. wg1 encrypts for be-1 and sends to be-1's last known endpoint. The bridge conntrack entry from be-1's keepalives lets it through.
5. be-1 decrypts on wg1. 10.3.1.10 is its own (eth0) address, so the packet is delivered locally, to Traefik on :8000 (Step 8.1). The reply returns by `10.1.0.0/16 dev wg1`, and tun-1 forwards it as established (`:12`).

**Why here:** The role needs `wireguard-tools` and `nftables` from `common` (Step 7.4). It needs all three VMs in the same play, because task 3 reads the peer's `wg_public_key` from task 2. The tunnels must exist before play 3 installs the API on be-1 and play 4 checks the frontend end to end through them (Steps 8.1, 9.1).

**How it connects:**
- `Endpoint` uses tun-1's `wan_ip` (Step 6.8) on the `wan` bridge (Step 6.4). The ports are the host's `sg_hub_in` (`nftables-vmfw.nft:98-101`, Step 2.6).
- The hub filter's tcp 8000 matches Traefik's `web` entrypoint, moved to `exposedPort: 8000` by `ansible/roles/k3s/files/traefik-config.yaml:10-12` (Step 8.1), and the frontend's default `API_URL` `http://10.3.1.10:8000` (`frontend/app.py:10`, Step 9.2).
- `vpc_ip` comes from Terraform (`terraform/inventory.tf:8`, Step 6.8). The `hub` group comes from `compute.tf:17`.
- The request path has three independent filters: the host's `lab_sg` on the underlay (Step 2.6), this hub filter, and inside k3s on be-1 the `db` namespace's NetworkPolicies, where only Traefik may reach PostgREST (`kubernetes/apps/db/networkpolicy.yaml:31-55`, Step 8.4).

**Re-run and removal:** The private key is kept (`creates:`), so a second run renders the same configs, notifies nothing and restarts nothing. Tasks 2 and 14 report ok. When a peer was rebuilt (new key, Step 6.7), the configs that name it change, and "Restart wireguard" bounces every tunnel on the affected VMs at the end of play 2. A changed `hub-forward.nft` is validated, copied and reloaded atomically (`flush ruleset`). Nothing removes this setup. It goes with the VM.

**Check it yourself:**
- `ssh tun-1 sudo wg show` (sudo on the VM; nothing on the host) lists `wg0` and `wg1`, each with one peer, a recent "latest handshake" and the AllowedIPs above.
- `ssh fe-1 ip route get 10.3.1.10` prints `10.3.1.10 dev wg0 src 10.1.1.10`.
- `ssh tun-1 sudo nft list table inet lab_hub` shows the rules with their counters ("dropped forward", "spoke to the hub itself").

**Watch out:**
- The addresses in `hub-forward.nft:13` are hand copies of the VPC IPs in `compute.tf:9,35`, and the interface names match `host_vars/tun-1.yml` (comment at `:4`).
- If a VM fails before task 2, Ansible drops it from the play and its `wg_public_key` is never registered. If fe-1 or be-1 failed, tun-1's template task fails on the undefined `hostvars`; if tun-1 failed, both spokes' template tasks fail. Ansible carries on with the hosts still alive, so later plays may run on a subset, but the playbook exits non-zero and the job is red. The error points at the template, not at the VM that failed first.
- "Restart wireguard" restarts all of a VM's interfaces when any one config changed. On tun-1, a rebuilt fe-1 also bounces be-1's tunnel.
- The first-build order inside play 2 is implicit. "Apply sysctl" sets `net.netfilter.*` keys that exist only after `nf_conntrack` is loaded. On a first build the modules-load file does nothing until a reboot. The module is loaded by task 13, because the ruleset it starts contains `ct` rules, and handlers run after all tasks, in their file order (Apply sysctl, Restart wireguard, Reload nftables). Removing every `ct` rule from the filter would break the first `sysctl -p`.
- `flush ruleset` clears every nftables table on tun-1, not only `lab_hub`. Anything else added to tun-1's firewall must go into this file.
- The spokes route 10.2.0.0/16 (the hub's VPC) into the tunnel (`host_vars/fe-1.yml:9`, `be-1.yml:10`), but tun-1 answers only ping there. That route is useful only for the ping test.

## Phase 8: Cluster and GitOps on be-1

Phase 8 turns be-1 into a single-node Kubernetes cluster that pulls the lab repo from Gitea and runs the database API. It runs inside the pipeline: job `configure` of `ansible.yml` (the fourth job of `deploy.yml`, `deploy.yml:21-24`) runs play 3 of `ansible/site.yml`, `hosts: backend`, roles `[k3s, fluxcd, app_secrets, app_deployed]` (`site.yml:17-21`). Ansible and Flux take turns (the turn-order table after **Hands on** shows who waits for whom). Ansible installs k3s (Step 8.1) and Flux, and hands Flux its Git source (Step 8.2). From that moment Flux works on its own inside be-1: it installs the CloudNativePG operator (Step 8.3) and, once that is Ready, applies the app for the first time (Step 8.4). It also starts k8s-monitoring at the same moment (Step 10.2). Meanwhile Ansible sits in `app_secrets`, waiting for Flux to create namespace `db`, and then drops the database password Secret into k3s (Step 8.5). CNPG then builds the PostgreSQL cluster and PostgREST becomes Ready (Step 8.6). Ansible's last role waits until Flux reports this commit as applied and healthy (Step 8.7). After the phase, be-1 answers `http://10.3.1.10:8000/items` with JSON from PostgreSQL. Only fe-1 can reach that address, through the tunnel. Flux follows Gitea's `main` every minute. The pipeline knows that the API runs exactly the commit being deployed.

**Needs from earlier phases:**
- The VM be-1 with `vpc_ip` 10.3.1.10, `mgmt_ip` 10.250.0.112, 2 vCPU, 4 GiB RAM and a 40 GiB disk (`terraform/compute.tf:29-41`, Steps 6.5 and 6.7). Its hostname is `be-1`, set by cloud-init `local-hostname` (`terraform/compute.tf:77`). The node name is the same, which the Ready wait relies on.
- The inventory variable `vpc_ip` and the group `backend` (`terraform/inventory.tf:4,8`, Step 6.8).
- Plays 1-2 (Steps 7.2-7.5): be-1's clock is synced from the host, and apt goes through the proxy. The tunnels and the hub filter are not needed by k3s, but they are needed by Phase 9.
- CoreDNS answering `proxy.lab.test` and `gitea.lab.test` with 10.250.0.1 (`services/coredns/conf/Corefile:5`, Step 3.1). The VM resolver points at 10.250.0.1 (`terraform/cloud-init/network-config.yaml.tftpl:21-22`, Step 6.6).
- Squid: `acl backend src 10.250.0.112` and `acl k3s_hosts` (get.k3s.io, github.com, release-assets, docker.io, docker.com, ghcr.io, pkg-containers) (`services/squid/conf/squid.conf:8-9,20`, Step 3.2).
- vmfw: the forward exception for VM traffic whose original destination is 10.250.0.1:443 (`host/files/nftables-vmfw.nft:155`), and lab_sg's source check (`:58`) (Step 2.6).
- Traefik's router `gitea-flux` with allowlist `flux-and-host` (`services/traefik/dynamic/gitea.yml:3-8`, `allowlists.yml:11-13`, Step 3.8). Gitea's repo `lab/lab`, with `main` at the commit being deployed (Steps 4.3 and 5.2).
- Env vars set by the job (`.gitea/workflows/ansible.yml:27-28,43-44`, Step 7.1): `FLUX_GIT_TOKEN` from Vault `kv/data/lab/pipeline/gitea-flux` (Step 4.4), and `APP_DB_AUTHENTICATOR_PASSWORD` from `kv/data/lab/pipeline/app-db` (Step 3.7). `GITHUB_SHA` comes from the runner's job environment.
- `/etc/lab-runner/ca.pem` on the controller (the host), written by `runner.ensure_config` (Step 4.8).

**Hands on:**
- k3s on be-1: the API at 10.3.1.10:6443, the admin kubeconfig `/etc/rancher/k3s/k3s.yaml` (root only), and the auto-apply folder `/var/lib/rancher/k3s/server/manifests` holding `traefik-config.yaml`, `flux.yaml`, `flux-git-auth.yaml`, `flux-sync.yaml` and `db-authenticator.yaml`.
- Bundled Traefik on be-1 port 8000 (through ServiceLB). The Ingress `postgrest` sends every path there to PostgREST. This is the API fe-1 calls (Phase 9) and the load demo hits (Step 11.3).
- Flux in `flux-system`: GitRepository `lab-repo` (`main`, every 1 min) and three Kustomizations. `lab-cnpg` and `lab-apps` are Ready, with `lab-apps` at this commit. Nothing checks `lab-monitoring` (Step 10.2).
- Secret `flux-system/flux-git-auth` (`username`, `password`, `ca.crt`). Its `ca.crt` is reused by k8s-monitoring (Step 10.2).
- Secret `db/db-authenticator` (basic-auth, user `authenticator`).
- CNPG Cluster `pg` (2 instances) with Service `pg-rw`, database `todo`, schema `todo`, table `todo.items`, and roles `api_anon` and `authenticator`.
- HPA `postgrest`, 1-4 replicas (Step 11.3).
- A guarantee for play 4: `lab-apps` `status.lastAppliedRevision` = `main@sha1:$GITHUB_SHA`.

**Turn order on a fresh build (Ansible play 3 and the cluster):**

| # | Ansible task (play 3) | Meanwhile in the cluster | Who waits |
|---|---|---|---|
| 1 | k3s role: config, `traefik-config.yaml`, k3s installed (`ansible/roles/k3s/tasks/main.yml:1-54`) | k3s starts and applies its manifests folder | Nobody |
| 2 | "k3s node is Ready" (`k3s/tasks/main.yml:56-62`) | Node `be-1` turns Ready | Ansible waits for the node (Step 8.1) |
| 3 | fluxcd role: `flux.yaml` dropped, then "Flux controllers are Available" (`ansible/roles/fluxcd/tasks/main.yml:38-53`) | k3s applies Flux; the three controllers start | Ansible waits for the controllers (Step 8.2) |
| 4 | `flux-git-auth.yaml` and `flux-sync.yaml` dropped, then "GitRepository ready" (`fluxcd/tasks/main.yml:55-79`) | source-controller fetches `main`; `lab-repo` turns Ready; `lab-cnpg` and `lab-monitoring` start, neither with a `dependsOn` | Ansible waits for the first fetch (Steps 8.2, 8.3, 10.2) |
| 5 | app_secrets: "Namespace db exists", up to about 10 min (`ansible/roles/app_secrets/tasks/main.yml:5-12`) | `lab-cnpg` turns Ready, then `lab-apps` (`dependsOn: lab-cnpg`, `flux-sync.yaml:28-29`) applies for the first time and creates namespace `db`. Its health check fails: PostgREST has no Secret yet (Step 8.4, row 21) | Ansible waits for Flux; then the cluster waits for Ansible |
| 6 | `db-authenticator.yaml` dropped (`app_secrets/tasks/main.yml:14-21`) | k3s applies the Secret. CNPG runs initdb and creates role `authenticator`; PostgREST pods turn Ready (Steps 8.5, 8.6) | Nobody: the cluster has what it needs |
| 7 | app_deployed: waits up to about 15 min for `lastAppliedRevision` = `main@sha1:$GITHUB_SHA` (`ansible/roles/app_deployed/tasks/main.yml:4-14`) | `lab-apps` retries every 2 min (`flux-sync.yaml:23`) and turns Ready at this commit | Ansible waits for Flux (Step 8.7) |

### Step 8.1: k3s

**Files:**
- `ansible/roles/k3s/defaults/main.yml`: the k3s version pin and the installer's `NO_PROXY` list.
- `ansible/roles/k3s/tasks/main.yml`: writes the node config and the Traefik override, installs k3s through Squid, and waits for the node.
- `ansible/roles/k3s/handlers/main.yml`: `Restart k3s` after a config change.
- `ansible/roles/k3s/files/traefik-config.yaml`: HelmChartConfig that moves the bundled Traefik's `web` entrypoint to port 8000 and hides `websecure`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `k3s_version` | `'v1.37.2+k3s1'`, the release the installer fetches (`defaults/main.yml:1`) | row 9 (task "k3s is installed") (`INSTALL_K3S_VERSION`, `tasks/main.yml:54`) | None |
| 2 | `k3s_no_proxy` | `127.0.0.1,localhost,10.0.0.0/8,.lab.test` (`defaults/main.yml:2`). It keeps loopback, the pod and service ranges (10.42/10.43), the VPC and mgmt ranges and lab names off Squid | row 9 (task "k3s is installed") (`NO_PROXY`, `tasks/main.yml:53`) | Copied by the installer into k3s's service env (k3s installer behaviour) |
| 3 | Task "k3s config folder exists" | `/etc/rancher/k3s`, root 0755 (`tasks/main.yml:1-7`) | play 3, role 1 | Directory |
| 4 | Task "k3s has the config" | `/etc/rancher/k3s/config.yaml` with the single line `node-ip: {{ vpc_ip }}` = 10.3.1.10, root 0600. It notifies `Restart k3s` (`tasks/main.yml:9-17`). The node registers with this IP, and the API server advertises 10.3.1.10:6443 | play 3 -> handler (row 11) | File |
| 5 | Task "k3s manifests folder exists" | `/var/lib/rancher/k3s/server/manifests`, root 0700, created before k3s exists (`tasks/main.yml:19-26`). k3s applies every file in this folder when it appears or changes. When k3s starts, it also writes its own packaged manifests here (CoreDNS, Traefik, local-path, metrics-server) | play 3 | Directory |
| 6 | HelmChartConfig `kube-system/traefik` | `helm.cattle.io/v1`. The values `ports.web.exposedPort: 8000` and `ports.websecure.expose.default: false` (`files/traefik-config.yaml:3-15`) are merged into k3s's bundled Traefik chart. The comment gives the reason: fe-1 calls 10.3.1.10:8000 and the hub filter allows only 8000 (`:2`) | k3s Helm controller | Traefik Service exposes 8000 only |
| 7 | Task "Traefik listens on 8000 only" | Copies row 6 into the manifests folder, root 0600 (`tasks/main.yml:28-35`). The comment notes that k3s watches the folder, so no restart is needed | play 3 | `manifests/traefik-config.yaml` |
| 8 | Task "k3s installer downloaded" | `get_url https://get.k3s.io` to `/usr/local/bin/k3s-install.sh` 0755, with `HTTPS_PROXY={{ proxy_url }}` (`tasks/main.yml:38-44`; `proxy_url` is `ansible/group_vars/all.yml:3`). No checksum, and without `force` an existing file is never fetched again | play 3 -> Squid (`backend` -> `get.k3s.io`) | Script file |
| 9 | Task "k3s is installed" | Runs the script with `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and `INSTALL_K3S_VERSION`, `creates: /usr/local/bin/k3s` (`tasks/main.yml:46-54`). The script downloads the k3s binary from GitHub releases through Squid, checks it against the release's sha256 list, writes `k3s.service` plus an env file with the proxy variables, and starts k3s, which reads `config.yaml` | play 3 -> Squid (`github.com`, `release-assets.githubusercontent.com`) | `/usr/local/bin/k3s`, `k3s.service`, `/etc/systemd/system/k3s.service.env`, `/etc/rancher/k3s/k3s.yaml` |
| 10 | k3s server and its packaged components | Nothing in the repo configures these, so k3s's defaults apply: the API server on :6443, embedded containerd (it pulls through Squid because of the env file), flannel (it masquerades pod traffic that leaves the node, so pods reach 10.250.0.1 as 10.250.0.112), the kube-router network policy controller, CoreDNS (it forwards non-cluster names to be-1's resolver 10.250.0.1), Traefik as a Helm chart, ServiceLB (`svclb-traefik` holds node port 8000), metrics-server and the local-path provisioner | k3s at start | System images from docker.io through Squid |
| 11 | Task "k3s node is Ready" | `k3s kubectl wait --for=condition=Ready node/be-1 --timeout=10s`, up to 30 tries 10 s apart (about 5 min) (`tasks/main.yml:56-62`). `changed_when: false` | play 3 | Reads the API |
| 12 | Handler `Restart k3s` | `systemd_service k3s restarted` (`handlers/main.yml:1-4`). The role has no `flush_handlers`, so a notify from row 4 runs at the end of play 3, after `app_deployed` (Step 8.7) | notified by row 4 | Restarts `k3s.service` |

**Why here:** k3s is the first role of the backend play. Everything in Phase 8 needs its API, its `k3s kubectl` and its manifests folder. Inside the role the order is load-bearing. `config.yaml` must exist before the first start, so the node registers on 10.3.1.10. The manifests folder and `traefik-config.yaml` must exist before the installer runs, so the bundled Traefik is installed on port 8000 from the start (comment `tasks/main.yml:19`). The download and the install need Squid's `backend` rule and CoreDNS's `proxy.lab.test` (Phase 3).

**How it connects:**
- `node-ip` 10.3.1.10 is the API endpoint behind `kubernetes.default` (10.43.0.1:443). The NetworkPolicy `pg-instances` allows exactly `10.3.1.10/32` port 6443 (`kubernetes/apps/db/networkpolicy.yaml:97-101`, Step 8.4).
- Port 8000 is the port that tun-1's hub filter forwards (`ansible/roles/wireguard/files/hub-forward.nft:13`, Step 7.5), that the frontend calls (`frontend/app.py:10`, Step 9.2) and that `demo/load.sh:6` hits (Step 11.3). The Traefik pod label `app.kubernetes.io/name: traefik` is the only source the NetworkPolicy `postgrest` admits (`networkpolicy.yaml:45-47`, Step 8.4).
- The manifests folder is where the fluxcd role (Step 8.2) and the app_secrets role (Step 8.5) deliver their objects. `/etc/rancher/k3s/k3s.yaml` is the kubeconfig for `flux check --pre` (Step 8.2).
- metrics-server feeds the HPA (Step 8.4). local-path backs CNPG's PVCs (Step 8.6). kube-router enforces the NetworkPolicies (Step 8.4). The CoreDNS label `k8s-app: kube-dns` is what `allow-dns` targets (`networkpolicy.yaml:24-26`).
- The masquerade to 10.250.0.112 is what lets every pod pass lab_sg's source check, Squid's `backend` acl, vmfw's saddr set (`nftables-vmfw.nft:155`) and Traefik's `flux-and-host` and `vms-and-host` lists (Steps 8.2, 8.3, 10.2).

**Re-run and removal:** On a second run the file tasks report no change, `get_url` keeps the existing script, `creates:` skips the install, and the Ready wait passes at once. The handler fires only when `config.yaml` changes. There is no uninstall task: k3s goes away with the VM (`teardown`, Step 12.1, or `destroy`, Step 12.2).

**Check it yourself:**
- `ssh be-1 sudo k3s kubectl get nodes -o wide` shows `be-1 Ready` with INTERNAL-IP `10.3.1.10` (sudo on be-1 is passwordless).
- `ssh be-1 sudo k3s kubectl -n kube-system get svc traefik` lists only `8000:<nodeport>/TCP`.
- `ssh be-1 sudo cat /etc/systemd/system/k3s.service.env` shows the `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` lines the installer copied.

**Watch out:**
- A `k3s_version` bump does nothing on a running lab: `creates: /usr/local/bin/k3s` skips the installer. An upgrade means rebuilding be-1.
- On a fresh build, row 4 always notifies the handler, so k3s restarts once at the end of play 3, after the app is already healthy and right before the frontend play. Pods keep running across a k3s restart, so this is harmless but surprising. The restart is not even needed, because `config.yaml` existed before the first start. If play 3 fails before its end, the handler is dropped and never runs later.
- be-1's VPC address 10.3.1.10 and the API port 8000 are copied by hand into the hub filter, the frontend, a NetworkPolicy and `demo/load.sh` (R1, rows "VPC IPs" and "API port 8000").
- be-1's internet egress is Squid's `pkg_hosts` (every VM, `squid.conf:7,19`) plus `k3s_hosts` (be-1 only, `squid.conf:9,20`). Both are `dstdomain` without `-n` (`squid.conf:7,9`, see Step 3.2).

### Step 8.2: fluxcd

**Files:**
- `ansible/roles/fluxcd/defaults/main.yml`: the Flux CLI version and the Git user name for Gitea.
- `ansible/roles/fluxcd/tasks/main.yml`: installs the CLI, puts the controllers into the manifests folder, writes the auth Secret and the sync objects, and waits until the repo is fetched.
- `ansible/roles/fluxcd/templates/flux-git-auth.yaml.j2`: Secret `flux-system/flux-git-auth` (Gitea user, read-only token, lab CA).
- `ansible/roles/fluxcd/files/flux-sync.yaml`: GitRepository `lab-repo` and the Kustomizations `lab-apps`, `lab-monitoring` and `lab-cnpg`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `flux_version` | `'2.10.0'` (`defaults/main.yml:1`). It picks the tarball, and through the CLI it also decides which controller manifests `flux install --export` renders | rows 3, 6 | None |
| 2 | `flux_git_user` | `labadmin` (`defaults/main.yml:2`). This must be the owner of the token, which is `LAB_ADMIN` (`lib/config.py:8`; `services/gitea/gitea.py:144`) | row 9 | None |
| 3 | Task "Flux tarball is downloaded" | `get_url` of `flux_2.10.0_linux_amd64.tar.gz` from GitHub releases to `/tmp/flux.tar.gz` with `HTTPS_PROXY` (`tasks/main.yml:3-9`). No checksum | play 3, role 2 -> Squid (`github.com`, `release-assets.githubusercontent.com`) | `/tmp/flux.tar.gz` |
| 4 | Task "Flux CLI is installed" | `unarchive` on the VM (`remote_src`) into `/usr/local/bin/`, root 0755, `creates: /usr/local/bin/flux` (`tasks/main.yml:11-19`) | play 3 | `/usr/local/bin/flux` |
| 5 | Task "Cluster passes Flux pre-check" | `flux check --pre` with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` (`tasks/main.yml:21-26`). It checks that the cluster version is one Flux supports | play 3 -> API | Reads the API |
| 6 | Task "Flux manifests are rendered" | `flux install --export --components=source-controller,kustomize-controller,helm-controller`, registered as `flux_manifests`, on every run, `changed_when: false` (`tasks/main.yml:28-36`). The comment (`:28`) names only the k8s-monitoring HelmRelease. helm-controller also runs HelmRelease `cnpg` (Step 8.3), which the comment does not mention. The next comment line (`:29`) says that exporting on every run lets a changed component list reach a running lab | play 3 | stdout only |
| 7 | Task "Flux manifests are in the k3s manifests folder" | Writes the export to `manifests/flux.yaml` 0644 (`tasks/main.yml:38-44`). k3s applies it: namespace `flux-system`, the CRDs, RBAC and the three controllers (see the inventory at the end of Phase 8). Controller images come from ghcr.io through containerd's proxy env | play 3 -> k3s deploy controller | `manifests/flux.yaml` |
| 8 | Task "Flux controllers are Available" | `k3s kubectl -n flux-system wait --for=condition=Available deployment --all --timeout=10s`, up to 30 tries 10 s apart (`tasks/main.yml:46-53`). Besides the controllers, this proves that the CRDs exist, which row 15 needs | play 3 | Reads the API |
| 9 | Template `flux-git-auth.yaml.j2` | Opaque Secret `flux-system/flux-git-auth`. `stringData`: `username: {{ flux_git_user }}`, `password` from env `FLUX_GIT_TOKEN`, and `ca.crt` from `lookup('file', '/etc/lab-runner/ca.pem') \| indent(4)` (`flux-git-auth.yaml.j2:1-11`). Lookups run on the controller, so the CA comes from the host | row 10 | None |
| 10 | Task "Flux gitea secret" | Renders row 9 to `manifests/flux-git-auth.yaml`, root 0600, `no_log` (`tasks/main.yml:55-62`) | play 3 -> k3s | Secret `flux-system/flux-git-auth` |
| 11 | GitRepository `flux-system/lab-repo` | `url: https://gitea.lab.test/lab/lab.git`, `ref.branch: main`, `interval: 1m`, `timeout: 60s`, `secretRef: flux-git-auth` (`flux-sync.yaml:1-13`). source-controller uses `username`/`password` for HTTP Basic auth and `ca.crt` to verify Traefik's `gateway` certificate. It keeps the latest fetched commit as its artifact, with revision `main@sha1:<sha>` | source-controller | Fetches from Gitea through Traefik |
| 12 | Kustomization `lab-apps` | `path: ./kubernetes/apps`, `interval: 5m`, `retryInterval: 2m`, `timeout: 5m`, `prune: true`, `wait: true`, `dependsOn: [lab-cnpg]`, source `lab-repo` (`flux-sync.yaml:16-32`). The comments say why: the Cluster in `apps/db` needs CNPG's CRDs and operator (`:29`), and the first CNPG bootstrap needs the long timeout (`:24`) | kustomize-controller | Steps 8.4, 8.6 |
| 13 | Kustomization `lab-monitoring` | `path: ./kubernetes/monitoring`, same timings, `prune`, `wait`, no `dependsOn` (`flux-sync.yaml:34-50`). It is kept separate so a monitoring failure never blocks the app's apply (`:35`) | kustomize-controller | Step 10.2 |
| 14 | Kustomization `lab-cnpg` | `path: ./kubernetes/cnpg`, same timings, `prune`, `wait` (`flux-sync.yaml:52-68`) | kustomize-controller | Step 8.3 |
| 15 | Task "Sync flux object" | Copies `flux-sync.yaml` to `manifests/flux-sync.yaml` 0644 (`tasks/main.yml:64-70`). From here on Flux works without Ansible: `lab-cnpg` and `lab-monitoring` start at once, and `lab-apps` waits for `lab-cnpg` | play 3 -> k3s | GitRepository, three Kustomizations |
| 16 | Task "GitRepository ready" | `wait --for=condition=Ready gitrepository/lab-repo`, up to 30 tries 10 s apart (`tasks/main.yml:72-79`). It proves the whole be-1 -> Gitea path: pod -> k3s CoreDNS -> host CoreDNS `gitea.lab.test` -> masquerade to 10.250.0.112 -> lab_sg -> Podman DNAT of 10.250.0.1:443 -> vmfw `:155` -> Traefik `gitea-flux` (`flux-and-host`) -> `gitea:3000` | play 3 | Reads the API |

**Why here:** Flux needs a running API and the manifests folder (Step 8.1). Inside the role, three orders matter. The controllers must be Available before `flux-sync.yaml` lands, because the custom resources need their CRDs. `flux-git-auth` must land before `flux-sync.yaml`, so the first fetch already authenticates. The GitRepository wait comes last, so a broken Gitea path fails here, with a clear task name, and not ten minutes later in `app_secrets`.

**How it connects:**
- `FLUX_GIT_TOKEN` is the `read:repository` token that `gitea.flux_token` created (`services/gitea/gitea.py:138-149`, Step 4.4). It is read from Vault by `ansible.yml:27` and passed to the playbook at `:43` (Step 7.1).
- `ca.crt` is the lab root CA, copied to `/etc/lab-runner/ca.pem` by `runner.ensure_config` (Step 4.8). k8s-monitoring reads the same key through `valuesFrom` (`kubernetes/monitoring/helmrelease.yaml:18-26`, Step 10.2).
- The repo URL equals `GITEA_REPO_URL` (`services/gitea/config/config.py:15`, Step 4.1). Its path must stay under the `gitea-flux` route's `PathPrefix(/lab/lab.git/)` (`services/traefik/dynamic/gitea.yml:4`, Step 3.8). Every other Gitea path from be-1 gets 403 from the `host-only` catch-all.
- `lab-cnpg` -> Step 8.3. `lab-apps` -> Steps 8.4, 8.6 and 8.7 (`app_deployed` reads its status). `lab-monitoring` -> Step 10.2.

**Re-run and removal:** `get_url` keeps an existing `/tmp/flux.tar.gz`. It downloads again only after a reboot of be-1 has cleared `/tmp`. `unarchive` is skipped by `creates:`. `flux install --export` runs every time, but the copy changes the file only if the output changed. The Secret is re-rendered: its content changes only if the token or the lab CA changed, and k3s then re-applies it. `flux-sync.yaml` changes only when the file in the repo changed. Nothing removes these objects except rebuilding the VM.

**Check it yourself:**
- `ssh be-1 sudo k3s kubectl -n flux-system get deploy` shows three controllers with `READY 1/1`.
- `ssh be-1 sudo k3s kubectl -n flux-system get gitrepository,kustomization` shows `lab-repo` Ready with `stored artifact for revision 'main@sha1:<sha>'`, and the three Kustomizations.
- `ssh be-1 flux --version` prints `flux version 2.10.0`.

**Watch out:**
- Flux's own objects come from the k3s manifests folder, not from Git. An edit to `flux-sync.yaml` in the repo reaches the cluster only through the next pipeline run of this role, not through Flux.
- A `flux_version` bump is ignored on a running lab: `creates:` keeps the old CLI, so `flux install --export` keeps rendering the old controllers. The tarball also has no checksum, unlike the Alloy `.deb` (Step 10.1).
- `labadmin` is typed twice, in `flux_git_user` and in `LAB_ADMIN` (R1). The `username` that Vault stores next to the token is never read (Step 4.4, Watch out).

> **Marked change (not applied), C8:** Remove the `flux check --pre` task (`ansible/roles/fluxcd/tasks/main.yml:21-26`): k3s and Flux are pinned together, and Step 8.1 already proves the node Ready. See Appendix C.
> **Marked change (not applied), C10:** The comments at `fluxcd/tasks/main.yml:28` and `flux-sync.yaml:29,35,53` cite section ids (B09.4, B09.8b) of the previous version of this file. See Appendix C.

### Step 8.3: lab-cnpg: CloudNativePG operator

**Files:**
- `kubernetes/cnpg/kustomization.yaml`: the three resources of `lab-cnpg`.
- `kubernetes/cnpg/proxy-secret.yaml`: Secret `flux-system/cnpg-proxy` with Squid's address.
- `kubernetes/cnpg/ocirepository.yaml`: the CNPG Helm chart as an OCI artifact from ghcr.io.
- `kubernetes/cnpg/helmrelease.yaml`: installs operator 1.30.2 (chart 0.29.2) into `cnpg-system`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `kustomization.yaml` | `resources: [proxy-secret.yaml, ocirepository.yaml, helmrelease.yaml]`. No namespace transformer: each file names `flux-system` itself (`kubernetes/cnpg/kustomization.yaml:1-6`) | Kustomization `lab-cnpg` (`flux-sync.yaml:63`) | None |
| 2 | Secret `flux-system/cnpg-proxy` | Opaque, `address: http://proxy.lab.test:3128` (`proxy-secret.yaml:1-9`). The comment says Flux takes proxy settings only from a Secret, and that each chart folder has its own copy (`:1`) | kustomize-controller | Secret |
| 3 | OCIRepository `flux-system/cnpg` | `url: oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg`, `tag: 0.29.2`, `interval: 1h`, `layerSelector` for the Helm chart tarball (`operation: copy`), `proxySecretRef: cnpg-proxy` (`ocirepository.yaml:1-16`). The comment says why OCI: a classic HelmRepository has no proxy setting (`:1`) | source-controller -> Squid (`backend` -> `ghcr.io`, `pkg-containers.githubusercontent.com`) | Chart artifact |
| 4 | HelmRelease `flux-system/cnpg` | `interval: 10m`, `releaseName: cnpg`, `targetNamespace: cnpg-system`, `install.createNamespace: true`, `chartRef` to OCIRepository `cnpg`, values `resources` (requests 50m/64Mi, limit 256Mi), because the chart sets none and be-1 has 4 GB (`helmrelease.yaml:1-19`) | helm-controller | Helm release `cnpg` |
| 5 | What Helm installs | Namespace `cnpg-system`, the CNPG CRDs (`Cluster` and the others in `postgresql.cnpg.io`), the operator Deployment (image from ghcr.io through containerd's proxy env), its admission webhooks, and RBAC. These are chart defaults, not in the repo. Helm waits until the operator is ready before it marks the release Ready | helm-controller -> API | cnpg-system objects |
| 6 | `lab-cnpg` Ready | With `wait: true`, the Kustomization turns Ready once the HelmRelease is Ready. kustomize-controller then lets `lab-apps` start (its dependency check repeats every 30 s by default) | kustomize-controller | Status only |

**Why here:** `lab-cnpg` starts the moment `flux-sync.yaml` lands (Step 8.2, row 15), in parallel with `lab-monitoring` (Step 10.2). It must be Ready before `lab-apps` applies, because `postgres.yaml` is a `Cluster`, and that kind exists only after the chart installed its CRDs (`flux-sync.yaml:28-29`). Ansible never waits for `lab-cnpg` directly. It waits for namespace `db` in Step 8.5, which appears only after `lab-cnpg` is Ready, so the 60 x 10 s budget there is sized for this step (`ansible/roles/app_secrets/tasks/main.yml:10`).

**How it connects:**
- The proxy address repeats `proxy_url` (`ansible/group_vars/all.yml:3`) and `kubernetes/monitoring/proxy-secret.yaml:9` (Step 10.2). Squid lets only be-1 reach ghcr.io (`squid.conf:8-9,20`, Step 3.2), and pods reach Squid as 10.250.0.112 (Step 8.1).
- The operator's pod label `app.kubernetes.io/name: cloudnative-pg` in namespace `cnpg-system` is the source that `pg-instances` admits on port 8000 (`networkpolicy.yaml:81-86`, Step 8.4).
- The `Cluster` CRD and the operator are what Steps 8.4 and 8.6 use.

**Re-run and removal:** The OCIRepository checks the tag once an hour, and the HelmRelease reconciles every 10 min. With nothing changed, both do nothing. If the folder were deleted from Git, `prune: true` would delete the HelmRelease, and Helm would uninstall the operator. The VM's teardown removes everything.

**Check it yourself:**
- `ssh be-1 sudo k3s kubectl -n flux-system get ocirepository/cnpg helmrelease/cnpg` shows both Ready (the release message names chart 0.29.2).
- `ssh be-1 sudo k3s kubectl -n cnpg-system get deploy` shows the operator `READY 1/1`.
- `ssh be-1 sudo k3s kubectl get crd clusters.postgresql.cnpg.io` exists.

**Watch out:**
- helm-controller creates CRDs on install but skips them on upgrade by default. A chart bump would leave the old CNPG CRDs in place unless the HelmRelease gets `upgrade.crds: CreateReplace`.
- Squid's address is typed three times: `group_vars/all.yml:3`, `cnpg/proxy-secret.yaml:9` and `monitoring/proxy-secret.yaml:9`.

### Step 8.4: lab-apps first apply

**Files:**
- `kubernetes/apps/kustomization.yaml`: root of `lab-apps`, which lists only `db`.
- `kubernetes/apps/db/kustomization.yaml`: puts everything in namespace `db`, lists the five manifests, and generates ConfigMap `postgres-init`.
- `kubernetes/apps/db/namespace.yml`: Namespace `db`.
- `kubernetes/apps/db/init.sql`: schema, table and the anonymous role, run once at initdb.
- `kubernetes/apps/db/postgres.yaml`: CNPG Cluster `pg`.
- `kubernetes/apps/db/postgrest.yaml`: PostgREST Deployment, ClusterIP Service and Traefik Ingress.
- `kubernetes/apps/db/postgrest-hpa.yaml`: HPA for PostgREST.
- `kubernetes/apps/db/networkpolicy.yaml`: default deny in `db` plus one allow per real connection.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `apps/kustomization.yaml` | `resources: [db]` (`kubernetes/apps/kustomization.yaml:1-4`) | `lab-apps` `path: ./kubernetes/apps` (`flux-sync.yaml:25`) | None |
| 2 | `db/kustomization.yaml`: namespace and resources | `namespace: db` sets the namespace on every object (`db/kustomization.yaml:3`). `resources`: `namespace.yml`, `postgres.yaml`, `postgrest.yaml`, `postgrest-hpa.yaml`, `networkpolicy.yaml` (`:4-9`) | kustomize build | None |
| 3 | `configMapGenerator` `postgres-init` | ConfigMap from `init.sql` with `disableNameSuffixHash: true` (`db/kustomization.yaml:10-15`), so the name stays `postgres-init` and the Cluster can name it | kustomize build | ConfigMap `db/postgres-init` |
| 4 | Namespace `db` | `namespace.yml:1-4`. Flux applies namespaces before everything else. This is the object `app_secrets` waits for (Step 8.5) | kustomize-controller | Namespace |
| 5 | `init.sql`: schema and table | `CREATE SCHEMA todo` (`init.sql:1`). `todo.items`: `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`, `name text NOT NULL`, `created_at timestamptz NOT NULL DEFAULT now()` (`:3-7`) | CNPG at initdb (Step 8.6) | Database `todo` |
| 6 | `init.sql`: role and grants | `CREATE ROLE api_anon NOLOGIN` (`:9-10`). `USAGE` on schema `todo`, `SELECT, INSERT, UPDATE, DELETE` on `todo.items`, `USAGE` on all sequences in `todo` (`:12-14`) | CNPG at initdb | Role `api_anon` |
| 7 | Cluster `db/pg`: instances and runtime | `instances: 2` (`postgres.yaml:6`). `smartShutdownTimeout: 10` instead of the default 180 s: PostgREST never disconnects, so a graceful delete stalled failover for 3 min (`:7`). `imageName` PostgreSQL 18.7 minimal, pinned by digest (`:8`). `storage.size: 1Gi`, default StorageClass `local-path` (`:9-10`). Requests 100m/256Mi, memory limit 512Mi (`:11-16`) | kustomize-controller -> CNPG operator | Cluster object |
| 8 | Cluster `pg`: `bootstrap.initdb` | `database: todo`, `owner: app`, `postInitApplicationSQLRefs` -> ConfigMap `postgres-init` key `init.sql` (`postgres.yaml:17-24`). CNPG runs that SQL once, as superuser, in database `todo`, right after initdb | CNPG operator | Step 8.6 |
| 9 | Cluster `pg`: `managed.roles` | Role `authenticator`: `ensure: present`, `login: true`, `inherit: false`, `inRoles: [api_anon]`, `passwordSecret: db-authenticator` (`postgres.yaml:25-34`). NOINHERIT plus membership means the role can only `SET ROLE api_anon`, which is what PostgREST does per request | CNPG operator | Step 8.6 |
| 10 | Deployment `db/postgrest`: pod basics | Selector and label `app: postgrest` (`postgrest.yaml:6-12`). Image `docker.io/postgrest/postgrest:v16.6`, pinned by digest (`:16`). Ports `http` 3000 and `admin` 3001 (`:17-21`). No `replicas` field, so the HPA owns the count and Flux does not fight it | kustomize-controller | Deployment |
| 11 | Deployment `postgrest`: env | `DB_USER` and `DB_PASSWORD` from Secret `db-authenticator` keys `username` and `password` (`postgrest.yaml:22-32`). `PGRST_DB_URI=postgres://$(DB_USER):$(DB_PASSWORD)@pg-rw:5432/todo?connect_timeout=5`. `$(VAR)` expands because both are defined above it. The timeout exists because a connect during failover hung for 136 s (`:33-34`). `PGRST_DB_SCHEMAS=todo`, `PGRST_DB_ANON_ROLE=api_anon`, `PGRST_ADMIN_SERVER_PORT=3001` (`:35-40`) | kubelet | Needs the Secret (Step 8.5) |
| 12 | Deployment `postgrest`: probe and resources | `readinessProbe` `GET /ready` on port `admin` (`postgrest.yaml:41-44`). It returns 200 only while PostgREST holds a database connection and its schema cache. Requests 50m/64Mi, memory limit 128Mi (`:45-50`). The 50m CPU request is what the HPA's 50 % is measured against | kubelet | None |
| 13 | Service `db/postgrest` | ClusterIP, port 3000 -> `targetPort: http`, selector `app: postgrest` (`postgrest.yaml:51-63`). The comment says why ClusterIP: Traefik owns be-1's port 8000 (`:52`) | Ingress backend | Service |
| 14 | Ingress `db/postgrest` | `ingressClassName: traefik`, no host rule, path `/` Prefix -> service `postgrest` port `http` (`postgrest.yaml:64-81`). fe-1 calls by IP, so there is no host (`:65`). Every request on be-1:8000 lands on PostgREST, and `/items` maps to table `todo.items` | k3s Traefik | Traefik route |
| 15 | HPA `db/postgrest`: target | `scaleTargetRef` Deployment `postgrest`, `minReplicas: 1`, `maxReplicas: 4`, CPU `averageUtilization: 50` (`postgrest-hpa.yaml:1-18`). It reads pod CPU from k3s's metrics-server | HPA controller | Deployment replicas |
| 16 | HPA `postgrest`: `behavior` | scaleUp: window 0, at most 2 pods or 100 % per 60 s, `selectPolicy: Max` (`postgrest-hpa.yaml:19-29`). scaleDown: window 300 s, then 1 pod per 60 s, `selectPolicy: Min` (`:31-37`) | HPA controller | None |
| 17 | NetworkPolicy `default-deny` | `podSelector: {}`, `policyTypes: [Ingress, Egress]`, no rules: nothing in `db` may talk (`networkpolicy.yaml:4-10`). The header notes that kube-router always allows traffic from the node itself, which covers kubelet probes and the API server calling webhooks (`:1-3`) | kube-router | Packet filter |
| 18 | NetworkPolicy `allow-dns` | Egress from every pod in `db` to kube-system pods `k8s-app: kube-dns` on UDP and TCP 53 (`networkpolicy.yaml:12-29`) | kube-router | Packet filter |
| 19 | NetworkPolicy `postgrest` | Pods `app: postgrest`. Ingress only from kube-system pods `app.kubernetes.io/name: traefik`, on TCP 3000. Egress only to pods `cnpg.io/cluster: pg` on TCP 5432 (`networkpolicy.yaml:31-56`) | kube-router | Packet filter |
| 20 | NetworkPolicy `pg-instances` | Pods `cnpg.io/cluster: pg` (instances and CNPG's initdb/join job pods, `:65`). Ingress 5432 from PostgREST and from other instances (`:68-76`). Ingress 8000 (instance manager status) from instances and from the CNPG operator in `cnpg-system` (`:77-88`). Egress 5432 and 8000 to instances (`:90-96`). Egress to `10.3.1.10/32` port 6443, the API server after kube-proxy turns 10.43.0.1:443 into 10.3.1.10:6443, needed by the instance manager to watch the Cluster for failover (`:97-101`) | kube-router | Packet filter |
| 21 | First apply on a fresh build | kustomize-controller applies all of it, namespace first. The health check (`wait: true`) then fails. CNPG can start building `pg`, but PostgREST pods sit in `CreateContainerConfigError`, because Secret `db-authenticator` does not exist yet. After the 5 min timeout `lab-apps` is not Ready and retries every 2 min (`retryInterval`). The namespace exists anyway, and that is what unblocks Step 8.5 | kustomize-controller | Namespace `db` and every object above |

**Why here:** `lab-apps` can apply only after `lab-cnpg` is Ready (Step 8.3). In real time this step happens while Ansible is still looping in `app_secrets`' namespace wait (Step 8.5). The first apply is meant to be incomplete: it creates namespace `db`, so Ansible can deliver the Secret into it.

**How it connects:**
- Namespace `db` -> the wait and the Secret in Step 8.5. `db-authenticator` (Step 8.5) -> rows 9 and 11.
- Cluster `pg` -> the CNPG operator (Step 8.6). The Service name `pg-rw` in row 11 is CNPG's convention for Cluster `pg`. It is not defined in the repo.
- Ingress -> Traefik on port 8000 (Step 8.1) -> hub filter (Step 7.5) -> `frontend/app.py:10` (Step 9.2). HPA -> metrics-server (Step 8.1) and the load demo (Step 11.3).
- NetworkPolicies depend on labels and addresses from other steps: `app.kubernetes.io/name: traefik` and `k8s-app: kube-dns` (k3s, Step 8.1), `cnpg.io/cluster: pg` and `app.kubernetes.io/name: cloudnative-pg` (CNPG, Steps 8.3 and 8.6), and 10.3.1.10 (`node-ip`, Step 8.1).
- `api_anon` is created in `init.sql:10` and named again in `postgres.yaml:32` and `postgrest.yaml:38`. The columns `id`, `name` and `created_at` are what `items.html` shows (Step 9.2).

**Re-run and removal:** Every commit gives the GitRepository a new revision, and kustomize-controller re-applies `lab-apps` with server-side apply. Unchanged objects stay unchanged. `prune: true` deletes objects that disappear from Git. Secret `db-authenticator` is not in Flux's inventory, so pruning never touches it. Editing `init.sql` later changes the ConfigMap only: the SQL already ran at initdb and will not run again.

**Check it yourself:**
- `ssh be-1 sudo k3s kubectl -n db get deploy,svc,ingress,hpa,networkpolicy,configmap` lists the objects above.
- `ssh be-1 sudo k3s kubectl -n flux-system get kustomization lab-apps` shows `READY True` and `Applied revision: main@sha1:<sha>` once Step 8.6 is done.
- `ssh fe-1 curl -s http://10.3.1.10:8000/items` returns a JSON array (empty `[]` on a fresh build).

**Watch out:**
- `init.sql` runs only when the cluster is first created. A schema change needs a migration run by hand, or a new cluster (which means a new be-1, Step 8.6).
- The `ipBlock` `10.3.1.10/32` must follow `node-ip`. If be-1's VPC address changes, CNPG instances lose the API, and failover breaks without any error at apply time.
- The custom scaleUp (2 pods or 100 % per 60 s) is slower than Kubernetes' default (4 pods or 100 % per 15 s). `selectPolicy: Min` on a single scaleDown policy changes nothing.
- PostgREST's admin port also serves `/metrics`, but nothing scrapes it, and `default-deny` would block a scraper anyway (Step 10.2).

> **Marked change (not applied), C10:** The comments at `kubernetes/apps/db/kustomization.yaml:9` and `kubernetes/apps/db/networkpolicy.yaml:1` cite B09.7 of the previous version of this file. See Appendix C.

### Step 8.5: app_secrets

**Files:**
- `ansible/roles/app_secrets/tasks/main.yml`: waits for namespace `db`, then writes the Secret manifest into k3s's folder.
- `ansible/roles/app_secrets/templates/db-authenticator.yaml.j2`: Secret `db/db-authenticator`, type `kubernetes.io/basic-auth`.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Task "Namespace db exists" | `k3s kubectl get namespace db` until it succeeds, up to 60 tries 10 s apart (about 10 min), `changed_when: false` (`tasks/main.yml:5-12`). The comments explain why: k3s applies a manifest file at once, so the namespace must exist first, and Flux creates it only after `lab-cnpg` is Ready, which on a fresh build means pulling a chart and an image through Squid (`:3-4`, `:10`) | play 3, role 3 | Reads the API |
| 2 | Template `db-authenticator.yaml.j2` | Secret `db-authenticator` in `db`, `type: kubernetes.io/basic-auth`, `stringData` `username: authenticator`, `password` from env `APP_DB_AUTHENTICATOR_PASSWORD` (`db-authenticator.yaml.j2:1-9`). basic-auth with `username`/`password` is the format CNPG's `passwordSecret` expects | row 3 | None |
| 3 | Task "App database authenticator secret" | Renders row 2 to `manifests/db-authenticator.yaml`, root 0600, `no_log` (`tasks/main.yml:14-21`). k3s applies it. PostgREST pods leave `CreateContainerConfigError` on the kubelet's next retry, and CNPG can now set the role's password | play 3 -> k3s | Secret `db/db-authenticator` |

**Why here:** The Secret has to land in a namespace that Flux creates (Step 8.4), and it has to land before the app can turn healthy (Step 8.6) and before `app_deployed` waits for that (Step 8.7). That is why the role order in `site.yml:20` is `app_secrets` then `app_deployed`, and why the comment there says so.

**How it connects:**
- The password is created once by `vault.app_db_passwords` (`services/vault/vault.py:116-131`, Step 3.7) as `secrets.token_urlsafe(24)`. `ansible.yml:28` reads it and `:44` passes it to the playbook (Step 7.1).
- `postgres.yaml:33-34` gives it to the managed role `authenticator`. `postgrest.yaml:22-32` reads both keys into `DB_USER`/`DB_PASSWORD` (Steps 8.4 and 8.6).
- The `username` value `authenticator` must equal the managed role's name (`postgres.yaml:27`).

**Re-run and removal:** The rendered file is the same on every run (the password never rotates), so the task reports no change, and k3s does nothing. Nothing removes the file. The Secret disappears with be-1.

**Check it yourself:**
- `ssh be-1 "sudo k3s kubectl -n db get secret db-authenticator -o jsonpath='{.type}{\"\n\"}'"` prints `kubernetes.io/basic-auth`. It does not print the password.
- `ssh be-1 sudo ls /var/lib/rancher/k3s/server/manifests` lists `db-authenticator.yaml` next to the Flux and Traefik files.

**Watch out:**
- The password is inserted into YAML unquoted. That is safe only because `token_urlsafe` emits `[A-Za-z0-9_-]`. The same applies to the hex Gitea token in `flux-git-auth.yaml.j2:9`.
- The password sits in clear text in a root-only file on be-1 and in a Kubernetes Secret. The cluster has no encryption at rest configured.

### Step 8.6: CNPG builds pg; PostgREST Ready (asynchronous)

**Files:**
- `kubernetes/apps/db/postgres.yaml` and `kubernetes/apps/db/postgrest.yaml`: introduced in Step 8.4. This step follows what the CNPG operator, the kubelet and Flux do with them. No new file.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Primary: PVC and initdb | The operator creates PVC `pg-1` (1 Gi, local-path on be-1's disk) and Job `pg-1-initdb`. initdb creates database `todo` owned by `app`, then runs `init.sql` from ConfigMap `postgres-init` (`postgres.yaml:17-24`, `init.sql:1-14`). The PostgreSQL image comes from ghcr.io through Squid | CNPG operator -> API, kubelet | PVC, Job, data files |
| 2 | Primary pod and Services | Pod `pg-1` starts as primary. The operator creates Services `pg-rw` (primary), `pg-ro` (replicas) and `pg-r` (any instance), and Secrets `pg-app` (the `app` owner's credentials, unused by the lab), `pg-ca`, `pg-server` and `pg-replication` | CNPG operator | Pod, Services, Secrets |
| 3 | Managed role `authenticator` | The operator creates the role with LOGIN, NOINHERIT and membership in `api_anon`, using the password from `db-authenticator` (`postgres.yaml:25-34`). Until Step 8.5 has delivered the Secret, it cannot do this and keeps retrying | CNPG operator -> PostgreSQL | Role in `todo` |
| 4 | Replica | Job `pg-2-join` clones the primary over 5432, then pod `pg-2` streams from it. The NetworkPolicy `pg-instances` allows exactly this traffic, plus the operator's status calls on 8000 and the instances' API watch on 10.3.1.10:6443 (`networkpolicy.yaml:58-101`) | CNPG operator | PVC `pg-2`, pod `pg-2` |
| 5 | PostgREST Ready | The pod gets `DB_USER`/`DB_PASSWORD`, connects to `pg-rw:5432/todo` as `authenticator`, loads its schema cache for `todo`, and `/ready` on 3001 returns 200 (`postgrest.yaml:22-44`). PostgREST retries the connection by itself until the role exists. The Deployment turns Available | kubelet -> PostgreSQL | Pod Ready |
| 6 | `lab-apps` healthy | On its current or next attempt (`retryInterval: 2m`, `timeout: 5m`), kustomize-controller finds every object healthy, including the Cluster's `Ready` condition. It sets Ready=True and `status.lastAppliedRevision: main@sha1:<sha>` (`flux-sync.yaml:22-27`). That field is set only after the apply and the health checks both succeed | kustomize-controller | Kustomization status |
| 7 | The API answers | `be-1:8000` -> ServiceLB -> Traefik -> Ingress `postgrest` -> PostgREST pod :3000 -> `pg-rw` -> `SET ROLE api_anon` -> `todo.items` (`traefik-config.yaml:12`, `postgrest.yaml:64-81`, `init.sql:12-14`). The hop-by-hop path with every filter is Step 11.1 | Traefik, PostgREST | None |

**Why here:** Nothing in this step is run by Ansible. It is what happens inside be-1 between Step 8.5 (the Secret lands) and Step 8.7 (Ansible checks the result). It needs the Secret, the local-path provisioner (Step 8.1), the CNPG operator (Step 8.3), and image pulls from ghcr.io and docker.io through Squid.

**How it connects:**
- `lastAppliedRevision` is exactly what `app_deployed` waits for (Step 8.7).
- The working API is what the frontend's HTTPS check calls through the tunnel (Step 9.1), and what the HPA demo loads (Step 11.3).
- The comments at `postgres.yaml:7` and `postgrest.yaml:34` come from failover tests. Deleting the primary pod by hand makes CNPG promote `pg-2`, and `pg-rw` then points at the new primary.

**Re-run and removal:** A later run rebuilds nothing. The Cluster keeps its data on the PVCs, initdb never runs again, and PostgREST pods are replaced only when their spec changes. All data lives on be-1's own disk (local-path). `teardown`, or any change that rebuilds be-1, deletes every row (Steps 12.1 and 12.3). No backup is configured.

**Check it yourself:**
- `ssh be-1 sudo k3s kubectl -n db get cluster pg` shows `INSTANCES 2`, `READY 2`, `STATUS Cluster in healthy state`.
- `ssh be-1 sudo k3s kubectl -n db get pods -o wide` shows `pg-1`, `pg-2` and at least one `postgrest-*` pod Running and Ready.
- `ssh fe-1 "curl -s -o /dev/null -w '%{http_code}\n' http://10.3.1.10:8000/items"` prints `200`. The request crosses the tunnel, Traefik, PostgREST and `pg-rw`.

**Watch out:**
- Both instances run on the one node, be-1. This is high availability against a pod failure, not against losing the VM.
- Secret `pg-app` holds a working password for the database owner `app`. The lab never uses it, but anyone with Secret read access in `db` has it.

### Step 8.7: app_deployed

**Files:**
- `ansible/roles/app_deployed/tasks/main.yml`: the pipeline gate that waits until Flux has applied this commit and found it healthy.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Task "Flux applied this commit to the app" | `k3s kubectl -n flux-system wait kustomization/lab-apps --for=jsonpath={.status.lastAppliedRevision}=main@sha1:<GITHUB_SHA> --timeout=10s`, retried 45 times, 10 s apart (`tasks/main.yml:4-14`). Each try takes up to 20 s (a 10 s delay plus up to 10 s of kubectl timeout), so the gate gives up after 7.5-15 min. The comment sizes it for a fresh build: a Flux retry after the Secret lands, the image pull, initdb and the replica clone (`:12`) | play 3, role 4 | Reads the API |
| 2 | End of play 3: pending handlers | If `config.yaml` changed in Step 8.1 (always on a fresh build), handler `Restart k3s` runs now (`ansible/roles/k3s/handlers/main.yml:1-4`) | Ansible | Restarts k3s |

**Why here:** The gate is last in play 3, after `app_secrets` (`site.yml:20`), because the app cannot turn healthy without the Secret. It comes before play 4, because the frontend's final check calls the API (Step 9.1). Play 3 has only one host, so if this task fails, the playbook stops and play 4 never runs.

**How it connects:**
- `GITHUB_SHA` is the same value that tagged the image (`.gitea/workflows/image.yml:15`, Step 5.6) and that names the image in the Quadlet (`ansible/roles/frontend/defaults/main.yml:1`, Step 9.1). One commit flows through the image, the cluster and the frontend.
- The GitRepository fetches every minute (`flux-sync.yaml:7`), so even a commit that does not touch `kubernetes/` changes `lastAppliedRevision`. The wait then passes within about 1-2 min.
- `lab-cnpg` is covered indirectly through `dependsOn`. `lab-monitoring` is not checked at all (Step 10.2).

**Re-run and removal:** It is read-only and has nothing to remove. A re-dispatch of the same commit passes at once, because the revision already matches.

**Check it yourself:**
- `ssh be-1 "sudo k3s kubectl -n flux-system get kustomization lab-apps -o jsonpath='{.status.lastAppliedRevision}{\"\n\"}'"` prints `main@sha1:` followed by the same hash as `git rev-parse HEAD` after a green run.
- The `configure` job log on the Gitea run page shows the task `Flux applied this commit to the app` as `ok`.

**Watch out:**
- If a newer commit reaches `main` while this run is in its ansible job, Flux applies the newer commit. This run's exact-revision wait then times out after about 15 min, although the app is healthy. `deploy.yml:8-10` only queues the second run.
- Run outside the pipeline, `GITHUB_SHA` is empty, so the task waits for `main@sha1:` and always times out.

### Phase 8 summary: Kubernetes object inventory

Who applies what, after Phase 8 and Step 10.2. It names objects from every step of this phase and from Step 10.2, so read it as a recap.

Five appliers write to this cluster. The k3s manifests folder applies any file Ansible drops there. Flux applies the folders under `kubernetes/`. helm-controller installs the two charts. The CNPG operator creates what a `Cluster` needs. k3s also installs its own packaged components. Flux does not manage its own objects: they come from the manifests folder, so a change to `ansible/roles/fluxcd/files/flux-sync.yaml` lands only when the fluxcd role runs again.

| Object | Namespace | Applied by | File |
|---|---|---|---|
| HelmChartConfig `traefik` | kube-system | k3s manifests folder (k3s role, Step 8.1) | `ansible/roles/k3s/files/traefik-config.yaml` |
| Namespace `flux-system`, the Flux CRDs (GitRepository, OCIRepository, Kustomization, HelmRelease and the rest), RBAC, Deployments `source-controller`, `kustomize-controller`, `helm-controller`, Service `source-controller`, and the NetworkPolicies `flux install` adds by default | flux-system, cluster-wide | k3s manifests folder (fluxcd role, Step 8.2) | Rendered by `flux install --export` v2.10.0 into `manifests/flux.yaml` (`ansible/roles/fluxcd/tasks/main.yml:30-44`). Not in the repo |
| Secret `flux-git-auth` | flux-system | k3s manifests folder (Step 8.2) | `ansible/roles/fluxcd/templates/flux-git-auth.yaml.j2` |
| GitRepository `lab-repo` | flux-system | k3s manifests folder (Step 8.2) | `ansible/roles/fluxcd/files/flux-sync.yaml:1-13` |
| Kustomizations `lab-apps`, `lab-monitoring`, `lab-cnpg` | flux-system | k3s manifests folder (Step 8.2) | `flux-sync.yaml:16-32`, `:36-50`, `:54-68` |
| Secret `db-authenticator` | db | k3s manifests folder (app_secrets role, Step 8.5) | `ansible/roles/app_secrets/templates/db-authenticator.yaml.j2` |
| Deployment `coredns`, Service `kube-dns` (label `k8s-app: kube-dns`) | kube-system | k3s packaged component | None in the repo |
| HelmChart `traefik` -> Deployment and Service `traefik` (LoadBalancer, port 8000), pods labelled `app.kubernetes.io/name: traefik`, IngressClass `traefik` | kube-system | k3s Helm controller, with our HelmChartConfig merged in | None, except `traefik-config.yaml` |
| DaemonSet `svclb-traefik-*` (hostPort 8000) | kube-system | k3s ServiceLB | None |
| Deployment `metrics-server` | kube-system | k3s packaged component | None |
| Deployment `local-path-provisioner`, StorageClass `local-path` (default) | kube-system, cluster-wide | k3s packaged component | None |
| Secret `cnpg-proxy`, OCIRepository `cnpg`, HelmRelease `cnpg` | flux-system | Flux Kustomization `lab-cnpg` (Step 8.3) | `kubernetes/cnpg/proxy-secret.yaml`, `ocirepository.yaml`, `helmrelease.yaml` |
| Namespace `cnpg-system`, the CNPG CRDs (`clusters.postgresql.cnpg.io` and others), the operator Deployment (pods labelled `app.kubernetes.io/name: cloudnative-pg`), its webhook Service and webhook configurations, RBAC | cnpg-system, cluster-wide | Helm (helm-controller, release `cnpg`) | Chart `cloudnative-pg` 0.29.2. Not in the repo |
| Namespace `db` | cluster-wide | Flux Kustomization `lab-apps` (Step 8.4) | `kubernetes/apps/db/namespace.yml` |
| ConfigMap `postgres-init` (key `init.sql`) | db | `lab-apps` (configMapGenerator) | `kubernetes/apps/db/kustomization.yaml:10-15`, `init.sql` |
| Cluster `pg` | db | `lab-apps` | `kubernetes/apps/db/postgres.yaml` |
| Deployment, Service and Ingress `postgrest` | db | `lab-apps` | `kubernetes/apps/db/postgrest.yaml` |
| HorizontalPodAutoscaler `postgrest` | db | `lab-apps` | `kubernetes/apps/db/postgrest-hpa.yaml` |
| NetworkPolicies `default-deny`, `allow-dns`, `postgrest`, `pg-instances` | db | `lab-apps` | `kubernetes/apps/db/networkpolicy.yaml` |
| Pods `pg-1`, `pg-2`, PVCs `pg-1`, `pg-2`, Jobs `pg-1-initdb`, `pg-2-join` | db | CNPG operator (Step 8.6) | None (derived from `postgres.yaml`) |
| Services `pg-rw`, `pg-ro`, `pg-r` | db | CNPG operator | None |
| Secrets `pg-app` (owner `app`, unused by the lab), `pg-ca`, `pg-server`, `pg-replication` | db | CNPG operator | None |
| PostgreSQL role `authenticator` (inside the database, not a Kubernetes object) | db (database `todo`) | CNPG managed roles | `postgres.yaml:25-34` |
| ReplicaSet and pods `postgrest-*` (1 to 4) | db | Deployment controller, scaled by the HPA | `postgrest.yaml`, `postgrest-hpa.yaml` |
| Secret `flux-proxy`, OCIRepository `k8s-monitoring`, HelmRelease `k8s-monitoring` | flux-system | Flux Kustomization `lab-monitoring` (Step 10.2) | `kubernetes/monitoring/proxy-secret.yaml`, `ocirepository.yaml`, `helmrelease.yaml` |
| Namespace `monitoring`, the Alloy operator, one Alloy collector, kube-state-metrics, RBAC | monitoring | Helm (helm-controller, release `k8s-monitoring`) | Chart `k8s-monitoring` 4.6.1. Not in the repo |

The names of the CNPG children and the k3s components follow those projects' conventions. They are not written anywhere in the repo, but several manifests rely on them (labels and `pg-rw`; see Steps 8.1, 8.4 and 8.6).

## Phase 9: App edge on fe-1

Phase 9 puts the user-facing web app on fe-1. It runs as play 4 of `site.yml`, `hosts: frontend`, role `[frontend]` (`site.yml:23-27`), in the same `configure` job, right after play 3 has proven the API healthy. The role installs Podman, writes the `app-edge` certificate, loads the image the `image` job built for this commit, and runs it as a systemd service through a Quadlet file. Its last task fetches the home page, which calls the API through the tunnel. That makes it the pipeline's only end-to-end test of the request path. After the phase, `https://app.lab.test` works for any client that resolves the name to the host's LAN IP and trusts the lab CA. vmfw DNATs the host's port 443 to fe-1 (Step 2.6), gunicorn terminates TLS, and Flask calls `http://10.3.1.10:8000/items` through tun-1.

**Needs from earlier phases:**
- `/var/lib/lab/images/frontend.tar` on the host, holding `localhost/frontend:<GITHUB_SHA>` (`.gitea/workflows/image.yml:17-20`, Step 5.6). The folder comes from the runner unit's `StateDirectory` (`services/gitea/runner/files/lab-runner.service:12`, Step 4.7).
- `APP_EDGE_CERT` and `APP_EDGE_KEY`: the `app-edge` leaf (SAN `app.lab.test`, `lib/config.py:38`, Step 3.3), copied to Vault by `vault.app_edge_cert` (`services/vault/vault.py:134-146`, Step 3.7), and read by `ansible.yml:29-30,45-46` (Step 7.1).
- The apt proxy on fe-1 (`ansible/roles/common/tasks/main.yml:30-38`, Step 7.4).
- The tunnel fe-1 -> tun-1 -> be-1, the spoke route `10.3.0.0/16 dev wg0 src 10.1.1.10` (`ansible/roles/wireguard/templates/wg.conf.j2:10`, `ansible/host_vars/fe-1.yml:7-10`), and the hub filter that allows only 10.1.1.10 -> 10.3.1.10 tcp 8000 (`hub-forward.nft:13`) (Step 7.5).
- A healthy API at this commit (Step 8.7).
- For outside clients: CoreDNS `app.lab.test` -> HOST_IP (`Corefile:6`, Step 3.1) and the vmfw DNAT to 198.51.100.11:443 (`nftables-vmfw.nft:121,128,150`, Step 2.6).

**Hands on:**
- `frontend.service` on fe-1, generated from `/etc/containers/systemd/frontend.container`. Container `frontend`, host network, gunicorn with TLS on `0.0.0.0:443`.
- `/etc/frontend/tls/tls.crt` (0644) and `tls.key` (uid 65532, 0600), mounted read-only at `/etc/app/tls`.
- The image `localhost/frontend:<sha>` in fe-1's Podman store, and its tar at `/var/lib/frontend/frontend.tar`.
- `/etc/sysctl.d/90-lab-unprivileged-ports.conf`: any non-root process on fe-1 may bind ports 443 and up.
- The DNAT target 198.51.100.11:443 now answers, so `https://app.lab.test` works (request path in Step 11.1).

### Step 9.1: frontend role

**Files:**
- `ansible/roles/frontend/defaults/main.yml`: `frontend_tag`, the commit SHA.
- `ansible/roles/frontend/tasks/main.yml`: Podman, the port sysctl, TLS files, image copy and load, the Quadlet file, the start, and the HTTPS check.
- `ansible/roles/frontend/handlers/main.yml`: `Apply sysctl` and `Restart frontend`, in that order.
- `ansible/roles/frontend/templates/frontend.container.j2`: the Quadlet unit.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `frontend_tag` | `{{ lookup('env', 'GITHUB_SHA') }}` (`defaults/main.yml:1`). This is the same SHA that `image.yml:15` tagged the image with | row 9 | None |
| 2 | Task "Podman is installed" | `apt podman`, `state: present` (`tasks/main.yml:3-6`). Ubuntu's package brings the Quadlet generator | play 4 -> apt through Squid | Package |
| 3 | Task "Non-root processes may bind 443 (the image runs as uid 65532)" | `/etc/sysctl.d/90-lab-unprivileged-ports.conf`: `net.ipv4.ip_unprivileged_port_start = 443`, and notifies `Apply sysctl` (`tasks/main.yml:8-16`). The image runs as uid 65532 (`frontend/Dockerfile:13`) on the host network, so the setting must hold in fe-1's own network namespace | play 4 -> handler (row 12) | sysctl file |
| 4 | Task "Frontend directories exist" | `/etc/frontend/tls` 0755, `/var/lib/frontend` 0700, `/etc/containers/systemd` 0755, all root (`tasks/main.yml:18-28`) | play 4 | Directories |
| 5 | Task "app-edge certificate is installed" | Env `APP_EDGE_CERT` -> `/etc/frontend/tls/tls.crt`, root 0644, and notifies `Restart frontend` (`tasks/main.yml:30-37`) | play 4 -> handler (row 13) | File |
| 6 | Task "app-edge key is installed, readable only by the container's user" | Env `APP_EDGE_KEY` -> `/etc/frontend/tls/tls.key`, owner and group 65532, 0600, `no_log`, and notifies `Restart frontend` (`tasks/main.yml:39-47`). Rootful Podman without a user namespace keeps uid 65532 the same inside the container, so only the app's user can read the key | play 4 -> handler | File |
| 7 | Task "Image tarball from the pipeline is on fe-1" | `copy` from the controller's `/var/lib/lab/images/frontend.tar` to `/var/lib/frontend/frontend.tar`, root 0600, registered as `frontend_tar` (`tasks/main.yml:49-56`). `copy` compares checksums, so it reports a change only for a new tar | play 4 | File |
| 8 | Task "Image is loaded into podman" | `podman load -i /var/lib/frontend/frontend.tar` `when: frontend_tar.changed` (`tasks/main.yml:58-60`) | play 4 -> podman | fe-1 image store |
| 9 | Template `frontend.container.j2` | `[Unit]`: description, `Wants`/`After=network-online.target` (`:1-4`). `[Container]`: `Image=localhost/frontend:{{ frontend_tag }}`, `ContainerName=frontend`, `Network=host`, `Volume=/etc/frontend/tls:/etc/app/tls:ro` (`:6-10`). `[Service]`: `Restart=always` (`:12-13`). `[Install]`: `WantedBy=multi-user.target` (`:15-16`), which the generator turns into a start at boot. `Network=host` is load-bearing: the API call leaves through fe-1's own route with source 10.1.1.10, which the hub filter requires | row 10 | None |
| 10 | Task "Quadlet unit runs this commit's image" | Renders row 9 to `/etc/containers/systemd/frontend.container` 0644 and notifies `Restart frontend` (`tasks/main.yml:62-69`). The tag is the SHA, so this file changes on every new commit | play 4 -> handler | Quadlet file |
| 11 | Task "Pending sysctl and restarts are applied" | `meta: flush_handlers` (`tasks/main.yml:71-72`). Handlers run in the order they are defined, so the sysctl is live before the container restarts | play 4 | Runs rows 12-13 |
| 12 | Handler `Apply sysctl` | `sysctl -p /etc/sysctl.d/90-lab-unprivileged-ports.conf` (`handlers/main.yml:1-2`) | row 11 | Kernel setting |
| 13 | Handler `Restart frontend` | `systemd_service frontend restarted` with `daemon_reload: true` (`handlers/main.yml:4-8`). The reload makes the Quadlet generator write `frontend.service` from row 10. On a fresh build this restart is the first start | row 11 | `frontend.service`, container `frontend` |
| 14 | Task "Frontend service is running" | `systemd_service frontend started`, `daemon_reload: true` (`tasks/main.yml:74-78`). It covers a run where no handler fired but the service is stopped. There is no `enabled:`, because a generated unit cannot be enabled. The `[Install]` section does that job | play 4 | `frontend.service` |
| 15 | Task "Frontend answers over HTTPS (and reaches the API)" | `uri https://127.0.0.1/`, `validate_certs: false`, until the status is 200, retried 12 times 5 s apart (about 1 min) (`tasks/main.yml:80-87`). `/` calls PostgREST, and an API failure renders a 502 page (`frontend/app.py:28-30,51-54`). A 200 therefore proves fe-1 -> wg0 -> tun-1 hub filter -> be-1 Traefik -> PostgREST -> PostgreSQL | play 4 -> gunicorn -> API | None |

**Why here:** The role needs the tar from the `image` job (Step 5.6), the TLS material from Vault (Step 7.1), the apt proxy (Step 7.4), and, for its last task, the tunnels (Step 7.5) and a healthy API (Step 8.7). That is why play 4 comes after play 3. Inside the role, the sysctl and the files come before the flush, so the first start already has the port right, the certificate and the image.

**How it connects:**
- `/var/lib/lab/images/frontend.tar` comes from `image.yml:18-20` (Step 5.6). `frontend_tag` = `GITHUB_SHA` = the revision `app_deployed` waited for (Step 8.7).
- `tls.crt` and `tls.key` are the `app-edge` pair from `state/pki` (Step 3.3) via Vault (Step 3.7). gunicorn reads them at `/etc/app/tls` (`frontend/Dockerfile:14`, Step 9.2).
- `Network=host` plus the spoke route `src 10.1.1.10` (Step 7.5) is the reason the hub filter's `ip saddr 10.1.1.10` matches (`hub-forward.nft:13`).
- 198.51.100.11:443 is the target of vmfw's DNAT for LAN clients and the host's own browser (`nftables-vmfw.nft:121,128,150`, Step 2.6). The full path is Step 11.1.

**Re-run and removal:** On a re-run with a new commit, the tar differs, so it is copied and loaded, and the Quadlet file changes. The service restarts once on the new image, and the uri check runs again. A re-run of the same commit can still copy a new tar (the `image` job saves it again), which triggers a `podman load` but no restart. Old images are never removed from fe-1, whose disk is 10 GiB (`terraform/compute.tf:7,51`). There is no removal task: fe-1 goes with `teardown` (Step 12.1).

**Check it yourself:**
- From the repo root on the host: `curl -s -o /dev/null -w '%{http_code}\n' --cacert state/pki/ca.pem https://app.lab.test/` prints `200`. The host's own request is DNATed by vmfw's output chain (`nftables-vmfw.nft:128`).
- `ssh fe-1 systemctl is-active frontend` prints `active`. `ssh fe-1 "sudo podman ps --format '{{.Names}} {{.Image}}'"` shows `frontend localhost/frontend:<sha>`.
- `ssh fe-1 systemctl cat frontend` shows the generated unit, with a `podman run` line that includes `--network host`.

**Watch out:**
- The uri check uses `validate_certs: false` and 127.0.0.1, so it does not prove that the certificate matches `app.lab.test`. The first curl above does.
- `Network=host` must stay. With a bridge network and a published port, the API call would leave with a NATed source that the hub filter drops.
- The two `Apply sysctl` handlers in `frontend` and `wireguard` share a name. That is fine only while the roles stay in separate plays (`site.yml:14,26`).
- Run outside the pipeline, `frontend_tag` is empty, and the Quadlet names an image that does not exist.

### Step 9.2: The app at runtime (frontend source)

**Files:**
- `frontend/app.py`: the Flask app. Its routes call PostgREST.
- `frontend/templates/items.html`: the single page.
- `frontend/requirements.txt`: the runtime Python packages inside the image.
- `frontend/Dockerfile`: decides what runs on fe-1 (user, port, TLS paths).
- All four are introduced in Step 5.6, which builds them into the image. This step reads them for what the running container does with each request.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Dockerfile build stage | Built in Step 5.6 (row 2): the `-dev` image runs `pip install --target /app/packages` (`Dockerfile:1-5`). Its only runtime effect is the package folder it hands on | `podman build` (Step 5.6) | None on fe-1 |
| 2 | Dockerfile runtime stage and `ENTRYPOINT` | Minimal Chainguard Python image (no shell, no pip), `PYTHONPATH=/app/packages`, `USER 65532` (`Dockerfile:7-13`). It runs `python -m gunicorn --bind 0.0.0.0:443 --workers 2 --access-logfile - --certfile /etc/app/tls/tls.crt --keyfile /etc/app/tls/tls.key app:app` (`:14`). With the host network it listens on every fe-1 address. TLS ends here, and the access log goes to stdout | Quadlet `frontend.service` (Step 9.1) | Binds :443, reads `/etc/app/tls` |
| 3 | `requirements.txt` | The eight `==` pins listed in Step 5.6 (row 1): Flask 3.1.3 and its dependencies, plus gunicorn 27.0.1 (`requirements.txt:1-8`). At run time they are what gunicorn and the app import from `/app/packages` | build stage | None |
| 4 | Module header, `API`, `app` | Docstring (`app.py:1`), stdlib `json`, `os`, `urllib` imports (`:3-6`), Flask imports (`:8`). `API = os.environ.get("API_URL", "http://10.3.1.10:8000") + "/items"` (`:10`). The Quadlet sets no environment, so the default is what runs. `app = Flask(__name__)` (`:12`) is the `app:app` gunicorn loads | gunicorn worker import | None |
| 5 | `api(method: str, query: str = "", body: dict \| None = None) -> list \| None` | Builds a `urllib` request to `API + query` with an optional JSON body and `Content-Type: application/json`, a 5 s timeout, and returns the decoded JSON, or None for an empty body (`app.py:15-25`). PostgREST answers GET with a JSON array, and POST, PATCH and DELETE with 201 or 204 and no body (no `Prefer` header is sent). A non-2xx raises `HTTPError`, a subclass of `URLError` | the four routes -> PostgREST through wg0 | TCP to 10.3.1.10:8000 |
| 6 | `index()` | `GET /` renders `items.html` with `api("GET", "?order=id")`, which PostgREST turns into `SELECT ... ORDER BY id` (`app.py:28-30`) | browser, role check (Step 9.1) | Reads `todo.items` |
| 7 | `add()` | `POST /add`: `api("POST", body={"name": request.form["name"]})`, then a 303 redirect to `/` (`app.py:33-36`). The database fills in `id` and `created_at` (`init.sql:4,6`) | form at `items.html:20-23` | Inserts a row |
| 8 | `update(item_id: int)` | `POST /update/<int>`: `api("PATCH", "?id=eq.<id>", {"name": ...})`, then 303 (`app.py:39-42`) | form at `items.html:28-31` | Updates a row |
| 9 | `delete(item_id: int)` | `POST /delete/<int>`: `api("DELETE", "?id=eq.<id>")`, then 303 (`app.py:45-48`) | form at `items.html:33-35` | Deletes a row |
| 10 | `api_error(err: Exception)` | Registered for `urllib.error.URLError` and `TimeoutError`. It renders the page with no items and `API error: <err>`, status 502 (`app.py:51-54`). An API outage becomes a readable page, not a traceback, and the role's uri check sees a non-200 | Flask error handling | None |
| 11 | `items.html` | `<head>` with inline CSS (`:1-17`), the add form (`:20-23`), the error line (`:24`), one `<li>` per item with an update form, `created_at` cut to minutes and labelled UTC, and a delete form (`:25-36`), and `No items yet.` for an empty list (`:37-39`). The columns `id`, `name` and `created_at` are those of `todo.items` (`kubernetes/apps/db/init.sql:3-7`). Jinja autoescapes `.html` templates, so item names cannot inject markup | `render_template` | None |

**Why here:** The frontend role (Step 9.1) only starts the container. These four files decide what each request does at run time, so they get their own step right after it. The build side is Step 5.6, and the full network path is Step 11.1.

**How it connects:**
- `API` -> route `10.3.0.0/16 dev wg0 src 10.1.1.10` (Step 7.5) -> hub filter -> be-1:8000 Traefik (Step 8.1) -> Ingress -> PostgREST (Step 8.4) -> `todo.items` as `api_anon` (Step 8.6).
- The TLS paths in the `ENTRYPOINT` match the Quadlet's `Volume=` and the files the role writes (Step 9.1). uid 65532 matches the key's owner (Step 9.1, row 6) and needs the port sysctl (row 3 there).
- `index()` is what the role's uri check requests (Step 9.1, row 15), and what a LAN browser gets through the DNAT (Step 11.1).

**Re-run and removal:** The container keeps no state, since every row lives in PostgreSQL. Each new commit brings a new image tag, and the restart replaces the container.

**Check it yourself:**
- `curl -s --cacert state/pki/ca.pem https://app.lab.test/ | grep -o 'Lab Todo' | head -1` from the repo root prints `Lab Todo`.
- `ssh fe-1 sudo podman logs --tail 5 frontend` shows gunicorn's access log lines, such as the role's `GET /` probes.

**Watch out:**
- The app has no login and no CSRF protection. Anyone who can reach `app.lab.test` can change the list.
- systemd restarts gunicorn if it dies, but nothing restarts it for API trouble, which only shows as 502 pages. The only probe is the role's one-time check.
- `API_URL` is never set anywhere in the lab, so `10.3.1.10:8000` in `app.py:10` is one more hand-copied value (Step 8.1, Watch out).

## Phase 10: Observability

Phase 10 sends telemetry from every machine to the host's Prometheus and Loki and lets the operator read it in Grafana. It has three kinds of agent, started at three different times. The host's own Alloy is part of `monitoring.up` (`platform_up` step 14, Steps 3.9-3.10). The k8s-monitoring chart on be-1 starts from Flux Kustomization `lab-monitoring` as soon as `flux-sync.yaml` lands in Step 8.2, in parallel with `lab-cnpg`. Nothing in the pipeline waits for it. Alloy on the three VMs is installed by play 5 of `site.yml`, `hosts: all`, role `[alloy]` (`site.yml:29-33`), the last play of the `configure` job. Nothing in the code forces that play to be last, but placing it there means a monitoring failure cannot block the app. After the phase, Grafana at `https://grafana.lab.test` (host only) shows node metrics and journals for `host`, `fe-1`, `tun-1` and `be-1`, plus cluster metrics, pod logs and events from k3s. Everything goes through the same two POST-only Traefik routes.

**Needs from earlier phases:**
- Prometheus with `--web.enable-remote-write-receiver` and Loki on `lab-backend`, and Grafana with both datasources (`services/monitoring/compose.yaml:4-49`, Step 3.9).
- Traefik routers `prometheus-write` and `loki-push` with allowlist `vms-and-host` (`services/traefik/dynamic/prometheus.yml:3-8`, `loki.yml:3-8`, `allowlists.yml:8-10`, Step 3.8).
- CoreDNS answering `prometheus.lab.test` and `loki.lab.test` with 10.250.0.1 (`Corefile:5`, Step 3.1).
- vmfw's forward exception for 10.250.0.110-112 -> 10.250.0.1:443 (`nftables-vmfw.nft:155`, Step 2.6).
- The lab CA in each VM's trust store through cloud-init `ca_certs` (`terraform/cloud-init/user-data.yaml.tftpl:16-19`, Step 6.6). The k8s collector on be-1 does not use that store: it gets the CA from Secret `flux-git-auth` key `ca.crt` (Step 8.2).
- Host internet for the Alloy `.deb` (github.com). be-1's Squid access for the chart and its images (Step 3.2).
- helm-controller in Flux (Step 8.2, row 6).

**Hands on:**
- `alloy.service` on fe-1, tun-1 and be-1, capped at 200 MB, pushing node metrics (`instance=<vm>`, `job=node`) and the journal (`instance`, `unit`, `service_name`, `level`).
- `/var/lib/lab/downloads/alloy-1.22.0-1.amd64.deb` on the host.
- Namespace `monitoring` on be-1 with one Alloy collector and kube-state-metrics, pushing kubelet, cAdvisor and kube-state-metrics series, pod logs and cluster events, tagged with cluster name `lab`.
- In Grafana: the dashboards "Node Exporter Full" and "Kubernetes / Views / Namespaces", and Explore on Prometheus and Loki.

### Step 10.1: VM Alloy (play 5)

**Files:**
- `ansible/roles/alloy/defaults/main.yml`: the Alloy version, the `.deb` name and its sha256, and the download folder on the host.
- `ansible/roles/alloy/tasks/main.yml`: downloads once on the host, installs on each VM, writes the config and a memory cap, and starts the agent.
- `ansible/roles/alloy/handlers/main.yml`: `Restart alloy`.
- `ansible/roles/alloy/templates/config.alloy.j2`: the agent pipeline (node exporter and journal, both pushed over HTTPS).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Defaults | `alloy_version: "1.22.0"`, `alloy_deb: alloy-1.22.0-1.amd64.deb`, `alloy_deb_sha256`, `alloy_download_dir: /var/lib/lab/downloads` "on the host (the Ansible controller)" (`defaults/main.yml:1-4`) | rows 2-5 | None |
| 2 | Task "Download directory exists on the host" | `/var/lib/lab/downloads` 0700, `delegate_to: localhost`, `run_once`, `become: false` (`tasks/main.yml:4-11`). The runner runs jobs as root, so this is a root-owned folder on the host | play 5 (once) | Host directory |
| 3 | Task "Alloy package is downloaded on the host (sha256 pinned)" | `get_url` from GitHub releases with `checksum: sha256:...`, on the host, once (`tasks/main.yml:13-21`). The comment says why: the VMs never reach GitHub, because Squid allows that only for be-1's k3s (`:2`) | play 5 -> github.com from the host | `/var/lib/lab/downloads/<deb>` |
| 4 | Task "Alloy package is on the VM" | `copy` to `/var/cache/<deb>`, root 0644 (`tasks/main.yml:23-29`) | play 5, every VM | File |
| 5 | Task "Alloy is installed (user alloy, in groups adm and systemd-journal)" | `apt deb: /var/cache/<deb>` (`tasks/main.yml:31-33`). Any dependencies come through the apt proxy (Step 7.4). The package creates the user `alloy` in groups `adm` and `systemd-journal` (task name), so the agent can read the journal, and it installs `alloy.service` | play 5 -> apt | Package, user, unit |
| 6 | `config.alloy.j2`: metrics | `prometheus.exporter.unix "node"` (`config.alloy.j2:6`). `discovery.relabel "node"` sets `instance = {{ inventory_hostname }}` and `job = node` (`:8-20`). `prometheus.scrape "node"` every 15 s (`:22-26`). `prometheus.remote_write "hub"` to `https://prometheus.lab.test/api/v1/write` (`:28-32`). There is no `tls_config`: the VM trusts the lab CA through cloud-init (comment `:2`) | Alloy | Pushes metrics |
| 7 | `config.alloy.j2`: logs | `loki.relabel "journal"` (with `forward_to = []`, so it is used only for its rules) maps `__journal__systemd_unit` to `unit` and to `service_name`, and `__journal_priority_keyword` to `level` (`:36-53`). `loki.source.journal "vm"`: `max_age 12h`, label `instance`, those rules (`:55-60`). `loki.write "hub"` to `https://loki.lab.test/loki/api/v1/push` (`:62-66`) | Alloy | Reads the journal, pushes logs |
| 8 | Task "Agent config names this VM" | Renders rows 6-7 to `/etc/alloy/config.alloy` 0644, notifies `Restart alloy` (`tasks/main.yml:35-42`) | play 5 -> handler | File |
| 9 | Task "Drop-in directory for the alloy unit exists" | `/etc/systemd/system/alloy.service.d` 0755 (`tasks/main.yml:44-50`) | play 5 | Directory |
| 10 | Task "Agent memory is capped (tun-1 has 512 MB)" | Drop-in `lab.conf`: `[Service] MemoryMax=200M`, notifies `Restart alloy` (`tasks/main.yml:52-61`) | play 5 -> handler | Drop-in |
| 11 | Task "Pending restarts are applied" and handler `Restart alloy` | `meta: flush_handlers` (`tasks/main.yml:63-64`) runs `systemd_service alloy restarted` with `daemon_reload: true` (`handlers/main.yml:1-5`). The reload picks up the drop-in | play 5 | Restarts `alloy.service` |
| 12 | Task "Alloy is running and starts on boot" | `state: started`, `enabled: true` (`tasks/main.yml:66-70`) | play 5 | Enables the unit |

**Why here:** The role needs only things that exist before the pipeline: the host monitoring stack (Steps 3.9-3.10), the Traefik push routes (Step 3.8), vmfw's exception (Step 2.6) and the CA in the VM trust store (Step 6.6). From plays 1-2 it needs only the apt proxy. It runs last by choice: if Alloy breaks, the app has already been deployed and checked.

**How it connects:**
- The push URLs must match the Traefik routers' `Host()` + `Path()` + `Method(POST)` rules (`prometheus.yml:4`, `loki.yml:4`, Step 3.8). Any other path from a VM falls to the priority-1 `host-only` catch-all and gets 403.
- The VMs' sources 10.250.0.110-112 are the `mgmt_ip`s (`terraform/compute.tf:11,24,37`, Step 6.5), listed in `vms-and-host` and in vmfw `:155`.
- The label `instance` = the inventory name, which is the Terraform `ansible_host` name (`terraform/inventory.tf:3`). `job=node`, `nodename` (from `node_uname_info`, set by the exporter, not by this repo) and `instance` are what the Node Exporter Full dashboard filters on (Step 10.3).
- The host's Alloy (`services/monitoring/files/alloy/host.alloy`, Step 3.10) runs the same pipeline with `instance=host`, the exporter reading `/host/proc`, `/host/sys` and `/host/root` (`host.alloy:5-9`), a rule that drops `libpod-healthcheck-*` journal units (`:46-50`; only the host has Podman healthchecks, Vault's and Gitea's, while fe-1's Quadlet defines none), and an explicit `ca_file` (`:35-37,79-81`), because the container does not use the host trust store.

**Re-run and removal:** `get_url` with a checksum skips a file that is already there and correct. `apt deb` does nothing when that version is installed. An unchanged config or drop-in does not notify, so Alloy keeps running. To bump the version, change `alloy_version` and `alloy_deb_sha256` together. The VMs lose Alloy with `teardown`. The host's download folder goes with `destroy`'s removal of `/var/lib/lab` (Step 12.2).

**Check it yourself:**
- `ssh tun-1 systemctl show alloy -p ActiveState -p MemoryMax` prints `ActiveState=active` and `MemoryMax=209715200`.
- From the repo root: `curl -sG --cacert state/pki/ca.pem https://prometheus.lab.test/api/v1/query --data-urlencode 'query=count by (instance) (node_uname_info)'` lists `host`, `fe-1`, `tun-1` and `be-1`.
- `curl -sG --cacert state/pki/ca.pem https://loki.lab.test/loki/api/v1/label/instance/values` lists the same four names.

**Watch out:**
- The role only checks that the unit runs. A push that fails (403, a TLS error, a DNS failure) shows only in `journalctl -u alloy` on the VM, never in the pipeline.
- `alloy_version` (`defaults/main.yml:1`) and the host Alloy image (`services/monitoring/compose.yaml:52`) are separate pins. Both are 1.22.0 today.

### Step 10.2: k8s-monitoring (Flux lab-monitoring)

**Files:**
- `kubernetes/monitoring/kustomization.yaml`: the three resources of `lab-monitoring`.
- `kubernetes/monitoring/proxy-secret.yaml`: Secret `flux-system/flux-proxy` with Squid's address.
- `kubernetes/monitoring/ocirepository.yaml`: the Grafana k8s-monitoring chart as OCI from ghcr.io.
- `kubernetes/monitoring/helmrelease.yaml`: collection-only k8s-monitoring, which sends to the host's Prometheus and Loki with the lab CA.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `kustomization.yaml` | `resources: [proxy-secret.yaml, ocirepository.yaml, helmrelease.yaml]` (`kubernetes/monitoring/kustomization.yaml:1-6`) | Kustomization `lab-monitoring` (`flux-sync.yaml:45`) | None |
| 2 | Secret `flux-system/flux-proxy` | Opaque, `address: http://proxy.lab.test:3128`. The comment: no credential, because be-1 pods reach the internet only through Squid (`proxy-secret.yaml:1-9`) | kustomize-controller | Secret |
| 3 | OCIRepository `flux-system/k8s-monitoring` | `oci://ghcr.io/grafana/helm-charts/k8s-monitoring`, `tag: 4.6.1`, `interval: 1h`, chart-layer selector, `proxySecretRef: flux-proxy` (`ocirepository.yaml:1-16`) | source-controller -> Squid | Chart artifact |
| 4 | HelmRelease `flux-system/k8s-monitoring`: frame | Lives in `flux-system` because `valuesFrom` reads only its own namespace (`helmrelease.yaml:7`). `interval: 10m`, `releaseName: k8s-monitoring`, `targetNamespace: monitoring`, `createNamespace`, `chartRef` to the OCIRepository (`:8-16`). The header says what it does: collection only, while be-1's node metrics and journal stay with the systemd Alloy of Step 10.1 (`:1-2`) | helm-controller | Helm release |
| 5 | `valuesFrom` | Secret `flux-git-auth` key `ca.crt` -> `destinations.hostPrometheus.tls.ca` and `destinations.hostLoki.tls.ca` (`helmrelease.yaml:17-26`). The comment says why: the lab CA changes with every build, so it cannot be written into Git | helm-controller | Reads Secret `flux-git-auth` (Step 8.2) |
| 6 | Values: cluster and destinations | `cluster.name: lab` (`:28-29`), the cluster name the chart attaches to what it sends. `hostPrometheus` type `prometheus`, URL `https://prometheus.lab.test/api/v1/write`. `hostLoki` type `loki`, URL `https://loki.lab.test/loki/api/v1/push` (`:31-37`) | chart | None |
| 7 | Values: features | `clusterMetrics` (kubelet, cAdvisor, kube-state-metrics), `podLogsViaKubernetesApi` (logs read through the API, no host mounts), `clusterEvents` (`:39-44`). Anything beyond these comes from chart defaults, which the repo does not show | chart | None |
| 8 | Values: collector | `collectors.alloy.presets: [singleton]`. With one collector, the chart gives it every feature (`:46-49`). Requests 50m/128Mi, memory limit 512Mi (`:50-53`). `configReloader` image from `docker.io/rancher/mirrored-prometheus-operator-prometheus-config-reloader:v0.89.0`, because quay.io is not in Squid (`:54-58`) | chart | None |
| 9 | Values: kube-state-metrics | `telemetryServices.kube-state-metrics.deploy: true`, image `docker.io/rancher/mirrored-kube-state-metrics-kube-state-metrics:v2.17.0`, because registry.k8s.io is not in Squid, and small resources (`:60-69`) | chart | None |
| 10 | Values: Alloy operator | `alloy-operator` resources (`:71-74`). `waitForAlloyRemoval` uses `docker.io/rancher/kubectl:v1.34.9` instead of registry.k8s.io (`:75-79`) | chart | None |
| 11 | What Helm creates | Namespace `monitoring`, the Alloy operator, one Alloy collector, kube-state-metrics and their RBAC (chart defaults). Images come through containerd's proxy env (Step 8.1). The comment at `flux-sync.yaml:44` counts four images on the first install | helm-controller -> API | `monitoring` objects |
| 12 | Data path | Collector pod -> k3s CoreDNS -> host CoreDNS (`prometheus.lab.test`) -> masquerade to 10.250.0.112 -> lab_sg -> Podman DNAT -> vmfw `:155` -> Traefik `prometheus-write` / `loki-push` (`vms-and-host`) -> Prometheus / Loki. TLS is checked against the lab CA from row 5. Namespace `monitoring` has no NetworkPolicy, so the pods' egress is open | Alloy collector | Pushes metrics, logs, events |

**Why here:** In runtime order this step belongs with Step 8.3: `lab-monitoring` has no `dependsOn` and starts the moment Step 8.2 drops `flux-sync.yaml`. It is walked here because it is telemetry, and because nothing in the pipeline waits for it (`flux-sync.yaml:35`). It needs `flux-git-auth` (Step 8.2), Squid for the chart and images (Step 3.2), and the host monitoring stack behind Traefik (Steps 3.8-3.9).

**How it connects:**
- `ca.crt` in `flux-git-auth` comes from `/etc/lab-runner/ca.pem` (Steps 4.8 and 8.2), which is the same `state/pki/ca.pem` that Traefik's `gateway` leaf chains to (Step 3.3).
- 10.250.0.112 is in `vms-and-host` (`allowlists.yml:10`) only because of be-1's Alloy. The pods use the same entry through the masquerade (Step 8.1).
- helm-controller exists because `flux install` exports it (`ansible/roles/fluxcd/tasks/main.yml:28,34`).
- The cluster series feed the "Kubernetes / Views / Namespaces" dashboard (Step 10.3).

**Re-run and removal:** The OCIRepository is checked hourly and the HelmRelease every 10 min. With nothing changed, there is no upgrade. After a new lab CA, `flux-git-auth` changes (Step 8.2), and the next HelmRelease reconcile renders the new `tls.ca`. `prune: true` would uninstall the release if the folder left Git. Otherwise it goes away with be-1.

**Check it yourself:**
- `ssh be-1 sudo k3s kubectl -n flux-system get kustomization/lab-monitoring helmrelease/k8s-monitoring` shows both Ready.
- `ssh be-1 sudo k3s kubectl -n monitoring get pods` shows the collector, the Alloy operator and kube-state-metrics Running.
- From the repo root: `curl -sG --cacert state/pki/ca.pem https://prometheus.lab.test/api/v1/query --data-urlencode 'query=count by (namespace) (kube_pod_info)'` returns one series per namespace, including `db`, `flux-system` and `kube-system`.

**Watch out:**
- A green pipeline says nothing about k8s monitoring. Check `lab-monitoring` yourself after a fresh build.
- A chart bump can bring new images from quay.io or registry.k8s.io, which Squid refuses. The pods then hang in `ImagePullBackOff`, the HelmRelease never turns Ready, and nothing in the pipeline notices. Each such image needs a docker.io override like rows 8-10.
- PostgREST's `/metrics` (admin port 3001) is not collected. The features above do not discover pods, and `default-deny` in `db` would block a scrape (Step 8.4).

### Step 10.3: Where it lands

**Files** (all built in Phase 3; read here from the consumer's side):
- `services/traefik/dynamic/prometheus.yml`: routers `prometheus-write` (POST push, VMs and host) and `prometheus` (host only) (Step 3.8).
- `services/traefik/dynamic/loki.yml`: routers `loki-push` and `loki` (Step 3.8).
- `services/traefik/dynamic/grafana.yml`: router `grafana` (host only) (Step 3.8).
- `services/monitoring/files/grafana/provisioning/datasources/datasources.yml`: Grafana's Prometheus and Loki datasources (Step 3.9).
- `services/monitoring/files/prometheus/prometheus.yml` and `services/monitoring/files/loki/loki.yml`: the storage side, retention and receiver settings (Step 3.9).
- `services/monitoring/files/grafana/dashboards/node-exporter-full.json` and `services/monitoring/files/grafana/dashboards/k8s-views-namespaces.json`: the two provisioned dashboards (Step 3.9).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Routers `prometheus-write` and `prometheus` | `` Host(`prometheus.lab.test`) && Path(`/api/v1/write`) && Method(`POST`) ``, priority 100, `vms-and-host`. Everything else on that host is priority 1, `host-only` (`services/traefik/dynamic/prometheus.yml:3-14`). Backend `http://prometheus:9090` (`:16-20`) | every agent's remote_write; host queries | None |
| 2 | Routers `loki-push` and `loki` | The same pattern for `/loki/api/v1/push`, backend `http://loki:3100` (`services/traefik/dynamic/loki.yml:3-20`) | every agent's log push; host queries | None |
| 3 | Prometheus as a receiver | `--web.enable-remote-write-receiver`, `--storage.tsdb.retention.time=2d` (`services/monitoring/compose.yaml:9-13`). `prometheus.yml` has no `scrape_configs`: it loads only `rules.yml` (`services/monitoring/files/prometheus/prometheus.yml:1-5`), so every series is pushed | Prometheus | Volume `prometheus-data` |
| 4 | Loki storage | Single instance, filesystem TSDB schema v13 (`services/monitoring/files/loki/loki.yml:21-29`). `retention_period: 48h`, `deletion_mode: disabled` (no delete API) (`:31-33`). The compactor enforces retention (`:35-38`). `auth_enabled: false`, so there are no tenants (`:1`) | Loki | Volume `loki-data` |
| 5 | Label scheme (what arrives) | Host: `instance=host`, `job=node` (`services/monitoring/files/alloy/host.alloy:11-23`). VMs: `instance=fe-1/tun-1/be-1`, `job=node` (`config.alloy.j2:8-20`). Journals: `instance`, `unit`, `service_name`, `level` (`config.alloy.j2:36-60`). Cluster: kubelet, cAdvisor and kube-state-metrics series, pod logs and events, sent under cluster name `lab` (`kubernetes/monitoring/helmrelease.yaml:28-44`) | agents | None |
| 6 | `datasources.yml` | `Prometheus` (uid `prometheus`, `http://prometheus:9090`, default) and `Loki` (uid `loki`, `http://loki:3100`), both proxy access (`datasources.yml:1-15`). Grafana reads them directly on `lab-backend`, not through Traefik | Grafana at start | None |
| 7 | Router `grafana` | `` Host(`grafana.lab.test`) ``, `host-only`, backend `http://grafana:3000` (`services/traefik/dynamic/grafana.yml:1-13`). Only the host's browser can open the UI. The admin login is `labadmin` with the password in Vault `kv/data/lab/bootstrap/grafana-admin` (Step 3.10) | operator's browser | None |
| 8 | `node-exporter-full.json` | Upstream dashboard "Node Exporter Full" (uid `rYdddlPWk`). It selects by `job`, then `nodename` (from `node_uname_info`: the kernel nodename the exporter sees, which is the cloud-init `local-hostname` on the VMs and, for the host's Alloy, most likely the host's own hostname; see Check it yourself), then `instance` (the Instance picker lists only the instances of the chosen nodename). Contents not reviewed | Grafana file provider | None |
| 9 | `k8s-views-namespaces.json` | Upstream dashboard "Kubernetes / Views / Namespaces" (uid `k8s_views_ns`), with `cluster` and `namespace` variables, for the k8s-monitoring series. Contents not reviewed | Grafana file provider | None |

**Why here:** This step closes the observability phase from the reader's side. All three agent kinds (Steps 3.10, 10.1 and 10.2) converge on the same two push routes, the same two stores and one Grafana. Phase 3 built these pieces before any agent existed.

**How it connects:**
- Push routes: host Alloy (Step 3.10), VM Alloy (Step 10.1) and the k8s collector (Step 10.2). Query routes: the operator, and `monitoring.wait_ready` (Step 3.10).
- The labels in row 5 are what the two dashboards and Explore filter on.
- `lab-backend` (Step 3.8) is the network on which Grafana reaches Prometheus and Loki by container name.

**Re-run and removal:** Data survives pipeline runs and VM rebuilds, because it lives in the host volumes `prometheus-data` and `loki-data`. It expires after 2 days (metrics) and 48 h (logs). `monitoring.down` removes the volumes on `destroy` (Steps 3.10 and 12.2).

**Check it yourself:**
- Open `https://grafana.lab.test` in the host's browser (it trusts the lab CA if `state/pki/ca.pem` is imported) and log in as `labadmin`. Dashboards -> "Node Exporter Full": the Nodename picker lists `fe-1`, `tun-1`, `be-1` (cloud-init `local-hostname`, `terraform/compute.tf:77`) and the nodename that the host's Alloy container reports. The service runs with `network_mode: host` and sets no `hostname` (`services/monitoring/compose.yaml:51-73`, `:55`). With host networking, Podman gives the container the host's hostname, so the host's entry is most likely the host's own name (not checked on a live lab). Picking one sets Instance to `fe-1`, `tun-1`, `be-1` or `host`.
- Explore -> Loki: `{instance="be-1", unit="k3s.service"}` shows k3s's journal.
- `ssh fe-1 "curl -s -o /dev/null -w '%{http_code}\n' https://prometheus.lab.test/api/v1/query"` prints `403`: a VM can push but cannot read.

**Watch out:**
- Any of the four allowed sources can push any series with any labels. There is no per-agent identity (`auth_enabled: false`, remote write without auth). A compromised VM could write fake series under another `instance`.
- No alerts and a short history (Step 3.9, Watch out).

## Phase 11: Runtime paths and demo

Phase 11 builds nothing new except one helper script, `demo/load.sh`. It reads the finished lab from the outside. It follows one user request from a LAN browser to PostgreSQL and back, naming the security boundary at every hop (Step 11.1). It shows who applies what, from `bootstrap.sh` down to the Kubernetes operators (Step 11.2). It runs the HPA demo (Step 11.3), and it follows the telemetry from every agent to Grafana (Step 11.4). Nothing in this phase runs as part of `bootstrap.sh` or the pipeline. It describes the lab after a green `deploy` run (Phases 2-10), and the operator runs `demo/load.sh` by hand on the host. After this phase you can trace any packet or object in the lab to the file that allows or creates it.

**Needs from earlier phases:**
- CoreDNS answering `app.lab.test` with the host's LAN IP and the platform names with 10.250.0.1 (`services/coredns/conf/Corefile:2-8`, Step 3.1).
- vmfw loaded: the security groups in `bridge lab_sg` and the DNAT, forward and input rules in `inet lab_vmfw` (`host/files/nftables-vmfw.nft`, Step 2.6).
- Traefik on 10.250.0.1:443 with the push, Gitea and host-only routes (`services/traefik/dynamic/*.yml`, Step 3.8), and the host monitoring stack (Steps 3.9-3.10).
- The three VMs with their addresses (`terraform/compute.tf:2-43`, Step 6.5) and the cloud-init default route via 198.51.100.1 (`terraform/cloud-init/network-config.yaml.tftpl:13-15`, Step 6.6).
- WireGuard spokes and hub, and the hub filter on tun-1 (`ansible/roles/wireguard/`, Step 7.5).
- k3s on be-1 with Traefik on port 8000, Flux, CNPG, PostgREST, the HPA and the NetworkPolicies (Phase 8).
- The frontend container on fe-1, serving `app-edge` TLS on port 443 (Phase 9).
- Alloy on every VM and the k8s-monitoring collector on be-1 (Phase 10).
- The `ssh fe-1` alias and the operator key (`host/ssh_access.py`, `host/files/60-lab-ssh.conf`, Step 4.6).

**Hands on:**
- `demo/load.sh`: a load generator that runs on fe-1 and makes the PostgREST HPA scale.
- A hop-by-hop map of the request path and the telemetry path, each hop tied to the rule that allows it. Use it when something stops answering.
- A control-path map: which identity changes which part of the lab, and where the pipeline waits for the asynchronous appliers.
- The commit SHA chain, which proves that fe-1 runs the image built from the pushed commit and that Flux applied that same commit to the API.

### Step 11.1: One user request

**Files** (all built earlier; read here along the path):
- `services/coredns/conf/Corefile`: `app.lab.test` -> HOST_IP, everything outside `lab.test` refused (Step 3.1).
- `host/files/nftables-vmfw.nft` and `host/vmfw.py` (`render_rules` only): the LAN DNAT to fe-1, the forward accept, the security groups on the `wan` bridge (Step 2.6).
- `frontend/Dockerfile`, `ansible/roles/frontend/templates/frontend.container.j2`, `frontend/app.py`: gunicorn TLS on fe-1's port 443 and the Flask API call (Steps 5.6, 9.1, 9.2).
- `ansible/roles/wireguard/templates/wg.conf.j2`, `ansible/host_vars/fe-1.yml`, `ansible/host_vars/tun-1.yml`, `ansible/host_vars/be-1.yml`: the tunnels, their routes and AllowedIPs (Step 7.5).
- `ansible/roles/wireguard/files/hub-forward.nft`: the hub filter (Step 7.5).
- `ansible/roles/k3s/files/traefik-config.yaml`: be-1's Traefik on port 8000 (Step 8.1).
- `kubernetes/apps/db/postgrest.yaml`, `kubernetes/apps/db/networkpolicy.yaml`, `kubernetes/apps/db/postgres.yaml`, `kubernetes/apps/db/init.sql`: Ingress, PostgREST, the policies, the database roles and grants (Steps 8.4, 8.6).
- `terraform/cloud-init/network-config.yaml.tftpl`: fe-1's default route, which carries the reply to the LAN client (Step 6.6).

**Build, in this order** (one row per hop of `GET https://app.lab.test/`; the boundary of each hop is in bold):

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Client setup (manual) | The LAN client must send `lab.test` queries to the host's LAN IP and trust `state/pki/ca.pem`. Nothing in the repo sets this up. **Boundary:** CoreDNS refuses every name outside `lab.test` (`Corefile:18-27`), so HOST_IP cannot be the client's only resolver. It needs split DNS or a hosts entry | operator | Client DNS config, client trust store |
| 2 | DNS answer | The `lab.test:53` block binds 10.250.0.1 and `{$HOST_IP}` and answers `{$HOST_IP} app.lab.test` from its `hosts` list (`Corefile:2-8`). `HOST_IP` is the live LAN address that `dns.up` passes to compose (`services/coredns/dns.py:13-17`) | client -> CoreDNS | None |
| 3 | DNAT to fe-1 | `lab_vmfw prerouting`: `iifname $lan_card ip daddr $host_ip tcp dport 443 dnat ip to 198.51.100.11` (`nftables-vmfw.nft:118-122`). The host's own browser takes the `output` chain instead (`:125-129`), because prerouting never sees locally started traffic. `$lan_card` and `$host_ip` are `define`s that `render_rules(network: dict) -> bytes` prepends to the file (`host/vmfw.py:13-19`). **Boundary:** only TCP 443 to the LAN IP on the LAN card. Traefik's 10.250.0.1:443 is a different address and is not touched | kernel nat hook | conntrack entry with DNAT |
| 4 | Forward into `wan` | `lab_vmfw forward`: the hairpin drop does not match (`:147`). `iifname $lan_card oifname "wan" ip daddr 198.51.100.11 tcp dport 443 ct status dnat accept` (`:150`). IP forwarding itself comes from libvirt's route-mode network `wan` (`terraform/network.tf:40-61`). **Boundary:** only this DNATed flow. Any other LAN packet towards `wan` hits `oifname "wan" counter drop` (`:153`). The host's frames into `fe-1-wan` pass the bridge output hook, which `lab_sg` does not filter (its chains are prerouting and forward, `:49-96`) | kernel forward hook | None |
| 5 | TLS on fe-1 | gunicorn binds `0.0.0.0:443` with `--certfile /etc/app/tls/tls.crt`, 2 workers (`frontend/Dockerfile:14`). The Quadlet runs the container with `Network=host` and mounts `/etc/frontend/tls` (`frontend.container.j2:9-10`). The certificate is the `app-edge` leaf, SAN `app.lab.test` (`lib/config.py:38`). **Boundary:** TLS ends here. Everything behind fe-1 is plain HTTP inside WireGuard | LAN client -> gunicorn | None |
| 6 | Flask calls the API | `index()` runs `api("GET", "?order=id")` (`frontend/app.py:28-30`). `api(method: str, query: str = "", body: dict \| None = None) -> list \| None` sends to `API` = `http://10.3.1.10:8000/items` unless `API_URL` is set, with a 5 s timeout (`app.py:10,15-25`) | gunicorn worker -> urllib | None |
| 7 | fe-1 routing into wg0 | The spoke's `PostUp` adds `ip route replace 10.3.0.0/16 dev wg0 src 10.1.1.10` (`wg.conf.j2:8-12`, `host_vars/fe-1.yml:7-10`). Because of `Network=host`, the container uses this route, so the packet's source is 10.1.1.10. WireGuard encrypts it and sends UDP to `198.51.100.12:51820`, tun-1's `wan_ip` (`wg.conf.j2:17-20`, `host_vars/fe-1.yml:6`) | kernel -> wg0 -> eth1 | None |
| 8 | Host bridge `wan` | `lab_sg prerouting` checks the frame's source IP and ARP address against `fe-1-wan . 198.51.100.11` and drops VLAN-tagged frames (`nftables-vmfw.nft:52-59`). `lab_sg forward` checks the destination (`:72`). The first packet is a new flow, allowed by `sg_hub_in`: `iifname @sg_frontend ether type ip udp dport 51820 ct state new accept` (`:90,98-99`). Later packets match the established pair rule (`:84-85`). **Boundary:** the security group. fe-1 may start only WireGuard to the hub. fe-1 <-> be-1 directly is the default drop (`:95`) | kernel bridge hooks | bridge conntrack entry |
| 9 | tun-1: decrypt and filter | wg0 accepts inner source 10.1.1.10 only because peer fe-1's AllowedIPs include `10.1.0.0/16` (`host_vars/tun-1.yml:7-9`). `net.ipv4.ip_forward = 1` (`ansible/roles/wireguard/tasks/main.yml:37-48`). The hub filter: `policy drop`, `ct state invalid drop`, `ct state established,related accept`, and one new-flow rule `iifname "wg0" oifname "wg1" ip saddr 10.1.1.10 ip daddr 10.3.1.10 tcp dport 8000 ct state new accept` (`hub-forward.nft:9-15`). **Boundary:** the hub filter. Only fe-1 -> be-1:8000 opens a connection | WireGuard -> kernel forward | conntrack entry on tun-1 |
| 10 | tun-1 -> be-1 | wg1's peer be-1 owns `10.3.0.0/16` (`host_vars/tun-1.yml:15-17`). The hub has no `Endpoint` for its peers (only spokes render one, `wg.conf.j2:17-20`). It sends to the address it learned from be-1's own handshakes. On the host, `lab_sg` allows hub -> backend only as established (`nftables-vmfw.nft:87`), because `sg_backend_in` is empty (`:107-108`). be-1 keeps that flow open with `PersistentKeepalive = 25` (`wg.conf.j2:19`). **Boundary:** the security group again: nothing may open a connection to be-1 | wg1 -> eth1 | None |
| 11 | be-1 port 8000 | wg1 accepts inner source 10.1.1.10 because be-1's peer tun-1 has `10.1.0.0/16` in AllowedIPs (`host_vars/be-1.yml:7-10`). k3s's ServiceLB (`svclb-traefik`, hostPort 8000) hands the connection to the bundled Traefik, whose `web` entrypoint is exposed on 8000 (`traefik-config.yaml:9-15`). **Boundary:** none on be-1 itself. It runs no host firewall, so the hub filter and `lab_sg` are what limit who reaches 8000 | ServiceLB -> Traefik pod | None |
| 12 | Traefik -> PostgREST | The Ingress `postgrest` has no host rule and sends path `/` (Prefix) to Service `postgrest` port `http` (`kubernetes/apps/db/postgrest.yaml:65-81`). The Service is ClusterIP 3000 -> pod port `http` (`:52-63`). **Boundary:** NetworkPolicy `postgrest` admits only pods labelled `app.kubernetes.io/name: traefik` in `kube-system`, on TCP 3000 (`networkpolicy.yaml:31-49`), on top of `default-deny` for every pod in `db` (`:4-10`). kube-router enforces it | Traefik -> PostgREST pod | None |
| 13 | PostgREST -> Postgres | PostgREST resolves `pg-rw` through `allow-dns` (`networkpolicy.yaml:12-29`) and connects to `pg-rw:5432` (egress `:50-56`; `pg-instances` ingress `:68-76`). It logs in as `authenticator` with the password from Secret `db-authenticator` (`postgrest.yaml:23-34`). With no JWT in the request, it switches to `PGRST_DB_ANON_ROLE` `api_anon` (`:37-38`). `authenticator` is a CNPG managed role, `inherit: false`, member of `api_anon` (`postgres.yaml:25-34`). **Boundary:** the database grants. `api_anon` has `USAGE` on schema `todo` and its sequences, plus `SELECT, INSERT, UPDATE, DELETE` on `todo.items`, and nothing else (`init.sql:10-14`) | PostgREST -> CNPG primary | Reads `todo.items` |
| 14 | Reply to fe-1 | The rows go back through Traefik and ServiceLB. be-1's route `10.1.0.0/16 dev wg1 src 10.3.1.10` (`wg.conf.j2:10`, `host_vars/be-1.yml:9`) sends them into the tunnel. `lab_sg` passes them as established be-1 -> hub (`nftables-vmfw.nft:86`). The hub filter passes them as established (`hub-forward.nft:12`), wg0 carries them, and `lab_sg` passes hub -> fe-1 as established (`nftables-vmfw.nft:85`) | the same hops in reverse | None |
| 15 | Reply to the LAN client | Flask renders `templates/items.html`, and gunicorn encrypts the page. fe-1 sends it to the client's real IP (DNAT keeps the source address) through its default route via 198.51.100.1 (`network-config.yaml.tftpl:13-15`). On the host, `lab_vmfw forward` accepts it as established (`nftables-vmfw.nft:149`), and conntrack reverses the DNAT, so the client sees HOST_IP:443 | fe-1 -> host -> client | None |
| 16 | Writes and errors | `POST /add`, `/update/<id>`, `/delete/<id>` call `api("POST" \| "PATCH" \| "DELETE")` with PostgREST filters such as `?id=eq.<id>` and answer `303` to `/` (`app.py:33-48`). A `URLError` or `TimeoutError` from the API renders the page with an error and status 502 (`app.py:51-54`) | Flask | Writes `todo.items` |

**What blocks everything else on this path:** be-1 opening a connection to fe-1: no hub rule, policy drop (`hub-forward.nft:10`). fe-1 <-> be-1 directly on `wan`: `lab_sg` default drop (`nftables-vmfw.nft:95`). Any VM to another VM on `mgmtbr1`: `lab_sg` drops all tap-to-tap frames there (`:69`). A VM routing through the host to another VM: the hairpin drop (`:147`). A spoke reaching tun-1 itself through a tunnel: the hub's input chain accepts only established traffic and ping (`hub-forward.nft:24-29`). A pod in `db` reaching anything other than DNS, Postgres or the API server: `default-deny` egress (`networkpolicy.yaml:4-10`).

**Why here:** Every hop uses something from an earlier phase: DNS (3.1), vmfw (2.6), the VM addresses and default route (6.5, 6.6), the tunnels and hub filter (7.5), Traefik and the NetworkPolicies (8.1, 8.4), the database roles (8.6) and the frontend (9.1, 9.2). The path can only be read once all of them exist. The pipeline tests this path only partly: the frontend role fetches `https://127.0.0.1/` on fe-1, which covers hops 5-14 (TLS, Flask, the tunnel and the API) but not the DNS answer, the DNAT or the reply route to a LAN client (`ansible/roles/frontend/tasks/main.yml:80-87`, Step 9.1).

**How it connects:**
- The two halves of the app ingress use the same live LAN address: CoreDNS's `HOST_IP` (Step 3.1) and vmfw's `$host_ip` (Step 2.6). Both are refreshed only by `update` (Step 12.3).
- Port 8000 is copied by hand into `traefik-config.yaml:12`, `hub-forward.nft:13`, `frontend/app.py:10` and `demo/load.sh:6`; the address 10.3.1.10 into `terraform/compute.tf:35`, `hub-forward.nft:13`, `app.py:10`, `load.sh:6` and `kubernetes/apps/db/networkpolicy.yaml:99` (the `pg-instances` ipBlock) (R1).
- The source 10.1.1.10 that the hub filter requires comes from the spoke route (`wg.conf.j2:10`) plus `Network=host` in the Quadlet (`frontend.container.j2:9`). `Network=host` puts the container in fe-1's own network stack, so its packets take the spoke route and leave as 10.1.1.10. On a Podman bridge network the source would be rewritten by NAT, and nothing in the repo makes sure it would still be 10.1.1.10.
- The Traefik pod label in `networkpolicy.yaml:47` and the Service name `pg-rw` in `postgrest.yaml:34` are names chosen by k3s and CNPG, not by this repo (R1).

**Re-run and removal:** Nothing on the path keeps state except conntrack entries and the rows in `todo.items`. The rows live on be-1's PVCs and are lost when be-1 is rebuilt or torn down (Steps 12.1, R4). A LAN IP change breaks hops 2-3 until the next `update` (Step 12.3).

**Check it yourself:**
- From the host, as yourself: `curl -s -o /dev/null -w '%{http_code}\n' --cacert state/pki/ca.pem https://app.lab.test/` prints `200`. This takes the output-chain DNAT (hop 3, `nftables-vmfw.nft:128`).
- `ssh fe-1 ip route get 10.3.1.10` prints `10.3.1.10 dev wg0 src 10.1.1.10`, and `ssh fe-1 curl -s http://10.3.1.10:8000/items` prints the JSON rows.
- `ssh be-1 curl -s -m 3 http://10.1.1.10:443/ ; echo $?` gives up after 3 s (exit 28): the hub filter drops a connection that be-1 starts. `ssh tun-1 sudo nft list chain inet lab_hub forward` shows the `dropped forward` counter going up.

**Watch out:**
- The API has no authentication. Anyone who reaches 10.3.1.10:8000 can read, add, change and delete items as `api_anon`. Only the hub filter keeps that to fe-1.
- fe-1 and be-1 have no host firewall of their own (a known limitation, R6). On be-1 the NetworkPolicies protect only namespace `db`.
- The default route via 198.51.100.1 exists in practice only for these replies. It does not give the VMs a way out: vmfw drops everything else that arrives from `wan` (`nftables-vmfw.nft:152`).

### Step 11.2: Control path: who applies what

**Files** (all built earlier; this step reads only the parts that apply changes):
- `main.py` (`platform_up`, `cmd_*`), `services/gitea/gitea.py` (`commit_changes`, `push`, `start_run`): what the operator's command changes (Steps 1.7, 5.1-5.3).
- `.gitea/workflows/deploy.yml`, `.gitea/workflows/image.yml`, `.gitea/workflows/ansible.yml`: what the runner does with a pushed commit (Steps 5.4-5.6, 7.1).
- `ansible/roles/k3s/tasks/main.yml`, `ansible/roles/fluxcd/tasks/main.yml`, `ansible/roles/app_secrets/tasks/main.yml`, `ansible/roles/app_deployed/tasks/main.yml`: what Ansible writes into k3s, and where it waits (Steps 8.1, 8.2, 8.5, 8.7).
- `ansible/roles/fluxcd/files/flux-sync.yaml`: what Flux pulls and applies (Step 8.2).
- `ansible/roles/frontend/defaults/main.yml`, `ansible/roles/frontend/templates/frontend.container.j2`: the image tag on fe-1 (Step 9.1).

**Build, in this order** (from the operator's keyboard to the pods):

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `sudo ./bootstrap.sh up\|update` | Runs as root. `platform_up()` changes the host directly: packages, netplan, nft, containers, Vault, Gitea, the runner (`main.py:30-47`). It logs in to Vault as AppRole `lab-bootstrap` from `/var/lib/lab/approle.json` (`services/vault/vault.py:202-208`) and to Gitea as `labadmin`, whose password it keeps in Vault (`services/gitea/gitea.py:53-58`) | operator -> every `up()` | Host, Vault, Gitea |
| 2 | `commit_changes() -> None` and `push(creds: dict) -> str` | Commits the working tree as `lab operator` (`gitea.py:189-196`), then pushes `HEAD` to Gitea's `main` with the admin's Basic auth in an `http.extraHeader` env var (`gitea.py:152-173`). git's push URLs (`/lab/lab.git/info/refs`, `/lab/lab.git/git-receive-pack`) fall under `PathPrefix(/lab/lab.git/)`, so the push goes through Traefik's `gitea-flux` router with the `flux-and-host` allowlist (`services/traefik/dynamic/gitea.yml:3-8`), not through the host-only catch-all. If `main` already holds `HEAD`, `start_run` dispatches `deploy.yml` instead (`gitea.py:275-280`) | `cmd_up`/`cmd_update` -> git | Gitea repo `lab/lab` |
| 3 | `deploy.yml` on the runner | `on: push` to `main` or `workflow_dispatch`, one run at a time in group `lab-deploy` (`deploy.yml:3-10`). Jobs check -> image -> terraform -> ansible (`:12-24`). The runner `lab-host` runs every job as root on the host, label `host` (`services/gitea/runner/files/lab-runner.service:7-8`, `files/config.yaml:10-11`) | Gitea -> runner | Host |
| 4 | Terraform (job `apply`) | Changes libvirt through `qemu:///system` as root: networks, pool, volumes, domains (`terraform/provider.tf:20-22`, Phase 6) | runner -> libvirt | `/var/lib/lab/tfstate`, `/var/lib/lab/pool` |
| 5 | Ansible (job `configure`) | Logs in to Vault as AppRole `lab-pipeline` through the Gitea Actions secrets, reads five values (`ansible.yml:16-30`), loads the pipeline SSH key into an agent (`:32-35`) and runs `site.yml` as `user` with `become` over the mgmt network (Phase 7). It configures the VM operating systems | runner -> ssh -> VMs | VM files and services |
| 6 | k3s manifests folder | Ansible writes five files into `/var/lib/rancher/k3s/server/manifests` on be-1: `traefik-config.yaml` (`k3s/tasks/main.yml:28-35`), `flux.yaml` (`fluxcd/tasks/main.yml:38-44`), `flux-git-auth.yaml` (`:55-62`), `flux-sync.yaml` (`:64-70`) and `db-authenticator.yaml` (`app_secrets/tasks/main.yml:14-21`). k3s applies whatever lands in this folder | Ansible -> k3s | Kubernetes objects |
| 7 | Flux source-controller | GitRepository `lab-repo` pulls `https://gitea.lab.test/lab/lab.git` branch `main` every minute, with Secret `flux-git-auth` (`flux-sync.yaml:1-13`). It reaches Gitea through Traefik's `gitea-flux` route, which admits only be-1 and the host (`services/traefik/dynamic/gitea.yml:3-8`). The token has scope `read:repository` (`gitea.py:144-145`) | Flux -> Gitea | Git artifact in the cluster |
| 8 | Flux kustomize-controller | Applies `./kubernetes/cnpg` (`lab-cnpg`), then `./kubernetes/apps` (`lab-apps`, `dependsOn: lab-cnpg`), and in parallel `./kubernetes/monitoring` (`lab-monitoring`). All three use `prune: true` and `wait: true` (`flux-sync.yaml:16-68`) | Flux -> API server | Objects in `db`, `flux-system` |
| 9 | Flux helm-controller | Installs HelmRelease `cnpg` (`kubernetes/cnpg/helmrelease.yaml`; chart 0.29.2 pinned in `kubernetes/cnpg/ocirepository.yaml:11`) and `k8s-monitoring` (`kubernetes/monitoring/helmrelease.yaml`; chart 4.6.1 pinned in `kubernetes/monitoring/ocirepository.yaml:11`) from OCI charts | Flux -> Helm | `cnpg-system`, `monitoring` |
| 10 | CNPG operator | Turns Cluster `pg` (`kubernetes/apps/db/postgres.yaml`) into pods `pg-1`/`pg-2`, PVCs, Services `pg-rw`/`pg-ro`/`pg-r`, Secrets (`pg-app` is unused), and the managed role `authenticator` | CNPG -> API server, Postgres | Pods, PVCs, roles |
| 11 | HPA and Deployment controllers | Set PostgREST's replica count between 1 and 4 from CPU (`kubernetes/apps/db/postgrest-hpa.yaml`, Step 8.4; exercised in Step 11.3) | kube-controller-manager | ReplicaSet `postgrest-*` |
| 12 | Pipeline sync points | Flux and the operators work on their own. The pipeline waits for them at fixed points: node Ready (`k3s/tasks/main.yml:56-62`), Flux controllers Available (`fluxcd/tasks/main.yml:46-53`), GitRepository Ready (`:72-79`), namespace `db` exists (`app_secrets/tasks/main.yml:5-12`), and `lab-apps` applied at this commit (`app_deployed/tasks/main.yml:4-14`). After those, the frontend role checks the page (`frontend/tasks/main.yml:80-87`) | Ansible -> `k3s kubectl wait` | Reads the API |
| 13 | Commit SHA chain | Local `HEAD` -> push -> the runner's `GITHUB_SHA`. One branch: image tag `localhost/frontend:<sha>` (`image.yml:15,20`) -> `frontend_tag` (`frontend/defaults/main.yml:1`) -> Quadlet `Image=` (`frontend.container.j2:7`). Other branch: Flux revision `main@sha1:<sha>` -> `app_deployed` waits for exactly that `lastAppliedRevision` (`app_deployed/tasks/main.yml:8`) | git -> Gitea -> runner, Flux | None |

**Who owns which part of the lab:**

| Part | Changed by | Identity | Applied when |
|---|---|---|---|
| Host packages, files, nft tables, containers | `bootstrap.sh` (`platform_up`) | root (sudo) | each `up`/`update`/`teardown` |
| Vault config and KV | `vault.up`, `gitea.up`, `monitoring.up` | AppRole `lab-bootstrap` | each run (create-once values, Step 3.7) |
| Gitea org, repo, tokens, Actions secrets | `gitea.up` | `labadmin` | each run (create-once) |
| Gitea `main` | `push` | `labadmin` | `up`/`update` with a new commit |
| libvirt objects (VMs) | runner, job `apply` | root | each pipeline run |
| VM operating systems | runner, job `configure` | `user` + sudo, pipeline SSH key | each pipeline run |
| k3s add-ons, Flux itself, Flux's Git source, `db-authenticator` | Ansible -> manifests folder | root on be-1 | each pipeline run |
| `kubernetes/cnpg`, `kubernetes/apps`, `kubernetes/monitoring` | Flux | Flux's service accounts | within a minute of a push, independent of the pipeline |
| Postgres pods, Services, roles | CNPG operator | its service account | whenever Cluster `pg` or its Secret changes |
| PostgREST replica count | HPA | controller-manager | every sync period |

The "Kubernetes object inventory" at the end of Phase 8 lists every Kubernetes object with its applier.

**Why here:** The steps before this one describe each applier on its own. Debugging needs the whole chain in one view: when an object is wrong, this table says which file and which run set it. It also explains why a pipeline run can be green while something is still converging (Flux, CNPG, k8s-monitoring).

**How it connects:**
- Gitea's `main` drives both the pipeline (Step 5.4) and Flux (Step 8.2). Anything that can push to `main` controls the host (through the runner) and the cluster (through Flux).
- Only the host can push. be-1 reaches only `/lab/lab.git/` through the `gitea-flux` router (`services/traefik/dynamic/gitea.yml:3-8`). That prefix also covers git's push endpoint, so the thing that stops a push from be-1 is that its only credential, the Flux token, has scope `read:repository` (`gitea.py:144-145`). Everything else on Gitea (UI, API, runner) is `host-only` (`gitea.yml:9-14`, Step 3.8).
- The manifests folder is the only way Ansible changes the cluster. So a change to `flux-sync.yaml` lands only when the fluxcd role runs again (Step 8.2), not when Flux syncs.

**Re-run and removal:** Every applier is idempotent: an unchanged file or manifest changes nothing. `prune: true` removes objects whose files leave a Flux path. Each run checks the files in the manifests folder again and rewrites one only when its content has changed. Their objects go away with be-1 (teardown, destroy or a rebuild).

**Check it yourself:**
- `ssh be-1 sudo ls /var/lib/rancher/k3s/server/manifests` lists `db-authenticator.yaml`, `flux-git-auth.yaml`, `flux-sync.yaml`, `flux.yaml` and `traefik-config.yaml`, next to k3s's own files.
- `ssh be-1 sudo k3s kubectl -n flux-system get gitrepository,kustomization` shows `main@sha1:<sha>`. Compare it with `git rev-parse HEAD`.
- `ssh fe-1 sudo podman ps --format '{{.Image}}'` shows `localhost/frontend:<the same sha>`.

**Watch out:**
- Flux pulls a pushed commit even if the pipeline fails at `check`. A broken change under `kubernetes/` reaches be-1 whatever the pipeline says.
- A green run does not wait for `lab-monitoring` (`flux-sync.yaml:35`, Step 10.2).
- The runner runs every job as root on the host (a known limitation, R6). A commit on Gitea's `main` is code that runs as root.

### Step 11.3: HPA demo

**Files:**
- `demo/load.sh`: the only new file in this phase. Run on the host as the operator, it makes fe-1 send requests to PostgREST through the tunnel and prints a count per HTTP status.
- `kubernetes/apps/db/postgrest-hpa.yaml` (built in Step 8.4) and `kubernetes/apps/db/postgrest.yaml` (`resources` and `readinessProbe` only): what the load makes scale.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Header | Shebang `#!/usr/bin/env bash` and the usage comment: "on the lab host: demo/load.sh [seconds, default 120] [parallel clients, default 8]" (`demo/load.sh:1-3`). The script has no `set -e` and no argument checks | operator | None |
| 2 | `DURATION`, `PARALLEL` | `${1:-120}` and `${2:-8}` (`load.sh:4-5`) | row 3 | None |
| 3 | `ssh fe-1 "..."` | One SSH command to fe-1 (`load.sh:6`). The alias and key come from `/etc/ssh/ssh_config.d/60-lab-ssh.conf` (`host/files/60-lab-ssh.conf:6-15`: user `user`, `IdentityFile ~/.ssh/lab_operator`, 10.250.0.110). fe-1 trusts that key through `runner.ensure_ssh_key` -> `/etc/lab-runner/ssh.pub` -> cloud-init (Steps 4.9, 6.6) | operator's shell -> ssh | None on the host |
| 4 | `timeout $DURATION sh -c '...'` | On fe-1, it stops the generator after DURATION seconds (`load.sh:6`) | sshd on fe-1 -> sh | None |
| 5 | Generator | `seq 1 10000000 \| xargs -P $PARALLEL -I{} curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 http://10.3.1.10:8000/items` (`load.sh:6`). xargs keeps PARALLEL curl processes running, one per input line (the `{}` is never used). Each curl opens a new TCP connection and prints only the status code. `000` means curl got no HTTP answer within 3 s | sh -> curl -> API | None |
| 6 | Summary | `\| sort \| uniq -c` runs after `timeout` ends and prints one line per status code with its count (`load.sh:6`) | sh on fe-1 | Prints to the host terminal |
| 7 | The path | The same as Step 11.1 hops 7-14: fe-1 route `src 10.1.1.10` -> `lab_sg` -> hub filter -> be-1:8000 -> Traefik -> PostgREST -> `pg-rw`. It skips the DNS answer, the DNAT, TLS and Flask, so it loads only the tunnel, Traefik, PostgREST and Postgres | curl -> be-1 | conntrack entries on tun-1 |
| 8 | Hub conntrack sizing | Every request is a new connection through tun-1. The wireguard role raises `nf_conntrack_max` to 65536 and the TIME_WAIT timeout to 30 s. The comment gives the numbers: the default on a 512 MB VM fills at about 34 new connections/s, the new values hold about 2200/s (`ansible/roles/wireguard/tasks/main.yml:24-48`) | kernel on tun-1 | `/etc/sysctl.d/90-lab-forward.conf` |
| 9 | CPU request | PostgREST requests `cpu: 50m`, memory 64Mi, limit 128Mi (`postgrest.yaml:45-50`). The HPA's percentage is measured against this request | kubelet, HPA | None |
| 10 | HPA `postgrest` | `minReplicas: 1`, `maxReplicas: 4`, target 50 % average CPU utilisation, so it scales out when the pods average more than 25m (`postgrest-hpa.yaml:1-18`). Scale-up: no stabilisation window, per 60 s the larger of +2 pods and +100 % (`:20-29`). From 1 pod the first step can reach at most 3, the next one 4. Scale-down: a 300 s window, then at most 1 pod per 60 s (`:31-37`) | HPA controller | Deployment `postgrest` replicas |
| 11 | metrics-server | k3s's packaged metrics-server supplies pod CPU to the HPA. The repo does not configure it (Step 8.1) | HPA -> metrics API | None |
| 12 | New pods | A new PostgREST pod gets traffic only after `/ready` on the admin port 3001 answers (`postgrest.yaml:41-44`). NetworkPolicies select by label, so new pods get the same allows (`networkpolicy.yaml:31-56`) | Deployment controller | Pods in `db` |

**Why here:** The demo needs the whole request path from fe-1 (Steps 7.5, 8.1, 8.4, 8.6), the `ssh fe-1` alias (Step 4.6), and metrics-server with the HPA (Steps 8.1, 8.4). It comes after Steps 11.1 and 11.2 because it reuses their path and their objects. Watch it with the k8s-monitoring series (Step 10.2) and the "Kubernetes / Views / Namespaces" dashboard (Step 10.3).

**How it connects:**
- `10.3.1.10:8000` is copied by hand from `terraform/compute.tf:35` and `traefik-config.yaml:12` (R1).
- The hub conntrack settings exist because of this kind of load (the comment at `wireguard/tasks/main.yml:35-36`).
- The k8s-monitoring collector sends the replica and CPU series to the host's Prometheus (Step 10.2). The "Kubernetes / Views / Namespaces" dashboard shows namespace `db` (Step 10.3).

**Re-run and removal:** The script changes nothing on disk. Each run starts from whatever replica count the HPA has at that moment. After the load stops, the HPA waits 300 s and then removes one pod per minute, so 4 -> 1 takes about 8 minutes. Nothing needs to be removed.

**Check it yourself:**
- In a second terminal: `ssh be-1 sudo k3s kubectl -n db get hpa postgrest -w`. TARGETS rises above `50%`, and REPLICAS goes up to 3, then 4, if the CPU stays above the target.
- `ssh be-1 sudo k3s kubectl -n db top pods` shows the PostgREST pods' CPU, from metrics-server.
- The output of `demo/load.sh 60` is a few lines such as `<count> 200`. Any other code is a failed request.

**Watch out:**
- Run it as the user who ran `sudo ./bootstrap.sh`, without sudo. Under sudo, `~/.ssh/lab_operator` in the alias points at root's home, where there is no key.
- fe-1 has 1 vCPU (`compute.tf:5`), and each request starts a new curl process. The generator itself can cap the request rate before PostgREST becomes busy enough to scale.
- `000` lines mean curl got no answer within 3 s. Likely causes are an overloaded PostgREST or Postgres, a primary failover, or conntrack drops on tun-1 (`dmesg` on tun-1 shows `nf_conntrack: table full`). A 5xx code is an answer from be-1's Traefik or PostgREST.

### Step 11.4: Telemetry path

**Files** (all built earlier; read here from the agent to Grafana):
- `services/monitoring/files/alloy/host.alloy` and `services/monitoring/compose.yaml` (service `alloy`): the host agent (Step 3.10).
- `ansible/roles/alloy/templates/config.alloy.j2`: the VM agent (Step 10.1).
- `kubernetes/monitoring/helmrelease.yaml`: the k8s collector on be-1 (Step 10.2).
- `host/files/60-lab-mgmtbr1.yaml` and `services/coredns/conf/Corefile`: how the names resolve on the host and on the VMs (Steps 2.2, 3.1).
- `host/files/nftables-vmfw.nft`: the one forward rule that lets VMs reach Traefik (Step 2.6).
- `services/traefik/compose.yaml`, `services/traefik/dynamic/tls.yml`, `prometheus.yml`, `loki.yml`, `allowlists.yml`, `grafana.yml`: the gateway, the push routes and who may use them (Step 3.8).
- `services/monitoring/files/loki/loki.yml`, `services/monitoring/files/grafana/provisioning/datasources/datasources.yml`: storage and viewing (Step 3.9).

**Build, in this order** (one VM metric sample, then what differs for the other agents):

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | Agents and labels | VM Alloy: node exporter, `instance=<vm>`, `job=node`, remote write to `https://prometheus.lab.test/api/v1/write`; journal with `instance`, `unit`, `service_name`, `level` to `https://loki.lab.test/loki/api/v1/push` (`config.alloy.j2:6-66`). Host Alloy: the same with `instance=host`, `/host/*` exporter paths, the `libpod-healthcheck-*` drop and an explicit `ca_file` (`host.alloy:5-83`). k8s collector: cluster metrics, pod logs and events, cluster name `lab`, the same two URLs, CA from Secret `flux-git-auth` (`kubernetes/monitoring/helmrelease.yaml:17-44`) | systemd / container / Helm | Reads node and journal data |
| 2 | Name lookup | A VM asks 10.250.0.1:53 (`network-config.yaml.tftpl:21-22`), which `lab_vmfw input` allows (`nftables-vmfw.nft:175-176`). CoreDNS answers 10.250.0.1 (`Corefile:5`). The host asks systemd-resolved, which sends `~lab.test` to 10.250.0.1 (`60-lab-mgmtbr1.yaml:11-13`). A pod asks k3s's CoreDNS, which forwards to be-1's resolver, which is the host | agent -> CoreDNS | None |
| 3 | Leaving the VM | The frame leaves eth2 through tap `<vm>-mgmt`. `lab_sg prerouting` checks its source IP and ARP address against `lab_addrs` (`nftables-vmfw.nft:52-59`). Pod traffic leaves be-1 masqueraded to 10.250.0.112 by flannel (a k3s default), so it passes the same check as be-1. **Boundary:** a VM cannot claim another VM's mgmt address | kernel bridge hook | None |
| 4 | Podman DNAT and vmfw | 10.250.0.1:443 is Podman's port mapping into Traefik's port 8443 (`services/traefik/compose.yaml:9,14-15`), so the packet is forwarded, not delivered to input. `lab_vmfw forward` accepts it with `iifname "mgmtbr1" ip saddr { 10.250.0.110, 10.250.0.111, 10.250.0.112 } ct original ip daddr 10.250.0.1 ct original proto-dst 443 ct status dnat accept` (`nftables-vmfw.nft:155`). Anything else forwarded from `mgmtbr1` is dropped (`:156`). The host's own agent connects from 10.250.0.1 and never enters `mgmtbr1`, so these rules do not apply to it. **Boundary:** VMs reach only Traefik, and only on 10.250.0.1:443 | kernel nat and forward hooks | conntrack entry |
| 5 | Traefik TLS | Traefik serves the `gateway` leaf (`dynamic/tls.yml:1-4`), whose SANs are gitea, grafana, prometheus and loki `.lab.test` (`lib/config.py:37`). The VM checks it against the lab CA from cloud-init (`config.alloy.j2:2`) | agent -> Traefik | None |
| 6 | Push routers | `prometheus-write`: `` Host(`prometheus.lab.test`) && Path(`/api/v1/write`) && Method(`POST`) ``, priority 100, middleware `vms-and-host` (`dynamic/prometheus.yml:3-8`). `loki-push` is the same for `/loki/api/v1/push` (`dynamic/loki.yml:3-8`). `vms-and-host` lists 10.250.0.1 and the three mgmt IPs (`allowlists.yml:8-10`). Every other request on those hosts falls to the priority-1 router with `host-only` and gets 403 (`prometheus.yml:9-14`, `loki.yml:9-14`, `allowlists.yml:5-7`). **Boundary:** VMs may write but not read | Traefik | None |
| 7 | Stores | Traefik forwards on `lab-backend` to `http://prometheus:9090` or `http://loki:3100` (`prometheus.yml:16-20`, `loki.yml:16-20`). Prometheus runs with `--web.enable-remote-write-receiver` and 2 days of retention (`services/monitoring/compose.yaml:9-13`). Loki has `auth_enabled: false`, 48 h retention and no delete API (`services/monitoring/files/loki/loki.yml:1,31-33`) | Traefik -> Prometheus, Loki | Volumes `prometheus-data`, `loki-data` |
| 8 | Viewing | Grafana reads both stores directly on `lab-backend` (`datasources.yml:1-15`). Its UI is reachable only from the host (`dynamic/grafana.yml:3-7`, `host-only`) | operator's browser -> Grafana | Volume `grafana-data` |

**Why here:** The telemetry path shares its first hops with the request path (DNS, the source checks) but takes the one VM -> host forward hole instead of the tunnels. Reading it after Steps 11.1-11.3 shows how the lab separates the data plane (tunnels) from the control and telemetry plane (mgmt).

**How it connects:**
- The same forward hole (`nftables-vmfw.nft:155`) carries be-1's Flux pull from Gitea (Step 11.2, row 7). Traefik's routers decide which of the two a request is.
- The mgmt IPs appear in `compute.tf`, `nftables-vmfw.nft:41,155` and `allowlists.yml:10,13` (R1).
- `monitoring.wait_ready` uses the host-only query routes before any VM exists (Step 3.10).

**Re-run and removal:** Agents reconnect and resend on their own. The stores keep their data across pipeline runs and VM rebuilds until retention expires it. `monitoring.down` deletes the volumes during `destroy` (Step 12.2).

**Check it yourself:**
- From the host, as yourself: `curl -sG --cacert state/pki/ca.pem https://prometheus.lab.test/api/v1/query --data-urlencode 'query=count by (instance) (node_load1)'` lists `host`, `fe-1`, `tun-1` and `be-1`.
- `ssh fe-1 "curl -s -o /dev/null -w '%{http_code}\n' https://loki.lab.test/loki/api/v1/labels"` prints `403`: a VM cannot read logs.
- `ssh be-1 "curl -s -o /dev/null -w '%{http_code}\n' https://gitea.lab.test/api/v1/version"` prints `403`, while `ssh be-1 "curl -s -o /dev/null -w '%{http_code}\n' 'https://gitea.lab.test/lab/lab.git/info/refs?service=git-upload-pack'"` prints `401` (the route lets be-1 through, and Gitea asks for credentials).

**Watch out:**
- Identity on this path is the source IP only. Any VM can push series or log lines labelled as another VM (a known limitation, R6).
- A failing push shows up only in the agent's own log (`journalctl -u alloy` on the VM). The pipeline only checks that the unit runs.

## Phase 12: Lifecycle: teardown, destroy, reboot, re-run

Phase 12 covers everything that happens to a built lab after its first green run: removing the VMs, removing the whole lab, and the situations that need an `update`. `sudo ./bootstrap.sh teardown` runs `cmd_teardown` (`main.py:91-98`). It brings the host platform up (Vault may be sealed after a reboot) and dispatches the pipeline workflow `teardown.yml`, whose only job runs `terraform destroy`. The host platform stays, and `update` builds the VMs again (Step 12.1). `sudo ./bootstrap.sh destroy` runs `cmd_destroy` (`main.py:101-105`). It runs `platform_down()`, fifteen `down()` calls in an order chosen so that each removal still works, then deletes `/var/lib/lab` and the marker (Step 12.2). Reboots, LAN IP changes, config edits and plain re-runs are all handled by `update` (Step 12.3). After `teardown` the host has its platform and no VMs. After `destroy` it is back to its pre-lab state, apart from a short list of things kept on purpose.

**Needs from earlier phases:**
- `state/initialized`, written by `cmd_up` (Step 5.1). `teardown` and `update` refuse without it, and `destroy` removes it.
- `teardown.yml` on Gitea's `main`, pushed by an earlier `up` or `update` (Steps 5.2, 5.4).
- The Terraform state in `/var/lib/lab/tfstate` (Step 6.2), and `/etc/lab-runner/ssh.pub` and `ca.pem`, which the configuration reads even for a destroy (`terraform/compute.tf:74-75`, Steps 4.8-4.9).
- Every `down()` from Phases 2-4, the names in `host/config/config.py:25-27` (`LAB_DOMAINS`, `LAB_NETWORKS`, `LAB_POOL`), and the guard `podman.check()` (Step 2.4).

**Hands on:**
- After `teardown`: no VMs, lab networks, pool or base image in libvirt, and an empty Terraform state. The host platform, Vault's secrets, the Gitea repo and the marker remain. The next `update` rebuilds everything.
- After `destroy`: no lab packages, containers, volumes, VMs, bridge, nft tables, certificates, Vault data or `/var/lib/lab`. Kept: the operator key `~/.ssh/lab_operator`, `state/bootstrap.log`, `state/run.lock`, the nftables package, the local git history, systemd-timesyncd (reinstalled), and packages that apt pulled in as dependencies (purge never autoremoves).
- Operating rules: what to run after a reboot, a LAN IP change or an edit, and what a plain re-run does.

### Step 12.1: teardown (VMs only)

**Files:**
- `.gitea/workflows/teardown.yml`: the dispatch-only workflow that destroys what `terraform.yml` created. New in this step.
- `main.py`: `cmd_teardown` (its gate is Step 1.7, its tail Step 5.1; read here as one flow).
- `services/gitea/gitea.py`: `dispatch` and `follow_run` only (built in Steps 5.2-5.3).
- `services/gitea/config/config.py`: `GITEA_TEARDOWN_WORKFLOW` and the poll settings (Step 4.1).

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `cmd_teardown() -> None` | Exits 1 if `state/initialized` is missing (`main.py:92-94`). No `commit_changes`: local edits are not pushed. Runs `platform_up()`; the comment says why: "after a reboot Vault is sealed and the runner is stopped" (`:95`). Gets the admin creds (`:96`), dispatches `teardown.yml` and follows the run (`:97`), then logs "teardown complete" (`:98`). The marker stays | `COMMANDS["teardown"]` (`main.py:111`) -> `platform_up`, `vault.login`, `gitea_admin`, `dispatch`, `follow_run` | Host (through `platform_up`) |
| 2 | `GITEA_TEARDOWN_WORKFLOW` | `"teardown.yml"`, "dispatch only; never triggered by a push" (`services/gitea/config/config.py:17`) | row 1 | None |
| 3 | `dispatch(creds: dict, workflow: str = config.GITEA_WORKFLOW) -> int` | `POST repos/lab/lab/actions/workflows/teardown.yml/dispatches?return_run_details=true` with `{"ref": "main"}`. A 404 means the file is not on `main`: it logs "is not on Gitea's main yet; run update first" and exits 1. Otherwise it returns `workflow_run_id` (`gitea.py:209-226`) | row 1 (also `start_run`, Step 5.2) -> `gitea_api` | A run on Gitea |
| 4 | `follow_run(creds: dict, run_id: int) -> None` | Polls the run every 10 s for up to 70 min (`config.py:19,21`), prints each job's conclusion and, for a failed job, the last 30 log lines. It exits 1 unless the run succeeded (`gitea.py:245-272`) | row 1 (also `cmd_up`, `cmd_update`, Step 5.1) -> `gitea_api` | None |
| 5 | Workflow header and trigger | `name: teardown`. The comment: it removes VMs, lab networks and pool, keeps the host platform, and is started only by `bootstrap.sh teardown` (`teardown.yml:1-4`). `on: workflow_dispatch` only (`:5-6`), so no push can ever start it | Gitea | None |
| 6 | `concurrency` | `group: lab-deploy`, `cancel-in-progress: false` (`teardown.yml:8-10`), the same group as `deploy.yml:8-10`. A teardown dispatched during a deploy waits for it, and the other way round. The single runner has `capacity: 1` (`services/gitea/runner/files/config.yaml:7`), but that alone would let jobs of two runs interleave | Gitea scheduler | None |
| 7 | Job `destroy` | `runs-on: host`, `env: TMPDIR: /var/lib/lab/tfstate` (`teardown.yml:12-16`), the same as the apply job (`terraform.yml:7-10`). Unlike `apply`, it does not check `/run/lab/vmfw.loaded`: removing VMs needs no firewall | runner | None |
| 8 | Step checkout | `actions/checkout@v4`, `persist-credentials: false` (`teardown.yml:18-20`): the Terraform files at Gitea's `main` | runner -> Gitea | Job workdir |
| 9 | Step "libvirt answers" | `virsh --connect qemu:///system list` (`teardown.yml:21-22`). It fails early if libvirt is down | runner -> libvirt | None |
| 10 | Step `terraform init` | `-input=false -lockfile=readonly` (`teardown.yml:23`): providers as pinned in `terraform/.terraform.lock.hcl`, local state in `/var/lib/lab/tfstate` (`terraform/provider.tf:15-17`) | runner -> Terraform | `terraform/.terraform/` in the workdir |
| 11 | Step `terraform destroy` | `-auto-approve -input=false` (`teardown.yml:24`). It destroys everything in the state: the three domains, their overlays, seed volumes and cloud-init disks, the base image volume, the pool `lab`, the four networks and the three `ansible_host` entries | runner -> libvirt | Empties the state; removes libvirt objects and their volume files |

**Why here:** `teardown` is the inverse of the terraform job (Phase 6), run through the same runner and state. It needs the platform up: Vault for the admin creds, Gitea for the dispatch, the runner to execute the job. That is why it runs `platform_up` first, even though it removes VMs. It skips the commit on purpose, because it only dispatches what is already on `main`.

**How it connects:**
- The next `update` runs `deploy.yml`. Its terraform job recreates everything, including the base image download (`terraform/storage.tf:9-22`). Ansible then builds new tunnels, a new k3s cluster and an empty database (Phases 7-10).
- Vault's secrets are untouched, so the VMs get the same SSH keys, the same `authenticator` password and the same `app-edge` certificate (Step 3.7).
- The marker stays, so `up` after `teardown` still says "use update" (`main.py:70-72`).

**Re-run and removal:** A second `teardown` on an empty state destroys nothing and succeeds. Without the marker it exits 1 before doing anything. The workflow file itself is removed only with the Gitea repo (`destroy`, Step 12.2).

**Check it yourself:**
- `virsh -r -c qemu:///system list --all` lists no `fe-1`, `tun-1` or `be-1`, and `virsh -r -c qemu:///system net-list --all` lists no `site-a`, `site-hub`, `site-c` or `wan`.
- `ls -l state/initialized` still exists.
- (sudo) `sudo terraform -chdir=terraform state list` prints nothing (the state folder is root-only; run `terraform init` there first if the checkout has no `.terraform/`).

**Watch out:**
- `teardown` runs the full `platform_up`, which applies any uncommitted host-side edits in the working tree without committing them (Step 5.1).
- It deletes be-1's database. There is no backup.
- A local edit to `teardown.yml` takes effect only after an `update` has pushed it.

### Step 12.2: destroy (whole lab) and the down order

**Files:**
- `main.py`: `cmd_destroy` and `platform_down` (the lock in `main()` is Step 1.2).
- `services/gitea/runner/runner.py` and `services/gitea/runner/config/config.py`: `down` and the paths it removes, including `OLD_USER` (Steps 4.7-4.10).
- `host/ssh_access.py`, `host/toolchain.py`, `host/kvm.py`, `host/vmfw.py`, `host/ntp.py`, `host/network.py`, `host/config/config.py`: their `down()` and the names and packages they remove (Phase 2, Step 4.6).
- `services/monitoring/monitoring.py`, `services/gitea/gitea.py`, `services/traefik/traefik.py`, `services/vault/vault.py`, `lib/pki.py`, `services/squid/squid.py`, `services/coredns/dns.py`: their `down()` (Phases 3-4).
- `podman/podman.py` and `podman/config/config.py`: `check`, `down` and the package list (Step 2.4).
- `lib/system.py`: `apt_purge` (Step 1.5).

**Build, in this order** (call order; the reason for each position is in bold):

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `cmd_destroy() -> None` | No marker check, no commit, no confirmation. `platform_down()`, then `shutil.rmtree(/var/lib/lab, ignore_errors=True)`, then `state/initialized.unlink(missing_ok=True)`, then "destroy complete" (`main.py:101-105`). It still takes the run lock, so it cannot overlap another bootstrap run (`main.py:141-146`). It makes no API calls, so it works on a lab whose Vault or Gitea is broken | `COMMANDS["destroy"]` (`main.py:112`) -> rows 2, 20, 21 | See below |
| 2 | `platform_down() -> None` | The fifteen `down()` calls in rows 5-19, "in the order that keeps each removal possible" (`main.py:50-66`). Any exception stops it, and `main()` returns 1 (`main.py:149-160`). Every `down()` is safe to run again, so the fix is to correct the cause and run `destroy` again | row 1 | None itself |
| 3 | `check() -> bool` and `socket_ready() -> bool` (podman) | `check` is true when every Podman package is installed and `podman.socket` is enabled and active (`podman/podman.py:30-35`). The service downs use it as their guard: without Podman there is nothing for compose to remove | rows 10-13, 15, 16 | Reads dpkg, systemd |
| 4 | `apt_purge(packages: list[str]) -> None` | `apt-get purge -y -qq` with a 120 s lock timeout (`lib/system.py:46-49`). It does not autoremove, so dependencies that apt pulled in stay | rows 7, 8, 14, 17, 18 | Removes packages and their config |
| 5 | `runner.down() -> None` | If the unit exists: `systemctl disable --now lab-runner`, delete the unit, `daemon-reload`. Then remove `/etc/lab-runner`, `/usr/local/bin/gitea-runner` and `/var/lib/lab/runner`. Last, `userdel lab-runner` if that old user still exists (`OLD_USER`, "the runner ran as this user until 2026-11-18", `services/gitea/runner/config/config.py:12`) (`runner.py:114-129`). **First:** a job in progress needs the toolchain, libvirt and the services removed below. Stopping the runner first means no job runs while they disappear. The stop gives a running job up to 60 s (`lab-runner.service:16`) | `platform_down` (`main.py:52`) -> systemctl, userdel | Unit, config, CA and `ssh.pub` copies, binary, registration file, job workdirs |
| 6 | `ssh_access.down() -> None` | Deletes `/etc/ssh/ssh_config.d/60-lab-ssh.conf`. Keeps the operator key, "a personal key the next up reuses" (`host/ssh_access.py:51-54`). **Any position works:** nothing below uses the aliases. It mirrors step 15 of `platform_up` | `main.py:53` | SSH alias file |
| 7 | `toolchain.down() -> None` | Deletes `/usr/local/bin/terraform`, `node` and `trivy`, removes the whole `ansible_collections/cloud` folder, purges `ansible-core` (`host/toolchain.py:124-131`). **After the runner:** only pipeline jobs use these tools. Nothing below needs them (`kvm.down` uses `virsh`, not Terraform) | `main.py:54` -> `apt_purge` | Binaries, collection, package |
| 8 | `kvm.down() -> None` with `remove_lab_vms() -> None` | If `virsh` exists: `destroy` then `undefine` each of `fe-1`, `tun-1`, `be-1`; `net-destroy`/`net-undefine` `site-a`, `site-hub`, `site-c`, `wan`; `pool-destroy`/`pool-undefine` `lab`. Errors are ignored, so missing objects are skipped (`host/kvm.py:33-40`). Then it purges the libvirt and QEMU packages (`:43-48`). The disk files go later with `/var/lib/lab`. **Before `vmfw.down`:** the VMs are powered off while `lab_sg` and `lab_vmfw` still filter them, so no VM ever runs unfiltered. **Before `network.down`:** the mgmt taps sit on `mgmtbr1`. **Before the `rmtree` in row 20:** the disks are not in use when they are deleted | `main.py:55` -> virsh, `apt_purge` | Domains, networks, pool, packages |
| 9 | `vmfw.down() -> None` | `nft destroy table bridge lab_sg` and `inet lab_vmfw` (no error if absent), then delete `/run/lab/vmfw.loaded` (`host/vmfw.py:40-45`). The nftables package stays: "never purged" (`host/config/config.py:58-59`). **After `kvm.down`:** see row 8. libvirt's and Podman's own nft tables are not touched | `main.py:56` -> nft | Two tables, marker |
| 10 | `monitoring.down() -> None` | If `podman.check()`: `compose monitoring down --volumes`, which removes Prometheus, Loki, Grafana and the host Alloy with their data (`services/monitoring/monitoring.py:64-70`). **Before `traefik.down`:** its containers sit on `lab-backend`, and Compose deletes a network only when no container is attached to it. Monitoring's project also declares `lab-backend` without `external` (`services/monitoring/compose.yaml:81-83`), so its own down leaves the network in place while Traefik and Gitea are still attached. **Before `pki.down`:** the host Alloy bind-mounts `state/pki/ca.pem` (`compose.yaml:72`) | `main.py:57` -> `podman.check`, compose | Containers, 4 volumes |
| 11 | `gitea.down() -> None` | If `podman.check()`: `compose gitea down --volumes`. The repo, the admin, the runner registration and the tokens go with the volumes (`services/gitea/gitea.py:296-302`). Its project marks `lab-backend` as `external` (`services/gitea/compose.yaml:28-31`), so it never deletes the network. **Before `traefik.down`:** it is the other member of `lab-backend` | `main.py:58` -> compose | Container, 2 volumes |
| 12 | `traefik.down() -> None` | If `podman.check()`: `compose traefik down`, which removes the container and the network `lab-backend` that its project owns (`services/traefik/traefik.py:18-24`, `services/traefik/compose.yaml:23-25`). **After rows 10-11:** only now does no container use the network. **Before `pki.down`:** it mounts the `gateway` leaf (`compose.yaml:19-20`) | `main.py:59` -> compose | Container, network |
| 13 | `vault.down() -> None` | If `podman.check()`: `compose vault down --volumes`, then delete `vault-init.json` and `approle.json`. The unseal key goes only after the data it unlocks (`services/vault/vault.py:250-258`). Without Podman it logs that the data and key are kept. **After Gitea and monitoring:** the reverse of `platform_up`, where both are Vault clients. **Before `pki.down`:** Vault mounts its leaf and `ca.pem` (`services/vault/compose.yaml:18-20`) | `main.py:60` -> compose | Container, network `lab-vault`, volume, both JSON files |
| 14 | `pki.down() -> None` | Removes `state/pki` (the CA key included) and purges `golang-cfssl` (`lib/pki.py:54-58`). **After rows 10, 12 and 13:** the three containers that bind-mount files from `state/pki` are gone. Deleting the files earlier would not make those downs fail, but a container that restarted in between could not mount them | `main.py:61` -> `apt_purge` | Certificates, keys, package |
| 15 | `squid.down() -> None` | If `podman.check()`: `compose squid down` (`services/squid/squid.py:23-29`). The access log inside the container goes with it. **Before `podman.down`:** compose needs the socket and the plugin. Otherwise its position mirrors `platform_up` | `main.py:62` -> compose | Container |
| 16 | `dns.down() -> None` | If `podman.check()`: `compose coredns down` with `HOST_IP` from a live `detect_network()` (`services/coredns/dns.py:20-26`). **Before `podman.down`:** as row 15 | `main.py:63` -> `detect_network`, compose | Container |
| 17 | `podman.down() -> None` | If `podman` exists: `systemctl disable --now podman.socket` and `podman system reset --force` (all containers, images, volumes). Then remove `/var/lib/containers` in any case, purge whichever of `PACKAGES + DEPENDENCIES` are installed, and delete the alvistack key, source and pin (`podman/podman.py:51-66`, `podman/config/config.py:8-17`). **After every service down:** they need compose and the socket, and with Podman gone their guard would skip them. The reset would still remove their containers, so the order keeps each step doing its own removal and logging it. **Before `ntp.down`:** the reverse of `platform_up` (ntp is step 3, podman step 4). A side effect: the `apt-get update` inside `ntp.down` no longer reads the alvistack source | `main.py:64` -> systemctl, podman, `apt_purge` | Socket, all Podman storage, packages, apt repo files |
| 18 | `ntp.down() -> None` | Deletes the chrony conf and drop-in, removes the drop-in folder if empty, `daemon-reload`, purges `chrony`, then installs `systemd-timesyncd` again, because chrony replaced it (`host/ntp.py:34-45`). The install runs `apt-get update` and needs internet (`lib/system.py:31-43`). **Before `network.down`:** chrony listened on 10.250.0.1 (`host/files/chrony-lab.conf:7`). It mirrors `platform_up` | `main.py:65` -> `apt_purge`, `apt_install` | chrony files and package, timesyncd |
| 19 | `network.down() -> None` | Deletes the netplan file, runs `netplan apply`, then `ip link delete` `mgmtbr1` and `mgmtbr1-anchor` if they still exist, "networkd leaves removed devices in place" (`host/network.py:75-82`). **Last:** 10.250.0.1 on `mgmtbr1` carried everything above: chrony, CoreDNS, Squid, the Vault and Traefik port mappings, and every VM's mgmt tap. Nothing may still use it | `main.py:66` -> netplan, ip | Netplan file, bridge, anchor |
| 20 | `shutil.rmtree(config.LAB_DIR, ignore_errors=True)` | Deletes `/var/lib/lab`: the Terraform state, the pool (VM overlays, seeds, base image), `images/frontend.tar`, `downloads/` (the Alloy package), and the Vault JSON files if row 13 skipped them (`main.py:103`). **After `platform_down`:** the VMs using the disks are off (row 8), and no job writes here any more (row 5) | `cmd_destroy` | `/var/lib/lab` |
| 21 | `INITIALIZED_MARKER.unlink(missing_ok=True)` | Deletes `state/initialized` (`main.py:104`). **Last:** from now on, `up` is the command that works, and `update` and `teardown` refuse | `cmd_destroy` | `state/initialized` |

**Why here:** `destroy` undoes Phases 2-4 in reverse, and with them everything the pipeline built, since the VMs, their disks and their state live in libvirt and `/var/lib/lab`. The order is the reverse of `platform_up` (`main.py:32-47` vs `:52-66`), except that `toolchain`, `kvm` and `vmfw` are moved ahead of every service down, and `kvm` ahead of `vmfw` (table below). Five positions matter on their own: the runner first, `kvm` before `vmfw`, the `lab-backend` members before Traefik, every compose service before Podman, and `network` last. Moving the three host downs forward is a grouping choice: it stops the VMs and the pipeline tools first, and no service down needs them (R5 row 34). It does not run `terraform destroy`. It removes libvirt objects by the names copied into `host/config/config.py:25-27`, then deletes the state with `/var/lib/lab`.

| Down # (row above) | `down()` | `platform_up` step | Position compared with an exact reverse |
|---|---|---|---|
| 1 (row 5) | `runner` | 16 | Reverse. First on purpose (H, R5 row 33) |
| 2 (row 6) | `ssh_access` | 15 | Reverse |
| 3 (row 7) | `toolchain` | 7 | Moved ahead of the service downs (G, R5 row 34) |
| 4 (row 8) | `kvm` | 5 | Moved ahead of the service downs (G, R5 row 34), and ahead of `vmfw`, which reverses their up order (H, R5 row 35) |
| 5 (row 9) | `vmfw` | 6 | Moved ahead of the service downs (G, R5 row 34) |
| 6-12 (rows 10-16) | `monitoring`, `gitea`, `traefik`, `vault`, `pki`, `squid`, `dns` | 14 down to 8 | Reverse |
| 13 (row 17) | `podman` | 4 | Reverse |
| 14 (row 18) | `ntp` | 3 | Reverse |
| 15 (row 19) | `network` | 2 | Reverse. Last on purpose (H, R5 row 40) |
| - | `preflight` | 1 | Has no `down()` |

**How it connects:**
- `LAB_DOMAINS`, `LAB_NETWORKS` and `LAB_POOL` must match the names in `terraform/compute.tf:3,16,29`, `network.tf:2,15,28,41` and `storage.tf:2`. A renamed VM or network would survive `destroy` as an orphan in libvirt until the libvirt purge (R1).
- The operator key survives, so the next `up` reuses it. The VMs then get the same operator key line, while the pipeline key is new, because Vault was wiped (Steps 3.7, 4.6).
- After `destroy`, `up` starts from scratch: new CA, new Vault, new Gitea repo (the full local history is pushed again), new runner registration (Step 1.7).

**Re-run and removal:** Every `down()` is guarded or tolerant: `missing_ok` unlinks, `ignore_errors` rmtrees, `nft destroy` (no error if absent), `shutil.which` checks, `podman.check()`, the installed-package filter in `podman.down`, and `virsh` errors ignored. `apt-get purge` of a package that is known but not installed succeeds. So `destroy` on a fresh host, or a second `destroy`, runs to the end.

**Check it yourself:**
- `ls state/` shows only `bootstrap.log` and `run.lock`, and `ls /var/lib/lab` fails with "No such file or directory".
- `ip link show mgmtbr1` fails with "does not exist". `dpkg -l chrony libvirt-daemon-system podman golang-cfssl ansible-core 2>&1 | grep '^ii'` prints nothing.
- `ls -l ~/.ssh/lab_operator` still exists, and `systemctl is-active systemd-timesyncd` prints `active`.

**Watch out:**
- There is no prompt. `destroy` deletes every Vault secret, the Gitea repo, all metrics and logs, and be-1's database at once. Your local git checkout is the only copy of the code that survives.
- It needs a default route and internet. `dns.down` calls `detect_network()`, which raises `IndexError` without a default route (`host/preflight.py:23`), and that stops `destroy` at row 16 with Podman, chrony and the bridge still in place. `ntp.down` downloads `systemd-timesyncd`.
- `vault.down`'s message "data and unseal key are kept" (when Podman is not set up) is true only for that function. Under `destroy`, `podman.down` removes `/var/lib/containers` anyway (`podman/podman.py:57`) and row 20 removes the JSON files.
- "Everything the lab installed is removed" (`main.py:105`) is not quite true. Dependencies of the purged packages stay (no autoremove), as do the nftables package, the loaded `nf_conntrack_bridge` module, an empty `/run/lab` until reboot, and Python 3.12 if `bootstrap.sh` installed it (`bootstrap.sh:23-41`).

### Step 12.3: Reboot, LAN IP change, config edits, re-run

**Files** (read here for their lifecycle behaviour only):
- `host/config/config.py`: `VMFW_MARKER` in `/run` (Step 2.0).
- `terraform/compute.tf` (`running`, `autostart`) and `terraform/network.tf` (`autostart`): what comes back after a reboot (Steps 6.4, 6.7).
- `main.py`: the marker in `state/` and the `up` gate (Step 1.7).
- `host/preflight.py` (`detect_network`), `host/vmfw.py`, `services/coredns/dns.py`: the two live readers of the LAN IP (Steps 2.1, 2.6, 3.1).
- `services/coredns/conf/Corefile` and `services/coredns/compose.yaml`: the `reload` plugin and the folder mount (Step 3.1).
- `services/squid/squid.py`, `services/monitoring/monitoring.py`, `services/monitoring/config/config.py`, `services/traefik/compose.yaml`, `services/vault/compose.yaml`, `services/vault/vault.py`, `services/gitea/runner/runner.py`: how each picks up a change or a restart (Phases 3-4).
- `host/files/chrony-makestep.conf`: the host clock after a suspend (Step 2.3).

**Build, in this order** (one row per lifecycle mechanism):

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `INITIALIZED_MARKER` | `state/initialized` lives in the checkout (`main.py:27`), so it survives a reboot. `up` on a built lab only logs "use update" and returns (`main.py:70-72`). After the first run, the recovery command is always `update` | `cmd_up`, `cmd_update`, `cmd_teardown`, `cmd_destroy` (unlinks it) | `state/initialized` |
| 2 | `VMFW_MARKER` and the nft tables | Both live in memory: `/run/lab/vmfw.loaded` ("/run empties on reboot, like the rules", `host/config/config.py:63`) and the two tables. After a reboot the terraform job refuses to run (`terraform.yml:15-16`) until `vmfw.up` reloads the rules and touches the marker (`host/vmfw.py:22-37`) | `vmfw.up` (every `update`) | Kernel tables, marker |
| 3 | `running = true`, `autostart = false` | The domains do not start at boot: "vmfw rules vanish on reboot; no VM boots before `bootstrap up` reloads them" (`terraform/compute.tf:97-98`). The command meant is `update`, since `up` returns early. The pipeline's apply sees `running = true` and starts them again (Step 6.7) | Terraform (pipeline) | Domain state |
| 4 | Network `autostart = true` | The four libvirt networks come back at boot (`terraform/network.tf:3,16,29,42`). `mgmtbr1` comes back from its netplan file. When the VMs start later, their taps join the bridges | libvirt, netplan | Bridges |
| 5 | Containers after a boot | Every compose service has `restart: unless-stopped` (for example `services/vault/compose.yaml:7`). Whether Podman restarts them at boot is decided outside the repo, which sets up no boot unit for them. Every `update` runs each service's `compose up -d` (Phase 3), which starts any stopped container | `*.up()` -> compose | Containers |
| 6 | `unseal(key: str, timeout: int = 30) -> None` | A Vault container that has restarted is sealed. `vault.up` unseals it with the key from `vault-init.json` on every run and waits until it is active (`services/vault/vault.py:77-94, 230-232`). Until then, the pipeline's `vault-action` fails | `vault.up` | Vault seal state |
| 7 | `ensure_service(changed: bool) -> None` | The runner unit is enabled (`lab-runner.service:19`). `main.py:95` says the runner is stopped after a reboot. Either way, `runner.up` restarts it if it is not active (`services/gitea/runner/runner.py:89-100`) | `runner.up` | `lab-runner.service` |
| 8 | `detect_network() -> dict` | Reads the LAN card and address live from the default route (`host/preflight.py:21-36`). Four places call it. `preflight.log_network` only logs it (`preflight.py:41`), and `dns.down` passes it to compose for the `${HOST_IP}` variable (`dns.py:25`). Two configure something with it: `dns.up` passes `HOST_IP` to CoreDNS (`dns.py:15-16`), and `vmfw.up` hands it to `render_rules`, which defines `$lan_card`/`$host_ip` (`vmfw.py:13-19,28-29`). After a DHCP change, `app.lab.test` points at the old address and the DNAT matches the old address, until the next `update`. Then compose recreates CoreDNS (its env changed) and vmfw reloads. The LAN clients' DNS setting must be changed by hand | `preflight.log_network`, `vmfw.up`, `dns.up`, `dns.down` | None |
| 9 | Corefile `reload` | CoreDNS watches its config (`Corefile:11`), and compose mounts the folder, not the file (`services/coredns/compose.yaml:12`). A Corefile edit goes live on its own within about half a minute (the plugin's default check interval), without a run. The edit still needs `update` to reach Git | CoreDNS | None |
| 10 | `SQUID_CONF_HASH` | `squid.up` passes the sha256 of `squid.conf` as an env var (`services/squid/squid.py:16-20`, `compose.yaml:10`). An edit changes the env, and compose recreates the container on the next `update` | `squid.up` | Squid container |
| 11 | `CONF_HASHES` and `conf_hash(folder: Path) -> str` | One hash per config folder: prometheus, loki, alloy, grafana (`services/monitoring/config/config.py:9-14`, `monitoring.py:22-26,57`). Editing a file recreates only that container | `monitoring.up` | One container |
| 12 | `certs_changed` | `pki.up()` returns True when it issued anything. Vault and Traefik then get `--force-recreate`, because they read their certificates at start (`main.py:41-43`, `vault.py:228-229`, `traefik.py:12-15`). Monitoring does not get the flag, so the host Alloy keeps an old CA (Step 3.10) | `platform_up` | Vault, Traefik containers |
| 13 | Traefik dynamic files | The file provider watches `/etc/traefik/dynamic`, a mounted folder (`services/traefik/compose.yaml:11,18`), so route and allowlist edits apply live. A change to `compose.yaml` itself recreates the container on `update` | Traefik | None |
| 14 | `vault.hcl` | A single bind-mounted file with no hash (`services/vault/compose.yaml:16`). `update` does not apply an edit to it until the container is recreated for another reason (Step 3.4). Policy files, by contrast, are re-uploaded on every run (`vault.py:149-160`) | none | None |
| 15 | Other host files | Applied on the next `update` by their `install_file` checks: netplan (then `netplan apply` and `reattach_taps`, `host/network.py:58-72`), chrony (restart, `host/ntp.py:17-25`), the runner config and unit (restart, `runner.py:48-58, 89-100`), the SSH aliases. `nftables-vmfw.nft` is reloaded on every run, changed or not (`vmfw.py:31-32`) | the step's `up()` | Host files |
| 16 | Pipeline-side edits | `terraform/`: the apply job. The edits that rebuild a VM are listed in R4. `ansible/`: the configure job, idempotent except for handlers. `kubernetes/`: Flux applies a pushed commit within about a minute, whatever the pipeline does (`flux-sync.yaml:7`). `frontend/`: a new image tag, so the Quadlet changes and the frontend restarts (Step 9.1). `ansible/roles/fluxcd/files/flux-sync.yaml`: only when the fluxcd role runs | pipeline, Flux | VMs, cluster |
| 17 | `chrony-makestep.conf` | `ExecStartPost=-+/usr/bin/chronyc makestep 1 -1` (`host/files/chrony-makestep.conf:4-5`) lets the running chrony step the clock whenever it is more than 1 s off. After a VMware suspend/resume the host corrects itself, and the VMs follow through timesyncd (`PollIntervalMaxSec=256`, `ansible/roles/common/tasks/main.yml:10-21`) | chrony | Host clock |

**Situations and what to run:**

| Situation | What breaks until you act | What to run | What that run does |
|---|---|---|---|
| Host reboot | VMs off; nft tables and `/run/lab/vmfw.loaded` gone; Vault sealed (if its container runs); runner maybe not active | `sudo ./bootstrap.sh update` | `platform_up` reloads vmfw, starts stopped containers, unseals Vault and restarts the runner (rows 2, 5-7). Then it pushes or dispatches `deploy.yml`, whose apply starts the VMs (row 3) and whose Ansible run checks every role. The data on the VM disks survives |
| Host LAN IP changes | `app.lab.test` answers the old IP; DNAT matches the old IP | `update`, then point the LAN clients' `lab.test` DNS at the new IP | CoreDNS is recreated with the new `HOST_IP`, and vmfw is reloaded with the new `$host_ip` (row 8). The VMs and the 10.250.0.1 services are not affected |
| Host suspend/resume | The clock jumps; apt and TLS can fail | nothing, normally | chrony steps the clock (row 17) |
| Edit a host-side file | Not applied (the Corefile and Traefik's route files apply live, rows 9 and 13) | `update` | It commits the edit, applies it on the host (rows 9-15), then runs the pipeline on the new commit |
| Edit a VM-side or cluster file | Not applied (Flux: applied within a minute of the push) | `update` | The pipeline applies it, with Flux for `kubernetes/` (row 16) |
| Nothing changed | Nothing | `update` | A full idempotent re-run (see below) |
| Want the VMs gone but keep the platform | Nothing | `teardown` | Step 12.1 |

**What a plain `update` re-run does:** `commit_changes` finds a clean tree. Most `up()` functions log "already ..." and change nothing. Some work is done on every run anyway: the alvistack key is downloaded again (`podman/podman.py:16`), vmfw is reloaded (`host/vmfw.py:31-32`), `network.up` reattaches any detached taps (`host/network.py:66`), `virsh list` is probed (`host/kvm.py:26-30`), five AppRole logins create 1 h tokens that are never revoked (Step 5.1), and `monitoring.wait_ready` checks the stores. `start_run` then dispatches `deploy.yml` on the same commit, because Gitea's `main` already holds it (`gitea.py:275-280`). The pipeline rebuilds the image under the same tag, plans no Terraform change, and runs every play. `app_deployed` passes at once, because `lab-apps` already shows this revision. A new commit, by contrast, leaves one more `localhost/frontend:<sha>` image on the host and on fe-1, and nothing prunes them (Step 5.6). If a VM was rebuilt, its new WireGuard key changes its peers' `wg*.conf`, and the handler restarts their tunnels (`ansible/roles/wireguard/tasks/main.yml:14-22`, Step 7.5).

**Why here:** These are the rules for operating the lab day to day, and they depend on every phase. They come last because each one combines facts from several steps: the marker (Step 1.7), the `/run` marker and live LAN reads (Steps 2.1, 2.6), the change detection of each service (Phase 3), and the rebuild rules (Step 6.7).

**How it connects:**
- `update` is the one command for every situation after the first `up`. It re-applies the host (Phases 2-4) and re-runs the pipeline (Phases 5-10).
- Row 3 couples the host firewall to VM start: no VM boots without vmfw, because the terraform job checks the marker (Step 6.1) and the domains never autostart.
- Rows 9-14 explain why some edits apply without a recreate (Corefile, Traefik routes) and one does not apply at all on `update` (`vault.hcl`).

**Re-run and removal:** This step is itself about re-runs. Nothing here creates state that needs its own removal.

**Check it yourself:**
- After a reboot, before `update`: `ls /run/lab/vmfw.loaded` fails, and `virsh -r -c qemu:///system list --all` shows the three domains `shut off`.
- `curl -s --cacert state/pki/ca.pem https://10.250.0.1:8200/v1/sys/seal-status` shows `"sealed":true` after a reboot (if the Vault container is running) and `false` after `update`. The Vault certificate includes 10.250.0.1 (`lib/config.py:36`).
- After a LAN IP change: `getent hosts app.lab.test` shows the old address until `update`, and the new one after it. Compare it with `ip -4 addr show` on the LAN card.

**Watch out:**
- After a reboot run `update`, not `up`, whatever the comment at `terraform/compute.tf:98` says (Step 6.7, Watch out).
- After a reboot, Vault stays sealed until `update`. Any pipeline run started in between (for example a dispatch from Gitea's UI) fails at `vault-action`.
- Editing the hosts of a certificate in `lib/config.py:34-39` does not re-issue it. Delete that leaf's `.pem` first (Step 3.3).
- `teardown` and `update` apply uncommitted host-side edits. Only `update` commits them (Step 5.1).

## Reference

These tables collect what spans many steps. Each row points back to the step that walks it.

### R1: Contracts: values copied by hand

No code checks that these copies agree. Change one copy and you must change the others in the same commit.

| Value | Copies (file:line) | What breaks if they disagree |
|---|---|---|
| VM names `fe-1`, `tun-1`, `be-1` | `terraform/compute.tf:3,16,29`; `host/config/config.py:25` (`LAB_DOMAINS`); `host/files/60-lab-ssh.conf:6,14,17,20`; `ansible/host_vars/<vm>.yml` file names and `peer:` (`fe-1.yml:5`, `be-1.yml:5`, `tun-1.yml:6,14`) | `destroy` misses a VM, `reattach_taps` misses its tap, `ssh <vm>` fails, WireGuard templates fail on a missing `hostvars` entry. The k3s Ready wait uses `node/{{ inventory_hostname }}`, which must equal the cloud-init hostname (`compute.tf:77`) |
| Tap names `<vm>-wan`, `<vm>-mgmt` (`<vm>-vpc` is named only in Terraform, `compute.tf:151`, and is not a contract) | `terraform/compute.tf:157,163`; `host/files/nftables-vmfw.nft:15-41`; `host/network.py:41` (`f"{vm}-mgmt"`) | A renamed tap is in no security-group set: `lab_sg` stops filtering it (`nftables-vmfw.nft:52,65` return early) |
| libvirt networks `site-a`, `site-hub`, `site-c`, `wan`; pool `lab` | `terraform/network.tf:2,15,28,41`; `terraform/storage.tf:2`; `host/config/config.py:26-27`; `nftables-vmfw.nft:147,150,152-153,156-157` | `destroy` leaves an orphan; the vmfw forward and input rules stop matching a renamed bridge |
| Bridge `mgmtbr1` and anchor `mgmtbr1-anchor`, 10.250.0.1/24 | `lib/config.py:17-18`; `host/config/config.py:8`; `host/files/60-lab-mgmtbr1.yaml:6,8-10`; `terraform/compute.tf:162`; `nftables-vmfw.nft:147,155-157,174-178` | VMs attach to nothing; vmfw rules stop matching |
| Host service address 10.250.0.1 | `Corefile:3,5,19`; `squid.conf:4`; `host/files/chrony-lab.conf:7`; `services/traefik/compose.yaml:15`; `services/vault/compose.yaml:10`; `lib/config.py:36,43` (via `VMNET`); `terraform/cloud-init/network-config.yaml.tftpl:22`; `ansible/group_vars/all.yml:4`; `nftables-vmfw.nft:155,175-176`; `services/traefik/dynamic/allowlists.yml:7,10,13` | Services bind an address the VMs do not use; the host-only allowlist rejects the host |
| VM mgmt IPs 10.250.0.110/.111/.112 | `terraform/compute.tf:11,24,37`; `nftables-vmfw.nft:41,155`; `allowlists.yml:10,13`; `squid.conf:8` (be-1 only); `60-lab-ssh.conf:15,18,21`; `Corefile:7` (`k3s.lab.test`, which nothing uses) | Source checks drop the VM; Traefik returns 403; Squid denies be-1; `ssh <vm>` goes nowhere |
| VM wan IPs 198.51.100.11-.13, gateway .1 | `terraform/compute.tf:10,23,36`; `terraform/network.tf:54`; `network-config.yaml.tftpl:15`; `nftables-vmfw.nft:40,121,128,150` | Source checks drop the VM; the LAN DNAT points at nothing |
| VPC IPs 10.1.1.10, 10.3.1.10 and ranges 10.1/16, 10.2/16, 10.3/16 | `terraform/compute.tf:9,22,35`; `ansible/host_vars/*.yml` (`allowed_ips`); `ansible/roles/wireguard/files/hub-forward.nft:13`; `frontend/app.py:10`; `demo/load.sh:6`; `kubernetes/apps/db/networkpolicy.yaml:99` | The hub drops the API call; CNPG instances lose the API server (failover breaks) |
| API port 8000 | `ansible/roles/k3s/files/traefik-config.yaml:12`; `hub-forward.nft:13`; `frontend/app.py:10`; `demo/load.sh:6` | The frontend gets 502. (Port 8000 in `networkpolicy.yaml:88,96` is CNPG's status port, an unrelated value) |
| WireGuard ports 51820/51821, interfaces `wg0`/`wg1`, tunnel IPs 10.99.0.x/10.99.1.x | `host_vars/tun-1.yml:3-5,11-13`; `fe-1.yml:3-6`; `be-1.yml:3-6`; `nftables-vmfw.nft:99-100`; `hub-forward.nft:13,26-28` | `lab_sg` drops the handshake; the hub filter stops matching |
| Ansible groups `frontend`, `hub`, `backend` | `terraform/compute.tf:4,17,30`; `ansible/site.yml:9,18,24`; `ansible/roles/wireguard/tasks/main.yml:33,47,58,66` (`'hub' in group_names`) | Play 1 fails; the hub gets no filter or forwarding |
| SSH user `user`, operator key name `lab_operator` | `terraform/cloud-init/user-data.yaml.tftpl:3`; `terraform/inventory.tf:7`; `60-lab-ssh.conf:7-8`; `host/config/config.py:68` | Ansible or `ssh <vm>` cannot log in |
| Runner label `host` | `services/gitea/runner/files/config.yaml:11`; `runs-on: host` in `check.yml:8`, `image.yml:8`, `terraform.yml:8`, `ansible.yml:8`, `teardown.yml:14` | Jobs wait for a runner forever (`follow_run` times out after 70 min) |
| Workflow file names and concurrency group | `services/gitea/config/config.py:16-17`; `.gitea/workflows/*.yml`; `deploy.yml:14,17,20,23` (`uses:`); `deploy.yml:9`, `teardown.yml:9` (`lab-deploy`) | Dispatch gets 404; a teardown could interleave with a deploy |
| Repo `lab/lab` and its URL | `services/gitea/config/config.py:13-15`; `ansible/roles/fluxcd/files/flux-sync.yaml:9`; `services/traefik/dynamic/gitea.yml:4` (`PathPrefix(/lab/lab.git/)`) | Flux gets 403 from the host-only catch-all |
| Flux Git user `labadmin` | `lib/config.py:8`; `ansible/roles/fluxcd/defaults/main.yml:2`. `gitea.flux_token` stores the username in Vault (`gitea.py:147`), but the template uses the role default | The token belongs to one user and the Secret names another |
| Vault KV paths | `services/gitea/config/config.py:4-6`; `services/gitea/runner/config/config.py:18`; `services/monitoring/config/config.py:21`; `services/vault/vault.py:97-146`; `.gitea/workflows/ansible.yml:26-30`; `services/vault/policies/lab-pipeline.hcl:6` | `vault-action` fails, or a policy denies the read |
| AppRole role name = policy file name | `gitea.py:131` (`"lab-pipeline"`); `services/vault/policies/lab-pipeline.hcl`; `vault.py:238` (`"lab-bootstrap"`) | The role's tokens get a policy that does not exist |
| Squid address `proxy.lab.test:3128` | `squid.conf:4`; `ansible/group_vars/all.yml:3`; `kubernetes/cnpg/proxy-secret.yaml:9`; `kubernetes/monitoring/proxy-secret.yaml:9` | apt, the k3s install and the chart pulls fail |
| `lab.test` names | `Corefile:5-7`; `lib/config.py:36-38` (SANs); `services/traefik/dynamic/*.yml` (`Host()`); client URLs in `gitea/config/config.py:9`, `gitea/runner/config/config.py:23` (`INSTANCE`), `monitoring/config/config.py:17-20`, `ansible.yml:20`, `config.alloy.j2:30,64`, `host.alloy:33,77`, `kubernetes/monitoring/helmrelease.yaml:34,37`, `flux-sync.yaml:9` | DNS fails, TLS fails (name not in the SANs), or Traefik matches no router (404) |
| Secret `db/db-authenticator` (basic-auth) | `ansible/roles/app_secrets/templates/db-authenticator.yaml.j2:3-9`; `kubernetes/apps/db/postgres.yaml:33-34`; `kubernetes/apps/db/postgrest.yaml:26,31` | PostgREST and the managed role have no password; `lab-apps` never turns healthy |
| Secret `flux-system/flux-git-auth`, key `ca.crt` | `ansible/roles/fluxcd/templates/flux-git-auth.yaml.j2:4,10`; `flux-sync.yaml:13`; `kubernetes/monitoring/helmrelease.yaml:20,24` | Flux cannot pull; the collector cannot verify TLS |
| Names chosen by other projects | Traefik pod label `app.kubernetes.io/name: traefik` (`networkpolicy.yaml:47`); `k8s-app: kube-dns` (`:26`); `cnpg.io/cluster: pg` (`:54,65,74,80,93`); `app.kubernetes.io/name: cloudnative-pg` (`:86`); Service `pg-rw` from Cluster `pg` (`postgrest.yaml:34`, `postgres.yaml:4`) | A k3s or chart upgrade that renames them silently blocks traffic |
| Role `api_anon`; ConfigMap `postgres-init` key `init.sql` | `init.sql:10`; `postgres.yaml:21-24,32`; `postgrest.yaml:38`; `kubernetes/apps/db/kustomization.yaml:10-15` | initdb fails, or PostgREST cannot switch role |
| Pod egress source = 10.250.0.112 | flannel's masquerade (a k3s default); relied on by `squid.conf:8`, `nftables-vmfw.nft:58,155`, `allowlists.yml:10,13` | Pods lose Squid, Flux and telemetry if the masquerade ever stops |
| API server 10.3.1.10:6443 | `ansible/roles/k3s/tasks/main.yml:13` (`node-ip: {{ vpc_ip }}`); `networkpolicy.yaml:99-101` | CNPG instance managers lose the API server |
| Runner paths `/etc/lab-runner/{ca.pem,ssh.pub}` | `services/gitea/runner/config/config.py:14-17`; `terraform/variables.tf:10,16`; `flux-git-auth.yaml.j2:11`; `ansible.yml:10`; `services/gitea/runner/files/config.yaml:9,13` | Terraform, Flux or the JS actions miss the CA or keys |
| Shared state paths | `/var/lib/lab/tfstate`: `terraform/provider.tf:16`, `terraform.yml:10`, `teardown.yml:16`, `lab-runner.service:12`. `/var/lib/lab/images/frontend.tar`: `image.yml:19-20`, `frontend/tasks/main.yml:51`. `/run/lab/vmfw.loaded`: `host/config/config.py:63`, `terraform.yml:16` | A job reads a file that another job never wrote |
| Version pins written twice | Terraform 1.17.2: `host/config/config.py:35`, `terraform/provider.tf:2`. Alloy 1.22.0: `ansible/roles/alloy/defaults/main.yml:1`, `services/monitoring/compose.yaml:52`. Base image date: `terraform/storage.tf:10`, `variables.tf:4`. Podman packages: `podman/config/config.py:8-11`, `podman/files/lab-alvistack.pref:2` | `terraform init` refuses the version; agents drift apart; a package comes from the wrong repo |

### R2: Vault paths and credential flow

The full table (path, keys, writer, reader, policy) and Vault's state machine are in Step 3.7. In short:

- **Two AppRoles.** `lab-bootstrap` is `bootstrap.sh`'s identity. Its role_id and secret_id are in `/var/lib/lab/approle.json` (root, 0600), and each `vault.login()` turns them into a 1 h token (`services/vault/vault.py:202-208`). `lab-pipeline` is the CI identity. `gitea.pipeline_secrets` stores its role_id and secret_id as the Gitea Actions secrets `VAULT_ROLE_ID` and `VAULT_SECRET_ID` (`services/gitea/gitea.py:119-135`). `deploy.yml:24` passes them to the ansible job with `secrets: inherit`.
- **Root and unseal.** The root token is used once, on the first run, and then revoked. The single unseal key stays in `/var/lib/lab/vault-init.json` on the same host and is used by every run (Steps 3.5-3.6).
- **Seven KV entries.** Under `kv/data/lab/pipeline/`: `ssh`, `app-db`, `app-edge`, `gitea-flux` (readable by both identities). Under `kv/data/lab/bootstrap/`: `gitea-admin`, `gitea-runner`, `grafana-admin` (bootstrap only).
- **From Vault to the target.** The ansible job reads five values (`ansible.yml:25-30`). `SSH_PRIVATE_KEY` goes into an ssh-agent and is used to SSH to the VMs as `user`. `FLUX_GIT_TOKEN` goes into Secret `flux-git-auth` and is used by Flux to pull from Gitea. `APP_DB_AUTHENTICATOR_PASSWORD` goes into Secret `db-authenticator`, used by CNPG's managed role and by PostgREST. `APP_EDGE_CERT` and `APP_EDGE_KEY` become `/etc/frontend/tls/` on fe-1 (key 0600, uid 65532). The public half of `ssh` reaches the VMs through `/etc/lab-runner/ssh.pub` and cloud-init (Step 4.9).
- **Credentials outside Vault.** The operator key `~/.ssh/lab_operator` (owned by the user). The runner's registration file `/var/lib/lab/runner/.runner` (0600). The CA private key `state/pki/ca-key.pem`. The Gitea admin password in `push`'s environment (`gitea.py:158-165`). Grafana's admin password in the compose environment (`services/monitoring/compose.yaml:41-42`).

### R3: External downloads

Two paths lead out. The host uses its own default route, directly. The VMs and pods can only use Squid, and only for the domains in `squid.conf:7,9`. CoreDNS resolves no internet names for anyone (`Corefile:18-27`).

| Step / job | What it fetches | From | Path | Integrity |
|---|---|---|---|---|
| `bootstrap.sh` | `python3.12`, only if Python < 3.12 (`bootstrap.sh:23-41`) | Ubuntu archive | host | apt signatures |
| `ntp`, `kvm`, `vmfw`, `pki`, `toolchain`, `ntp.down` | chrony, libvirt and QEMU, nftables, golang-cfssl, ansible-core, systemd-timesyncd (`lib/system.py:31-43`) | Ubuntu archive | host | apt signatures |
| `podman` | The alvistack `Release.key` on every run (`podman/podman.py:16`); Podman 6 packages; `docker-compose-v2` | `downloadcontent.opensuse.org` (pinned origin, `lab-alvistack.pref:1-9`); Ubuntu archive | host | HTTPS for the key (rewritten if it changed); apt signatures |
| `toolchain` | Terraform 1.17.2, Node 24.22.3, Trivy 0.76.2 (`host/config/config.py:35-55`); `cloud.terraform` 4.0.0 (`host/toolchain.py:66-85`) | releases.hashicorp.com, nodejs.org, github.com; Ansible Galaxy | host | sha256 pinned for the three binaries; version only for the collection |
| `runner` | `gitea-runner` 6.0.0 (`services/gitea/runner/config/config.py:6-8`) | gitea.com | host | sha256 pinned |
| Every compose service | CoreDNS, Squid, Vault, Traefik, Gitea, Prometheus, Loki, Grafana, Alloy images (`services/*/compose.yaml`) | docker.io | host (Podman) | tag + digest |
| Every job (`uses:`) | `actions/checkout@v4`; `actions/upload-artifact@v4` (image); `hashicorp/vault-action@v4`, `webfactory/ssh-agent@v0.10.0` (ansible) | Gitea's default actions source, github.com (the compose file sets no `GITEA__actions__DEFAULT_ACTIONS_URL`, `services/gitea/compose.yaml:9-17`) | host (runner) | tag only (mutable) |
| `check`, `terraform`, `ansible`, `teardown` | Providers `dmacvicar/libvirt` 0.9.9 and `ansible/ansible` 1.5.0 at `terraform init` (`terraform/provider.tf:4-13`) | Terraform registry | host | hashes in `terraform/.terraform.lock.hcl`, `-lockfile=readonly` |
| `check` | Trivy's misconfiguration checks for `trivy config` (`check.yml:17`) | Trivy's default registry (not set in the repo) | host | not pinned |
| `image` | Base images `cgr.dev/chainguard/python` (`frontend/Dockerfile:1,7`); Python packages (`frontend/requirements.txt:1-8`); Trivy's vulnerability database (`image.yml:24-25`) | cgr.dev; PyPI; Trivy's default registry | host (Podman build) | digest; versions pinned, no hashes; not pinned |
| `terraform` | Ubuntu 24.04 cloud image, on first create and again after a teardown (`terraform/variables.tf:4`, `storage.tf:9-22`) | cloud-images.ubuntu.com | host (libvirt provider) | none |
| `ansible`, alloy role | `alloy-1.22.0-1.amd64.deb`, once, kept in `/var/lib/lab/downloads` (`ansible/roles/alloy/tasks/main.yml:13-21`) | github.com | host (`delegate_to: localhost`) | sha256 pinned |
| `ansible`, common role and others | `nftables`, `wireguard-tools` (`common/tasks/main.yml:40-45`); `podman` on fe-1 (`frontend/tasks/main.yml:3-6`); Alloy's dependencies | archive.ubuntu.com, security.ubuntu.com | VM -> Squid `pkg_hosts` (`squid.conf:7,19`) | apt signatures |
| `ansible`, k3s role | Installer script (`k3s/tasks/main.yml:38-44`); the k3s binary and its system images | get.k3s.io; github.com, release-assets.githubusercontent.com; docker.io | be-1 -> Squid `k3s_hosts` (`squid.conf:9,20`) | none for the script; the installer checks the binary's sha256 |
| `ansible`, fluxcd role | Flux CLI tarball to `/tmp` (`fluxcd/tasks/main.yml:3-10`); the controller images that `flux install` names | github.com; ghcr.io, pkg-containers.githubusercontent.com | be-1 -> Squid | none for the tarball; image tags |
| Flux in the cluster | CNPG chart 0.29.2 and k8s-monitoring chart 4.6.1 (OCI, `proxySecretRef`); the CNPG operator and PostgreSQL images; PostgREST; the collector, kube-state-metrics and reloader images | ghcr.io; docker.io | be-1 pods and containerd -> Squid | chart tags; PostgreSQL and PostgREST by digest (`postgres.yaml:8`, `postgrest.yaml:16`); others by tag |
| Flux `lab-repo` | The lab repo | Gitea on the host | be-1 -> Traefik (no internet) | TLS + read token |

### R4: What rebuilds a VM

Terraform replaces a VM through the chain cloud-init seed -> seed volume -> disk overlay -> domain (`terraform/compute.tf:65,87,185`). The triggers are: a new `/etc/lab-runner/ssh.pub` (a new operator or pipeline key, or a different sudo user), a new `/etc/lab-runner/ca.pem` (a new lab CA), any change in the rendered cloud-init templates, a VM's addresses or MACs, its `disk_gb`, the base image, or its name. `vcpu`, `memory`, `group` and anything under `ansible/` do not rebuild. A rebuild means new SSH host keys, a new WireGuard key (the peers then restart their tunnels) and, on be-1, a new cluster with an empty database. The full list with the reason for each trigger is "What rebuilds a VM" in Step 6.7. `teardown` (Step 12.1) and `destroy` (Step 12.2) remove the VMs outright.

### R5: Order rules

H = hard dependency (breaks if reversed). G = grouping (the code chose an order, but nothing depends on it).

| # | Rule | Kind | Reason | Evidence |
|---|---|---|---|---|
| 1 | `ensure_root` before `ensure_python` before `exec main.py` | H | `ensure_python`'s `apt-get` fallback needs root; `lib/log.py` imports `typing.override`, new in 3.12; `ensure_root` also guarantees `SUDO_UID` for `git()` | `bootstrap.sh:29-36,48-50`; `lib/log.py:6`; `gitea.py:181` |
| 2 | `parse_args` before `setup_logging` before the lock | H | `--help` and bad arguments leave no trace; `setup_logging` creates `state/`, where the lock file lives | `main.py:136-146`; `lib/log.py:49` |
| 3 | Marker gate before `commit_changes` before `platform_up` | H | A refused command commits nothing; the commit pushed later is the tree that `platform_up` applied | `main.py:70-74,82-86`; `gitea.py:153` |
| 4 | `network` before `ntp`, `dns`, `squid`, `vault`, `traefik` | H | They bind or publish on 10.250.0.1 | `main.py:33`; `chrony-lab.conf:7`; `Corefile:3`; `squid.conf:4`; `traefik/compose.yaml:15`; `vault/compose.yaml:10` |
| 5 | `podman` before every compose service | H | `compose()` uses the socket and the plugin | `main.py:35`; `lib/system.py:73-80` |
| 6 | `ntp` at step 3, `kvm` at 5, `vmfw` at 6, `toolchain` at 7 | G | Only the pipeline needs them; vmfw rules name interfaces that need not exist yet | `main.py:34-38` |
| 7 | `dns` before `gitea`, `monitoring`, `runner` | H | They call `https://*.lab.test` | `services/gitea/config/config.py:9`; `monitoring/config/config.py:17-20`; `runner/config/config.py:23` |
| 8 | `squid` before `pki` | G | Independent; Squid serves only the VMs | `main.py:40-41` |
| 9 | `pki` before `vault` and `traefik` | H | They mount leaves at start and need `certs_changed` | `main.py:41-43` |
| 10 | `vault` before `gitea`, `monitoring`, `runner` and the command tail | H | Each logs in to Vault and stores or reads secrets | `gitea.py:286`; `monitoring.py:56`; `runner.py:108`; `main.py:75,87,96` |
| 11 | `traefik` before `gitea` and `monitoring` | H | It creates `lab-backend` (external for Gitea); their APIs are reached through it | `gitea/compose.yaml:28-31`; `monitoring.py:40-51` |
| 12 | `gitea` before `monitoring` | G | Independent of each other | `main.py:44-45` |
| 13 | Inside `gitea.up`: admin -> org -> repo -> runner token -> pipeline secrets -> Flux token | H | Admin creds for every call; repo-level secrets need the repo | `gitea.py:285-292` |
| 14 | `ssh_access` before `runner` | H | `ensure_ssh_key` reads the operator key | `main.py:46-47`; `runner.py:65` |
| 15 | Inside `runner.up`: `ensure_config` before `ensure_ssh_key` | H | `ensure_config` creates `/etc/lab-runner` | `runner.py:50,66` |
| 16 | `runner.up` before `start_run` | H | A run needs a registered, active runner | `main.py:47,76` |
| 17 | Marker touched before `follow_run` | H | A red or interrupted first run must still leave `update` usable | `main.py:76-78` (Step 5.1) |
| 18 | `check` -> `image` -> `terraform` -> `ansible` | H: image and terraform before ansible. G: check first, image before terraform | The frontend role needs the tar; the inventory comes from the state; check and image only fail fast before any VM changes | `deploy.yml:12-24` |
| 19 | vmfw loaded before `terraform apply` | H | No VM may run unfiltered | `terraform.yml:15-16`; `compute.tf:98` |
| 20 | `mgmtbr1` before the domains | H | eth2 attaches to it | `compute.tf:162` |
| 21 | Play 1 before plays 2-5 | H | Fails fast when the state has no VMs | `site.yml:1-9` |
| 22 | `vm_ready` -> `common` -> `wireguard` | H | cloud-init done; the clock fixed before apt; wireguard-tools installed | `site.yml:14`; `common/tasks/main.yml:1,40-45` |
| 23 | Hub nftables started before the sysctl handler | H | `net.netfilter.*` keys exist only once `nf_conntrack` is loaded, which the ruleset's `ct` rules do; handlers run at the end of the play | `wireguard/tasks/main.yml:24-66` |
| 24 | Play 2 (tunnels) before plays 3-4 | H | The frontend check calls the API through the tunnel | `frontend/tasks/main.yml:80-87` |
| 25 | k3s config and manifests folder before the installer | H | The node registers on 10.3.1.10, and Traefik starts on 8000 | `k3s/tasks/main.yml:9-35` vs `:46-54` |
| 26 | Flux controllers Available before `flux-git-auth` and `flux-sync` | H | The CRDs must exist before their objects | `fluxcd/tasks/main.yml:46-53` vs `:55-70` |
| 27 | Traefik `gitea-flux` route before GitRepository Ready | H | Flux pulls through it (built in `platform_up`) | `dynamic/gitea.yml:3-8`; `fluxcd/tasks/main.yml:72-79` |
| 28 | `lab-cnpg` Ready before `lab-apps` | H | Cluster `pg` needs CNPG's CRDs | `flux-sync.yaml:28-29` |
| 29 | `lab-monitoring` alongside `lab-cnpg` | G | No `dependsOn`; nothing waits for it | `flux-sync.yaml:35-50` |
| 30 | Namespace `db` before `db-authenticator`; `app_secrets` before `app_deployed` | H | The Secret needs its namespace; the app is healthy only with the Secret | `app_secrets/tasks/main.yml:5-12`; `site.yml:20` |
| 31 | Backend play before frontend play | H | The frontend check needs a healthy API | `site.yml:17-27`; `frontend/tasks/main.yml:80-87` |
| 32 | Host monitoring before the VM agents; Alloy play last | H for the first; G for the second | Push targets must answer; last only so that a monitoring failure cannot block the app | `main.py:45`; `site.yml:29-33` |
| 33 | `runner.down` first | H | No job may run while its tools and services are removed | `main.py:52` |
| 34 | `toolchain`, `kvm`, `vmfw` downs before the service downs | G | Stops the VMs and the pipeline tools first; no service down needs them (`kvm` before `vmfw` is row 35) | `main.py:54-57` |
| 35 | `kvm.down` before `vmfw.down` and `network.down` | H | No VM runs unfiltered; the taps sit on `mgmtbr1` | `main.py:55-56,66` |
| 36 | `monitoring.down`, `gitea.down` before `traefik.down` | H for a clean removal | Compose deletes `lab-backend` only when nothing is attached | `main.py:57-59`; `traefik/compose.yaml:23-25` |
| 37 | `monitoring`, `traefik`, `vault` downs before `pki.down` | G (reverse of up) | They mount files from `state/pki`; the downs would still succeed | `main.py:57-61` |
| 38 | Every compose service down before `podman.down` | H | They need the socket; `podman.check()` would skip them | `main.py:57-64`; `podman/podman.py:34-35` |
| 39 | `podman.down` before `ntp.down` | G (reverse of up) | Side effect: the apt update no longer reads the alvistack source | `main.py:64-65` |
| 40 | `network.down` last; `rmtree /var/lib/lab` after `platform_down`; marker last | H | 10.250.0.1 carried everything; the disks are free; `up` works again | `main.py:66,103-104` |
| 41 | `teardown.yml` and `deploy.yml` in one concurrency group | H | Never destroy while a deploy runs | `teardown.yml:8-10`; `deploy.yml:8-10` |

### R6: Security boundaries

| Boundary | Where enforced | What it allows | Known limitation |
|---|---|---|---|
| LAN -> lab | `lab_vmfw prerouting`/`forward` (`nftables-vmfw.nft:118-122,150,153`) | Only TCP 443 on the host's LAN IP, DNATed to fe-1 | CoreDNS also answers `lab.test` names on the LAN IP (`Corefile:3`). The lab does not firewall the host's own LAN-side services |
| VM -> internet | No route out (`nftables-vmfw.nft:152-157`); CoreDNS refuses non-`lab.test` names (`Corefile:18-27`); Squid allowlist (`squid.conf:6-21`) | apt hosts for every VM; the k3s, GitHub and registry hosts for be-1 only | `dstdomain` without `-n` (`squid.conf:7,9`): an IP-only request is matched by its reverse-DNS name. Fix pending |
| VM -> host services | `lab_vmfw input` (`nftables-vmfw.nft:168-179`) | DNS, NTP and Squid on 10.250.0.1 over mgmt; established replies; ping. Nothing over `wan` | None |
| VM -> Traefik services | `lab_vmfw forward` (`:155`); Traefik routers and allowlists (`dynamic/*.yml`, `allowlists.yml`) | VMs: POST to the two push paths. be-1: `/lab/lab.git/`. Everything else host only | Identity is the source IP only. A VM can push metrics and logs under another VM's labels |
| VM <-> VM on `wan` | `lab_sg forward` (`:62-108`) | New flows only spoke -> hub on UDP 51820/51821, plus their replies | `lab_sg` checks IP and ARP addresses, not Ethernet source MACs, so MAC spoofing is possible |
| VM <-> VM on mgmt, or through the host | `lab_sg :69`; `lab_vmfw :147` | Nothing | None |
| Address spoofing | `lab_sg prerouting` (`:52-59`), before conntrack | Each tap sends only from its own IPv4 address and ARP address, untagged | Same MAC limitation |
| Tunnel hub | `hub-forward.nft:9-29` on tun-1 | fe-1 (10.1.1.10) -> be-1 (10.3.1.10) TCP 8000 and replies; ping to tun-1 | None |
| Guest hosts | None on fe-1 and be-1; tun-1's filter covers only its tunnel interfaces | Whatever the lab-level filters let through | No guest firewalls |
| Inside be-1's cluster | NetworkPolicies in `db` (`networkpolicy.yaml:1-101`), enforced by kube-router | Traefik -> PostgREST :3000; PostgREST -> Postgres :5432; instances among themselves and to the API server; DNS | IPv6 link-local traffic bypasses the NetworkPolicies. Namespaces other than `db` have no policies of the lab's own |
| Database | `init.sql:10-14`; `postgres.yaml:25-34` | `api_anon`: CRUD on `todo.items` (plus USAGE on schema `todo` and its sequences) only; `authenticator` can only switch to it | The API itself has no authentication |
| Cluster RBAC for monitoring | k8s-monitoring chart defaults (not in the repo) | The collector reads cluster state for metrics and logs | The monitoring RBAC can read all Secrets |
| Edge TLS | `app-edge` leaf on fe-1 (`lib/config.py:38`) | HTTPS for `app.lab.test` | Clients must trust the lab CA by hand; certificates last 8760 h and nothing checks expiry (Step 3.3) |
| Vault | AppRoles `lab-bootstrap` (root-only file) and `lab-pipeline` (Gitea secrets); policies (`services/vault/policies/*.hcl`); root revoked | Bootstrap: all of `kv/data/*`. CI: `kv/data/lab/pipeline/*` | The unseal key sits on the same host as the data. `lab-pipeline` may also write (Step 3.6) |
| Gitea and the pipeline | Traefik `host-only` catch-all (`dynamic/gitea.yml:9-14`); Flux token `read:repository` | Push and API from the host only; be-1 reads the repo | The CI runner runs jobs as root on the host, so a commit on `main` runs as root |
| Telemetry stores | Traefik POST-only push routes; `auth_enabled: false` (`services/monitoring/files/loki/loki.yml:1`) | Any of the four sources writes; only the host reads | No per-agent identity (see VM -> Traefik) |
| Operator access | `60-lab-ssh.conf`; cloud-init keys; mgmt only | The host's user and the pipeline SSH to the VMs as `user` with passwordless sudo | Host-key checking is off (`60-lab-ssh.conf:10-11`, `ansible/ansible.cfg:3`) |

## Appendix A: Decisions and dropped designs

One line per decision. The sources are the roadmap, the B09 and B10 tables and the decision notes in the previous version of this file (`git show 0af7956:build-order.md`); the `build-order.md:N` citations in the last column refer to that version, not to this document. Where the decision is visible in the code, the step that walks it is named in the first column.

| Decision | Why | Alternative rejected or deferred | Source |
|---|---|---|---|
| Plain KVM driven by Terraform (libvirt) and Ansible on one host (Phases 6-7) | Fits the target host (4 cores, 16 GB) without a cloud management stack | Apache CloudStack (management server, MySQL, NFS, system VMs): dropped | `build-order.md:6-7,868` |
| Terraform state in a local file, `/var/lib/lab/tfstate` (Step 6.2) | One host, and the runner runs on it | MinIO for state and artifacts: dropped | `build-order.md:869` |
| Ubuntu cloud image plus a cloud-init seed (Steps 6.3, 6.6) | No image pipeline to maintain | Packer images: dropped | `build-order.md:876` |
| Short workflows built from ready-made actions; `check.yml` runs fmt, validate and a Trivy scan (Steps 5.4-5.5) | Less pipeline code to own | A `src/pipeline` Python framework; a Conftest/Rego plan gate and a PR gate; `pr.yml`, `deliver.yml`, `schedules.yml`: dropped | `build-order.md:870-871,876` |
| One `config.py` per module (Steps 1.4, 2.0) | Plain Python constants | A TOML config loader: dropped | `build-order.md:877` |
| Gitea Actions runner on the host, running jobs as root (Step 4.7) | Rootless Podman 6 builds failed: no subuid range, no `uidmap`, and a `storage.conf` that forces a root `graphroot` | A dedicated `lab-runner` user (now only removed, as `OLD_USER`). Trade-off: a commit on `main` runs as root (R6) | `build-order.md:761` |
| Frontend image delivered to fe-1 as a tarball from the runner (Steps 5.6, 9.1) | fe-1 has no registry to pull from: Squid lets it reach only the apt hosts (`squid.conf:6-7,19`) | A registry | `build-order.md:759` |
| Server-side Flask frontend calling PostgREST (Step 9.2) | One small Python app that calls PostgREST server-side, so only fe-1 needs the tunnel path | nginx plus a JavaScript front end | `build-order.md:762` |
| Trivy reports only, never fails the run (Steps 5.5-5.6) | The operator's choice: findings are read in the job log | A failing scan gate | `build-order.md:765` |
| k3s and Flux installed from their official sources through Squid, be-1 only (Steps 3.2, 8.1-8.2) | Fewer steps | An offline install | `build-order.md:592` |
| Flux installed with `flux install --export` into k3s's manifests folder (Step 8.2) | `flux bootstrap` needs a write token, and its push to Gitea would start the pipeline again | `flux bootstrap` | `build-order.md:726-728` |
| k3s's bundled Traefik on be-1's port 8000, PostgREST behind an Ingress (Steps 8.1, 8.4) | Already part of k3s; the hub filter and the frontend's `API_URL` stay as they were | Istio: dropped; ingress-nginx: retired upstream | `build-order.md:37,846` |
| PostgREST autoscaling with an HPA, 1 to 4 replicas (Steps 8.4, 11.3) | High-availability demo under load from fe-1 | A Traefik rate limit: deferred | `build-order.md:38,850` |
| PostgreSQL as a 2-instance CloudNativePG `Cluster` (Steps 8.3, 8.6) | Automatic failover of the database (pod-level only: both instances run on be-1) | A single Postgres Deployment | `build-order.md:39,851` |
| NetworkPolicies for namespace `db`, enforced by k3s's built-in kube-router (Step 8.4) | No CNI swap needed | Calico or Cilium; policies for namespace `monitoring`: dropped, it stays open | `build-order.md:41,849` |
| Plain HTTP inside the tunnels from fe-1 to be-1 (Step 11.1) | End-to-end TLS was judged too much work; tun-1 filters at L4 and can see the HTTP traffic | Server TLS, then mTLS, from fe-1 to be-1's Traefik: dropped | `build-order.md:40,847` |
| The app database password delivered by Ansible as a Secret in k3s's manifests folder (Step 8.5) | The planned replacement needs be-1 to reach Vault (a new vmfw hole) and a Vault auth method for k3s | Vault Secrets Operator: planned, not built | `build-order.md:44,848` |
| Telemetry is push-only, over HTTPS through Traefik (Phase 10) | The VMs reach the host only through vmfw's single Traefik hole | Prometheus scraping the VMs | `build-order.md:809-810` |
| Grafana's k8s-monitoring chart, collection only, through Flux's helm-controller (Step 10.2) | Replaces a hand-built ServiceAccount and kube-state-metrics setup | The hand-built setup | `build-order.md:813` |
| No alert rules (`rules.yml` is empty, Step 3.9) | Deferred | Node and pod alerts in Prometheus and Grafana | `build-order.md:49,834` |
| No firewall inside the guests; the hub filter on tun-1 instead (Step 7.5) | Every direct fe-1 to be-1 path is already blocked on the host, and tunnel traffic is filtered at the hub | nftables on every VM: deferred | `build-order.md:628-631` |
| One lab CA, with the `app-edge` leaf signed by it (Step 3.3) | Nothing used it; it comes back only if a design needs it | A second app CA with its own leaves: removed | `build-order.md:873` |
| Vault holds KV secrets and AppRoles only (Steps 3.6-3.7) | No code uses it | Vault Transit: deferred | `build-order.md:872` |
| No backups; disaster recovery is a walkthrough only (Step 12.2) | A short-lived lab, rebuilt with `destroy` and `up` | Backup, restore and key-loss demo: cut; a host baseline and revert proof: dropped | `build-order.md:45,852,874-875` |
| No host hardening beyond vmfw (R6) | Last on the list, likely skipped | Console CA trust, host SSH hardening, a host firewall | `build-order.md:46,853-855` |

## Appendix B: Documents that describe an older build

**Files:**
- `docs/diagram/lld/backend/backend-k3s.md`: low-level description of be-1 and its k3s cluster.
- `docs/diagram/lld/backend/backend-k3s.drawio`: the drawing for it (one long line of XML).
- `docs/diagram/lld/traffic/request-flow.md`: one app request, hop by hop.
- `docs/diagram/lld/traffic/request-flow.drawio`: the drawing for it.

**Build, in this order:**

| # | Function / unit | What it does | Called by -> calls | Reads / writes on the system |
|---|---|---|---|---|
| 1 | `backend-k3s.md` | be-1, its networks, namespaces and app. The node size, addresses and the k3s version are right (`:7-8`). The edge, the Flux controllers, the database and the firewall details are stale (see Watch out). | Companion to `backend-k3s.drawio` | Nothing |
| 2 | `backend-k3s.drawio` | The drawing. It labels PostgREST "LoadBalancer :8000". | draw.io | Nothing |
| 3 | `request-flow.md` | Request path browser -> HOST_IP -> fe-1 -> wg0 -> tun-1 -> wg1 -> be-1 (`:17-25`) and what is blocked (`:33-38`). The hops are right. The be-1 internals (`:15,25`) are stale. | Companion to `request-flow.drawio` | Nothing |
| 4 | `request-flow.drawio` | The drawing for the same path. | draw.io | Nothing |

**Why here:** Read these only after Phase 11, as a contrast. Read first, they plant facts the code contradicts. Phases 8 and 11 describe what is actually built on be-1 and how a request travels.

**How it connects:**
- Code comments still point into the previous version of `build-order.md` by section id, and those sections no longer exist (marked as C10 in Appendix C): `main.py:120` (argparse description), `services/squid/conf/squid.conf:1` (B08.1), `ansible/roles/fluxcd/files/flux-sync.yaml:29,35,53` and `ansible/roles/fluxcd/tasks/main.yml:28` (B09.4, B09.8b), `kubernetes/apps/db/kustomization.yaml:9` and `kubernetes/apps/db/networkpolicy.yaml:1` (B09.7).
- `request-flow.md` corresponds to Step 11.1 and `backend-k3s.md` to Phase 8.

**Re-run and removal:** Nothing runs. Editing or deleting these files is a commit like any other, and `update` then runs the full pipeline (Step 1.7, Step 5.2).

**Check it yourself:**
- `grep -n LoadBalancer docs/diagram/lld/*/*.md` and then `grep -n -E '^kind:|ClusterIP' kubernetes/apps/db/postgrest.yaml`: the docs say LoadBalancer, the manifest has a ClusterIP Service and an Ingress.
- `git grep -n -E 'build-order|B0[89]' -- ':!build-order.md' ':!review'`: the code comments that still cite the old section ids (C10).

**Watch out:**
- `backend-k3s.md:9,26` say k3s's bundled Traefik is off and ServiceLB opens :8000 for a LoadBalancer Service. In the code, the bundled Traefik runs with its `web` entrypoint moved to 8000 (`ansible/roles/k3s/files/traefik-config.yaml:9-15`), and PostgREST is a ClusterIP Service behind an Ingress (`kubernetes/apps/db/postgrest.yaml:52-81`).
- `backend-k3s.md:19` says vmfw lets only be-1 through to Traefik on 443. In the code, all three VMs pass (`host/files/nftables-vmfw.nft:155`), and Traefik then restricts each route by source address (`services/traefik/dynamic/allowlists.yml:5-13`).
- `backend-k3s.md:25` lists two Flux controllers. The role installs source, kustomize and helm (`ansible/roles/fluxcd/tasks/main.yml:34`).
- `backend-k3s.md:33-34` and `request-flow.md:15,25` describe one plain postgres, a different anonymous role and a different Secret name. The code runs a CloudNativePG Cluster `pg` with 2 instances (`kubernetes/apps/db/postgres.yaml:2-6`), anonymous role `api_anon`, and Secret `db-authenticator` (`postgres.yaml:27-34`, `postgrest.yaml:23-38`).

> **Marked change (not applied), C11:** Update these pages to the code (Traefik Ingress, CloudNativePG `pg`, `api_anon`, `db-authenticator`), or delete them and point to Phase 8 and Step 11.1. See Appendix C.

## Appendix C: Pending changes (marked, not applied)

These changes came out of the 2026-11-26 review of the code against this walkthrough. Each was checked against the code by an independent verifier and judged small and low-risk. **None is applied**: the code at `0af7956` still behaves as the steps above describe. Each change is also marked in its step as `Marked change (not applied), C<n>`. When one is applied, update the step's text and delete its marker and its row here.

| ID | Change | Files | Why | Marked in |
|---|---|---|---|---|
| C1 | Add `-n` to both `dstdomain` ACLs; add a probe that expects `http://195.154.246.97/` to be blocked from fe-1 | `services/squid/conf/squid.conf:7,9` | Without `-n`, a request to a bare IP matches through the IP's reverse-DNS name, which whoever owns the IP controls: a way around the egress allowlist (reproduced from fe-1) | Step 3.2 |
| C2 | Make the pipeline policy read-only: `capabilities = ["read"]`; drop the WireGuard-keys comment | `services/vault/policies/lab-pipeline.hcl:5-8` | The pipeline only reads; today a job could overwrite the SSH key, Flux token, app-edge certificate or database password | Step 3.6 |
| C3 | Replace `senior/` with `/review/` | `.gitignore:5` | `senior/` does not exist; `review/` is ignored only by the local `.git/info/exclude`, so a fresh clone would commit and push review notes | Step 1.7 |
| C4 | Replace `ensure_python`'s apt fallback with check-and-die; drop `log()`, `QUIET`, `PYTHON_PKG` | `bootstrap.sh:5-9,23-47` | The fallback cannot change `/usr/bin/python3` (owned by `python3-minimal`), so it is dead code | Step 1.1 |
| C5 | Declare `lab-backend` with `external: true` | `services/monitoring/compose.yaml:81-83` | Traefik's project owns the network; Gitea already declares it external | Step 3.9 |
| C6 | Fetch the alvistack key only when the keyring is missing; write it with `system.write_file` | `podman/podman.py:14-20` | Every run downloads the key, so every `update` needs the openSUSE mirror | Step 2.4 |
| C7 | Remove the `lab-runner` user migration: `OLD_USER`, the `chown` in `ensure_home`, the `userdel` in `down` | `services/gitea/runner/config/config.py:12`, `services/gitea/runner/runner.py:22-26,123-128` | Leftover from before the runner ran as root; the host has been rebuilt since | Step 4.7 |
| C8 | Remove the `flux check --pre` task | `ansible/roles/fluxcd/tasks/main.yml:21-26` | k3s and Flux are pinned together and the node is already proven Ready | Step 8.2 |
| C9 | Fix misleading comments: `platform_up` docstring; one renderer name; `gitea-flux` "pull only"; `compute.tf` "bootstrap up" -> "bootstrap update"; why `TMPDIR` is the tfstate folder | `main.py:31`, `host/network.py:70,76`, `host/config/config.py:11`, `services/traefik/dynamic/gitea.yml:3`, `terraform/compute.tf:98`, `.gitea/workflows/terraform.yml:9-10`, `.gitea/workflows/teardown.yml:15-16` | The comments disagree with what the code does | Steps 1.2, 2.2, 3.8, 6.1, 6.7 |
| C10 | Remove or update code comments that cite section ids of the previous version of this file | `services/squid/conf/squid.conf:1` (B08.1), `ansible/roles/fluxcd/tasks/main.yml:28` (B09.4), `ansible/roles/fluxcd/files/flux-sync.yaml:29,35,53` (B09.4, B09.8b), `kubernetes/apps/db/kustomization.yaml:9`, `kubernetes/apps/db/networkpolicy.yaml:1` (B09.7) | Those sections no longer exist; `git grep -n -E 'B0[89]\.' -- ':!build-order.md'` lists them | Steps 3.2, 8.2, 8.4 |
| C11 | Update the stale docs: README usage and layout lines, the HLD gaps, the two LLD pages (or delete the LLD pages) | `README.md`, `docs/diagram/hld/overall-architecture.md`, `docs/diagram/lld/**` | They describe an older build (Step 0.1 Watch out, Appendix B) | Step 0.1, Appendix B |

**Optional, worth knowing (not planned).** Real but latent; none affects the running lab today.

| Item | Where | Note |
|---|---|---|
| Policy upload order | `services/vault/vault.py:151` (Steps 3.6-3.7) | Policies are uploaded in sorted order. A new file that sorts before `lab-bootstrap.hcl` (for example an `app-db.hcl` for the planned Vault Secrets Operator) is uploaded before lab-bootstrap's own widened policy and fails with 403 on every `update`. Name it to sort after, or upload `lab-bootstrap.hcl` first |
| Stale `approle.json` after a re-init | `services/vault/vault.py:45-65,234-239` (Step 3.5) | If Vault is re-initialized while `/var/lib/lab/approle.json` survives, `vault.up` skips the root branch and the login fails with no hint. Unlink the file after `sys/init` |
| k3s restart handler | `ansible/roles/k3s/handlers/main.yml` (Steps 8.1, 8.7) | The handler is never flushed in the role, so on a fresh build k3s restarts at the end of play 3, after `app_deployed` and right before the frontend play. Add `meta: flush_handlers` before the Ready wait |
| Flux CLI download | `ansible/roles/fluxcd/tasks/main.yml:3-19` (Step 8.2) | No checksum, and `creates:` ignores a `flux_version` bump, so a bump keeps rendering the old controllers |
| Duplicate command bodies | `main.py:69-98` (Step 5.1) | `cmd_up` and `cmd_update` differ only in the marker check, and all three commands repeat the Vault login and `gitea_admin` that `gitea.up` already did |
