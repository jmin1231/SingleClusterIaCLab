# Build Plan

A single-host infrastructure lab, built from nothing on a fresh Ubuntu 24.04 VM.

**This is the current plan.** [`build-order.md`](build-order.md) is the original
sixteen-phase syllabus; its per-step *Learning* notes are still the best
explanation of why each piece exists, but its **order is wrong now** and five
things in it were cut. Where the two disagree, this file wins.

Effort: **S** an evening · **M** a weekend · **L** split it.

---

## The one thing that changed, and why it matters

The original plan built trust **before** the secret store: an offline openssl root
CA, an intermediate, and a leaf for Vault — because Vault needs a certificate to
start and could not issue its own.

That is gone. **Vault is the CA** (decision 3.4-5), which means the dependency
runs the other way:

```
old:   openssl CA  ->  Vault  ->  everything else       3 CA certs, 2 chains
now:   Vault  ->  its own PKI  ->  everything else      1 CA cert, 1 chain
```

The circularity — Vault needs a certificate, Vault issues certificates — is
broken by **two passes**: a self-signed certificate brings the listener up, then
once the PKI exists Vault issues itself a real one and restarts. TLS is on from
the first start either way. Around 860 lines of openssl scripting disappear with
it, and so does the entire class of bug that motivated them: `openssl ca` exits 0
when it *refuses* a CSR.

Read that paragraph again before Phase 3. It is the part of this lab most worth
understanding, and the part the old document will actively mislead you on.

---

## What you need

| | Minimum |
|---|---|
| OS | Ubuntu 24.04 LTS, x86_64 |
| CPU | 12 cores, VT-x/AMD-V **enabled** |
| RAM | 16 GB — a hard ceiling, see `resource-budget.md` |
| Disk | 200 GB SSD |
| Virtualization | `/dev/kvm` present; **nested virt on** if this host is itself a VM |

The two that stop people first:

```sh
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
ls -l /dev/kvm                       # must exist
```

**Do not run `bootstrap.sh` from an IDE's integrated terminal.** VS Code's
AppArmor profile blocks MySQL's post-install script from signalling its own
temporary server, and the run stalls with a timeout three layers from the cause.
A plain terminal, a TTY, or ssh. See `failure-log.md`.

---

## The whole thing is one command

```sh
git clone <this repo> && cd SingleClusterIaCLab
make setup                  # required once per clone: enables the git hooks
sudo ./bootstrap.sh         # ~40 minutes, mostly CloudStack
```

Then `sudo SKIP_HOST_PREP=1 ./bootstrap.sh` re-runs just the service layer.

**That command is the syllabus.** Every phase below is one step inside it, in the
order it actually runs:

```
check_kvm                 Phase 0
install_cloudstack        Phase 1
install_coredns           Phase 2
install_vault             Phase 3   <- the CA lives here now
ensure_cloudstack_secret  Phase 3
install_gitea             Phase 4
install_proxy             Phase 4
setup_gitea_repo          Phase 5
install_toolbox           Phase 5
```

**How to work through it:** run `bootstrap.sh` once and let it finish. Then go
back and take each phase apart — read the script, run its *Done when*, break it
deliberately, run it again. Reading a working system beats watching a broken one
assemble itself, and every step is safe to re-run.

---

# Phase 0 · The host · `S`

**Read:** `bootstrap.sh`, top to `main()`. It is 300 lines and the only bash you
must understand before anything else.

`check_kvm` is verify-only and fatal — later phases boot real VMs, and finding out
then is expensive. `SKIP_HOST_PREP=1` skips the steps that **mutate** the host,
not everything before the services; `require_root` and `check_kvm` stay, because
neither prepares anything.

**Learn:** why a provisioner asserts before it acts. Why `set -euo pipefail` is
the first line of every script here.
**Done when:** `sudo ./bootstrap.sh` gets past `check_kvm` on your VM.

---

# Phase 1 · The cloud · `L` — split: install, then read back what it built

**Read:** `cloudstack/cloudstack-install-all.sh`. **Not**
`scripts/cloudstack-install.sh` — that is 2,704 lines of vendored upstream code,
excluded from lint and fmt so the diff against upstream stays readable.

Six steps, and three of them are interesting:

- **The resolver floor.** Before CloudStack rebuilds host networking, no link
  supplies DNS — so a global resolver is written first and retired by CoreDNS in
  Phase 2. A bootstrap dependency that exists only to be removed.
- **Seeding the apt repo.** The version is pinned to 4.21 because the installer's
  own default is broken upstream. It proves the repo yields an installable
  package *before* the 40-minute install, not during it.
- **`sshd -T`.** After writing the SSH drop-in it asserts on what sshd
  **concluded**, not on the file — a lower-numbered drop-in silently outranks
  yours, and nothing else can detect that.

**LAB ONLY:** this sets a root password and enables root + password SSH, because
CloudStack adds a KVM host over SSH even when that host is itself.

**Learn:** what a hypervisor and a control plane actually are. And the lesson in
`failure-log.md` — *a control plane reports its database, not reality.*
**Done when:** `https://<host>:8080/client` loads and a zone exists.

---

# Phase 2 · Names · `M`

**Read:** `docker/coredns/` — the installer, the Corefile, the zone template.

Three ideas:

- **Authoritative vs forwarding.** The Corefile has two blocks: `lab.test` served
  from a zone file, everything else forwarded upstream. Get the second wrong and
  the host resolves `web.lab.test` but not `github.com`.
- **`Domains=~lab.test`.** The `~` means *route this domain here and nothing
  else*. Without it you get a search suffix; without `Domains=` at all, CoreDNS
  becomes the resolver for everything and its correctness becomes all DNS.
- **Both protocols.** Docker publishes TCP by default. DNS is UDP, so a bare
  `53:53` looks completely dead — and TCP is still needed when a response
  exceeds 512 bytes.

Note the installer **deletes** the Phase 1 resolver floor rather than overriding
it: `DNS=` accumulates across drop-ins, so both would answer and `lab.test` would
fail intermittently.

**Learn:** why an address discovered at run time beats one written down.
**Done when:** `dig gitea.lab.test @<host>` answers, and `github.com` still
resolves.

---

# Phase 3 · Trust and secrets · `L` — split: Vault running, then the CA

**Read:** `docs/vault-lesson.md`. It is a seven-lesson walkthrough of this phase
written line by line, and this is the phase it exists for.

Then `docker/vault/vault-installer.sh` — 325 lines, from nothing to a running,
unsealed, configured Vault that issues its own certificate.

The four things to come away with:

- **Seal is not stop.** A restarted Vault is running, listening, and answering
  everything 503. `vault-unseal.sh` is separate because unsealing must work after
  a reboot, in a drill, with nothing else present.
- **`operator init` happens once, ever.** It mints the storage key, returns it
  exactly once, and it **cannot live in Vault**. `secrets/` is the one directory
  not mounted into the container.
- **The CA is one self-signed root inside Vault.** No file on disk holds its key.
- **A PKI role is server-side policy.** A caller asks for a name and a lifetime;
  the role decides. Compare a config file the client chooses to honour.

`ensure_cloudstack_secret` follows, and teaches the **three directions of a
secret**: captured (CloudStack already has a key), generated (Vault is the
origin), minted-once (the service will never show it again).

**Learn:** where trust comes from, and why it comes out of the secret store.
**Done when:** `vault status` says unsealed over HTTPS, `vault list pki/issuers`
returns exactly one, and `vault write pki/issue/lab-server
common_name=x.example.com` is **refused by the role**.

---

# Phase 4 · Serving it · `M`

**Read:** `docker/gitea/gitea-installer.sh`, then `docker/proxy/proxy-installer.sh`.

Gitea's credentials are **generated in Vault before Gitea exists** — Vault is
their origin, and nobody ever chooses them. Gitea publishes no ports at all; the
proxy is the only way in.

**The ordering here is the lesson, and it was a real bug.** The proxy must start
after Gitea (it joins Gitea's network and resolves the `gitea` container name at
startup) but before anything talks to Gitea's API (which is only reachable
through the proxy). That is a cycle, and `install_proxy` sits at the one point
that breaks it. See `failure-log.md` — it went unnoticed for months because the
proxy was always already running.

The proxy also refuses names it does not know: nginx promotes the first server
block to the default, so without an explicit one it answers for every name that
resolves to the host and presents the wrong certificate.

**Learn:** why one place holds certificates rather than every service.
**Done when:** `https://gitea.lab.test` loads with **no** `-k`, and an unknown
name fails to connect rather than serving the wrong site.

---

# Phase 5 · CI · `M`

**Read:** `docker/gitea/gitea-repo-setup.sh`, `docker/toolbox/`,
`.gitea/workflows/`.

The repo is pushed to Gitea and an API token is minted — the minted-once case
from Phase 3, where the guard is whether the stored token still *works*, because
there is nothing on the far side to compare against.

The toolbox is one image holding `terraform`, `ansible`, `kubectl` and `packer`,
every version pinned, nothing installed at job time. It is built here and never
published.

**The runner keeps the host Docker socket; jobs get a rootless dind instead.**
Read `decisions.md` 4.4-1 — this is the deviation the lab makes knowingly, and it
explains what a runner with the host socket would give away.

**Workflows live in `.gitea/workflows/` and nowhere else.** Gitea Actions reads
that path only; anywhere else and CI is silently dead.

**Learn:** why a pipeline that `apt-get`s its own tools is slower every run and
trusts whatever the network served that minute.
**Done when:** a push runs a job in the toolbox image, and a broken commit shows
red in Gitea.

> **Drill 5** — this is where `bootstrap.sh` finishes. Run it again, whole. Every
> step reports "already". That is the claim the whole lab rests on.

---

> **Phases 6–12 are not built yet.** Nothing below exists on any host; these are
> the plan, not a walkthrough. Their *Done when* lines get sharper as you reach
> them.

# Phase 6 · Images
### 6.1 A Packer build · `L` — split: any image first, then the customisation
### 6.2 Publish and register it · `M`
Serve it behind the **existing proxy** at `images.lab.test`, then register it as a
CloudStack template. Not Gitea's registry: `registerTemplate` pulls by URL, so a
private package means a credential in that URL, which lands in CloudStack's
database and logs.
### 6.3 Both builds in CI · `M`

# Phase 7 · Infrastructure as code
### 7.1 Provider, offerings, one tier, one VM · `M`
**Settle the state backend before the first `apply`.** Check whether this Gitea
has the Terraform state backend — 1.24.7 answered 404 on a first probe. If not:
upgrade, or stay on a local file and revisit at 7.4. Decide it here, in writing.
### 7.2 Three tiers with deny-by-default ACLs · `L` — split: networks, then rules
The thing CloudStack gives you that libvirt does not.
### 7.3 VMs, addresses, and DNS from Terraform outputs · `M`
### 7.4 Remote state, with locking proven · `M`
### 7.5 Terraform in CI, with drift detection · `M`

# Phase 8 · Configuration management
### 8.1 Ansible, dynamic inventory from Terraform · `M`
### 8.2 A base role — users, resolver, your CA, time · `M`
### 8.3 Ansible in CI · `S`

# Phase 9 · Kubernetes
### 9.1 k3s, single node, with Cilium · `M`
`--flannel-backend=none --disable-network-policy`, then Cilium. Decided here
because a CNI cannot be swapped without rebuilding. See 9.1-1.
### 9.2 Deploy something, reach it through Gateway API · `M`
### 9.3 cert-manager, issuing from Vault · `M`
### 9.4 Registry trust · `S`
### 9.5 Segment the cluster, deny by default · `M`
NetworkPolicy is **allow-only and additive** — the opposite of how a VPC ACL
reads. Egress deny breaks DNS first.

# Phase 10 · GitOps and the application
### 10.1 Flux, pointed at Gitea · `M`
### 10.2 Base and overlays · `M`
### 10.3 Vault Kubernetes auth and External Secrets · `M`
### 10.4 Postgres, an API, a web tier · `L`
### 10.5 Break something by hand, watch it heal · `S`

# Phase 11 · Seeing it
### 11.1 kube-prometheus-stack · `M`
### 11.2 Loki on the host, Alloy everywhere · `L`
Loki runs on the **host**, not the cluster — so the logs survive the cluster
dying. Grafana does not, which is the trade. See L-7.
### 11.3 One alert that arrives · `S`

# Phase 12 · Operations
### 12.1 Back up everything stateful · `M`
Gitea's Postgres and data, Vault's storage **and unseal key**, Terraform state,
CloudStack's database. Decide the destination first — a copy on the host you are
backing up is not a backup.
### 12.2 Restore, for real · `M`
### 12.3 Rebuild from zero · `L`
### 12.4 Failure injection · `M`

---

## Not in this plan

Named so they are choices, not omissions — see S-1: identity and SSO, Kyverno
admission policies, image signature verification, MinIO, the offline root CA,
multi-node k3s as a default, and WireGuard between tiers.

## If a step is too big

Say which one and it gets split. That is a plan defect, not a you defect.
