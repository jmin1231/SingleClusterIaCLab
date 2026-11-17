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
   2 network.up     vmnet_conflicts, system.install_file(netplan), netplan apply, check
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
  13 runner.up      ensure_user, ensure_binary, ensure_config, vault.login,
                    ensure_ssh_key, ensure_registered, ensure_service

Pipeline (Gitea Actions, runs-on: host, user lab-runner)
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
| kvm before runner | `ensure_user` runs `usermod -aG libvirt lab-runner`; the group exists only after libvirt is installed |
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

`config.py` holds: paths (BASE_DIR, STATE_DIR, LAB_DIR, SERVICES_DIR), the bridge (BRIDGE, VMNET), apt and Compose (APT_ENV, COMPOSE = `/usr/libexec/docker/cli-plugins/docker-compose`, DOCKER_HOST), PKI (CFSSL_DIR, PKI_DIR, LAB_CA, LAB_CA_CERT, CERTS), Vault (VAULT_PORT, VAULT_ADDR, VAULT_INIT_FILE, VAULT_POLICY_DIR, VAULT_APPROLE_FILE), LAB_ADMIN (used only by gitea.py) and RUNNER_UID (used only by the runner config).

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
| `up() -> None` | compose up --wait, then the seeding above | platform_up / compose, vault.login | container gitea |
| `down() -> None` | `compose gitea down --volumes` | platform_down / podman.check, compose | |

Acceptance: `lab/lab` exists, and its Actions secrets list both VAULT_* names. Status: Verified.

### B04.2 Host runner
Files: `src/services/gitea/runner/{runner.py,config/config.py,files/config.yaml,files/lab-runner.service}`

| Function | Purpose | Called by / calls | Touches |
|---|---|---|---|
| `ensure_user() -> None` | User lab-runner (uid 1990) in group libvirt | up | `/var/lib/lab/runner` |
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

## B08 Next (in this order)

### B08.1 Squid egress proxy (Next)
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

### B08.2 Base role (Next)
Proposed files: `ansible/roles/base/{tasks/main.yml,handlers/main.yml,templates/timesyncd-lab.conf.j2}`, `ansible/group_vars/all.yml`

| Task | Does | Uses |
|---|---|---|
| apt proxy | `/etc/apt/apt.conf.d/90lab-proxy`: `Acquire::http::Proxy "http://proxy.lab.test:3128";` | B08.1 |
| NTP | `/etc/systemd/timesyncd.conf.d/lab.conf` with `NTP=10.250.0.1`, handler restarts systemd-timesyncd | B02.3 chrony |
| DNS check | `resolvectl query gitea.lab.test` must succeed (DNS is already set by cloud-init network-config) | B03.1 |
| packages | `apt` with `base_packages` from group_vars (nftables, wireguard-tools) | proxy |

`site.yml`: change `hosts: all` roles to `[ready, base]`.
Acceptance: `timedatectl timesync-status` shows server 10.250.0.1, and `apt-get update` works on all three VMs.

### B08.3 VM firewall inside the guests (Next, plan item 6.1b)
Proposed files: `ansible/roles/base/tasks/firewall.yml`, `ansible/roles/base/templates/nftables.conf.j2`,
`ansible/group_vars/{frontend,hub,backend}.yml`

| Item | Does |
|---|---|
| `nftables.conf.j2` | `table inet lab_guest`: input policy drop. Allow lo, established, ssh on eth2 from 10.250.0.1, and `fw_allow` entries from group_vars. Forward policy drop (the hub opens one path in B08.4) |
| group_vars | frontend: tcp 443 on eth1. hub: udp 51820 and 51821 on eth1. backend: wg ingress to 8000 only |
| tasks | Template to `/etc/nftables.conf`, validate with `nft -c -f %s`, enable nftables, handler `systemctl reload nftables` |

Acceptance: from the host, `nc -zv 10.250.0.112 22` works, while any port not in `fw_allow` times out.

### B08.4 One data-driven wireguard role (Next)
Create `ansible/roles/wireguard/` (an empty local directory is not tracked by git). Source for addressing and routing:
docs/three-vpc-design.md section 5.

Proposed files: `ansible/roles/wireguard/{tasks/main.yml,handlers/main.yml,templates/wg.conf.j2}`, `ansible/group_vars/all.yml` (`wg_links`)

| Item | Does | Connects to |
|---|---|---|
| `inventory.tf` | Add `vpc_ip` and `wan_ip` to `ansible_host.variables` | B06 locals.vms |
| `wg_links` data | `[{spoke: fe-1, iface: wg0, port: 51820, hub_addr: 10.99.0.1/24, spoke_addr: 10.99.0.2/24}, {spoke: be-1, iface: wg1, port: 51821, hub_addr: 10.99.1.1/24, spoke_addr: 10.99.1.2/24}]`, hub tun-1 | ports must match nftables-vmfw.nft; peers' AllowedIPs include the other end's /32 |
| key task | `wg genkey` into `/etc/wireguard/<iface>.key` (0600, `creates:`), `wg pubkey`, then set_fact `wg_pub` | |
| template | Hub: one `[Interface]` per link with ListenPort = port, peer AllowedIPs = spoke vpc subnet. Spoke: Endpoint = `hostvars['tun-1'].wan_ip:port`, AllowedIPs = the other site's subnet | hostvars, no Vault needed |
| hub forward | sysctl `net.ipv4.ip_forward=1`. Guest nft forward allows only 10.1.1.10 to 10.3.1.10 tcp 8000 | B08.3 |
| service | `wg-quick@<iface>` enabled, restarted by a handler | |
| site.yml | Add a play `hosts: hub:frontend:backend` with roles `[wireguard]` | |

Acceptance: `wg show` on tun-1 shows two recent handshakes, and from fe-1 `nc -zv 10.3.1.10 8000` reaches be-1 (any listener). be-1 cannot reach fe-1's vpc address.

### B08.5 Teardown, destroy, and a fresh up from zero (Next, blocking the rehearsal)
Done 2026-11-16 evening (Implemented, not yet run): `kvm.remove_lab_vms` before the libvirt purge,
`rmtree(/var/lib/lab)` in cmd_destroy (pool, tfstate, runner home, Vault files), `start_run` for up,
`vault.down` guard, `cmd_teardown` exits 1.

| Still to do | File | Connects to |
|---|---|---|
| Root-owned `.git` after commit_changes: Implemented 2026-11-17, not yet run (`git()` runs as SUDO_UID:SUDO_GID; `bootstrap.sh` refuses to start without SUDO_UID) | `gitea.py`, `bootstrap.sh` | `.git` stays the user's |
| Optional `teardown` (VMs only, keep the platform): `teardown.yml` with `workflow_dispatch`, TMPDIR, `terraform init` + `destroy -auto-approve`; `dispatch(creds, workflow=GITEA_WORKFLOW)`; `cmd_teardown` = `follow_run(creds, dispatch(creds, "teardown.yml"))` | `.gitea/workflows/teardown.yml`, `gitea.py`, `src/__main__.py` | runner, tfstate |
| The rehearsal itself | | |

Acceptance: `sudo ./bootstrap.sh destroy`, then `virsh list --all` (libvirt is gone), `ls /var/lib/lab` (missing), and `nft list tables` (no lab tables). Then `sudo ./bootstrap.sh up` ends with a green run.

Already proven from zero (2026-11-14, older code, `state/bootstrap.log`): destroy then platform_up through Vault init, AppRole creation, Gitea admin, org and repo. Never proven from zero: kvm, vmfw, toolchain, runner, the initial push, and the first pipeline run creating the VMs.

---

## B09 Later

| ID | Step | Proposed files / functions | Connects to | Status |
|---|---|---|---|---|
| B09.1 | Consoles | `src/host/trust.py` `up()/down()`: copy `state/pki/ca.pem` to `/usr/local/share/ca-certificates/lab.crt`, `update-ca-certificates`, Firefox `policies.json` (Certificates.Install). Called after `pki.up` | Gitea UI, Vault UI, `virsh console` | Planned |
| B09.2 | Host SSH hardening | `src/host/sshd.py` + `files/sshd-lab.conf` drop-in (no passwords, no root), validate with `sshd -t`, reload | platform_up after network | Planned |
| B09.3 | Host firewall | `files/nftables-host.nft` table `inet lab_host` (input drop. Allow lo, established, LAN ssh; cloudbr1 to 53, 123, 443, 3128, 8200; LAN to host_ip 53 if LAN clients should resolve app.lab.test, since CoreDNS binds HOST_IP too), loaded by `vmfw.up` or `hostfw.py` next to it | must not break the LAN :443 DNAT | Planned |
| B09.4 | Monitoring | `src/services/monitoring/compose.yaml` (prometheus, node-exporter, grafana) behind Traefik. Add grafana/prometheus SANs and Corefile names back | traefik, pki | Planned |
| B09.5 | k3s / Istio / DB / app | Design-only for the review: docs/diagram/lld/backend, request-flow. Would need Transit mount, a second CA, and roles on be-1 | k3s.lab.test record exists | Deferred |
| B09.6 | DR | Walkthrough only (unseal key loss, tfstate loss) | vault-init.json, tfstate | Deferred |

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
| Optional | `bootstrap.sh` ensure_python: just check and die. Move `RUNNER_UID` and `LAB_ADMIN` to their module configs |

---

## Known issues (one line each)

| Issue | Where | Fix when |
|---|---|---|
| Root runs `git add/commit`, so `.git/index` and objects become root-owned and the user's next commit fails | `gitea.commit_changes` | Implemented 2026-11-17 (B08.5), not yet run |
| `podman.down` wipes all rootful containers on the host | `podman.py` | Accept: the lab owns the host (README) |
| Any change to the netplan file (even a comment) runs `netplan apply`, which rebuilds `cloudbr1` and leaves the running VMs' `*-mgmt` taps detached (run #9). Workaround: `ip link set <vm>-mgmt master cloudbr1` | `network.up` | Next: reattach `*-mgmt` taps after `netplan apply` |
| Runner `VERSION` bump ignored (any existing binary is accepted) | `runner.ensure_binary` | Optional |
| cloud-init exit 2 with `status: done` passes `ready` | `roles/ready` | Accept: exit 2 means warnings; a failure prints `status: error` |
| `write_file` does not re-apply the mode when the content is unchanged | `system.py` | Accept |
| pki does not reissue a cert when its SANs change | `pki.py` | Delete the .pem by hand |
| `wait_for_run` assumes every push triggers deploy.yml. Do not add `paths-ignore` | `gitea.py` | |
| `podman.repo()` downloads the key on every run | `podman.py:18` | Optional |
| No default route raises an IndexError with an unclear message | `preflight.py:23` | Optional |
