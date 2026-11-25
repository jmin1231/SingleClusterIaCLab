# SingleClusterIaCLab

One Ubuntu 24.04 host runs a small private cloud, built and changed through a pipeline:

- **Host platform** (Python, the repo root): management bridge `mgmtbr1` (10.250.0.1/24), chrony,
  Podman, KVM/libvirt, a VM firewall (nftables), CoreDNS (`lab.test`), a cfssl CA,
  Vault, Traefik, Gitea and a Gitea Actions runner.
- **Tenant infrastructure** (declarative): Terraform (libvirt provider) builds three VMs on
  three isolated networks plus a shared `wan`; Ansible configures them. Both run from
  Gitea Actions on every push.

| VM | Role | site network | wan | mgmt |
|---|---|---|---|---|
| fe-1 | frontend | 10.1.1.10 (site-a) | 198.51.100.11 | 10.250.0.110 |
| tun-1 | WireGuard hub | 10.2.1.10 (site-hub) | 198.51.100.12 | 10.250.0.111 |
| be-1 | backend | 10.3.1.10 (site-c) | 198.51.100.13 | 10.250.0.112 |

[`build-order.md`](build-order.md) is the working plan: every step and function in build
order, how they connect, and what is next.

## Host

Ubuntu 24.04 Desktop, 4 cores, 16 GB RAM, `/dev/kvm`, internet access. The lab owns the host:
it changes netplan and chrony, and `destroy` removes Podman and libvirt with everything in them.

## Usage

Always run as root; the operator is the owner of this infrastructure.

```sh
sudo ./bootstrap.sh up        # first build: host platform, then the first pipeline run
sudo ./bootstrap.sh update    # after editing: commit, re-apply the host, push, follow the run
sudo ./bootstrap.sh destroy   # remove the VMs and everything the lab installed
```

`update` commits your edits, pushes them to the Gitea repo `lab/lab` (or re-runs the pipeline
if nothing changed) and prints each job's result in the terminal.

Pipeline (`.gitea/workflows/deploy.yml`): `check` (terraform fmt, validate) → `terraform`
(apply) → `ansible` (Vault AppRole → SSH key → `ansible-playbook site.yml`).

## Repository layout

| Folder | What |
|---|---|
| `bootstrap.sh`, `main.py` | Entry point: `sudo ./bootstrap.sh up\|update\|destroy` runs `python3 -B main.py` |
| `lib/` | Shared settings, logging, helpers, PKI (`lib/cfssl/`) |
| `host/` | Host steps: preflight, mgmt bridge, chrony, KVM, VM firewall, toolchain, operator SSH |
| `podman/` | Installs Podman and Compose on the host |
| `services/` | Host Podman services: `coredns/`, `squid/`, `vault/`, `traefik/`, `gitea/` (+ `gitea/runner/`), `monitoring/`; each has Python `up()/down()` + `compose.yaml` + `config/` + files |
| `demo/` | Demo helpers (`load.sh`: request load for the HPA demo) |
| `terraform/` | The three VMs and their networks (libvirt) |
| `ansible/` | VM configuration: WireGuard, k3s, Flux, frontend, Alloy |
| `kubernetes/` | Everything Flux applies in k3s: the app (`apps/`) and monitoring (`monitoring/`) |
| `frontend/` | The Flask app image built and scanned by the pipeline |
| `.gitea/workflows/` | The pipeline: check → image → terraform → ansible |
| `docs/` | Design notes and diagrams |

## Where things live

| What | Where |
|---|---|
| Lab CA and certificates | `state/pki/` (trust `state/pki/ca.pem` to open the web UIs) |
| Vault unseal key, bootstrap AppRole | `/var/lib/lab/vault-init.json`, `/var/lib/lab/approle.json` (root, 0600) |
| Lab SSH key, Gitea admin, runner token | Vault `kv/lab/pipeline/ssh`, `kv/lab/bootstrap/*` |
| Pipeline's Vault login | Gitea Actions secrets `VAULT_ROLE_ID`, `VAULT_SECRET_ID` |
| Terraform state | `/var/lib/lab/tfstate` (root, 0700) |
| Log of every run | `state/bootstrap.log` |

Web UIs: `https://gitea.lab.test`, `https://grafana.lab.test`, `https://vault.lab.test:8200`.

## Docs

- [`docs/three-vpc-design.md`](docs/three-vpc-design.md): the network and WireGuard design.
- [`docs/diagram/`](docs/diagram/): architecture and traffic diagrams.
