# SingleClusterIaCLab

A single-host infrastructure lab, built from scratch as a learning exercise: a
private cloud on one Ubuntu host, three network tiers inside it, and a real
application deployed end to end.

Built by following [`docs/build-plan.md`](docs/build-plan.md).
[`docs/build-order.md`](docs/build-order.md) is the original sixteen-phase
syllabus — superseded as the plan, kept for its per-step explanations.

## Status

**This lab is being rebuilt from nothing, by hand.**

A complete working version sits in [`reference/`](reference/) — CloudStack,
CoreDNS, a self-signed CA inside Vault, Gitea with a runner, a reverse proxy, and
a CI toolbox, all from one `bootstrap.sh`. **Nothing in it runs**; its containers
are stopped and the root does not depend on it.

Follow [`docs/build-plan.md`](docs/build-plan.md). It gives you what each piece
has to do, the decisions inside it, and the traps — not the code. Attempt a step,
get its *Done when* passing, **then** open the reference. A file you can open is
a file you will copy, so if the temptation is strong, read it from history
instead:

```sh
git show 91b02cf:bootstrap.sh
```

Phases 7–13 — Packer, Terraform, Ansible, Kubernetes, GitOps, observability,
operations — exist in **no** version of this lab. There is nothing to check
against there.

### What changed from the original design

Five things were cut (decision `S-1`) and the build order itself inverted:

| | |
|---|---|
| **Vault is the CA** | one self-signed root inside Vault, issuing leaves directly. The offline openssl root, the intermediate and ~860 lines went with it (`3.4-5`) |
| **Trust comes after Vault** | it used to come before, because Vault needed a certificate. A self-signed bootstrap certificate breaks that circularity |
| No MinIO | Gitea's registries and a proxy vhost cover what it was provisioned for |
| No shared library | 26 scripts became 11, each standing alone |
| Loki on the host | not in the cluster, so logs survive the cluster dying (`L-7`) |
| Cilium, not flannel | flannel enforces NetworkPolicy correctly and shows you nothing (`9.1-1`) |

[`docs/build-order.md`](docs/build-order.md) is the original syllabus. Its
per-step explanations are still the best in the repo, but **its order is wrong
now** — it builds the CA before Vault.

### Working on more than one machine

The CA does not travel. It lives inside Vault, whose storage is gitignored and
whose unseal key is a single file on this host, so bringing the lab up on a second
machine mints a **different** CA — and certificates issued under one will not
validate against the other. That is intended, not a gap: a second machine is for
writing code and docs, and certificates are issued where they will be used.

## Running the reference build

Everything below builds the version at `91b02cf`, not the one you are writing.
Useful for standing the finished lab up on a VM to compare against — and the
prerequisites, the laptop-side DNS and the CA import apply to your rebuild too.

### 1 · Before you create the VM

Nested virtualization, per the check above. It is set on the hypervisor and
**cannot be fixed from inside the guest** — get it wrong and you rebuild the VM.

Size it to the table in [Requirements](#requirements). 16 GB is a ceiling the
whole lab is budgeted against, not a suggestion; `docs/resource-budget.md` shows
where every megabyte goes.

### 2 · On the fresh VM

A minimal Ubuntu image has neither `git` nor `make`, and `bootstrap.sh` cannot
install them because you need them to fetch and run it:

```sh
sudo apt update && sudo apt install -y git make
git clone https://github.com/jmin1231/SingleClusterIaCLab.git
cd SingleClusterIaCLab
make setup
```

`bootstrap.sh` installs everything else it needs — `curl`, `jq`, `gnupg`,
`openssl`, `gettext-base`, Docker.

### 3 · Decide two things before you run it

```sh
sudo ROOT_PASSWORD='something-you-choose' ./bootstrap.sh
```

**`ROOT_PASSWORD` defaults to `password`,** and Phase 1 uses it to set the root
password *and enable root login with a password over SSH* — because CloudStack
adds a KVM host over SSH even when that host is itself. On a home network behind
NAT that is a lab convenience. On anything reachable it is a hole. Set it.

Other tunables, all with working defaults:

| | |
|---|---|
| `SKIP_HOST_PREP=1` | re-run only the service layer; skips clock, packages and Docker |
| `CS_REPO_VERSION` | CloudStack apt component, default `4.21` — its own default, 4.22, is broken upstream |
| `GITEA_ADMIN_USER` / `GITEA_ADMIN_EMAIL` | default `labadmin` / `labadmin@lab.test` |
| `CHECK_BRIDGE_NETFILTER=false` | skip the bridge check, for runs not using local KVM bridges |

### 4 · Run it

**From a plain terminal — not an IDE's.** Roughly 40 minutes, and most of that is
one step:

```sh
sudo ./bootstrap.sh
```

It is safe to re-run. If it stops, fix what it named and run it again; every step
before the failure is a no-op the second time.

### 5 · Check it worked

```sh
sudo docker ps                      # coredns vault proxy gitea gitea-db gitea-dind gitea-runner
dig gitea.lab.test @$(hostname -I | awk '{print $1}')
curl https://gitea.lab.test         # 200, with NO -k
sudo docker exec vault vault status # Sealed: false
```

The `curl` is the real test: no `-k` means DNS, the CA, the trust store and the
proxy are all correct at once.

### 6 · Reach it from your laptop

The lab answers to `*.lab.test`, which only its own CoreDNS knows and only its own
CA vouches for. Two steps on the machine you browse from.

**Point `lab.test` at the VM.** On macOS or Linux with systemd-resolved:

```sh
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=<vm-ip>\nDomains=~lab.test\n' \
  | sudo tee /etc/systemd/resolved.conf.d/10-lab.conf
sudo systemctl restart systemd-resolved
```

The `~` matters: it routes **only** `lab.test` to the lab and leaves the rest of
your DNS alone. Without it you have made a lab VM the resolver for your whole
machine.

The cruder alternative is `/etc/hosts` entries per name — fine for two names, and
it stops working the moment Terraform starts generating them.

**Trust the lab's CA**, or every page is a warning you click through:

```sh
scp <you>@<vm-ip>:~/SingleClusterIaCLab/docker/vault/certs/ca.crt lab-ca.crt
# Linux
sudo cp lab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain lab-ca.crt
```

Firefox keeps its own store and ignores the system one — import it under
*Settings → Privacy & Security → Certificates*.

**This CA is unique to that VM.** Building the lab twice mints two different CAs,
and certificates from one will not validate against the other.

### 7 · When it fails

[`docs/failure-log.md`](docs/failure-log.md) has the ones that already cost
someone an hour, with the diagnosis path rather than just the fix. The two most
likely on a first build:

- **A stall during MySQL setup** — you are running from an IDE terminal.
- **`exit 1` at the end of a successful CloudStack install** — no usable `TERM`.
  Its `cleanup()` calls `clear` under `set -e`.

## Requirements

| | Minimum |
|---|---|
| OS | Ubuntu 24.04 LTS, x86_64 |
| CPU | 12 cores, VT-x/AMD-V enabled |
| RAM | **16 GB — a hard ceiling** |
| Disk | 200 GB, SSD — the floor, with no margin |
| Virtualization | `/dev/kvm` present. **If this host is a VM, nested virtualization must be on** — set on the hypervisor, not fixable from inside |

Check the two that stop people first:

```sh
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
ls -l /dev/kvm                       # must exist
```

## Layout

```
docs/           build-plan.md — follow this. Plus decisions.md,
                failure-log.md, network-plan.md, resource-budget.md,
                vault-lesson.md
reference/      the finished lab, stopped. Read it AFTER you attempt a step
<everything else you write goes here>
```

The root is empty on purpose. Phase 0 puts one thing in it — a `.gitignore` —
and Phase 1 the first script. There is deliberately no build tooling: no
Makefile, no linter, no hooks. `reference/` has all three if you ever want them,
and `decisions.md` 0.2-x records why the previous build thought they earned their
keep.

## Conventions

- **Everything is idempotent.** Running an installer twice must not break
  anything, and the second run should say so rather than silently redoing work.
- **Discovered, never declared.** An address that differs per host is asked for
  at run time. An interface name in a constant is a per-host fact wearing a
  constant's clothing.
- **Decisions are written down.** See [`docs/decisions.md`](docs/decisions.md) —
  what was chosen, what was rejected, and why.
- **So are failures.** See [`docs/failure-log.md`](docs/failure-log.md) — what
  broke, what it actually was, and where the search should have started.
