# SingleClusterIaCLab

A single-host infrastructure lab, built from scratch as a learning exercise: a
private cloud on one Ubuntu host, three network tiers inside it, and a real
application deployed end to end.

Built by following [`docs/build-plan.md`](docs/build-plan.md).
[`docs/build-order.md`](docs/build-order.md) is the original sixteen-phase
syllabus — superseded as the plan, kept for its per-step explanations.

## Status

**Phases 0–5 are built.** CloudStack with `Zone1` and its system VMs, CoreDNS
answering for `lab.test`, a two-tier CA, Vault initialised with its PKI engine,
Gitea with a registered runner and CI history, MinIO, and the reverse proxy
terminating TLS for all of it.

**Next is Phase 1 of the current plan — refactoring what exists.** Five things
were cut (decision S-1) and three designs changed (L-7, 9.1-1), so the first work
is applying those to a running lab rather than building anything new:

| | |
|---|---|
| Vault's PKI becomes the root | the offline openssl root and intermediate go; certificates stay |
| Gitea takes state and images | MinIO's two jobs, minus the one it did better |
| The proxy serves templates | `images.lab.test` — CloudStack registers by URL, and a private Gitea package needs a credential in that URL |
| MinIO is deleted | after the two above prove out |

Nothing from Phase 6 onward exists yet: no Packer, Terraform, Ansible, k3s or
Flux.

**The service containers are stopped.** Only CloudStack runs under systemd.
`sudo SKIP_HOST_PREP=1 ./bootstrap.sh` brings the rest back — from a terminal
**outside VS Code**, whose AppArmor profile blocks MySQL's postinst from signalling
its own temporary server. That one cost an hour; see `docs/failure-log.md`.

### Working on more than one machine

The CA does not travel. Keys are gitignored and the passphrases live in `/root`
(2.3-5), so running `ca-install-all.sh` on a second machine mints a **different**
root, and certificates issued under one will not validate against the other.
That is the intended behaviour, not a gap — but it means a second machine is for
writing code and docs, and certificates are issued where they will be used.

## Getting started

```sh
git clone <this repo> && cd SingleClusterIaCLab
make setup
```

`make setup` is **required on every clone**. It enables the git hooks by setting
`core.hooksPath`, which git cannot carry inside a commit. Skip it and the
pre-commit hook sits there doing nothing, silently.

```sh
make            # list the available targets
make lint       # check formatting and syntax — never writes
make fmt        # rewrite files into canonical format
```

## Requirements

| | Minimum |
|---|---|
| OS | Ubuntu 24.04 LTS, x86_64 |
| CPU | 12 cores, VT-x/AMD-V enabled |
| RAM | **16 GB — a hard ceiling** |
| Disk | 200 GB, SSD — the floor, with no margin |
| Virtualization | `/dev/kvm` present; nested virt on if this host is a VM |

Check the two that stop people first:

```sh
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
ls -l /dev/kvm                       # must exist
```

## Layout

Organised by tool. Directories appear as the phase that creates them is reached.

```
bootstrap.sh    bare Ubuntu to a running lab, in one command
ca/             the two-tier CA — removed at 1.3 of the current plan
lib/            common.sh and vault.sh, sourced by every installer
cloudstack/     the vendored all-in-one installer and its wrappers
docker/         one directory per service: coredns, vault, gitea, proxy,
                minio (removed at 1.6), toolbox
workflows/      CI, mirrored into Gitea
docs/           build-plan.md (current), build-order.md (reference),
                decisions.md, failure-log.md, network-plan.md,
                resource-budget.md
.githooks/      versioned git hooks; enabled by `make setup`
```

## Conventions

- **`lint` never writes; `fmt` does.** The pre-commit hook only ever calls `lint`,
  so it cannot modify a file and make the second run differ from the first.
- **Missing tools warn locally, fail in CI.** `STRICT=1` turns a skipped linter
  into an error; CI sets it.
- **No suppression without a reason.** Every entry in `.trivyignore` and
  `.shellcheckrc` carries a comment explaining itself.
- **Decisions are written down.** See [`docs/decisions.md`](docs/decisions.md) —
  what was chosen, what was rejected, and why.
- **So are failures.** See [`docs/failure-log.md`](docs/failure-log.md) — what
  broke, what it actually was, and where the search should have started.
