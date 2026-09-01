# SingleClusterIaCLab

A single-host infrastructure lab, built from scratch to be understood.

One Ubuntu machine becomes a small private estate: containers behind a reverse
proxy, its own DNS and certificate authority, a secret store, a git server with
CI, VMs provisioned by Terraform, a Kubernetes cluster reconciled by GitOps, and
an application running on top of all of it.

**Written in Python**, with one bash file: `bootstrap.sh` provisions the host up
to the point Python can run, because Ubuntu will not let Python install itself.
Everything past that is Python.

## Start here

[`docs/build-plan.md`](docs/build-plan.md) — thirteen phases, ~50 steps, each an
evening or a weekend. It is a syllabus, not a runbook: every step says what to
build, what it teaches, and a *Done when* you can actually run.

The plan is built on one idea: **make something work, feel what is missing, then
fix that.** DNS arrives after you have typed too many addresses. A certificate
authority arrives after a browser has refused your site. Each foundation shows up
after the problem it solves, so you already know what it is for.

## Getting started

```sh
git clone <this repo> && cd SingleClusterIaCLab
sudo ./bootstrap.sh          # installs python3-venv, builds .venv, installs deps
python -m lab --version
```

## What the machine needs

| | Minimum |
|---|---|
| OS | Ubuntu 24.04 LTS, x86_64 |
| CPU | 8 cores with VT-x/AMD-V **enabled** |
| RAM | 16 GB |
| Disk | 200 GB SSD |
| Virtualization | `/dev/kvm` present; nested virt on if this host is itself a VM |

The two that stop people first:

```sh
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
ls -l /dev/kvm                       # must exist
```

## The other documents

| | |
|---|---|
| [`docs/decisions.md`](docs/decisions.md) | What was chosen, what was rejected, why |
| [`docs/network-plan.md`](docs/network-plan.md) | Every address range, decided before anything claims one |
| [`docs/resource-budget.md`](docs/resource-budget.md) | What runs in 16 GB |
| [`docs/failure-log.md`](docs/failure-log.md) | What broke, and where the search should have started |

## Conventions

- **Everything is idempotent.** Running an installer twice must not break
  anything, and the second run should say so.
- **`lint` never writes; `fmt` does.** The pre-commit hook only ever calls `lint`.
- **A comment explains what the code cannot.** If it restates the line below it,
  delete it.
- **Decisions are written down** — briefly. Four paragraphs usually means two
  decisions.

## History

An earlier build of this lab used CloudStack, MinIO and bash throughout, and
followed a sixteen-phase plan that ended in SSO and chaos drills. It worked as far
as it went. It is in git history, along with its 3,148-line decision log, if you
ever want to see how something was wired up.
