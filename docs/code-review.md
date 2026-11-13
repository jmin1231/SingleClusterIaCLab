# SingleClusterIaCLab code review

Review of the working tree on 2026-11-13; the tree was changing during review, so recheck findings against later edits. The lab is under active construction; its enterprise plan records later decisions that supersede some individual steps. This review distinguishes defects in existing code from intentionally unfinished features. Line numbers refer to the reviewed working tree and can move as development continues.

The highest priorities are protecting existing host data during destroy, preserving Vault recovery material until data removal is confirmed, avoiding exposure of CloudStack database keys, and making interrupted setup recoverable. The current code is not an end-to-end implementation of the full architecture.

## Finding index

- **F1 — Destructive host cleanup.** `src/host/podman.py:35–42` resets all rootful Podman storage and removes `/var/lib/containers`, including unrelated workloads; `preflight` does not reject a host with such workloads. `ntp.down()` purges chrony and installs timesyncd without knowing the original state. Define and enforce a fresh-host contract or track ownership and restore the baseline before using destroy.
- **F2 — Vault recovery material can be lost.** `src/services/vault/vault.py:216–224` deletes the unseal key even when `podman.check()` is false and the Vault volume was not removed. A stopped socket is not proof that no volume exists. Confirm deletion before discarding the key. Initializing Vault before durably saving its response (`:60–66`) also leaves an unavoidable recovery window that needs an explicit operating procedure and backup.
- **F3 — CloudStack credentials exposed in process arguments.** `src/host/cloudstack.py` passes the database password and encryption keys to `cloudstack-setup-databases` in argv. Local process inspection can reveal them. Check what the installed upstream command supports for secret input; if it requires argv, document and reduce the exposure rather than implying that suppressing exceptions hides it.
- **F4 — Partial CloudStack setup can be mistaken for complete setup.** `databases()` checks schema names and a version row but does not validate Vault credentials against the installed configuration. A version row alone may not prove every setup step completed. `management()` now detects two lines in `limits.conf` before deciding whether setup ran; those lines can be present after a partially completed setup, so verify that they prove the entire setup succeeded. `down()` now starts installed MySQL before dropping databases, but ignores a failed management stop and treats a missing MySQL package as proof there are no databases to remove.
- **F5 — LAN bridge recovery is not independent of the running process.** `bridge()` now restores the previous file on caught failures, an improvement over the earlier review. A hard kill, host crash or connectivity loss that terminates the process before its handler runs can still leave the changed file in place; restoring the file can itself fail. The current DHCP-only refusal is deliberate and removes the earlier static-template issue. Validate recovery from a local console with an independent rollback mechanism if remote operation is required.
- **F6 — Changed files and runtime state can diverge.** `cloudstack.mysql()` and `nfs()` now remove their generated file on a caught restart/reload failure, allowing a retry. However, they delete an existing prior configuration instead of restoring it, and abrupt termination between write and reload still leaves the new file without its side effect. `ntp.up()` has the same write-then-restart retry problem. `network.up()` leaves its netplan file after a failed apply or readiness timeout.
- **F7 — Compose changes do not reliably converge.** Vault and Traefik use `--no-recreate` unless certificates changed. Image, port, environment or other Compose changes can be ignored on a normal rerun. Reconcile service definitions and verify the actual container configuration.
- **F8 — PKI checks accept incomplete material.** `src/lib/pki.py:23–25` checks only the root certificate, not its private key; leaf checks at `:37–42` do not validate matching key/certificate or group and mode. Detect inconsistent material and stop with a recovery instruction. One-year certificates with no automatic renewal are an explicit short-lived-lab decision, not an unplanned omission.
- **F9 — Partial AppRole files block recovery.** `vault.approle()` writes directly to the final filename and regards an existing file with the expected UID as complete. An interrupted write can leave a partial or empty file that makes future login fail. Write a validated temporary file and atomically install it. The one-year bootstrap secret ID and manual generate-root recovery are documented design choices.
- **F10 — File permissions do not converge.** `src/lib/system.py:54–61` returns without applying the requested mode when content is unchanged. An isolated temporary-file test left mode `0644` after requesting `0600`. Reconcile permissions even when bytes match; use atomic writes where interruption matters.
- **F11 — Unfinished command behavior.** `src/__main__.py` exposes `update` and `teardown` as successful no-ops. CloudStack `down()` is explicitly partial, but the top-level destroy reports complete restoration. Return an explicit failure for unimplemented operations and report cleanup accurately until complete.
- **F12 — DNS and network assumptions need validation.** `detect_network()` selects the first default route and the first address, assumes a gateway exists, and interprets the address's dynamic flag as the DHCP decision. Multiple routes/addresses or unusual host configuration can select the wrong LAN; validate inputs and fail clearly. `bridge_ready()` relies on an ICMP response, so a gateway that blocks ping can cause rollback despite working routing.

## Entry point and host files

### `bootstrap.sh`

Checks root and Python 3.12, installs the package if needed, changes to the repository and starts the Python package. A system where `python3.12` is installed but `python3` still points to an older interpreter fails the recheck. This shim otherwise has no provisioning logic. Installation and help behavior were not exercised as root.

### `src/__main__.py`

`cmd_up()` sequences preflight, network, time, Podman, DNS, PKI, Vault, gateway and CloudStack. `cmd_update()` and `cmd_teardown()` are placeholders (F11). `cmd_destroy()` composes cleanup in reverse, but inherits F1, F2 and F4. `parse_args()` handles the command list; `main()` initializes logging and obtains a nonblocking file lock. Logging creates the state directory before the lock is opened; a previous claim that a fresh clone necessarily fails due to the missing directory was incorrect. The lock coordinates this checkout, not separate checkouts pointing at the same host resources.

### `src/host/preflight.py`

`check_host()` verifies `/dev/kvm` access. `detect_network()` discovers the route and address (F12); `log_network()` reports them; `up()` calls both. Fresh-host cleanliness and resource requirements are not checked yet, which matters for destructive cleanup (F1).

### `src/host/network.py`

`vmnet_conflicts()` checks route overlap; `check()` checks the bridge address; `up()` installs the host-only bridge and waits; `down()` deletes its file and links. Apply failure and timeout leave the configuration installed (F6). `check()` establishes address presence, not DNS routing or all bridge properties.

### `src/host/ntp.py`

`up()` installs chrony, copies its config and starts or restarts the service. A restart failure after writing an unchanged file can be skipped on retry (F6). `down()` assumes timesyncd was the original service (F1).

### `src/host/podman.py`

`socket_ready()` checks enabled and active states; `check()` combines this with installed packages; `up()` installs and enables them. `down()` is host-wide and destructive (F1). `check()` being false does not mean containers or volumes are absent (F2).

### `src/host/cloudstack.py`

`repo()` fetches the repository key and installs source and pin; `check_version()` refuses a management package version other than the configured value. The separate agent package is not checked, and an already-installed wrong management version is refused rather than converged. The plan deliberately uses the vendor key without a fingerprint check; the trust model depends on HTTPS and the source host.

`mysql()` and `nfs()` install host configuration (F6). The NFS export deliberately permits the detected LAN subnet with `rw,no_root_squash`; clients on that subnet can act as root on the exported storage, and firewall protection is not yet implemented. `lan_card()` discovers the physical bridge member; `netplan_yaml()` renders DHCP configuration; `restore_netplan()`, `bridge_ready()` and `bridge()` implement application and rollback (F5, F12).

`cs_credentials()` creates Vault values once or reads them. `databases()` handles schema presence, version and creation (F3, F4). Its version query does not use `check=True`, so a query failure is reported as a missing version rather than exposing the database error. `mgmt_ready()` checks HTTP on the local client URL, which does not establish that the CloudStack API and downstream services work. `setup_done()` checks two limits lines, not every effect of setup; `management()` invokes setup or starts the unit and waits (F4); a plain `start` does not restore an enabled-on-boot state after `down()` disabled it. `down()` is an intentionally partial reset (F4, F11). `up()` orchestrates the above.

## Shared Python files

### `src/lib/config.py`

Centralizes paths, bridge addresses, Compose socket, certificate identities and Vault paths. Certificate hostnames and service addresses must be kept consistent with DNS and gateway configuration. Values such as the Vault container UID are assumptions to verify with the pinned image and runtime.

### `src/lib/log.py`

`ConsoleFormatter` formats severity; `FileFormatter` adds a timestamp; `setup_logging()` creates the state directory and handlers. If root logging already has handlers, it returns without configuring the lab file or ensuring the state directory exists. The normal CLI starts without such handlers, but embedding it in another process can differ.

### `src/lib/system.py`

`ip_json()` parses command output. `missing_packages()` and `apt_install()` install missing packages, not desired versions; `apt_purge()` removes names without tracking prior ownership. `systemctl_ok()` reduces status to a boolean, so callers must not infer that inactive means absent. `write_file()` and `install_file()` have F10 and non-atomic-write limitations. `compose()` invokes the pinned Compose executable through the Podman socket.

### `src/lib/pki.py`

`up()` creates two roots and service certificates using cfssl (F8); `down()` removes the PKI directory and purges cfssl without tracking whether it predated the lab. If a root certificate is lost, regenerating it changes trust; clients that trusted the old root need a separate trust update. No automatic renewal is a documented decision.

## Services and their configuration

### `src/services/coredns/dns.py`, `compose.yaml`, and `conf/Corefile`

`up()` supplies the discovered host IP to a host-networked CoreDNS container; `down()` removes it if Podman is considered ready. The Corefile answers the listed lab names and forwards other requests to the host resolver. The host-only netplan file supplies split-DNS settings; the previously reported claim that no split DNS is configured was incorrect. DNS reachability, forward-loop behavior and the dynamic host IP need live validation. Grafana and telemetry names will need records when those services are implemented.

### `src/services/traefik/traefik.py`, `compose.yaml`, `dynamic/tls.yml`, and `dynamic/gitea.yml`

`up()` and `down()` manage the HTTPS gateway and temporary `whoami` backend. The Gitea route pointing to whoami is an explicitly temporary phase, not an implemented Gitea service. Compose changes may not take effect (F7). The certificate is mounted from the PKI directory; verify TLS and name resolution on the target host.

### `src/services/vault/vault.py`

`api()` uses the lab CA and handles GET 404; `init()` initializes and stores the unseal key (F2). `mount()` creates missing engines but checks presence rather than their configuration. `unseal()` submits the key and waits for health; `ssh_key()` creates a key pair once; `policy()` uploads policy files; `enable_approle()` enables auth; `approle()` creates role credentials (F9); `login()` exchanges them for a token; `revoke_root()` revokes the initial root token. `up()` starts the container and configures Vault (F7, F9); `down()` has the key-deletion risk in F2.

### `src/services/vault/compose.yaml` and `vault.hcl`

The pinned Vault container exposes TLS only on the host-only address and uses a named Raft volume. Its health check intentionally treats sealed status as ready for initialization; this is not proof Vault is unsealed or usable. Storage ownership, TLS mounts and recovery need live testing.

### `src/services/vault/policies/lab-bootstrap.hcl` and `lab-pipeline.hcl`

Bootstrap policy has broad named administrative paths; pipeline policy excludes bootstrap secrets and allows the paths listed for jobs. These policies are the current phase's starting permissions, not a complete authorization review of future jobs. Test positive and negative access using real tokens when the runner exists.

## Templates and data files

- `src/host/files/60-lab-cloudbr1.yaml`: host-only bridge, dummy anchor and split DNS; must match `config.py` and `network.py`.
- `src/host/files/cloudbr0-dhcp.yaml.tmpl`: transfers DHCP and the NIC MAC to the LAN bridge. DHCP-only is now enforced; the deleted static template is an intentional working-tree deletion.
- `src/host/files/chrony-lab.conf`: binds time service to the host-only IP and permits the VM subnet; requires that address before chrony starts.
- `src/host/files/cloudstack-mysql.conf`: MySQL options and loopback bind; impacts the host MySQL instance, so prior configuration and rollback require care.
- `src/host/files/lab-cloudstack.list` and `lab-cloudstack.pref`: repository and version preference; the management version check does not validate every package.
- `src/cfssl/ca-csr.json` and `app-root-csr.json`: distinct CA identities and one-year lifetimes. `ca-config.json` defines one-year server and client profiles. These durations are deliberate for the planned short-lived lab.
- `.gitignore`: excludes runtime state, Terraform state, `.terraform` and builds; it does not by itself prevent secrets being committed elsewhere.
- Empty package markers: `src/__init__.py`, `src/host/__init__.py`, `src/lib/__init__.py`, `src/services/__init__.py`, and each of `src/services/coredns/__init__.py`, `src/services/traefik/__init__.py`, `src/services/vault/__init__.py` contain no executable behavior.

## Documentation and diagrams

- `PLAN-enterprise.md` is the architectural reference, but some older steps still describe static LAN, Vault PKI or MinIO state despite later DHCP, cfssl and local-state decisions. Check the dated decisions before implementing a step.
- `README.md` contains merge-conflict markers and obsolete commands and CA instructions. Resolve it against the current CLI and plan before using it as a runbook.
- `STUDY-PLAN.md` retains superseded Vault PKI, mesh CA and removed-step material; update exercises when those phases are taught.
- `docs/diagram/hld/overall-architecture.md` and `.drawio` describe target architecture, not evidence that services are deployed.
- `docs/diagram/lld/backend/backend-k3s.md` and `.drawio` differ in their treatment of node-agents and mesh membership; reconcile with the latest plan's separate node-exporter and audit-agent decisions.
- `docs/diagram/lld/traffic/request-flow.md` and `.drawio` describe the future request path; the Markdown still attributes mTLS certificates to Vault rather than the later cfssl decision. Verify both when implementing the application.

## Validation and next checks

The prior review parsed all Python sources and checked shell syntax and CLI help. The prior isolated netplan check concerned a static template that has since been removed; do not apply that result to the current DHCP-only design. The file-permission reproduction remains applicable. No live `up`, `destroy`, package changes, Vault initialization, network reconfiguration or CloudStack deployment was performed during this review.

On a disposable Ubuntu 24.04 host with console access, test a clean build and rerun; failure injection around MySQL/NFS reload, bridge apply and management setup; reboot and unseal; Vault recovery; and destroy followed by a baseline comparison. Verify API readiness, permissions and actual package/schema versions. Preserve a baseline and recovery access before testing destructive operations.
