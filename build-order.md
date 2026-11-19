# Lab build order

This is the build order for the lab, from an empty repo to the finished lab. It lists every
function in the order you write it, what calls it, and what it reads or writes.

- Design baseline: plain KVM, Terraform (libvirt) and Ansible, run by Gitea Actions on one host
  runner. Target host: Ubuntu 24.04 Desktop, 4 cores, 16 GB.
- Evidence baseline: Gitea run #8 at commit `dfa3aa9` (2026-11-16) passed check, terraform and ansible.
- The cleanup after run #8 (2026-11-16 evening: `start_run`, `kvm.remove_lab_vms`, single-root PKI, the
  assert play, `vault.down` guard) is Implemented until the next `update` run proves it.
- This file replaces the earlier build-order.md, and PLAN-enterprise.md as the working plan.

| Status | Meaning |
|---|---|
| Verified | A recorded run exercised this code path and it passed: run #8 (`dfa3aa9`, 2026-11-16) unless another run is named |
| Implemented | Code exists and was read. The path has not been proven by a recorded run |
| Partial | Code exists, but it does not yet do what the step promises |
| Next | On the critical path. Build it now, in the order listed |
| Planned | Build after Next |
| Deferred | Design-only, or kept for the review discussion |

How to work a step: write the functions top to bottom in the order shown. After each step, run
`sudo ./bootstrap.sh update` and do the acceptance check. Then change the step's status in this
file.

---

## Interconnections

### Call graph: up and update

```
sudo ./bootstrap.sh <cmd>
  bootstrap.sh main: ensure_root, ensure_python, exec python3 -B -m src <cmd>
    src/__main__.py main: parse_args, setup_logging, flock state/run.lock, COMMANDS[cmd]

cmd_up                                       cmd_update
  state/initialized exists? info, return       state/initialized missing? error, exit 1
  gitea.commit_changes                         gitea.commit_changes
  platform_up                                  platform_up
  creds = gitea.gitea_admin(vault.login())     creds = gitea.gitea_admin(vault.login())
  run = gitea.start_run(creds)                 gitea.follow_run(creds, gitea.start_run(creds))
  touch state/initialized
  gitea.follow_run(creds, run)

gitea.start_run(creds): main_differs ? wait_for_run(creds, push(creds)) : dispatch(creds)
  (an empty repo has no main, so the first up always pushes)

platform_up (each step is idempotent; an unchanged step does nothing)
   1 preflight.up   check_host, log_network > detect_network > system.ip_json
   2 network.up     vmnet_conflicts, system.install_file(netplan), netplan apply, check, reattach_taps
   3 ntp.up         system.apt_install, install_file(chrony-lab.conf), systemctl
   4 podman.up      repo, system.apt_install, socket_ready
   5 kvm.up         system.apt_install, libvirtd.socket, virsh list
   6 vmfw.up        preflight.detect_network, render_rules, nft -c, nft -f, marker
   7 toolchain.up   ensure_terraform, ensure_ansible, ensure_node
   8 dns.up         preflight.detect_network > system.compose("coredns", HOST_IP)
   9 pki.up         returns certs_changed
  10 vault.up(certs_changed)
                    compose, init, unseal,
                    [first run: policy(root), enable_approle(root), approle(root)],
                    login, revoke_root, mount(kv), policy, ssh_key
  11 traefik.up(certs_changed)   compose (creates network lab-backend)
  12 gitea.up       compose, vault.login, gitea_admin, ensure_org, ensure_repo,
                    runner_registration_token, pipeline_secrets > vault.approle_credentials
  13 runner.up      ensure_home, ensure_binary, ensure_config, vault.login,
                    ensure_ssh_key, ensure_registered, ensure_service

Pipeline (Gitea Actions, runs-on: host, as root since 2026-11-18)
  push to main | workflow_dispatch
    deploy.yml (concurrency lab-deploy)
      check.yml      terraform init -backend=false, fmt -check, validate
      terraform.yml  test vmfw marker, virsh list, init, apply   (TMPDIR=/var/lib/lab/tfstate)
      ansible.yml    vault-action (AppRole), ssh-agent, terraform init, ansible-playbook site.yml
```

Order rules that the code depends on:

| Rule | Why |
|---|---|
| network before ntp and dns | chrony and CoreDNS bind 10.250.0.1 on cloudbr1 |
| kvm before runner | Terraform in the runner's jobs needs libvirt (the runner runs as root since 2026-11-18) |
| dns before gitea and runner | `gitea_api`, `push` and `gitea-runner register` use `https://gitea.lab.test`, which the host resolves only through CoreDNS (netplan `~lab.test`). `vault_api` uses the IP, but ansible.yml's vault-action uses `vault.lab.test` |
| podman before dns, vault, traefik, gitea | `system.compose` talks to the Podman socket |
| vmfw before any pipeline run | terraform.yml refuses to start VMs without `/run/lab/vmfw.loaded` |
| toolchain before runner | jobs run terraform, ansible-playbook and node on the host |
| pki before vault and traefik | both mount certs from `state/pki`. New certs force-recreate both |
| vault before gitea and runner | they read and write Vault through `vault.login()` |
| traefik before gitea | Traefik creates `lab-backend`, which Gitea joins as an external network |
| gitea before runner | the runner registration token comes from Gitea through Vault |

### Data handoffs

| Producer | Artifact | Consumer |
|---|---|---|
| `pki.up` | `state/pki/ca.pem` | `vault_api`, `gitea_api` (TLS), `gitea.push` (GIT_SSL_CAINFO), `runner.ensure_config` |
| `runner.ensure_config` | `/etc/lab-runner/ca.pem` | runner `config.yaml` (ca_file, GIT_SSL_CAINFO), ansible.yml NODE_EXTRA_CA_CERTS, Terraform `var.lab_ca_cert_file` > cloud-init `ca_certs` |
| `pki.up` | `state/pki/vault*.pem`, `gateway*.pem`, `ca.pem` | Vault container (vault.hcl; `ca.pem` for its healthcheck via VAULT_CACERT), Traefik (`dynamic/tls.yml`) |
| `vault.init` | `/var/lib/lab/vault-init.json` (unseal key, root token) | `vault.unseal`, first-run `policy`/`enable_approle`/`approle`, `revoke_root` |
| `vault.approle` | `/var/lib/lab/approle.json` (lab-bootstrap) | `vault.login()` in vault.up itself, cmd_up, cmd_update, gitea.up, runner.up |
| `vault.ssh_key` | `kv/data/lab/pipeline/ssh` (private_key, public_key) | `runner.ensure_ssh_key` (public), ansible.yml vault-action (private) |
| `runner.ensure_ssh_key` | `/etc/lab-runner/ssh.pub` | Terraform `var.ssh_public_key_file` > cloud-init `ssh_authorized_keys` |
| `gitea.gitea_admin` | `kv/data/lab/bootstrap/gitea-admin` (labadmin) | every `gitea_api` call, `gitea.push` |
| `gitea.runner_registration_token` | `kv/data/lab/bootstrap/gitea-runner` | `runner.ensure_registered` |
| `gitea.pipeline_secrets` | Gitea secrets `VAULT_ROLE_ID`, `VAULT_SECRET_ID` (lab-pipeline role) | deploy.yml `secrets: inherit` > ansible.yml vault-action |
| `vmfw.up` | `/run/lab/vmfw.loaded` | terraform.yml first step |
| `preflight.detect_network()['host_ip']` | CoreDNS `HOST_IP` env and vmfw `define host_ip` | together they are the app ingress: `app.lab.test` → HOST_IP, then DNAT HOST_IP:443 → fe-1 198.51.100.11 |
| runner `files/config.yaml` | label `host:host` | `runs-on: host` in check.yml, terraform.yml, ansible.yml |
| `lab-runner.service` | `/var/lib/lab/tfstate` (StateDirectory, 0700) | provider.tf local backend, terraform.yml TMPDIR (cloud-init ISO) |
| `terraform apply` | `ansible_host` resources in state | `ansible/inventory.yml` (cloud.terraform.terraform_provider, `terraform show`) |
| `compute.tf` | cloud-init user-data, network-config (eth0 vpc, eth1 wan, eth2 mgmt, DNS 10.250.0.1) | each VM on first boot. The `ready` role waits for it |
| `dns.up` | CoreDNS `lab.test` (gitea, vault, app={HOST_IP}, k3s) | host resolver (netplan `~lab.test`), the VMs over mgmt |

---

## B01 Entry point and lib

### B01.1 Shell shim
Files: `bootstrap.sh`, `.gitignore` (`/state/`, `__pycache__/`, `*.tfstate*`, `terraform/.terraform/`)

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `log()` | Print a `[+]` line | ensure_python | stdout |
| `die()` | Print `[x]` and exit 1 | ensure_root, ensure_python | stderr |
| `ensure_root()` | Refuse unless EUID is 0 | main | EUID |
| `check_python_version()` | Return 0 if python3 is 3.12 or newer | ensure_python | python3 |
| `ensure_python()` | Die if python3 is older than 3.12 | main | (apt branch never runs on 24.04) |
| `main "$@"` | cd to the repo, then exec `python3 -B -m src "$@"` | script end / ensure_root, ensure_python | `src/__main__.py` |

Acceptance: `sudo ./bootstrap.sh` prints help and exits 1.
Status: Verified (run #8 was started through it).

### B01.2 Logging
Files: `src/__init__.py`, `src/lib/__init__.py`, `src/lib/log.py`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `ConsoleFormatter.format(record) -> str` | `[+]/[!]/[x] msg`, never a traceback | logging | stderr |
| `FileFormatter.format(record) -> str` | ISO timestamp + message + traceback | logging / ConsoleFormatter.format | |
| `setup_logging() -> None` | Install the stderr handler and the file handler once | `__main__.main` | `state/bootstrap.log` |

Acceptance: a failing step prints one `[x]` line. The traceback appears only in `state/bootstrap.log`.
Status: Verified.

### B01.3 Shared settings and helpers
Files: `src/lib/config.py`, `src/lib/system.py`. Every package directory under `src/` has an empty `__init__.py`.

`config.py` holds: paths (BASE_DIR, STATE_DIR, LAB_DIR, SERVICES_DIR), the bridge (BRIDGE, VMNET), apt and Compose (APT_ENV, COMPOSE = `/usr/libexec/docker/cli-plugins/docker-compose`, DOCKER_HOST), PKI (CFSSL_DIR, PKI_DIR, LAB_CA, LAB_CA_CERT, CERTS), Vault (VAULT_PORT, VAULT_ADDR, VAULT_INIT_FILE, VAULT_POLICY_DIR, VAULT_APPROLE_FILE), LAB_ADMIN (used only by gitea.py).

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `ip_json(*args) -> list[dict]` | `ip -j ...` parsed | preflight, network | |
| `missing_packages(pkgs) -> list[str]` | Packages not installed | apt_install, podman | dpkg-query |
| `apt_install(pkgs) -> bool` | Update and install only if something is missing | pki, kvm, ntp, toolchain, podman | apt |
| `apt_purge(pkgs) -> None` | apt-get purge | every `down()` that installed packages | apt |
| `systemctl_ok(verb, unit) -> bool` | `systemctl <verb> --quiet` exit 0 | kvm, ntp, podman, runner | systemd |
| `write_file(content, dst, mode) -> bool` | Write only if different | install_file, toolchain, runner | dst |
| `install_file(src, dst, mode) -> bool` | Copy a repo file to the host if different | network, ntp, podman, runner / write_file | dst |
| `compose(service, *args, env=None) -> None` | docker-compose on `src/services/<service>/compose.yaml` over the Podman socket | dns, vault, traefik, gitea | `/run/podman/podman.sock` |

Acceptance: `python3 -c "import src.lib.system"` imports cleanly.
Status: Verified.

### B01.4 Command skeleton
Files: `src/__main__.py`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `parse_args(argv) -> Namespace` | Subcommands from COMMANDS. With no command: help, exit 1 | main | |
| `main(argv=None) -> int` | Logging, non-blocking flock, run the command, central error handler (130 / 1) | `__name__ == "__main__"` / parse_args, setup_logging | `state/run.lock` |
| `platform_up() -> None` | The 13 host steps in order (grows with B02-B04) | cmd_up, cmd_update | |
| `platform_down() -> None` | Reverse removal: runner, toolchain, kvm (VMs first), vmfw, gitea, traefik, vault, pki, dns, podman, ntp, network | cmd_destroy | |

Write `platform_up` empty first, and add one line per step as you finish B02-B04. cmd_up and
cmd_update come in B05.
Acceptance: a second concurrent run prints "another bootstrap.sh run is in progress".
Status: parse_args, main, platform_up Verified. platform_down Partial: a destroy on 2026-11-14 (`state/bootstrap.log`) ran the gitea-to-network part with older code; runner, toolchain, vmfw and kvm `down()` have never run, and it leaves the VMs (B08.5).

---

## B02 Host steps

### B02.1 Preflight
Files: `src/host/__init__.py`, `src/host/preflight.py`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `check_host() -> None` | Exit 1 unless /dev/kvm is usable | up | /dev/kvm |
| `detect_network() -> dict` | Live LAN facts: card, host_ip, prefix, gateway, dhcp | log_network, vmfw.up, dns.up, dns.down / ip_json | |
| `log_network() -> None` | Log the LAN facts | up | |
| `up() -> None` | check_host, then log_network | platform_up | |

Acceptance: the log shows the LAN card, address and gateway. Status: Verified.

### B02.2 Management bridge
Files: `src/host/network.py`, `src/host/config/{__init__,config}.py`, `src/host/files/60-lab-cloudbr1.yaml`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `vmnet_conflicts() -> list[str]` | Routes that overlap 10.250.0.0/24 | up / ip_json | |
| `check() -> bool` | cloudbr1 holds 10.250.0.1 | up / ip_json | |
| `up() -> None` | Install netplan file, apply if changed, wait for the address | platform_up / install_file | `/etc/netplan/60-lab-cloudbr1.yaml` |
| `down() -> None` | Remove the file, netplan apply, delete the links | platform_down | cloudbr1, cloudbr1-anchor |

Acceptance: `ip -4 addr show cloudbr1` shows 10.250.0.1/24. Status: Verified.

### B02.3 Time
Files: `src/host/ntp.py`, `src/host/files/chrony-lab.conf`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `up() -> None` | Install chrony and the drop-in. Restart on change | platform_up / apt_install, install_file, systemctl_ok | `/etc/chrony/conf.d/chrony-lab.conf` |
| `down() -> None` | Remove the drop-in, purge chrony, reinstall systemd-timesyncd | platform_down | |

Acceptance: `chronyc sources` works and port 123 is bound on 10.250.0.1. Status: Verified.

### B02.4 Container runtime
Files: `src/services/podman/{podman.py,config/config.py,files/lab-alvistack.list,files/lab-alvistack.pref}`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `repo() -> None` | alvistack key, source, pin | up / install_file | `/etc/apt/{keyrings,sources.list.d,preferences.d}` |
| `socket_ready() -> bool` | podman.socket enabled and active | check, up / systemctl_ok | |
| `check() -> bool` | Podman usable: the guard in every service `down()` | dns, vault, traefik, gitea down | |
| `up() -> None` | repo, install Podman 6 + docker-compose-v2, enable socket | platform_up | apt, podman.socket |
| `down() -> None` | Disable the socket, `podman system reset`, purge, remove the repo | platform_down | `/var/lib/containers` |

Acceptance: `podman --version` reports 6.x, and `DOCKER_HOST=unix:///run/podman/podman.sock /usr/libexec/docker/cli-plugins/docker-compose version` answers. Status: up Verified; down ran once on 2026-11-14.

### B02.5 Virtualization
Files: `src/host/kvm.py`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `up() -> None` | Install QEMU/libvirt, enable libvirtd.socket, `virsh list` | platform_up / apt_install, systemctl_ok | qemu:///system |
| `remove_lab_vms() -> None` | `virsh destroy`/`undefine` LAB_DOMAINS, `net-destroy`/`net-undefine` LAB_NETWORKS, `pool-destroy`/`pool-undefine` LAB_POOL; missing ones are skipped | down | qemu:///system |
| `down() -> None` | remove_lab_vms (if virsh exists), then purge KVM packages. The disk files go with `/var/lib/lab` in cmd_destroy | platform_down | |

LAB_DOMAINS, LAB_NETWORKS and LAB_POOL in `src/host/config/config.py` must match the names in
`terraform/compute.tf`, `network.tf` and `storage.tf`.
Acceptance: `virsh -c qemu:///system list --all` answers. Status: up Verified; down Implemented (never run).

### B02.6 VM firewall
Files: `src/host/vmfw.py`, `src/host/files/nftables-vmfw.nft`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `render_rules(network) -> bytes` | Prepend `define lan_card` and `define host_ip` to the .nft file | up | |
| `up() -> None` | Check, then atomically load both tables. Touch the marker | platform_up / detect_network, render_rules | nft, `/run/lab/vmfw.loaded` |
| `down() -> None` | `nft destroy table` for both tables, remove the marker | platform_down | |

Rules: bridge `lab_vmfw_l2` drops mgmt tap-to-tap traffic and allows only ARP + WireGuard
(fe-1 to tun-1 on udp 51820, be-1 to tun-1 on 51821) on wan. inet `lab_vmfw` DNATs LAN :443
to fe-1 198.51.100.11, and drops other wan forwarding and host input from wan.
Acceptance: `nft list tables` shows both tables, and the marker exists. `up()` first runs `apt_install(VMFW_PACKAGES)` (nftables: preinstalled on Ubuntu, installed if missing, never purged).
Status: up Verified; down never run.

### B02.7 Toolchain for the runner
Files: `src/host/toolchain.py`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `installed_version_ok(cmd, version) -> bool` | Is the pinned version installed? | ensure_* | |
| `download(url, sha256) -> bytes` | Fetch and verify the hash | ensure_terraform, ensure_node | network |
| `ensure_terraform() -> None` | terraform 1.17.2 from the zip | up / write_file | `/usr/local/bin/terraform` |
| `ensure_ansible() -> None` | ansible-core (apt) + cloud.terraform 4.0.0 | up / apt_install | `/usr/share/ansible/collections` |
| `ensure_node() -> None` | node 24.22.3 `bin/node` only, from the tar.xz | up / write_file | `/usr/local/bin/node` |
| `up() -> None` | The three ensure functions in order | platform_up | |
| `down() -> None` | Remove both binaries and the collection, purge ansible-core | platform_down | |

Acceptance: `terraform version`, `node --version` and `ansible-galaxy collection list cloud.terraform` show the pins.
Status: up Verified; down never run.

---

## B03 Host services

### B03.1 DNS
Files: `src/services/coredns/{dns.py,compose.yaml,conf/Corefile}`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `up() -> None` | `compose coredns up -d` with HOST_IP | platform_up / detect_network, compose | container coredns (host network) |
| `down() -> None` | `compose coredns down` | platform_down / podman.check, detect_network, compose | |

Records: gitea and vault point to 10.250.0.1, app.lab.test to {$HOST_IP}, k3s.lab.test to 10.250.0.112.
Acceptance: `resolvectl query gitea.lab.test` returns 10.250.0.1. Status: Verified.

### B03.2 Certificates
Files: `src/lib/pki.py`, `src/cfssl/ca-csr.json`, `src/cfssl/ca-config.json` (profile `server` only) (CERTS table in `src/lib/config.py`)

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `up() -> bool` | Install cfssl; create the `ca` root if missing (and delete every leaf, since the old root signed them); issue missing CERTS leaves; chown keys. Return changed | platform_up / apt_install | `state/pki/*` |
| `down() -> None` | Remove `state/pki` and purge cfssl | platform_down | |

One root (`ca`) signs every leaf: `vault`, `gateway` (gitea.lab.test) and `app-edge` (app.lab.test, for the fe-1 ingress).
Acceptance: `openssl x509 -in state/pki/gateway.pem -noout -ext subjectAltName` lists gitea.lab.test. Status: Verified.

### B03.3 Vault
Files: `src/services/vault/{vault.py,compose.yaml,vault.hcl,policies/lab-bootstrap.hcl,policies/lab-pipeline.hcl}`

Write the functions in this order:

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `vault_api(method, path, body=None, token=None) -> dict` | HTTPS client trusting the lab CA. A GET 404 returns `{}` | every Vault call, gitea, runner | `https://10.250.0.1:8200/v1/*` |
| `init() -> None` | Initialize once and save keys (0600, O_EXCL) | up / vault_api | `/var/lib/lab/vault-init.json` |
| `unseal(key, timeout=30) -> None` | Unseal and wait until active | up / vault_api | sys/unseal, sys/health |
| `policy(token) -> None` | Upload `policies/*.hcl` | up (root on first run, then lab-bootstrap) / vault_api | sys/policies/acl/{lab-bootstrap,lab-pipeline} |
| `enable_approle(token) -> None` | Enable auth/approle | up (root, first run) / vault_api | sys/auth/approle |
| `approle_credentials(token, role) -> dict` | Create the role, return role_id + new secret_id | approle, gitea.pipeline_secrets / vault_api | auth/approle/role/<role> |
| `approle(token, role, creds_file, owner) -> None` | Write lab-bootstrap creds once | up / approle_credentials | `/var/lib/lab/approle.json` |
| `login(creds_file=VAULT_APPROLE_FILE) -> str` | AppRole login, return a 1h token | up, cmd_up, cmd_update, gitea.up, runner.up / vault_api | auth/approle/login |
| `revoke_root(root) -> None` | Revoke the root token (403 means already revoked) | up / vault_api | auth/token/revoke-self |
| `mount(token, path, body) -> None` | Enable kv v2 if missing | up / vault_api | sys/mounts/kv |
| `ssh_key(token) -> None` | Create the ed25519 lab key pair once | up / vault_api | `kv/data/lab/pipeline/ssh` |
| `up(certs_changed) -> None` | compose, init, unseal, first-run root work, login, revoke, mount, policy, ssh_key | platform_up / compose | container vault |
| `down() -> None` | `compose down --volumes`, then delete both JSON files. Without Podman it keeps them: the unseal key goes only with the data | platform_down / podman.check, compose | |

Acceptance: `curl --cacert state/pki/ca.pem https://vault.lab.test:8200/v1/sys/health` shows initialized and unsealed. The root token is revoked.
Status: Verified.

### B03.4 Gateway
Files: `src/services/traefik/{traefik.py,compose.yaml,dynamic/gitea.yml,dynamic/tls.yml}`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `up(certs_changed) -> None` | `compose traefik up -d`, with `--force-recreate` on new certs | platform_up / compose | 10.250.0.1:443, network lab-backend |
| `down() -> None` | `compose traefik down` | platform_down / podman.check, compose | |

Acceptance: `curl --cacert state/pki/ca.pem https://gitea.lab.test/api/healthz` returns pass (after B04.1). Status: Verified.

---

## B04 Gitea and runner

### B04.1 Gitea service and seeding
Files: `src/services/gitea/{gitea.py,compose.yaml,config/config.py}`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `gitea_api(creds, method, path, body=None, raw=False)` | REST client with basic auth and the lab CA | all Gitea helpers | `https://gitea.lab.test/api/v1` |
| `gitea_admin(token) -> dict` | labadmin creds from Vault. Created on first run with `gitea admin user create --random-password` | up, cmd_up, cmd_update / vault_api | `kv/data/lab/bootstrap/gitea-admin` |
| `ensure_org(creds) -> None` | Org `lab` | up / gitea_api | orgs/lab |
| `ensure_repo(creds) -> None` | Private, empty repo `lab/lab`, default branch main | up / gitea_api | repos/lab/lab |
| `runner_registration_token(token, creds) -> None` | Store a registration token once | up / gitea_api, vault_api | `kv/data/lab/bootstrap/gitea-runner` |
| `pipeline_secrets(token, creds) -> None` | lab-pipeline creds as repo Actions secrets, if missing | up / gitea_api, vault.approle_credentials | secrets VAULT_ROLE_ID, VAULT_SECRET_ID |
| `flux_token(token, creds) -> None` | Read-only labadmin token (`read:repository`) for Flux, stored once (B08.7 item 2; Implemented, never run) | up / gitea_api, vault_api | `kv/data/lab/pipeline/gitea-flux` |
| `up() -> None` | compose up --wait, then the seeding above | platform_up / compose, vault.login | container gitea |
| `down() -> None` | `compose gitea down --volumes` | platform_down / podman.check, compose | |

Acceptance: `lab/lab` exists, and its Actions secrets list both VAULT_* names. Status: Verified.

### B04.2 Host runner
Files: `src/services/gitea/runner/{runner.py,config/config.py,files/config.yaml,files/lab-runner.service}`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `ensure_home() -> None` | Runner data directory, root 0700 (was `ensure_user()`: user lab-runner uid 1990, until 2026-11-18) | up | `/var/lib/lab/runner` |
| `ensure_binary() -> bool` | gitea-runner 6.0.0, sha256-checked | up / write_file | `/usr/local/bin/gitea-runner` |
| `ensure_config() -> bool` | Install config.yaml and the CA copy | up / install_file | `/etc/lab-runner/{config.yaml,ca.pem}` |
| `ensure_ssh_key(token) -> None` | Public key from Vault for Terraform | up / vault_api, write_file | `/etc/lab-runner/ssh.pub` |
| `ensure_registered(token) -> None` | Register once with the stored token, chown `.runner` | up / vault_api | `/var/lib/lab/runner/.runner` |
| `ensure_service(changed) -> None` | Install the unit, enable it, restart on change | up / install_file, systemctl_ok | `lab-runner.service`, `/var/lib/lab/tfstate` |
| `up() -> None` | The six steps above, with one vault.login | platform_up | |
| `down() -> None` | Stop and remove the unit, config, binary and user | platform_down | |

Acceptance: `systemctl is-active lab-runner` is active, and Gitea shows runner `lab-host` with label `host`. Status: up Verified; down never run. `ensure_binary` accepts any existing binary, so a `VERSION` bump is ignored (check `gitea-runner --version` like `installed_version_ok`).

---

## B05 up/update and the pipeline skeleton

### B05.1 Git and run helpers
Files: `src/services/gitea/gitea.py` (same file as B04.1), `src/services/gitea/config/config.py` (RUN_*, COMMIT_IDENTITY)

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `git(*args) -> str` | `git -C BASE_DIR ...` | commit_changes, push, main_differs | `.git` |
| `commit_changes() -> None` | `add -A` + commit "update YYYY-MM-DD HH:MM" as "lab operator", if dirty | cmd_up, cmd_update / git | `.git` (as root) |
| `push(creds) -> str` | Push HEAD to Gitea main, return sha | start_run / git | GIT_SSL_CAINFO = `state/pki/ca.pem` |
| `main_differs(creds) -> bool` | Local HEAD differs from Gitea main (a 404 on an empty repo counts as different) | start_run / gitea_api, git | branches/main |
| `dispatch(creds) -> int` | workflow_dispatch deploy.yml, return run id | start_run / gitea_api | actions/workflows/deploy.yml |
| `wait_for_run(creds, sha) -> int` | Find the push run for sha (60 s) | start_run / gitea_api | actions/runs |
| `start_run(creds) -> int` | main_differs ? wait_for_run(push) : dispatch | cmd_up, cmd_update | |
| `follow_run(creds, run_id) -> None` | Wait for completion, print job results and the failed-job log tail. Exit 1 unless success | cmd_up, cmd_update / gitea_api | actions/jobs/{id}/logs |

Status: commit_changes, push, main_differs, wait_for_run, follow_run Verified (run #8 came from an
update push). dispatch Verified (run #7 at `c287ecb`, unchanged since). start_run Implemented: it
replaced initial_push and update's inline branch on 2026-11-16 evening, so a retried `up` pushes local
fixes instead of dispatching the old main.

### B05.2 Commands
Files: `src/__main__.py`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `cmd_up() -> None` | First build (see the call graph) | COMMANDS["up"] | `state/initialized` |
| `cmd_update() -> None` | Converge the host, push or dispatch, follow | COMMANDS["update"] | |
| `cmd_teardown() -> None` | Not implemented: logs an error and exits 1 (B08.5) | COMMANDS["teardown"] | |
| `cmd_destroy() -> None` | platform_down, `rmtree(/var/lib/lab)`, remove the marker | COMMANDS["destroy"] | |

Acceptance: `sudo ./bootstrap.sh update` with no edits dispatches a run and prints its job results.
Status: cmd_update Verified (run #8; now calls start_run). cmd_up Implemented (never run from zero in its current form). cmd_destroy Implemented (never run with VMs; B08.5 rehearsal). cmd_teardown Next (B08.5).

### B05.3 Workflow skeleton
Files: `.gitea/workflows/deploy.yml`, `.gitea/workflows/check.yml`

| Workflow | Does | Uses |
|---|---|---|
| deploy.yml | Trigger on push to main and dispatch. Concurrency `lab-deploy`. Chains check > terraform > ansible | `uses: ./.gitea/workflows/*.yml`, `secrets: inherit` for ansible |
| check.yml | Job `validate`: checkout, `terraform init -backend=false`, `fmt -check -recursive`, `validate` | actions/checkout@v4 |

Acceptance: run #8 shows check passing before terraform. Status: Verified.

---

## B06 Terraform

Files and resources in build order (provider dmacvicar/libvirt 0.9.9, ansible/ansible 1.5.0):

| File | Resources / content | Connects to |
|---|---|---|
| `terraform/provider.tf` | Version pins. Local backend `/var/lib/lab/tfstate/terraform.tfstate`. libvirt uri qemu:///system | runner StateDirectory |
| `terraform/.terraform.lock.hcl` | Provider lock (`-lockfile=readonly` in all jobs) | check, terraform, ansible jobs |
| `terraform/variables.tf` | `base_image_url`, `ssh_public_key_file` (/etc/lab-runner/ssh.pub), `lab_ca_cert_file` (/etc/lab-runner/ca.pem) | runner.ensure_ssh_key, runner.ensure_config |
| `terraform/storage.tf` | `libvirt_pool.lab` (/var/lib/lab/pool), `libvirt_volume.base` (Ubuntu 24.04 cloud image) | compute.tf backing store |
| `terraform/network.tf` | `site_a`, `site_hub`, `site_c` (isolated, no IP), `wan` (route, 198.51.100.1/24) | domain NIC 0 and NIC 1, vmfw bridge name `wan` |
| `terraform/compute.tf` | `local.vms`, `libvirt_volume.disk` (`<vm>-<gb>g.qcow2`), `libvirt_cloudinit_disk.seed`, `libvirt_volume.seed` (iso), `libvirt_domain.vm` (file-path disks, NICs vpc/wan/mgmt with taps `<vm>-vpc/-wan/-mgmt`) | vmfw tap names, cloudbr1 |
| `terraform/cloud-init/user-data.yaml.tftpl` | User `user` (key only, sudo), root login off, `ca_certs.trusted` | ssh.pub, ca.pem |
| `terraform/cloud-init/network-config.yaml.tftpl` | eth0 vpc_ip, eth1 wan_ip with default route via 198.51.100.1, eth2 mgmt_ip with DNS 10.250.0.1 | CoreDNS |
| `terraform/inventory.tf` | `ansible_host.vm`: groups frontend/hub/backend, ansible_host = mgmt_ip, ansible_user = user | ansible/inventory.yml |
| `.gitea/workflows/terraform.yml` | Job `apply`: marker test, virsh, init, `apply -auto-approve`. TMPDIR=/var/lib/lab/tfstate | vmfw.up marker |

VMs:

| VM | group | vCPU / MiB / disk | vpc (eth0) | wan (eth1) | mgmt (eth2) |
|---|---|---|---|---|---|
| fe-1 | frontend | 1 / 1024 / 10G | 10.1.1.10 (site-a) | 198.51.100.11 | 10.250.0.110 |
| tun-1 | hub | 1 / 512 / 10G | 10.2.1.10 (site-hub) | 198.51.100.12 | 10.250.0.111 |
| be-1 | backend | 2 / 4096 / 40G | 10.3.1.10 (site-c) | 198.51.100.13 | 10.250.0.112 |

Acceptance: `virsh -c qemu:///system list` shows three running domains. A second apply reports no changes.
Status: Verified. Creation from an empty pool passed in run #6, right after the AppArmor fix (`c287ecb`,
2026-11-16 15:26); runs #7 and #8 were applies over the existing VMs. A fresh `up` from zero is B08.5.

---

## B07 Ansible

| File | Content | Connects to |
|---|---|---|
| `ansible/ansible.cfg` | inventory = inventory.yml, host key checking off, ControlPersist | ansible.yml `working-directory: ansible` |
| `ansible/inventory.yml` | `plugin: cloud.terraform.terraform_provider`, `project_path: ../terraform` | Terraform state (ansible_host) |
| `ansible/site.yml` | Play 1 on `localhost`: assert `frontend`, `hub`, `backend` each have one host (an empty inventory fails instead of passing). Play 2 `hosts: all`, `gather_facts: false`, roles `[ready]` | roles/, inventory |
| `ansible/roles/ready/tasks/main.yml` | `wait_for_connection` (300 s), then `cloud-init status --wait` must show done | cloud-init |
| `.gitea/workflows/ansible.yml` | Job `configure`: checkout, vault-action@v4 (approle, `kv/data/lab/pipeline/ssh private_key`), ssh-agent@v0.10.0, `terraform init`, `ansible-playbook site.yml`. NODE_EXTRA_CA_CERTS=/etc/lab-runner/ca.pem | Gitea secrets, Vault lab-pipeline policy |

Acceptance: the ansible job is green, and every host reports ok.
Status: ready play Verified (run #8, against VMs that had already booted). Assert play Implemented (tested locally against a fixture inventory and an empty one).

---

## B08 Next (in this order; 2026-11-18 starts at B08.7)

### B08.1 Squid egress proxy (Verified 2026-11-17, run #12)
The VMs have no internet: wan is route mode, and vmfw drops wan egress. All package installs go
through Squid.

Proposed files: `src/services/squid/{__init__.py,squid.py,compose.yaml,conf/squid.conf}`

| Function / item | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `squid.up() -> None` | `compose squid up -d` | platform_up, after `dns.up` / system.compose | container squid, `10.250.0.1:3128` |
| `squid.down() -> None` | `compose squid down` | platform_down, before `dns.down` / podman.check, compose | |
| `compose.yaml` | Digest-pinned image (e.g. ubuntu/squid), `network_mode: host` or publish `10.250.0.1:3128`, conf mounted ro, cap_drop ALL | | |
| `conf/squid.conf` | `http_port 10.250.0.1:3128`. Allow `10.250.0.0/24` to an allowlist (archive.ubuntu.com, security.ubuntu.com and any later package hosts). Allow CONNECT only to 443. Deny all else. No cache | | |
| Corefile | Add `10.250.0.1 proxy.lab.test` to the hosts line | | |

Acceptance: on fe-1, `curl -x http://proxy.lab.test:3128 -I http://archive.ubuntu.com` returns 200, and `curl -I https://example.com` fails without the proxy.

Implemented 2026-11-17, not yet run: `src/services/squid/` (image `ubuntu/squid:7.2-26.04_edge` digest-pinned, contains
squid 7.7-0ubuntu0.26.04.2 (checked in /usr/share/rocks/dpkg.query); a Rockcraft image: runs as `_daemon_` UID 584792,
binary `squid-gnutls`, so the entrypoint runs it directly, `cap_drop: ALL` with no additions, `pid_filename none`; own
config path `/etc/squid-lab`, FTP denied for CVE-2026-47729, file access log at `/var/log/squid/access.log` in the
container, a squid.conf hash in the compose env recreates the container on change), `proxy.lab.test` in the Corefile,
and vmfw now also drops forwarding to/from `cloudbr1`, `site-a`, `site-hub`, `site-c` (a changed guest route could
otherwise leave via the host through 10.250.0.1; the tier networks are isolated, so their names are only a guard). Extra acceptance: `curl -x … http://example.com`
returns 403, and the new vmfw drop counters exist (`nft list chain inet lab_vmfw forward`).

Widened 2026-11-17 for k3s and Flux (chosen over an offline install: official sources, fewer steps), be-1 only:
`acl backend src 10.250.0.112` + `acl k3s_hosts dstdomain get.k3s.io github.com release-assets.githubusercontent.com
.docker.io .docker.com ghcr.io pkg-containers.githubusercontent.com`, `http_access allow backend k3s_hosts`.
Verified: from be-1 get.k3s.io 200, Docker Hub and ghcr.io 401 (reached); from fe-1 and tun-1 403.
Production answer: a pull-through registry mirror, or images baked into the VM image.

### B08.1b Operator SSH access (Verified 2026-11-17, run #13)
`src/host/ssh_access.py`: `up()` creates `~/.ssh/lab_operator` for the sudo user once (ssh-keygen run as that user)
and installs `src/host/files/60-lab-ssh.conf` to `/etc/ssh/ssh_config.d/` (aliases fe-1, tun-1, be-1 on the mgmt IPs);
`public_key()` derives the public key with `ssh-keygen -y`; `down()` removes only the aliases and keeps the key.
`runner.ensure_ssh_key()` writes both public keys (pipeline from Vault, operator) to `/etc/lab-runner/ssh.pub`;
`compute.tf` splits it into `ssh_public_keys` and the user-data template loops over it. Wired in `platform_up` before
`runner.up` and in `platform_down` after `runner.down`.
Acceptance: after `update` (the VMs are rebuilt once), `ssh fe-1 hostname` prints fe-1 as the normal user.
Verified: run #13 rebuilt the VMs; `ssh fe-1 hostname` prints fe-1. From fe-1, Squid: archive.ubuntu.com via proxy 200,
example.com via proxy 403, ftp:// via proxy 403, CONNECT to :22 403, direct HTTPS times out (exit 28).

### B08.2 Common role (Verified 2026-11-17, run #14)
Files: `ansible/roles/common/tasks/main.yml`, `ansible/group_vars/all.yml` (`proxy_url`, `common_packages`)

| Task | Does | Uses |
|---|---|---|
| apt proxy | `/etc/apt/apt.conf.d/90lab-proxy`: `Acquire::http::Proxy` and `Acquire::https::Proxy` = `{{ proxy_url }}` (Implemented; content tested on fe-1 with `apt-get -c`) | B08.1 |
| packages | `apt` installs `common_packages` (nftables, wireguard-tools) | proxy |

`site.yml`: the `hosts: all` play gets `become: true` and roles `[ready, common]`.
Acceptance: `apt-config dump` shows the proxy and `wg --version` works on all three VMs.
Verified: run #14; on fe-1, tun-1, be-1 the proxy lines are in `apt-config dump`, `90lab-proxy` is root:root 644,
wireguard-tools 1.0.20210914 installed. Still to see: a second run reports changed=0.

Considered and skipped (2026-11-17):
- NTP in the VMs: kvm-clock follows the host, which chrony keeps synced; measured offset under 0.6 s; nothing in a
  1-2 day lab depends on sub-second time. Production: an NTP client on every VM (CIS baseline).
- DNS check task: cloud-init owns DNS and `gitea.lab.test` already resolves on eth2.

### B08.3 VM firewall inside the guests (Deferred 2026-11-17, plan item 6.1b)
Deferred: every direct fe-1 to be-1 path is already blocked on the host (tested from fe-1: mgmt 10.250.0.112, wan
198.51.100.13 and site-c 10.3.1.10 all unreachable). Traffic inside WireGuard is invisible to the host, so if a
port or direction limit is wanted, it goes on tun-1's forward chain in the wireguard role, not on every VM.
Proposed files: `ansible/roles/base/tasks/firewall.yml`, `ansible/roles/base/templates/nftables.conf.j2`,
`ansible/group_vars/{frontend,hub,backend}.yml`

| Item | Does |
|---|---|
| `nftables.conf.j2` | `table inet lab_guest`: input policy drop. Allow lo, established, ssh on eth2 from 10.250.0.1, and `fw_allow` entries from group_vars. Forward policy drop (the hub opens one path in B08.4) |
| group_vars | frontend: tcp 443 on eth1. hub: udp 51820 and 51821 on eth1. backend: wg ingress to 8000 only |
| tasks | Template to `/etc/nftables.conf`, validate with `nft -c -f %s`, enable nftables, handler `systemctl reload nftables` |

Acceptance: from the host, `nc -zv 10.250.0.112 22` works, while any port not in `fw_allow` times out.

Done instead (2026-11-17): only tun-1's forward chain, in the wireguard role (B08.4). Input chains on the VMs and the
host (B09.3) stay deferred.

### B08.4 One data-driven wireguard role (Verified 2026-11-17, run #16 + hub filter run)
Files: `ansible/host_vars/{fe-1,tun-1,be-1}.yml` (`wg_interfaces`), `ansible/roles/wireguard/{tasks/main.yml,
handlers/main.yml,templates/wg.conf.j2,files/hub-forward.nft}`, `terraform/inventory.tf` (`vpc_ip`, `wan_ip`).
Addressing: docs/three-vpc-design.md section 5.

| Item | Does | Connects to |
|---|---|---|
| `wg_interfaces` (host_vars) | Per local interface: `name`, `address`, `peer`, `allowed_ips`; hub entries `listen_port`, spoke entries `endpoint_port` | ports match the wan rules in nftables-vmfw.nft |
| key tasks | One key per VM: `wg genkey` into `private.key.tmp` then `mv` to `/etc/wireguard/private.key` (umask 077, `creates:`; a failed genkey leaves no file); `wg pubkey` registered as `wg_public_key` (`changed_when: false`) | peers read `hostvars[peer].wg_public_key.stdout`; all VMs in one play |
| `wg.conf.j2` | `Address`, `ListenPort` if `listen_port`; `PostUp = wg set %i private-key …` (no PrivateKey line, the key never reaches Ansible); spokes: `PostUp = ip route replace <net> dev %i src {{ vpc_ip }}` per AllowedIPs, `Endpoint = hostvars[peer].wan_ip:endpoint_port`, `PersistentKeepalive = 25` | `notify: Restart wireguard` (restart, not reload: reload skips Address/PostUp) |
| hub forwarding | `/etc/sysctl.d/90-lab-forward.conf` `net.ipv4.ip_forward = 1`, `when: 'hub' in group_names`, handler `sysctl -p` | |
| hub filter | `hub-forward.nft` → `/etc/nftables.conf` (`validate: nft -c -f %s`), nftables enabled: forward policy drop, invalid drop, established/related accept, only `wg0→wg1 10.1.1.10 → 10.3.1.10 tcp 8000 ct state new` | handler `Reload nftables` |
| service | `wg-quick@<name>` enabled and started per interface | |
| site.yml | play 2: `hosts: all`, roles `[ready, common, wireguard]` | |

Verified: handshakes on wg0 and wg1; fe-1 `ip route get 10.3.1.10` = `dev wg0 src 10.1.1.10`; ip_forward 1 on tun-1
only. Hub filter: fe-1 → 10.3.1.10 tcp 8000 connects (temporary listener); tcp 22, tcp 5432 and ping blocked; be-1 →
fe-1 blocked; drop counter rises; mgmt and wan paths between VMs still blocked. Still to see: changed=0 on a rerun.

### B08.5 Teardown, destroy, and a fresh up from zero (Planned after B08.7; includes the bridge rename)
Done 2026-11-16 evening (Implemented, not yet run): `kvm.remove_lab_vms` before the libvirt purge,
`rmtree(/var/lib/lab)` in cmd_destroy (pool, tfstate, runner home, Vault files), `start_run` for up,
`vault.down` guard, `cmd_teardown` exits 1.

| Still to do | File | Connects to |
|---|---|---|
| Root-owned `.git` after commit_changes: Done 2026-11-17 (update e5cf4a0, no root-owned files in .git) (`git()` runs as SUDO_UID:SUDO_GID; `bootstrap.sh` refuses to start without SUDO_UID) | `gitea.py`, `bootstrap.sh` | `.git` stays the user's |
| Optional `teardown` (VMs only, keep the platform): `teardown.yml` with `workflow_dispatch`, TMPDIR, `terraform init` + `destroy -auto-approve`; `dispatch(creds, workflow=GITEA_WORKFLOW)`; `cmd_teardown` = `follow_run(creds, dispatch(creds, "teardown.yml"))` | `.gitea/workflows/teardown.yml`, `gitea.py`, `src/__main__.py` | runner, tfstate |
| Rename the mgmt bridge `cloudbr1` → `mgmtbr1` (name confirmed 2026-11-18; do it after B09.4 monitoring, then rebuild in a fresh 4-core / 16 GB VM as the from-zero test; anchor `mgmtbr1-anchor`, netplan `60-lab-mgmtbr1.yaml`). Do it between `destroy` (old code removes cloudbr1) and the fresh `up`, so no migration code is needed. Renaming on a live host would leave two bridges with 10.250.0.1 | `src/lib/config.py` BRIDGE, `src/host/config/config.py`, the netplan file, `network.py`, `nftables-vmfw.nft`, `terraform/compute.tf`, comments in `60-lab-ssh.conf`/`chrony-lab.conf`, docs | everything on mgmt |
| The rehearsal itself | | |

Acceptance: `sudo ./bootstrap.sh destroy`, then `virsh list --all` (libvirt is gone), `ls /var/lib/lab` (missing), and `nft list tables` (no lab tables). Then `sudo ./bootstrap.sh up` ends with a green run.

Already proven from zero (2026-11-14, older code, `state/bootstrap.log`): destroy then platform_up through Vault init, AppRole creation, Gitea admin, org and repo. Never proven from zero: kvm, vmfw, toolchain, runner, the initial push, and the first pipeline run creating the VMs.

---

### B08.6 k3s on be-1 (Verified 2026-11-17)
Files: `ansible/roles/k3s/{defaults/main.yml,tasks/main.yml,handlers/main.yml}`, `site.yml` play 3 (`hosts: backend`,
`become: true`, roles `[k3s]`).

| Item | Does | Connects to |
|---|---|---|
| defaults | `k3s_version: v1.37.2+k3s1` (stable 2026-11-17), `k3s_no_proxy: 127.0.0.1,localhost,10.0.0.0/8,.lab.test` | k3s adds pod/service CIDRs and cluster.local itself |
| config | `/etc/rancher/k3s/config.yaml` (folder made first, 0600): `node-ip: {{ vpc_ip }}`, `disable: [traefik]`; written before the first start | handler `Restart k3s` |
| install | `get_url https://get.k3s.io` (HTTPS_PROXY) → `k3s-install.sh`, run with HTTP(S)_PROXY, NO_PROXY, INSTALL_K3S_VERSION, `creates: /usr/local/bin/k3s`; the installer verifies the binary's sha256 and copies the proxy vars into `k3s.service.env` | Squid be-1 allowlist (B08.1) |
| ready | `k3s kubectl wait --for=condition=Ready node/{{ inventory_hostname }} --timeout=10s` in an `until` loop (30 × 10 s) | |
| vmfw | forward: `iifname "cloudbr1" ip saddr 10.250.0.112 ct original proto-dst 443 ct status dnat accept` (Traefik is a podman port mapping, so VM → Gitea is forwarded, not input) | Flux (B08.7) |

Verified: node be-1 Ready, INTERNAL-IP 10.3.1.10, coredns/local-path/metrics-server Running, no Traefik; proxy lines
in `k3s.service.env`; be-1 → `https://gitea.lab.test` 200, fe-1 → Gitea, be-1 → Vault and be-1 → internet time out.
Notes: flannel picked eth1 (`public-ip 198.51.100.13`); irrelevant with one node, a second node would need
`flannel-iface: eth0`. Runs #18/#19 failed on the first ready check: the `command` module splits with shlex and
dropped the quotes in a jsonpath filter.

### B08.7 Flux, the app and the frontend (Next, 2026-11-18)
Goal: a browser on the LAN does CRUD at `https://app.lab.test`; the database is reachable only inside k3s, and from
fe-1 only `10.3.1.10:8000` passes the hub.

| Order | Item | Proposed files | Connects to |
|---|---|---|---|
| 1 | Flux v2.10.0 controllers in k3s (`flux install --export`, images from ghcr.io via Squid) | `k8s/flux-system/` or the k3s manifests folder, applied by the k3s role | B08.6 |
| 2 | Flux → Gitea: read-only token made by bootstrap, kept in Vault, delivered as a Secret with the lab CA; `GitRepository` + `Kustomization` for `kubernetes/apps/` | `gitea.py`, `ansible.yml` (vault-action), roles/k3s or roles/flux | vmfw be-1 → 443 |
| 3 | App: PostgreSQL (ClusterIP only, init SQL: `items` table, `web_anon` role with CRUD grants), PostgREST (LoadBalancer :8000) | `kubernetes/apps/*.yaml` | hub filter tcp 8000 |
| 4 | Frontend as a built, scanned container on fe-1 (decided 2026-11-18, replaces apt nginx): see item 4 plan below | `frontend/` (Dockerfile, index.html, nginx.conf), `.gitea/workflows/image.yml`, `ansible/roles/frontend/` | Gitea registry, vmfw fe-1 → 443, LAN :443 DNAT → fe-1 |
| 5 | ✔ Acceptance: CRUD in a browser; from fe-1 `nc 10.3.1.10 5432` and `ssh 10.3.1.10` fail; tun-1 port-8000 counter rises | | |

Status (2026-11-18): item 1 Verified (commit `a52a51d`, pipeline green): `ansible/roles/fluxcd` installs the CLI,
runs `flux check --pre`, writes `flux install --export --components=source-controller,kustomize-controller` to
`/var/lib/rancher/k3s/server/manifests/flux.yaml`, and waits for both Deployments. No `flux bootstrap` (it needs a
write token and its push to Gitea would retrigger the pipeline).

Item 3 Verified (`e1db038`): CRUD on `10.3.1.10:8000/items` from fe-1, pipeline waits for Flux to apply the commit.

Item 2 Verified (commit `c7017af`): GitRepository `lab-repo` Ready (token from Vault, lab CA, be-1 → Gitea 443).

Item 4 Verified (`b1c4797`, `07bbeeb`): Flask frontend on fe-1 from the pipeline-built image; `app.lab.test` works from
LAN and from the host's own browser (vmfw `nat output` DNAT added).

Item 5 Verified (2026-11-18): CRUD in the host browser; from fe-1 :8000 → 200, :5432, :22, :6443 blocked; be-1 → fe-1
:443 blocked; hub drop counter 8 → 23. **B08.7 done.** Next: B09.4 monitoring (plan below).
- [x] `GITEA_FLUX_KV = "kv/data/lab/pipeline/gitea-flux"` in `gitea/config/config.py` (`lab-pipeline` can already read it)
- [x] `flux_token(token, creds)` in `gitea.py`, called in `up()`: a labadmin token, scope `read:repository`, name
  `flux`, stored as `{username, token}`. Implemented, never run. Gotcha: if a run dies between the POST and the
  Vault write, the next POST fails (name taken): delete the `flux` token in Gitea and run again.
- [x] Run `sudo ./bootstrap.sh update`; check `vault kv get kv/lab/pipeline/gitea-flux` has both fields
- [x] `ansible.yml`: add `kv/data/lab/pipeline/gitea-flux token | FLUX_GIT_TOKEN` to the vault-action `secrets:`, and
  pass `FLUX_GIT_TOKEN` as `env:` on the playbook step
- [x] `fluxcd` role: `copy` a Secret (username, password = token, `ca.crt` = lab CA) into the k3s manifests folder
  with `no_log: true`, using `lookup('env', 'FLUX_GIT_TOKEN')`
- [x] `GitRepository` (`https://gitea.lab.test/lab/lab.git`, branch `main`) + `Kustomization` (`./kubernetes/apps`) in the
  same folder; check `k3s kubectl -n flux-system get gitrepository` is Ready (the pod must resolve and reach Gitea)

Item 3 plan (layout A: separate Postgres and PostgREST pods, namespace `db`):
- [x] Passwords: `vault.py` `app_db_passwords()` → `kv/lab/pipeline/app-db`; `ansible.yml` reads both; `roles/app_secrets` → Secret `app-db` (keys `POSTGRES_PASSWORD`, `AUTHENTICATOR_PASSWORD`). Verified `d902077`
- [x] `kubernetes/apps/db/namespace.yml` (Flux), `lab-apps` Ready
- [x] `kubernetes/apps/db/init.sh` via configMapGenerator (kustomization.yaml) (database and schema `todo` since 2026-11-18, table `todo.items`, `web_anon` NOLOGIN with CRUD grants, `authenticator` LOGIN NOINHERIT with the password)
- [x] `kubernetes/apps/db/postgres.yaml` (verified `9acb2ec`, authenticator → web_anon works): PVC (local-path), Deployment (Recreate, `envFrom` Secret `app-db`, init mounted at `/docker-entrypoint-initdb.d`), Service ClusterIP 5432
- [x] `kubernetes/apps/db/postgrest.yaml` (verified `30e11b3`: CRUD from fe-1 via wg0, 5432 and 22 blocked): Deployment (`PGRST_DB_URI` with `$(AUTHENTICATOR_PASSWORD)`, schemas `todo`, anon role `web_anon`), Service LoadBalancer :8000
- [x] `fluxcd` role: wait until `lab-apps` lastAppliedRevision = `main@sha1:$GITHUB_SHA` (verified `e1db038`; livenessProbe dropped from PostgREST); from fe-1 `curl http://10.3.1.10:8000/items` (done `59c5f2a`)

Item 4 plan (container build + Trivy; 2026-11-18: runner runs as root, image path to fe-1 still open: tarball vs registry):
- [x] Host: Trivy 0.76.2 pinned in `toolchain.py` (binary + sha256). Installed
- [x] Host: runner as root, verified `9efb1db` (`lab-runner.service` User=root, `StateDirectory=lab/tfstate lab/images`; `ensure_home()` replaces `ensure_user()`; `down()` removes the old `lab-runner` user). Decided because rootless builds hit three alvistack/Podman 6 issues: no subuid range, no `uidmap`, and `/usr/share/containers/storage.conf` forcing root `graphroot` on every non-root user. Trade-off: jobs run as root on the host (Q&A)
- [x] `frontend/` (2026-11-18, Python instead of nginx + JS): `app.py` (Flask: GET /, POST /add, /update/<id>, /delete/<id>, calls PostgREST server-side via urllib, `API_URL`), `templates/items.html` (autoescaped), `requirements.txt` (8 pinned packages), multi-stage `Dockerfile` (Chainguard python `latest-dev` pip stage → distroless `latest`, Python 3.15.2, gunicorn TLS on 443 with `/etc/app/tls/tls.{crt,key}`). Tested: CRUD against live PostgREST via tunnel; Trivy 0 vulns (wolfi + 8 python-pkg)
- [x] `vault.py` `app_edge_cert()` + `ansible.yml` APP_EDGE_CERT/APP_EDGE_KEY (verified 2026-11-18: kv/lab/pipeline/app-edge)
- [x] `check.yml`: `trivy config --skip-dirs terraform/.terraform .` (report only, written; preview: terraform clean, Dockerfile only DS-0026 after `USER 65532`, ~15 securityContext findings per k8s manifest)
- [x] `image.yml` (verified 2026-11-18; `rm -f` before `podman save`, which refuses to overwrite) (deploy.yml: check → image → terraform → ansible, written): `podman build` tag = commit SHA → `podman save -o /var/lib/lab/images/frontend.tar` → `trivy image --input` **report only** (user's choice 2026-11-18, no gate): table in the log + `trivy-image.{txt,json}` uploaded as artifact `trivy-image-report` (upload-artifact@v4, 7 days)
- [x] (verified 2026-11-18: service active, image tag = commit, key 65532 0600, cert CN app.lab.test, page 200 via API; host-local curl to HOST_IP gets no DNAT (prerouting is LAN-card only), test from a LAN device) `frontend` role on fe-1: podman (Ubuntu 4.9, quadlet keys from the 4.9 set only), sysctl `net.ipv4.ip_unprivileged_port_start=443` (Chainguard runs non-root), copy + `podman load` the tar, quadlet `Network=host` on 443, `app-edge` cert mounted at `/etc/app/tls` (key readable by uid 65532)

## B09.4 Monitoring plan (decided 2026-11-18: an agent on every system pushes to the host stack; metrics, k3s, logs, alerts)

**RESUME HERE: B09.4 step 3, push and verify the VM agents.** Step 2 code done (Grafana admin labadmin, password at kv/lab/bootstrap/grafana-admin; needs one-time grafana-data volume reset + update). Step 3 written 2026-11-18: ansible/roles/alloy (host downloads the pinned .deb, copies to each VM, apt installs; config.alloy.j2 with instance=inventory_hostname; MemoryMax=200M), last play in site.yml. vmfw exception for all 3 VMs must be loaded (update) before the push.

```
  every system runs one agent (Grafana Alloy)               host = aggregation only (compose, src/services/monitoring/)
  ┌ host  (Alloy container, host net) ─┐
  ├ fe-1  (Alloy, systemd)             ├─ metrics: remote_write ─▶ https://prometheus.lab.test ─ Traefik ─▶ Prometheus (lab-backend)
  ├ tun-1 (Alloy, systemd)             ├─ logs:    push         ─▶ https://loki.lab.test       ─ Traefik ─▶ Loki (lab-backend)
  └ be-1  (Alloy, systemd) + k3s       ┘                            Grafana ── Traefik ── https://grafana.lab.test
```

| Agent on | Metrics | Logs |
|---|---|---|
| every system | node: CPU, memory, disk, network (Alloy's built-in unix exporter) | systemd journal |
| be-1, extra: k3s | kubelet/cAdvisor (pod and container CPU, memory), k3s API server, kube-state-metrics (pod ready, restarts, deployments), PostgREST `/metrics` (admin port, found by pod discovery) | `k3s.service` (in the journal), pod logs from `/var/log/pods` (postgres, postgrest, flux, coredns) |

- Push only, VM → host, over HTTPS through Traefik (prometheus.lab.test, loki.lab.test). Traefik's podman port mapping
  makes that forwarded traffic, so vmfw's Traefik exception (be-1 only until now) is extended to fe-1 and tun-1.
- be-1's agent runs as root: it reads k3s's admin client certificate (`/var/lib/rancher/k3s/server/tls/`) for the kubelet
  and API server, and pod log files. kube-state-metrics stays ClusterIP; the agent reaches pod IPs from the node. No new
  LoadBalancer ports.
- Alloy install: pinned binary + sha256 downloaded by the host toolchain (like Trivy), copied by Ansible with a small
  systemd unit. No Grafana apt repo, no Squid change.

| Step | What | Files |
|---|---|---|
| 1 | Host stack: Prometheus (`--web.enable-remote-write-receiver`), Loki, Grafana, host Alloy; pinned digests; `up()/down()` | `src/services/monitoring/{monitoring.py, compose.yaml, config/monitoring_config.py, files/}` |
| 2 | Grafana behind Traefik: route, `grafana.lab.test` SAN on `gateway`, Corefile record, provisioned datasources, admin password | `traefik/dynamic/grafana.yml`, `src/lib/config.py`, Corefile, `files/grafana/` |
| 3 | VM agents: Alloy binary (toolchain), role `alloy` (binary, unit, `config.alloy`: unix metrics + journal) | `src/host/config/config.py`, `toolchain.py`, `ansible/roles/alloy/`, `site.yml` |
| 4 | k3s: kube-state-metrics via Flux; be-1 Alloy extras (kubelet/cAdvisor, API server, pod discovery for PostgREST + kube-state-metrics, pod logs) | `kubernetes/apps/monitoring/`, `roles/alloy/templates/` |
| 5 | Alerts: InstanceDown (no data 2 min), DiskAlmostFull, MemoryHigh, PodNotReady, PodRestarting, PostgRESTDown | `files/prometheus/rules.yml` |
| 6 | Dashboards: Node Exporter Full (1860), a Kubernetes pods dashboard (pinned JSON); logs via Explore | `files/grafana/dashboards/` |
| 7 | Acceptance: every system and k3s in Grafana, k3s + pod logs searchable, stop Alloy on fe-1 → InstanceDown fires | |

Budget: about 600 MB on the host stack, about 100 MB per agent (watch tun-1, 512 MB), about 50 MB for kube-state-metrics.

## B09 Later

| ID | Step | Proposed files / functions | Connects to | Status |
|---|---|---|---|---|
| B09.4 | Monitoring | `src/services/monitoring/compose.yaml` (prometheus, node-exporter, grafana) behind Traefik. Add grafana/prometheus SANs and Corefile names back | traefik, pki | Planned |
| B09.5 | Istio ambient for the app (after B08.7 acceptance, decided 2026-11-18) | Helm-rendered ambient install delivered by Flux (`profile=ambient`, `global.platform=k3s`: istio-base, istiod, istio-cni, ztunnel), namespace label `istio.io/dataplane-mode=ambient`, one L4 `AuthorizationPolicy` (only the postgrest service account → postgres:5432), PostgREST :8000 PERMISSIVE because fe-1 is outside the mesh. Transit stays deferred | B08.7 | Planned |
| B09.5a | Vault Secrets Operator (with B09.5, decided 2026-11-18) | VSO Helm chart via Flux (same Helm setup as Istio), vmfw be-1 → 10.250.0.1:8200, `VaultConnection` with the lab CA, Vault Kubernetes auth (Vault → k3s API :6443, k3s `tls-san`, token reviewer) or JWT auth with k3s's static SA public key, policy `app-db.hcl` (read `kv/data/lab/pipeline/app-db`), `VaultStaticSecret` in git replaces `roles/app_secrets`. Pod manifests unchanged (they only name Secret `app-db`) | B08.7, B09.5 | Planned |
| B09.6 | DR | Walkthrough only (unseal key loss, tfstate loss) | vault-init.json, tfstate | Deferred |
| B09.1 | Consoles | `src/host/trust.py` `up()/down()`: copy `state/pki/ca.pem` to `/usr/local/share/ca-certificates/lab.crt`, `update-ca-certificates`, Firefox `policies.json` (Certificates.Install). Called after `pki.up` | Gitea UI, Vault UI, `virsh console` | Last, likely skipped (2026-11-18) |
| B09.2 | Host SSH hardening | `src/host/sshd.py` + `files/sshd-lab.conf` drop-in (no passwords, no root), validate with `sshd -t`, reload | platform_up after network | Last, likely skipped (2026-11-18) |
| B09.3 | Host firewall (today every VM reaches anything listening on 10.250.0.1 or 0.0.0.0, e.g. sshd 22, rpcbind 111) | `files/nftables-host.nft` table `inet lab_host` (input drop. Allow lo, established, LAN ssh; cloudbr1 to 53, 123, 443, 3128, 8200; LAN to host_ip 53 if LAN clients should resolve app.lab.test, since CoreDNS binds HOST_IP too), loaded by `vmfw.up` or `hostfw.py` next to it | must not break the LAN :443 DNAT | Last, likely skipped (2026-11-18) |

---

## B10 Dropped or deferred

| Item | Decision | Date | Replaced by |
|---|---|---|---|
| Apache CloudStack (mgmt server, MySQL, NFS, SSVM, cloudbr0) | Dropped | 2026-11-14 | KVM + Terraform libvirt, 3 isolated networks |
| MinIO (Terraform state, artifacts) | Dropped | 2026-11-12 | Local backend in `/var/lib/lab/tfstate` |
| Conftest / Rego plan gate, PR gate | Dropped | 2026-11-16 | check.yml (fmt, validate) |
| `src/pipeline` Python framework | Dropped | | Short workflows with ready-made actions |
| Vault Transit | Deferred to phase 8 (no longer mounted by code since `dfa3aa9`; the running Vault keeps transit/ until a fresh up) | 2026-11-16 | |
| Second app CA and its certs (app-root, backend-gw, frontend-client) | Removed; re-add in phase 8 if built | 2026-11-16 | `ca` only (`app-edge` kept, signed by `ca`) |
| Backups, restore, key-loss demo (phase 9) | Cut; discussion only | 2026-11-13 | B09.6 walkthrough |
| Host baseline and revert proof | Dropped (short-lived lab) | | destroy + fresh up (B08.5) |
| Packer images, pr.yml, deliver.yml, schedules.yml | Dropped | | Cloud image + cloud-init |
| TOML config loader | Dropped | | `config.py` per module |

---

## Cleanup log and what is left

Done 2026-11-16 evening: removed `src/cfssl/app-root-csr.json` with APP_ROOT, the backend-gw and
frontend-client certs and `profiles.client`; removed `STUDY-PLAN.md`, `docs/code-review.md`, the dead
first `ensure_node`, the unused `GITEA_URL` import, `hostname` in compute.tf, duplicate `.gitignore`
lines, `cloudstack.lab.test` (Corefile and gateway SANs), stale comments and strings; README rewritten;
PLAN-enterprise.md marked historical.

Left:

| Item | Fix |
|---|---|
| `state/pki/gateway*.pem` | Still has the old SANs (pki does not reissue on a SAN change). Delete both files before an `update` to reissue; Vault and Traefik restart once |
| `state/pki/{app-root,backend-gw,frontend-client}*` | Leftover local files, gitignored. Delete by hand, or they go with the next destroy |
| `docs/three-vpc-design.md` | Keep for B08.3/B08.4. Rename vpc-east/hub/west to site-a/site-hub/site-c, and lab_vpc to lab_vmfw |
| `docs/diagram/**` | Keep (review deliverable). Redraw the HLD for cloudbr1, site-*, wan and the pipeline. Fix addressing in request-flow and backend-k3s when preparing B09.5 |
| Optional | `bootstrap.sh` ensure_python: just check and die. Move `LAB_ADMIN` to its module config (`RUNNER_UID` removed 2026-11-18) |

---

## Known issues (one line each)

| Issue | Where | Fix when |
|---|---|---|
| Root runs `git add/commit`, so `.git/index` and objects become root-owned and the user's next commit fails | `gitea.commit_changes` | Done 2026-11-17 (B08.5) |
| `podman.down` wipes all rootful containers on the host | `podman.py` | Accept: the lab owns the host (README) |
| Any change to the netplan file (even a comment) runs `netplan apply`, which rebuilds `cloudbr1` and leaves the running VMs' `*-mgmt` taps detached (run #9). Workaround: `ip link set <vm>-mgmt master cloudbr1` | `network.up` | Implemented 2026-11-17, not yet run: `network.reattach_taps()` on every `network.up` (after `netplan apply` and on the early return) |
| Runner `VERSION` bump ignored (any existing binary is accepted) | `runner.ensure_binary` | Optional |
| cloud-init exit 2 with `status: done` passes `ready` | `roles/ready` | Accept: exit 2 means warnings; a failure prints `status: error` |
| `write_file` does not re-apply the mode when the content is unchanged | `system.py` | Accept |
| pki does not reissue a cert when its SANs change | `pki.py` | Delete the .pem by hand |
| `wait_for_run` assumes every push triggers deploy.yml. Do not add `paths-ignore` | `gitea.py` | |
| `podman.repo()` downloads the key on every run | `podman.py:18` | Optional |
| No default route raises an IndexError with an unclear message | `preflight.py:23` | Optional |
