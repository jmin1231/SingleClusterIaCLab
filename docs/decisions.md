# Decisions

Append-only. Each entry: what was decided, what was rejected, and why. Six weeks
from now the *why* is the only part that still matters.

Format: newest at the bottom, so the file reads as a history.

---

## 0.2-1 · Repository layout is organised by tool

**Decided:** top-level directories per tool — `host/`, `docker/`, `packer/`,
`terraform/`, `ansible/`, `clusters/`, `app/`, `tests/`.

**Rejected:** organising by environment (`environments/dev/{terraform,ansible}`),
which makes promotion obvious but fragments each tool's config and fights
Terraform's module conventions.

**Why:** matches the reference lab, so its structure is directly readable while
learning. Accepted cost: one environment's definition is spread across
`terraform/`, `ansible/` and `clusters/overlays/`. Revisit at Phase 10.2 when
dev/prod overlays make the cost concrete.

---

## 0.2-2 · Bash everywhere — scripts, hooks, and Makefile recipes

**Decided:** bash is the shell dialect for this repo. `Makefile` sets
`SHELL := /bin/bash`; every script and hook uses `#!/usr/bin/env bash`.

**Rejected:** POSIX `sh` everywhere. More portable and more disciplined, but it
buys portability this repo does not need — it targets Ubuntu 24.04 on one host,
not arbitrary systems.

**Why it matters:** `/bin/sh` on Ubuntu is *dash*, not a smaller bash. It has no
`pipefail`, no `[[ ]]`, no arrays, and a narrower `local`. Mixed dialects mean a
recipe that works when pasted into a terminal fails inside make with no useful
error — a genuinely expensive class of bug to diagnose.

The repo was already half-committed to bash before this was settled: the
pre-commit hook used `set -euo pipefail`, and `.shellcheckrc` disables SC2199, a
bash array idiom. Making it explicit removed the split rather than creating one.

**Enforced, not just documented:** `.shellcheckrc` sets `shell=bash`, so
shellcheck applies bash rules even to files whose shebang it cannot determine.
A decision written only in prose is a decision that drifts.

---

## 0.2-3 · pre-commit lints the working tree, not the staged content

**Decided:** `make lint` reads `git ls-files --cached --others --exclude-standard`
— everything in the working tree that git does not ignore.

**Rejected:** linting the staged content only, via `git stash --keep-index` or a
temporary checkout of the index. Correct, but a stash accident inside a hook can
destroy uncommitted work.

**Why:** simple and catches essentially everything in practice. Two known gaps,
accepted deliberately:

- *False block* — an unstaged broken file refuses a commit that did not include it.
- *False pass* — a broken file staged, then fixed in the working tree without
  re-staging, lints clean while the broken version is committed.

The second is closed in CI at Phase 4.5, which runs against what was actually
pushed and cannot be bypassed with `--no-verify`.

---

## 0.2-4 · A missing linter warns; a missing `make` warns

**Decided:** absent tooling degrades gracefully. `make lint` skips a linter that
is not installed and prints `skip: <tool> not installed`. The pre-commit hook
does the same for `make` itself, then exits 0.

**Rejected:** blocking. It would make the guard pointless — an unguarded
`make lint` fails identically — and would prevent any commit on a fresh host.

**Why:** `make`, `shellcheck`, `shfmt` and `yamllint` are none of them present on
a minimal Ubuntu 24.04; they arrive in Phase 0.3. Phase 0.2 runs before that, so
"no commits until the toolchain exists" is not a workable rule.

**How the gap is closed:** `STRICT=1` makes a missing tool fatal, and CI sets it
from Phase 4.5. Lenient locally, strict where it counts.

---

## 0.2-5 · The Makefile repeats its guard four times

**Decided:** four near-identical `if command -v … else skip` blocks, rather than
factoring them into a `define` or `$(call …)`.

**Why:** deliberate deferral, not oversight. At four instances the repetition is
still readable and the abstraction would obscure more than it saves. Revisit if
a fifth linter appears, or if the guard logic needs to change in more than one
place at once — that is the signal the abstraction has earned its cost.

---

## 0.2-6 · Filenames in this repo may not contain spaces

**Decided:** treat whitespace in filenames as unsupported.

**Why:** `make lint` pipes the file list through `xargs`, which splits on
whitespace. `find -print0 | xargs -0` is the usual fix, but it does not apply
here — make lists are space-separated by definition, so a filename with a space
is already two entries before `xargs` sees it.

**Consequence:** a file named `my script.sh` will be silently mis-linted rather
than reported. This is a constraint the tooling imposes, so it is written down
rather than left to be discovered.

---

## 0.2-7 · Phantom files are filtered with `$(wildcard)`

**Decided:** `SH := $(wildcard $(filter %.sh,$(FILES)))`.

**Why:** `git ls-files --cached` lists names in git's *index*, not files that
exist on disk. A file staged and then deleted appears in the list and crashes
the linter trying to open it. `$(wildcard)` drops anything not present on disk.

Found the hard way: `make lint` broke immediately after the hook's own test file
was deleted but left staged.

---

## 0.3-1 · `prepare-host.sh` lives at the repository root

**Decided:** the day-0 script sits at the root, not under `host/`.

**Rejected:** `host/prepare-host.sh`, which groups it with the netplan config
Phase 0.4 will add.

**Why:** it is the single entry point a human runs on a bare machine, and the
reference puts its equivalent at the root for the same reason. Revisit at 0.4 —
if the bridge config and this script end up sharing more than a phase number,
a `host/` directory earns its place.

---

## 0.3-2 · No NTP daemon is installed; the clock is asserted, not the mechanism

**Decided:** `sync_clock` enables systemd's NTP best-effort, then waits for
`timedatectl show -p NTPSynchronized --value` to report `yes`. It installs no
NTP daemon and dies if the clock never synchronises.

**Rejected:** installing chrony, which is what the reference does.

**Why:** the reference's comment — *"CloudStack expects it as the NTP daemon"* —
is contradicted by CloudStack's own installer, whose package list includes
**openntpd**. Both packages `Provides: time-daemon` and `Conflicts: time-daemon`,
so installing chrony now means apt removes it during Phase 1. Verified on the
reference host: chrony inactive, openntpd active.

**The principle worth keeping:** assert on the *outcome* (is the clock correct?)
not the *mechanism* (is a particular daemon enabled?). A host where openntpd owns
time reports `NTP=no` and `NTPSynchronized=yes` and is perfectly healthy —
checking the mechanism would fail a working machine.

The clock is corrected before any apt or TLS work because both validate against
system time and both report skew as something else entirely: a broken mirror, an
untrusted certificate.

---

## 0.3-3 · `check_kvm` verifies only, and its failures are fatal

**Decided:** check for a `vmx`/`svm` CPU flag and a `/dev/kvm` character device.
Both fatal. Nothing is installed.

**Rejected:** using `kvm-ok`, which gives a friendlier verdict but ships in the
`cpu-checker` package — installing something inside a verification function,
which breaks the verify/install split the rest of the script keeps.

**Why fatal:** every phase from 1 onward boots VMs. Continuing past this produces
a QEMU failure twenty minutes later that does not mention KVM.

**Why two checks:** they fail independently. The CPU flag can be present while
the device node is missing, if `kvm_intel`/`kvm_amd` did not load.

---

## 0.3-4 · Docker comes from its own apt repository, in deb822 format

**Decided:** add Docker's signing key to `/etc/apt/keyrings/`, write
`/etc/apt/sources.list.d/docker.sources`, and install `docker-ce`,
`docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` and
`docker-compose-plugin`.

**Rejected:** `curl -fsSL https://get.docker.com | sh`, which the reference uses.
One line, always current, officially supported — and a remote script piped into a
root shell, which is the thing this repo's lint and hook gates exist to make us
think twice about.

**Also rejected:** Ubuntu's `docker.io` package. No third-party repo, but the
version lags and Compose v2 packaging varies.

**Why:** the key and repository are pinned and every package is signed
thereafter, so the trust decision is made once, explicitly, and is auditable in
the diff. Adding a third-party signing key is still a trust decision — it is
simply a legible one.

**Format:** deb822 (`Types:`/`URIs:`/`Suites:`) rather than the older one-line
`deb [signed-by=…]`. Both work; deb822 is what the current docs show and it
avoids the quoting awkwardness of building a repo line inside a shell string.

**Verified by daemon, not binary:** `docker info` and `docker compose version`,
because `command -v docker` passes even when the daemon failed to start, and
`docker compose` is a subcommand the shell cannot see at all.

---

## 0.3-5 · "Installed" means the command resolves on PATH

**Decided:** `install_cli_tools` tests `command -v` for curl, jq, envsubst and
openssl — with one deliberate exception. `ca-certificates` ships no binary, so
its presence is asked of `dpkg -s` instead.

**Why:** later phases need a *usable command*, not a database entry. The two
notions diverge, and when they do this script will loop rather than converge.

Found the hard way while testing: renaming `/usr/bin/jq` made `command -v jq`
fail while dpkg still reported the package installed, so `apt-get install jq`
did nothing and every run repeated *"Installing CLI tools: jq"*. `mv` is not an
uninstall. The signature of that divergence is a script that claims to install
something which never appears; `apt-get install --reinstall` is the repair.

Note also that command name and package name are not the same thing: `envsubst`
comes from `gettext-base`. That entry is the only one where a name had to be
typed rather than repeated, and it is the one that was mistyped.

---

## 0.3-6 · `DEBIAN_FRONTEND=noninteractive` is exported once, at script scope

**Decided:** exported next to `set -euo pipefail` rather than prefixed per
command or per function.

**Why:** it suppresses maintainer-script prompts that would hang an unattended
run, and two separate functions call `apt-get`. Exporting once means no call site
can forget it.

**Note the reasoning changed.** The original argument was that Docker's
convenience script runs apt in a child process that cannot be prefixed. Choosing
the apt-repository route (0.3-4) removed that constraint, so the decision now
rests only on having multiple call sites. Recorded because a justification that
has quietly expired is worse than none.

It does **not** resolve config-file conflicts — that needs
`-o Dpkg::Options::="--force-confold"` and will matter the first time a package
ships a new default for a file we have edited.

---

## 0.3-7 · Failure messages name the likely cause, not the symptom

**Decided:** every `die` states what to do next, not merely what went wrong.

Compare `"/dev/kvm does not exist"` with *"/dev/kvm is missing — the
kvm_intel/kvm_amd module did not load. Check `lsmod | grep kvm`."* The first
starts a search; the second ends one.

**Why:** these messages are read on a fresh machine, by someone with no context,
at the moment nothing works yet. That is the worst possible time to be terse.

**Related working practice:** prove the failure path before believing it. Four
bugs this phase — a hook that never fired, a wait loop that could not fail, a
`STRICT` branch that never ran, and a `gettext-base` typo — were all invisible
because the failing branch was never executed. Breaking a check on purpose costs
ten seconds.

---

## 0.4-1 · Services bind to `0.0.0.0`; the bridge address is still discovered

**Decided:** container services publish on `0.0.0.0` rather than on the cloudbr0
address. A `cloudbr0_ip()`-style discovery function is still written, because
most uses of that address are not bind addresses.

**Rejected:** the reference's approach of pinning every service to the bridge IP
via `PROXY_BIND_IP` / `GITEA_BIND_IP` / `MINIO_BIND_IP` / `VAULT_BIND_IP`.

**Why:** binding is only one of the address's jobs, and the smaller one. Of
roughly ten consumers, four are bind addresses and the rest are *reference*
values — things that must be told the address rather than listen on it:

- `ROOT_URL`, so Gitea's generated links and cookies match how a browser arrives
- the registry string in `daemon.json`, k3s `registries.yaml`, and Vault
- `VAULT_ADDR` for CI and for the cluster's ClusterSecretStore
- the git URL `flux bootstrap` bakes into `gotk-sync.yaml`
- DNS records, from Phase 2
- `cloudstack-setup-databases -i <ip>`, and the zone's public/pod range, which
  CloudStack derives from the bridge's own `/24`

So `0.0.0.0` simplifies the compose files without removing the need to know the
address. Concluding "I never need the bridge IP" is the version that fails in
Phase 1, where CloudStack asks for it directly.

**What it costs:** services answer on every interface — eight on the reference
host, including four Docker bridges and `cloud0`. On an isolated single-host lab
that is acceptable. It does mean a port is claimed globally rather than per
address, and it slightly widens the surface the tier ACLs are compensating for.

**Note the reference is already inconsistent here:** Gitea, MinIO and the proxy
bind to the bridge address, while Vault listens on `0.0.0.0:8200` and
CloudStack's Tomcat on `*:8080`. This decision picks one side of a split the
reference never resolved.

---

## 0.4-2 · CloudStack creates the bridge; we verify rather than configure

**Decided:** let the Phase 1 installer create `cloudbr0`. Phase 0.4 produces an
address plan only. The bridge address is checked against that plan in Phase 1.3,
after the fact.

**Rejected:** creating the bridge ourselves in Phase 0 via netplan, so we could
choose the host's position in the `/24`.

**Why:** the original argument for building it ourselves was that DNS and the CA
had to exist before the cloud — and that argument expired when the cloud moved to
Phase 1. What remained was control over the host's address, which matters because
the installer derives the zone from the bridge's own subnet, scanning for
addresses that do not answer and claiming roughly `.11–.30` for public IPs and
`.31–.50` for pod IPs.

That turned out to be a theoretical concern. **Verified empirically:** the
reference stack was run on a fresh VM with no address collision. DHCP pools
conventionally start well above `.50`, so the host lands clear of the scanned
range without anyone arranging it. The installer also converts the NIC's current
DHCP address into a **static** assignment on the bridge — `dhcp4: false` on the
NIC, a fixed address on `cloudbr0` — so staying static is handled too.

**Residual risk, accepted:** the DHCP server does not know that address became
static, so it could hand the same lease to another device later. A reservation on
the router closes this where the network is ours to configure. On an isolated lab
network it is unlikely enough to accept.

**What this means in practice:** Phase 0.4 is a documentation step. The check
that the host address sits outside `.11–.50`, and that the derived ranges match
the plan, happens in Phase 1.3 when reading back what the installer built.

---

## 1.2-1 · Everything that runs `cmk` runs as root

**Decided:** the `cmk` profile lives at `/root/.cmk/config` and has one owner.
Both callers — the Phase 1.2 orchestrator and the Phase 3.6 Vault seeding script
— already run as root, so this is a constraint to preserve rather than a change
to make.

**Rejected:** running `generate_cloudstack_api_keys` under `sudo -u` so the
profile lands in the invoking user's `~/.cmk/`, usable without `sudo`.

**Why:** `cmk` resolves its config from `$HOME` and offers no way to override it
per-invocation. Split the users and the seeding script writes its URL and
credentials to a profile nothing else reads — `cmk` reports no error, it simply
behaves as though never configured.

**Accepted:** the profile stores the CloudStack admin password in cleartext,
mode `0600` (set by `cmk`). Fine for a lab whose admin password is `password` by
design, and the reason this file is never copied, committed, or templated.
