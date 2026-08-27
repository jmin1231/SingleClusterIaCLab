# SingleClusterIaCLab

A single-host infrastructure lab, built from scratch as a learning exercise: a
private cloud on one Ubuntu host, three network tiers inside it, and a real
application deployed end to end.

Built by following [`docs/build-order.md`](docs/build-order.md) — a sixteen-phase
syllabus that puts names, trust and policy in place *before* the services that
depend on them, so nothing has to be retrofitted.

## Status

**Phase 2 — names and trust.** CoreDNS is running on the bridge (2.1). The root
and intermediate CAs are written, and whether they have been *generated* is a
per-machine fact — see "Working on more than one machine" below. `ca/root/` and
`ca/intermediate/` are gitignored, so a clone shows nothing either way; check
the host rather than the repo.

Work in flight, with every decision written up in
[`docs/decisions.md`](docs/decisions.md) and each numbered `TODO` pointing at the
entry that settles it:

| File | State | Next |
|---|---|---|
| `ca/scripts/issue-leaf.sh` | key, CSR and signing written; 17 TODOs | `verify_leaf`, then `check_existing` last |
| `bootstrap.sh` | working; logging complete (L-1, L-2) | run it on the target VM — never tested outside harnesses |

Blocking everything in `ca/` on a machine that has not done it: run
`sudo ./ca/ca-install-all.sh` once. It is a no-op if the CA is already there. It
creates the root and the intermediate, and — less obviously — the `index.txt` and
`newcerts/` that `openssl ca` needs before a leaf can be signed at all.

**The CA issues one certificate, for Vault** (3.4-1). Vault's PKI engine becomes
the issuing CA at 3.4, and since 3.4 lands before Gitea, MinIO and Grafana, every
other certificate in the lab comes from Vault. The reverse proxy of 2.5 moves
after 3.4 for the same reason. `issue-leaf.sh` is a bootstrap step, not a
general-purpose issuer.

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
docs/           build-order.md (the syllabus), decisions.md, failure-log.md
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
