# Decisions

Append-only. Each entry: what was decided, what was rejected, and why. Six weeks
from now the *why* is the only part that still matters.

Format: newest at the bottom, so the file reads as a history.

---

## Open questions

Noticed but not settled, each tagged with the phase that will settle it. Kept
above the history so that appending a decision never has to step around them.

- **Does cloud-init fight netplan on the Packer image, and on the zone's VMs?**
  — Phase 6.2, then again at 7.3. On *this* host the question is closed: subiquity
  wrote `/etc/cloud/cloud-init.disabled` at install time, so the vendored
  installer's `rm -f /etc/netplan/50-cloud-init.yaml` sticks. Verified by boot
  rather than by the marker — the host booted `2026-08-19 09:24:59` while
  cloud-init's `boot-finished` stamp still reads `2026-08-13 12:38`, so it did not
  run on that boot.

  Neither later host inherits that. Cloud images ship cloud-init **enabled**,
  because it is their entire provisioning mechanism, and CloudStack feeds guests
  network config through its own datasource. `50-` also sorts after `01-`, so
  cloud-init's netplan wins there by default. On those hosts that is the design,
  not a bug to work around — the real question is whether the Phase 8.2 base role
  writes anything that competes with it, and if so which of the two should yield.

- **Which of the installer's in-place edits still cannot be undone once
  `/etc/netplan` is snapshotted?** — settled alongside T-4. The snapshot of
  1.3-6 covers netplan, `libvirtd.conf` and the `/etc/default` files. What it
  does not cover is anything *appended* to a file that also has legitimate
  non-lab content: `NEED_STATD=yes` in `/etc/default/nfs-common` (installer line
  1343) and `LIBVIRTD_ARGS="--listen"` in `/etc/default/libvirtd` (line 1425)
  are both appended only when absent, so a present one cannot be attributed.
  Sentinel comments around every appended block would settle it; whether that is
  worth patching the vendored installer for is the open part.

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

---

## 2.1-1 · `prepare-host.sh` is renamed `bootstrap.sh` and becomes all-in-one

**Decided:** one script at the repository root takes a bare host to a running
lab — host preparation, CloudStack, then services in dependency order. Supersedes
[0.3-1](#03-1--prepare-hostsh-lives-at-the-repository-root), which named the same
file `prepare-host.sh` throughout Phases 0 and 1.

**Rejected:** keeping `prepare-host.sh` and adding a separate `bootstrap.sh` that
calls it. Three independently runnable scripts plus a `make` target would have
kept host preparation and service deployment in separate failure domains.

**Why:** one command on a fresh VM was worth more than the separation. The
reference lab is built this way and it works; splitting it was a refinement that
had not earned its cost.

**The constraint the merge has to respect:** `cloudbr0` does not exist until
CloudStack creates it, so every step that calls `bridge_ip` or `gateway_ip` must
come after `install_cloudstack`. This is why the merge only works with CloudStack
*inside* the script — a bootstrap that assumed a prepared host and started at the
services would die on the first `bridge_ip`.

**The cost, and the mitigation:** the four host-preparation steps now run on every
invocation, and `sync_clock` waits up to 60s for NTP. `SKIP_HOST_PREP=1` skips
them, which matters from Phase 3 on when the service layer is re-run often.

**Not renamed:** `cloudstack/scripts/prepare-kvm-host.sh`, which is a different
thing — it prepares the host *for CloudStack to add as a KVM host*, and is called
by `cloudstack-install-all.sh`.

---

## 2.1-2 · Verification lives in `make verify`, not in `bootstrap.sh`

**Decided:** `bootstrap.sh` deploys and stops there. Checking that the result
works is a separate `make verify` target, run by choice.

**Rejected:** a `verify_dns` step at the end of `install_coredns`, and a zone
parse check inside `render_coredns`.

**Why:** the parse check was re-testing a mostly-static artifact — the template
is committed and its only variable input, `bridge_ip`, already refuses to return
an empty value. Once the template is right it cannot become wrong between runs.

It also kept `bootstrap.sh` free of dependencies that `install_cli_tools` does
not declare. The check needed `python3-dnspython` and the DNS probe needs `dig`
(`bind9-dnsutils`); neither is in the declared list, and both were present on the
development host by accident. A deployment script that silently depends on
undeclared tools fails on the fresh VM it exists to serve.

**Accepted risk:** `docker compose up -d` returns when the container *starts*,
and CoreDNS answers a failed zone load by logging and carrying on. So a deploy
where nothing resolves is indistinguishable from a working one until something
tries to use a name. That is the gap `make verify` closes, and until it exists
the gap is open.

**What `make verify` should check:**

| Check | Passes when |
|---|---|
| `dig @<bridge> gitea.lab.test` | an answer **and** the `aa` flag — `aa` absent means the zone did not load and upstream replied |
| `dig @<bridge> example.com` | resolves, proving the forward block reaches the gateway |
| zone parse | `named-checkzone lab.test <zone>` accepts the rendered file |
| port binding | `:53` is bound on the bridge address, not `0.0.0.0` — a wildcard bind means `CLOUDBR0_IP` was empty |

**Tool policy:** guard `dig` and `named-checkzone` in the Makefile the way
`shellcheck`, `shfmt` and `yamllint` are guarded — missing warns and skips,
`STRICT=1` makes it fatal. That is [0.2-4](#02-4--a-missing-linter-warns-a-missing-make-warns)
applied unchanged, so `make verify` inherits the policy rather than inventing one.
Both come from the `bind9-*` packages and stay out of `install_cli_tools`, which
declares what the *lab* needs, not what checking it needs.

---

## 2.3-1 · The root CA is generated by hand, once, and refuses to run twice

**Decided:** `ca/scripts/root-ca-create.sh` is run manually, once per lab.
`bootstrap.sh` does not call it, and the script dies if a root already exists in
the target directory.

**Rejected:** an `install_root_ca` step in `bootstrap.sh`, and making the script
re-runnable like every other script in this repo.

**Why:** idempotent means *re-running produces the same result*. For a CA it
produces a **different** root, and every certificate issued under the old one
stops validating — silently, because nothing re-checks a chain until something
tries to use it. The safe re-run is no run at all, which is why the guard is a
`die` and not a skip.

Keeping it out of `bootstrap.sh` follows from the same thing. `bootstrap.sh` is
the fresh-VM path, run whenever the host is rebuilt; a trust anchor that is
replaced on every rebuild is not an anchor. This is the first script here that is
deliberately not part of the one-command build, and the boundary is real: from
here on, *deploying* the lab and *establishing its identity* are separate acts.

**Consequence for later phases:** a rebuilt host must be pointed at the existing
`ca/root/`, not given a new one. Phase 2.6 (distributing trust) is where that
stops being a note and becomes a procedure.

---

## 2.3-2 · RSA 4096, twenty years, `pathlen:1`

**Decided:** the root is an RSA-4096 key, self-signed with SHA-256 for 7300 days,
carrying `basicConstraints = critical, CA:TRUE, pathlen:1` and
`keyUsage = critical, keyCertSign, cRLSign`. No subjectAltName.

**Rejected:** EC P-384, which was the original choice here and was reversed
before the CA was generated. It is smaller and faster and every current client
handles it — but "every current client" is a claim about a lab that is only six
phases old, and the things still to be added (a JVM trust store in Phase 4, a
Packer-built image, container bases of unknown vintage, whatever appliance turns
up later) are exactly where an unexpected RSA-only path would surface. RSA-4096
is the most exercised code path in every TLS stack in existence, and the cost of
choosing it — larger certificates, slower signing — is invisible at the scale of
one host issuing a handful of certificates.

**Why SHA-256 rather than SHA-384:** RSA-4096 is worth roughly 150 bits of
security and SHA-256 gives 128 bits of collision resistance, so the pair is
balanced; SHA-384 would be defensible and buys nothing measurable. `default_md`
in `root-ca.cnf` is the single place it is set.

**Why `pathlen:1`:** it puts "this root signs exactly one intermediate, and
nothing below that one may be a CA" inside the certificate, where a client
enforces it, rather than in a habit that holds until someone is in a hurry. The
intermediate gets `pathlen:0` for the same reason.

**Why no SAN:** modern clients read subjectAltName on *leaf* certificates and
identify a CA by its subject. A SAN on a root is noise that implies the root is
usable as a server certificate.

**Why twenty years:** the root outlives the lab, so its expiry is never a phase's
problem. The intermediate is the thing that rotates, and 3.5 automates that.

**Deliberately absent:** no CRL distribution point and no OCSP URI. Nothing is
serving either yet, and a revocation URL that points nowhere is worse than none —
clients that check it fail closed on a URL that will never answer. Phase 3.4,
where Vault takes over issuance, is where revocation gets a home.

---

## 2.3-3 · "Offline" is the passphrase, not the location

**Decided:** the CA lives in `ca/root/`, ignored wholesale by git. The key is
AES-256 encrypted at the moment it is created — never written in the clear — and
left `0400`. The passphrase is prompted for, confirmed, required to be twelve
characters, and handed to `openssl` through a process substitution.

**Rejected:** `-pass pass:...`, which puts the passphrase in the argument list
where `ps` shows it to every user on the host, and `-pass env:...`, which leaves
it in `/proc/<pid>/environ`. A pipe on a file descriptor is visible to neither.

**Rejected:** keeping the root outside the repository, or on removable media that
has to be remounted for 2.4 and 3.4.

**Why:** an encrypted key is equally unusable to someone who copies it whether it
sits in the working tree or on a USB stick — the passphrase is what makes it
offline, and the passphrase is not on the disk. Location buys protection only
against an attacker who already has the key, and at the cost of friction on every
phase that legitimately needs it.

**Accepted risk:** the root sits on the same disk as the lab it protects, so one
backup of the wrong directory carries it off-host, still encrypted. That trade is
right for a lab and wrong for anything real; if this CA ever protects something
that matters, removable media is the change to make, and it is a one-argument
change — the script already takes the CA directory as `$1`.

**Also decided, quietly:** the script requires no privilege, and warns if run
under `sudo`. Generating a key needs none, and root-owned files in the working
tree are a nuisance for the rest of the phase. It is the only script here that
does not start with `require_root`.

**The CA database** (`index.txt`, `serial`, `newcerts/`) is created now rather
than in 2.4, because `openssl ca` will not sign anything without it. The serial
is sixteen random bytes rather than `01`: serials are public, and a sequential
one tells every certificate holder how many others this CA has issued.

---

## 1.3-1 · apt waits for the dpkg lock; it does not race it

**Decided:** every `apt-get` in this repo goes through `apt_get()` in
`lib/common.sh`, which adds `-o DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT:-300}`.

**Rejected:** polling `fuser /var/lib/dpkg/lock-frontend` in a wait loop, which
reimplements — worse — something apt has done natively since 2.0.

**Rejected:** `systemctl stop unattended-upgrades` before installing. It
interrupts a dpkg transaction that is already in flight, and leaves the host in
the half-configured state this whole script exists to avoid.

**Rejected:** `DPkg::Lock::Timeout=-1` (wait forever). A genuinely stuck lock
should fail a CI run, not hang it until someone notices.

**Why:** found on the first real run against a fresh VM. `unattended-upgrades`
starts on a new host's first boots and holds the frontend lock for minutes;
`prepare-kvm-host.sh` reached `openssh-server` roughly nine seconds after it
started and lost the race. The failure is pure timing — it says nothing about the
host, is not reproducible on the second run, and surfaces at the exact moment the
operator has least context to judge it. Re-running was already the correct fix,
which is precisely why the script should not have needed a human to work that out.

**The deeper point:** "safe to re-run" is not the same as "does not fail
spuriously." Idempotence made recovery cheap here, and still cost a confusing
error on a first install. Both properties are worth having.

**Note for 0.3-7:** the two `die` messages on the apt paths now name the lock as
the likely cause and say to wait and re-run, rather than reporting only that the
install failed.

---

## 1.3-2 · A bootstrap resolver floor, because the installer rebuilds the network under itself

**Decided:** `cloudstack-install-all.sh` writes a global `DNS=` drop-in for
systemd-resolved before invoking the vendored installer, and proves it by
resolving `download.cloudstack.org` rather than by checking the file exists.

**Why:** the installer reconfigures host networking in the middle of its own run.
`netplan apply` moves the NIC into `cloudbr0`, sets `dhcp4: false` on it — which
takes the DHCP-supplied nameserver with it — and puts a static resolver on the
bridge. `netplan apply` returns when networkd *accepts* the config, not when it
has converged, and the next thing the installer does is `curl` the CloudStack
signing key. Measured on a first run: netplan at `09:53:07.975`, curl failing
inside the same second.

**Two errors, one cause.** The failure prints as `curl (6) Could not resolve
host` and then `gpg: no valid OpenPGP data found`. The second is not a second
problem — `curl -fsSL … | gpg --dearmor | tee` handed gpg an empty pipe. Reading
them as independent sends you looking for a keyserver problem that does not exist.

**Rejected:** pre-creating `cloudbr0` so the installer skips network
configuration. It is the more complete fix — it protects every later network call,
not just the key fetch — but it reverses [0.4-2](#04-2) and moves real work back
into Phase 0.4. Held in reserve: if anything downstream of the bridge shows the
same flakiness, that is the answer, and 0.4-2 should be rewritten rather than
worked around twice.

**Rejected:** pre-seeding the repository and key from the wrapper. Smallest
change, but it shields only this one step, while `apt-get update` and the package
install that follow run against the same just-rebuilt network.

**Why DNS and not connectivity:** the error is consistently curl 6, never curl 7.
The bridge carries the existing address across without a DHCP round trip, so
routing is up almost immediately; it is systemd-resolved's per-link state that
lags. Fixing the resolver is therefore sufficient, and a `wait-online` loop would
have been aimed at the wrong layer.

**A near miss worth recording.** The failed run left a **0-byte**
`/etc/apt/keyrings/cloudstack.gpg` — `set -euo pipefail` tripped `error_exit`, but
`tee` had already created the file. Re-running was safe only because the key is
written *before* `cloudstack.list`, so the `.list` never appeared and the
already-configured branch did not engage. Had those two writes been ordered the
other way, the silent-mode short-circuit —

```sh
if [[ -n "$repo_entry" ]]; then
  if is_silent; then ... return 0
```

— would have skipped the key fetch on every subsequent run, pairing an empty
keyring with a live repository and surfacing as apt signature failures many steps
later. **A failing step that writes a file before it fails is not idempotent, it
is merely lucky.** Worth checking for wherever this repo pipes into `tee`.

---

## 1.3-3 · Drop-in numbers, and which direction each system reads them

**Decided:** the bootstrap resolver floor is `05-cloudstack-bootstrap.conf`, below
CoreDNS's `10-lab.conf`, and `coredns-installer.sh` **deletes** it when it takes
over. The deletion is what retires it; the number only makes the intent legible.

**Rejected:** `99-`, which is what it was first written as. That was backwards.
systemd parses drop-ins in lexicographic order and later assignments win, so `99-`
left the temporary floor outranking the resolver meant to replace it.

**Rejected:** relying on sort order alone once renumbered. `DNS=` is a list
setting, so the realistic failure is not "the wrong one wins" but "both survive" —
a global `8.8.8.8` still answering everything outside `~lab.test` while CoreDNS
handles the lab names. Every name resolves, so nothing looks broken; the host has
simply stopped using its own resolver for most of its traffic.

**The rule worth memorising, because it is not consistent:**

| Directory | Rule | Winner |
|---|---|---|
| `/etc/sysctl.d/` | lexicographically latest takes precedence | higher number |
| `/etc/systemd/*.conf.d/` | later assignment overrides | higher number |
| `/etc/netplan/` | later file overrides on the same key | higher number |
| `/etc/ssh/sshd_config.d/` | *"the **first** obtained value will be used"* | **lower number** |

sshd is the odd one out, and `prepare-kvm-host.sh` already accounts for it: it
asserts on `sshd -T`, the merged effective config, so a lower-numbered file
outranking `01-cloudstack.conf` is caught rather than assumed away. Ubuntu placing
`Include` at line 12 of `sshd_config` — near the top, where first-wins makes it
authoritative — is load-bearing for that, not incidental.

**Observed while checking this, not yet acted on:** `01-bridge-cloudbr0.yaml`
declares `renderer: networkd`, but `01-network-manager-all.yaml` sorts after it
(`01-b` < `01-n`) and declares `renderer: NetworkManager`. NetworkManager wins.
`networkctl status cloudbr0` reports `unmanaged`, `nmcli` shows the bridge on
`netplan-cloudbr0`, and netplan emitted a `.nmconnection` rather than a `.network`
file. It works, so it is left alone — but the bridge is governed by a file the
installer never wrote, and any later reasoning that begins "networkd will…" is
wrong. Revisit if the renderer ever matters.

---

## 1.3-4 · The CloudStack repo is seeded by us, pinned to 4.21

**Decided:** `cloudstack-install-all.sh` writes `/etc/apt/keyrings/cloudstack.gpg`
and `/etc/apt/sources.list.d/cloudstack.list` itself, pinned to
`CS_REPO_VERSION=4.21`, then proves the repository resolves to an installable
`cloudstack-management` before any other step runs.

**Why, first reason — 4.22 is broken upstream.** The vendored installer hardcodes
`default_cs_version="4.22"`. The signed `Release` for noble declares
`4.22/binary-all/Packages.bz2` as 5670 bytes; the CDN serves 6848. apt refuses the
index and exits **100**. Measured across all three published components:

| Component | `apt-get update` |
|---|---|
| 4.22 (installer default) | exit 100 — size mismatch, 6848 != 5670 |
| 4.21 | **exit 0** |
| 4.20 | exit 100 — size mismatch, 8365 != 6861 |

4.21 publishes the full set at 4.21.0.0 — management, agent, usage, common, ui.
Not a transient mirror sync despite apt's suggestion: that `Release` was created
2026-05-25 and was still inconsistent on 2026-08-19.

**Why, second reason — the failure was silent, and that is the worse bug.**
`update_system_packages` runs:

```sh
apt-get update 2>&1 | while IFS= read -r line; do ... done
...
if [[ $? -eq 0 ]]; then ... else ... return 1; fi
```

Under the installer's own `set -euo pipefail`, a non-zero `apt-get update` fails
the pipeline, and `set -e` terminates the script *before* the `$?` test can run.
The author's error handling is unreachable. What you see is the installer printing
"Skipping repository setup", then nothing — no message, no log line, no non-zero
exit visible to the caller. **An error handler placed after a failing command in a
`set -e` script is decoration.**

**Rejected:** patching `default_cs_version` in the vendored installer. It is read,
driven, never maintained — and the installer already offers a supported way to
choose: its silent-mode path returns early when the list file exists, so writing
that file is how you pick the version without touching upstream.

**Rejected:** letting the installer's own repo step run and pinning afterwards.
There is no "afterwards" — it dies in the step that follows.

**Verified before the installer, not during.** The seeding step ends with
`apt-get update` and an `apt-cache policy` check for a real candidate version.
A broken component now fails in ten seconds with a message naming the component
and where to look, instead of twenty minutes in with nothing at all. The `die`
tells you to try another `CS_REPO_VERSION` and where to read what is published.

**The key is dearmoured to a temp file and installed only once non-empty**, which
is 1.3-2's near miss turned into a rule. `curl ... | gpg | tee keyring` creates
the file before curl's failure can stop it; `install`-after-check cannot.

**Two smaller rules the code now follows silently, recorded because the comments
that explained them were removed.**

*Capture, do not pipe, into `grep -q`.* `cmd | grep -q pattern` lets grep exit on
its first match; the producer then takes SIGPIPE and `pipefail` reports **141** —
a successful match read as a failure. Measured, so it is not folklore:

```
$ bash -c 'set -euo pipefail; seq 1 2000000 | grep -q "^1$"; echo reached'
   -> exit 141, "reached" never printed
$ bash -c 'set -euo pipefail; v="$(seq 1 2000000 || true)"; grep -q "^1$" <<<"$v"'
   -> exit 0
```

`apt-cache policy` emits four lines and would never have triggered it, which is
precisely the argument for fixing it: the pattern survives to somewhere it does.
`coredns-installer.sh` had already been bitten by this with `resolvectl status`.

*A `RETURN` trap does not cover `die`.* `die` calls `exit`, which fires `EXIT`,
not `RETURN` — so every failure path leaked its `mktemp` file. `trap ... RETURN
EXIT` covers both. Verified by running the function to a forced `die` under each
form: the `RETURN`-only version leaked, `RETURN EXIT` cleaned up. Safe here
because this is the script's only trap, and the surviving `rm -f` is a no-op on a
file already gone.

---

## 2.3-4 · `bootstrap.sh` creates the root CA when there is none

**Decided:** `install_root_ca` runs `ca/scripts/root-ca-create.sh` on every
bootstrap. The script creates a CA when nothing exists, leaves an existing one
untouched, and refuses anything in between. Supersedes
[2.3-1](#23-1--the-root-ca-is-generated-by-hand-once-and-refuses-to-run-twice),
which kept CA creation out of `bootstrap.sh` entirely.

**Rejected:** the by-hand-once rule of 2.3-1. It was written for an offline root
in the real sense — an asset that outlives any host — and this lab wants one
command to take a bare VM to a working system. Those are not reconcilable, and
the requirement wins.

**Why the guard moves rather than disappears:** *bootstrap* decides whether to
call the generator; the *generator* still refuses to clobber. Re-running on a
working host is a no-op, re-running on a wiped one mints a new root, and neither
path can silently replace a live trust anchor.

**Where it sits in `main()`, and why exactly there.** Three constraints pin it:

| Constraint | Reason |
|---|---|
| after `sync_clock` | `notBefore`/`notAfter` come from the system clock. A skewed clock mints a certificate nothing accepts, and reports it as "certificate is not yet valid" — a certificate problem, apparently, rather than a clock problem |
| after `install_cli_tools` | that step is what declares `openssl`. Ubuntu ships it, so this would appear to work anywhere — the accident [2.1-2](#21-2--verification-lives-in-make-verify-not-in-bootstrapsh) called out about `dig` |
| before `install_cloudstack` | not technical. Anything that can fail should fail before forty minutes of installer, not behind it |

**Consequence, unchanged from 2.3-1:** a rebuilt host mints a *new* root, so
every trust store that trusted the old one is wrong. That is Phase 2.6, and it is
the strongest argument for backing up `/root/.root-ca.pass` alongside
`ca/root/` — together they turn a rebuild back into the same lab.

---

## 2.3-5 · The passphrase is generated, not typed, and lives outside the repo

**Decided:** `create_passphrase` writes 32 random bytes, base64-encoded, to
`/root/.root-ca.pass` at `0400`, and the key is encrypted with it. No prompt, no
human input, nothing to remember. Supersedes
[2.3-3](#23-3--offline-is-the-passphrase-not-the-location), which had the script
prompt for a twelve-character passphrase and confirm it.

**Rejected:** the prompt. It is the strongest option — the passphrase exists only
in the operator's head — and it is one manual step, which is one more than
"bootstrap does everything" allows.

**Rejected:** no passphrase at all. Same threat model against a compromised host,
strictly worse against the realistic leak: a copy of the working tree.

**Rejected:** storing the passphrase beside the key. That is not encryption, it
is a filename change.

**Why the split is the whole design.** The key sits in `ca/root/`, inside the
tree; the passphrase sits in `/root`, outside it. A backup, an `rsync`, a VM
snapshot or a `git add -f` on a bad day carries the tree and not `/root` — an
encrypted key with no way in. That is the only protection this buys, and it is
worth stating plainly: **anyone with root on this host can decrypt the key**,
because `bootstrap.sh` can, unattended, by design.

**Why it cannot be delegated to Vault.** Phase 3 stores secrets, but Vault runs
behind TLS issued from this CA. The root sits at the bottom of the trust chain
and has to be self-sufficient — which is why real PKI reaches for hardware or an
air gap rather than a secret store.

**Reverses 2.3-3 on privilege:** the script now starts with `require_root`, and
not out of habit. `/root` is `0700`, so an unprivileged run cannot *stat*
`PASS_FILE` at all — `check_existing` would report a fresh host and try to
recreate a CA that is sitting right there.

**Four mechanics the code no longer explains**, recorded here because the
comments that carried them were stripped in favour of one-line function headers:

- **`umask 077` before the redirect, not `chmod` after it.** The redirect creates
  the file the instant the subshell starts. `chmod` a line later closes a window
  that was open while 256 bits of secret were written into a `0644` file.
- **The subshell scopes the mask.** A bare `umask` would apply to everything the
  script does afterwards.
- **`-pass file:` and never `pass:` or `env:`.** The first puts a path in the
  argument list; the others put the secret where `ps` and `/proc/<pid>/environ`
  show it.
- **`die` outside the parentheses.** Inside, it exits only the subshell, and the
  script stops solely because `set -e` saw a non-zero return — a guarantee that
  evaporates the moment that call lands in a condition.

---

## 2.4-1 · The intermediate is issued with `openssl ca`, not `req -x509`

**Decided:** the intermediate is created as a CSR and signed by the root through
`openssl ca`, using the `[ root_ca ]` section of `root-ca.cnf`.

**Rejected:** a second `req -x509`, which is how the root itself was made. It
would produce a working certificate and skip everything that makes an issuance an
issuance: no database entry, no serial allocation, no policy check.

**Why:** this is the first time the CA signs something that is not itself, and
`openssl ca` is the subcommand that models that. `intermediate_pol` enforces what
the root requires of a request — same `domainComponent`, same `organizationName`,
a `commonName` it supplies itself — so a CSR from the wrong organisation is
refused rather than certified.

**`copy_extensions = none`**, stated explicitly rather than left to default. A
CSR is a *request*: the requester chooses the key and the name, the CA chooses
what the certificate may do. Copying extensions from a CSR is how a leaf asks to
be a CA and gets told yes.

**`rand_serial = yes`** rather than a counter file. Serials are public, and a
sequential one tells every holder how many certificates this CA has issued.

**`dir = $ENV::CA_DIR`** rather than a hardcoded path, so the same config serves
a CA directory that moves. The cost is that `$ENV::` expands when openssl *loads*
the file — every command reading this config must set `CA_DIR`, including ones
that never touch the `[ ca ]` section.

**Outstanding, since closed:** `openssl ca` needs `index.txt` and `newcerts/` to
exist, and nothing created them when this was written. The database belongs to
the CA whose issuances it records, so `root-ca-create.sh` is where that went —
`init_ca_db()`, and `intermediate-ca-create.sh` has its own for the leaves it
will issue. Left in place rather than deleted, because this file is append-only
and a resolved note still records what the gap was.

---

## 2.4-2 · What the intermediate is allowed to issue

**Decided:** `intermediate-ca.cnf` issues leaves at `default_days = 397`, with
`basicConstraints = critical,CA:false`, `keyUsage = digitalSignature,
keyEncipherment`, `extendedKeyUsage = serverAuth`, and a subjectAltName taken
from `$ENV::LEAF_SAN`.

**Why 397 days:** the CA/Browser Forum cap is 398, and browsers enforce it on
publicly-trusted certificates. Nothing here is publicly trusted, so this is a
habit rather than a requirement — but a lab that issues ten-year leaves teaches
the wrong instinct, and 3.5 is where renewal gets automated anyway.

**Why the SAN comes from the environment:** a DNS name is per-certificate, and
a config file is per-CA. The same expansion caveat as `CA_DIR` applies and is
sharper here — `$ENV::LEAF_SAN` is read when the file loads, so *every* openssl
command using this config must set it, including the intermediate's own CSR,
where `LEAF_SAN=""` is the correct value.

**The trap this encodes:** `[ leaf_pol ]` lists `domainComponent` and
`organizationName` as `match`, so a leaf CSR must carry the full DN, not just a
CN — and any field not listed in the policy is silently dropped from the issued
certificate rather than refused.

---

## 1.3-5 · The NFS export is a drop-in, not an append to `/etc/exports`

**Decided:** the installer writes `/etc/exports.d/cloudstack.exports` instead of
appending to `/etc/exports`. `exports(5)`: *"After reading /etc/exports exportfs
reads files in the /etc/exports.d directory as extra export tables. Only files
ending in .exports are considered."* The directory is not shipped on Ubuntu, so
it is created first.

**Rejected:** a sentinel comment (`# >>> cloudstack >>>`) around the appended
block. It works, and it is the right tool for a file with no drop-in mechanism —
but NFS has one, and every other component in this repo already uses the drop-in
directory for exactly this reason: `resolved.conf.d`, `sshd_config.d`,
`sources.list.d`, `sysctl.d`, `mysql.conf.d`, `netplan`.

**Rejected:** leaving it alone and having teardown match on content. `sed -i
'\|^/export |d' /etc/exports` deletes any line beginning `/export `, including
one the operator wrote. The lab does not own that file and should not be
pattern-matching inside it.

**Why:** it moves the artifact from the *shared* bucket to the *reversible* one
(T-2). Teardown becomes `rm -f` plus `exportfs -ra` — no parsing, no markers,
and no way to delete someone else's export.

**Three call sites,** all in `cloudstack/scripts/cloudstack-install.sh`: the
append at 1333-1334, the early-return skip at 1323, and the status summary at
1684. Miss the third and the lab works while its own validation reports *exports
not configured* — the same shape of bug as a drop-in that is silently ignored.

**A row for the table in 1.3-3, and it breaks that table's pattern.**
`/etc/exports.d/` has no precedence semantics at all. sysctl.d, resolved.conf.d,
netplan and sshd_config.d all answer *which file wins*; exports.d **unions** the
tables, and two files exporting the same path with different options is a
conflict `exportfs` complains about, not a contest one of them wins. So a number
prefix would be meaningless here: `cloudstack.exports`, not
`10-cloudstack.exports`.

**Migration:** hosts installed before this change carry the line in
`/etc/exports` and `nfs_configured=yes` in the tracker, so the step will not
re-run to fix it. Remove the line by hand, and remember that editing the tracker
does not re-enable a step — delete its line (see `failure-log.md`).

---

## 1.3-6 · `/etc/netplan` is snapshotted whole, before the installer runs

**Decided:** `cloudstack-install-all.sh` copies `/etc/netplan/` — the entire
directory — plus `/etc/libvirt/libvirtd.conf` and
`/etc/default/{libvirtd,nfs-kernel-server,nfs-common,quota}` to a backup
directory before it invokes the vendored installer. Only when that directory
does not already exist.

**Rejected:** saving `/etc/netplan/50-cloud-init.yaml` by name, which is the file
the installer names at line 2353 (`rm -f`, immediately after writing the bridge
config). On *this* host that file does not exist and the `rm -f` is a no-op — the
file actually governing the bridge is `01-network-manager-all.yaml`, per the open
question above. Saving the filename the installer mentions would have captured
nothing. Save the directory; the host decides which file inside it matters.

**Rejected:** patching the vendored installer to `mv` instead of `rm`. The
snapshot belongs in code we own, which is the seam Phase 1.1 is about — and one
snapshot step covers netplan, libvirt and the `/etc/default` edits together,
where patching would mean four separate changes to a file we re-vendor.

**Rejected:** storing the snapshot in MinIO (Phase 5.1) rather than a local
directory. The dependency is circular: the snapshot is taken in Phase 1 before
the vendored installer runs, and MinIO needs `minio.lab.test` from CoreDNS
(2.1), which binds the bridge address that the Phase 1 installer creates — plus
TLS from 2.4 and a root credential from Vault at 3.1. The store would depend,
four phases down, on the thing the snapshot exists to recover from.

It also buys no durability. This is one host: an object in MinIO sits on the same
disk as `/etc/netplan`. And the artifact being saved is the *network* config, so
a host that needs the restore cannot reach a store addressed by name, over TLS,
through a bridge. **A restore path must not depend on the thing it restores.**

Object storage earns its place where an artifact must outlive the host or be read
by something that is not the host — Terraform state at 5.2, images at 6.1.
Netplan fails both tests. The genuine disaster-recovery copy is the VM snapshot
of T-4; this local one exists so teardown can put netplan back in seconds instead
of forcing a full rollback.

**Why:** it is the only fix that moves an artifact out of the *unrecoverable*
bucket (T-2). Without it, undoing the bridge means reconstructing a netplan file
by parsing the bridge config for an interface, an address and a gateway, and
writing something that is a guess. A partial guess leaves the host unreachable.

**The trap:** a second bootstrap run must not overwrite the snapshot with
post-install state — by then the directory contains `01-bridge-cloudbr0.yaml`
and no original. Guard on the snapshot directory's existence, not on the files
inside it.

---

## T-1 · Teardown is one script, dry-run by default

Teardown has no phase in `build-order.md`; these are numbered `T-n` and will be
renumbered if it acquires one. The skeleton is `teardown.sh` at the repo root:
one TODO per decision still to make, numbered by the step it belongs to. Grep
`TODO` there for what is left.

**Decided:** a single `teardown.sh` mirroring `bootstrap.sh` — same shape, same
`lib/common.sh`, steps in reverse order — that prints what it would do and
changes nothing unless given `--yes`.

**Rejected:** acting by default with a `--dry-run` flag. Consider which mistake
is recoverable: a script that printed when you wanted it to act costs one
re-run; one that acted when you wanted it to print costs the lab.

**Rejected:** an `--uninstall` mode inside each installer. Attractive because the
code that installs knows how to remove — but the vendored installer is not ours
to extend, and teardown ordering is not per-script reversal (see T-2). Revisit
when there is a third component: per-component teardown scripts called by a
top-level ordering script would then mirror how `bootstrap.sh` calls installers.

**Two runners, not one.** `try` reports a failure and continues; `run` does not.
Most steps want the first — removing something already gone is success, and one
absent file must not abandon the forty steps after it. A few want the second,
where continuing is worse than stopping. Both take argv and run `"$@"`: taking a
string would need `eval`, and `eval` re-parses, so `rm -f "/export/a dir/x"`
becomes two paths and `rm -f` cheerfully succeeds at deleting neither.

---

## T-2 · Every artifact is sorted into one of four buckets first

**Decided:** before writing the line that removes something, classify it.

| Bucket | Meaning | What teardown does |
|---|---|---|
| reversible | the installer created it, nothing else wants it | remove it |
| reconstructable | the installer destroyed prior state | rebuild, or refuse |
| shared | predates the lab, or others depend on it | leave, or gate |
| unrecoverable | edited in place over unsaved values | report, never guess |

**Why:** an installer and its teardown are not mirror images, and assuming they
are is what makes teardown scripts dangerous. Three asymmetries:

- Some installer actions destroyed state that no longer exists to restore. The
  inverse of *created `01-bridge-cloudbr0.yaml`* is not *delete it* — do that and
  the host has no network configuration at all. 1.3-6 is the fix.
- Some actions were *ensure present*, not *create*. `install_docker` skips when
  Docker exists; `install_cli_tools` installs only what is missing. The inverse
  of *ensure present* is not *remove*.
- Order is broadly reverse-of-install, but check rather than assume: a service
  must stop before the database it holds open can be dropped, and Docker must be
  removed after the CoreDNS container that runs on it.

**Worked examples.** `/etc/systemd/resolved.conf.d/10-lab.conf` is reversible.
`/etc/apt/keyrings/` is shared — it holds `cloudstack.gpg` alongside
`docker.asc`, so teardown removes the file and never the directory.
`/etc/libvirt/libvirtd.conf` is unrecoverable: five keys rewritten in place over
values saved nowhere, so teardown reports it rather than guessing at defaults.

**Everything in the unrecoverable and shared buckets is reported at the end.** If
that list is empty after a real run, something has been mis-sorted rather than
perfectly torn down.

---

## T-3 · A fresh VM is assumed, so nothing records what was installed

**Decided:** `bootstrap.sh` runs on a fresh VM. Teardown may therefore purge the
packages bootstrap installs without asking whether they were already present.

**Rejected:** an install manifest — `bootstrap.sh` recording which packages it
actually installed, so teardown could distinguish *we put it there* from *it was
already here*. Correct in general, and it would have retired the
`--purge-packages` flag honestly. It solves a problem this lab does not have.

**Rejected:** a marker file asserting the host was bootstrapped, so teardown
refuses to run elsewhere. Cheap, and the right call if bootstrap were ever run on
a workstation. It is not.

**Consequences, which are larger than the rejected work:**

- `--restore-network` and `--purge-packages` both go. On a fresh-VM model the
  real teardown for a wrecked host is a snapshot rollback, which is total and
  cannot be subtly wrong. `teardown.sh` is not competing with that.
- What teardown is *for* is the inner loop: redoing CoreDNS, the CA or the
  CloudStack database without paying for a full VM rebuild each time.
- Remaining flags: `--yes`, `--purge-storage`, `--keep-ca`.

**The wrinkle:** "always a fresh VM" is true of the first bootstrap and false of
the one that runs after a teardown. That host is whatever teardown left behind.
1.3-6 closes the largest gap; the open question above tracks the rest. What is
not acceptable is assuming freshness while the code delivers drift — the failure
then surfaces as a bootstrap that behaves differently on a "fresh" host, and gets
debugged as a bootstrap bug.

---

## T-4 · Teardown is verified by re-running bootstrap, not by inspection

**Decided:** the success criterion is a loop, and the fresh-VM assumption of T-3
is what makes it cheap:

1. Snapshot the VM.
2. `bootstrap.sh`
3. `teardown.sh --yes`
4. `bootstrap.sh` again — it must come up green, and the host must match run 1.

**Rejected:** asserting on absence — a checklist of paths teardown should have
removed. It passes while missing everything nobody thought to list, which is
precisely the failure mode a teardown has.

**Why:** it tests the property that actually matters. Anything failing the second
bootstrap is either a teardown gap or an unrecoverable-bucket item that now has
to be decided deliberately. The snapshot means a failed run costs nothing, so
the loop can be run before the script is finished rather than after.

**Run it as soon as steps 1-4 exist,** before writing step 5 — it will say
whether step 5 needs to exist at all.

---

## 2.3-6 · The ignore rule follows the key, not the directory

**What happened:** the `pki/` → `ca/` rename carried the tracked files and both
`.gitignore` entries with them. It did not carry the *generated* CA, which is
untracked by design — so `pki/root/` kept the encrypted root key while the only
rule protecting it moved to `ca/root/`. `git check-ignore pki/root` answered *not
ignored*. Nothing showed in `git status`, because the directory is `0700
root:root` and git could not read it; every script here runs under `sudo`, and
one `sudo git add -A` would have staged the lab's trust anchor.

Two deliberate decisions had to line up for that, and both are recorded above:

- `*.key` does not match `root-ca.key.enc`. The suffix exists to say out loud
  that the key is encrypted ([2.3-3](#23-3--offline-is-the-passphrase-not-the-location)),
  and the `.gitignore` comment drew the conclusion that made this possible —
  *"this directory entry is what protects it."*
- The passphrase is absolute and the key is repo-relative
  ([2.3-5](#23-5--the-passphrase-is-generated-not-typed-and-lives-outside-the-repo)).
  The split is the entire design. It also means a rename moves one and not the
  other, which is the same shape of bug one layer down.

**Decided:** two changes, one per layer.

- `*.key.enc` joins the belt-and-braces list in `.gitignore`. A rule keyed on the
  filename follows the key wherever a later rename puts it; a rule keyed on the
  directory is a rule about a path that no longer holds the thing.
- `make lint` asserts `git check-ignore -q` on every path a CA script writes a
  key to (`CA_KEYS`). This is the guard the Makefile already applies to
  `VENDORED`, for a failure mode it had already named in a comment — *"a moved or
  renamed file leaves an exclusion that quietly matches nothing and looks exactly
  like no exclusion at all."* That was right, and it was one file short of where
  it was needed. Verified by breaking both rules and watching lint fail, then by
  removing only the directory entry and watching it still pass.

**Rejected:** re-adding `pki/` to `.gitignore`. It silences the symptom and
leaves a rule describing a path that should not exist. The directory is the thing
to remove.

**Rejected:** renaming the key `root-ca.enc.key` so `*.key` catches it. It works,
and it trades a filename that states a fact for one that games a glob.

**The other half, and a correction.** `check_existing` compares an absolute
`PASS_FILE` against a repo-relative `ROOT_DIR`, so after the rename it found the
passphrase present and the key missing and died *"Incomplete root CA"* — refusing
correctly, while advising two things that could not be done: restore the missing
key, which was in `pki/root` and then deleted, and move `ca/root` aside, which
never existed.

This entry first concluded that the message could stand, because the case that
misled it was now unreachable. That was wrong, and it was disproved within the
hour — the very next run hit the same message from the other direction. Deleting
a CA directory without its passphrase leaves exactly the same state, and
[2.3-5](#23-5--the-passphrase-is-generated-not-typed-and-lives-outside-the-repo)
guarantees the two are stored apart and therefore removed apart. A passphrase
outliving its key is not a rename artifact; it is the ordinary residue of
removing a CA.

**So `check_existing` now names it.** Passphrase present with both key and
certificate absent is an *orphaned passphrase*, and the message says to delete
it. That half-state is the only one with an unambiguous remedy — a passphrase
with no key protects nothing, so nothing is lost by removing it. Every other
combination can still destroy something and keeps the conservative generic
message, which does not presume to know which side is the survivor. All four
states were driven through the function to confirm which branch each takes, per
[0.3-7](#03-7--failure-messages-name-the-likely-cause-not-the-symptom).

**Disposition of the orphan:** deleted, not moved into place. The key was minted
2026-08-19 09:47 by a draft of `root-ca-create.sh` that was not finished until
2026-08-20 10:26 — and that commit also edited `root-ca.cnf`. It had signed
nothing, `pki/intermediate/` was empty, and no trust store, leaf or service
referred to it, so a fresh root cost nothing while a preserved one would have
been a trust anchor of uncertain provenance. Its passphrase was deleted with it,
which is what makes the deletion total: an AES-256 key whose only passphrase is
gone is not recoverable by anyone, including us.

---

## 2.4-3 · An existing intermediate is verified against the root, not counted

**Decided:** `check_existing` in `intermediate-ca-create.sh` no longer exits on
finding three files. It calls `openssl verify -CAfile` first, and only reports
*"Using the existing intermediate CA"* if the root **currently on disk** is the
one that signed it.

**The bug:** the guard tested presence — key, certificate, CSR — and any three
files with those names satisfied it. Nothing in an intermediate's filenames says
which root issued it. So after
[2.3-6](#23-6--the-ignore-rule-follows-the-key-not-the-directory) minted a fresh
root, a surviving `ca/intermediate/` would have been adopted by it: the script
reports success, `bootstrap.sh` continues, and every leaf issued afterwards
chains to a root no client has. The failure surfaces phases later as a TLS error
on a certificate that looks perfectly well-formed.

**Why it was reachable at all.** This is the same shape as 2.3-6 one directory
down. There, an ignore rule and the key it protected drifted apart because
nothing tied them together; here, a root and its intermediate drift apart for
exactly the same reason. Both were written as checks on *names*. A name is not
an identity, and the CA already has the primitive that answers properly.

**Rejected:** moving `require_root_ca` above `check_existing`. It looks like the
tidier fix — establish the root before deciding anything about the intermediate —
but it does not actually detect this. `require_root_ca` proves the passphrase
opens the root key; it says nothing about what that root signed. It would also
decrypt the root key on every bootstrap of a healthy host, which the current
order avoids by exiting first.

**Rejected:** comparing the intermediate's `authorityKeyIdentifier` to the root's
`subjectKeyIdentifier`. Cheaper, and correct in the ordinary case, but it
reimplements path validation by hand. `openssl verify` also checks the signature,
the validity dates and `pathlen`, and it is the same code a client will run.

**Rejected:** rebuilding the intermediate automatically on mismatch. Silently
replacing a CA is how a lab loses certificates it still needed. The script says
what is wrong and what to remove; deleting a CA stays a decision a human makes.

**Reads only `root-ca.crt`,** never the key, so the check needs no passphrase and
adds no decryption to a re-run.

**Proven** by minting two roots with **identical subject DNs** — both come from
the same `[ ca_dn ]` block, so only the signature distinguishes them — signing an
intermediate with the first, then swapping the second into place. Accepted before
the swap, refused after, and refused again with the root certificate removed.
A check on names passes that test; this one does not.

**Still open, same function — since closed:** `ca-chain.crt` was not in the
checked set, so an intermediate whose chain file was deleted still reported as
complete and Phase 2.5 would have found no chain to serve. Rebuilt rather than
refused; see [2.4-4](#24-4--a-missing-chain-file-is-rebuilt-not-refused).

---

## 2.4-4 · A missing chain file is rebuilt, not refused

**Decided:** `check_existing` calls `ensure_chain` immediately after
`verify_chain_to_root`. If `ca-chain.crt` is absent, or does not match
`intermediate-ca.crt` and `root-ca.crt` concatenated, it is regenerated and the
operator warned. Closes the gap left open in
[2.4-3](#24-3--an-existing-intermediate-is-verified-against-the-root-not-counted).

**Why rebuild here, when 2.4-3 refuses.** The chain is *derived*. Both its inputs
were verified one line above, so exactly one content is correct and the script
can produce it. A key or a certificate carries information that exists nowhere
else, and refusing is the only safe answer for those. The rule: **refuse when the
artifact holds something unrecoverable, rebuild when it does not.**

**Deliberately not added to the present/missing set.** Putting the chain in that
loop would report a deleted chain as an *"Incomplete intermediate CA"* and send
the operator to delete a working CA over a file that costs two `cat`s to rebuild.

**Compared, not merely existence-checked.** A chain that exists holding the wrong
certificates fails exactly like a missing one and is much harder to see. `cmp`
against the concatenation is the entire test.

**`build_chain` now deletes before it writes.** It leaves the chain `0444`, so
rewriting in place worked only because the script runs as root and root may
ignore the mode — a dependency on privilege where none is needed. It stayed
invisible until a test tried to corrupt the file as an ordinary user and was
refused by the very permission that was hiding it. Deleting first makes a rebuild
depend on the logic instead of on who runs it.

**Proven** with the chain absent, correct, and present-but-wrong at `0444` — the
last as a non-root user, which fails against the old in-place write and passes
now. The correct case leaves the mtime untouched, so a healthy re-run does not
churn the file.

---

## 2.4-5 · Issued leaves live with their consumer, not under `ca/`

**Decided:** `issue-leaf.sh` writes to `docker/proxy/certs/` — the directory the
Phase 2.5 proxy bind-mounts — and never into `ca/`. One flat directory, resolved
from a normalised `REPO_ROOT`.

**Rejected:** `ca/leaf/`, which is the symmetrical-looking answer and was the
first thing proposed.

**Why, heaviest reason first:**

1. **It would falsify [2.3-5](#23-5--the-passphrase-is-generated-not-typed-and-lives-outside-the-repo)
   without editing a word of it.** Everything secret under `ca/` is AES-encrypted
   with its passphrase in `/root`, and that is the entire basis for *"a backup, an
   `rsync`, a VM snapshot or a `git add -f` on a bad day carries the tree and not
   `/root` — an encrypted key with no way in."* A leaf key cannot be encrypted:
   nginx, Vault and CoreDNS start unattended, and a passphrase makes every
   restart a manual step. Store one under `ca/` and that sentence becomes false
   while still sitting there, being read as true.
2. **Opposite postures as siblings.** `ca/root` and `ca/intermediate` are `0700
   root`; a leaf directory must be readable by the service serving it. That pair
   is one `chmod -R` from widening access to the CA itself.
3. **Leaves are retired wholesale at 3.4,** when Vault's PKI engine takes over
   issuance. Kept outside `ca/`, that retirement is a directory delete instead of
   surgery inside the CA — and it keeps teardown's `--keep-ca` unambiguous: keep
   the CA, drop the leaves, with no argument about whether a leaf is part of
   "the CA".

**What `ca/leaf/` would not have bought:** the CA's record of what it issued.
`openssl ca` already archives every certificate into `ca/intermediate/newcerts/`
by serial, with `index.txt` as the register. What `issue-leaf.sh` writes is a
*distribution* copy, and distribution copies belong with the consumer.

**Consistent with the script's own frame.** Its header says the key never moves.
Generated under `ca/` and copied to the proxy, it has moved — and two copies of
an unencrypted private key then exist, with one of them in nobody's cleanup path.

**Accepted cost:** with more than one consumer, certificates scatter across
service directories and `index.txt` becomes the only place holding the whole
picture. That is the correct home for the register, but *"what have I issued?"*
is now a `cat`, not an `ls`.

**Consequences, already applied:**

- `.gitignore` gains `docker/proxy/certs/`, written **before** the directory
  exists — 2.3-6's lesson applied rather than repeated.
- `CA_KEYS` gains a probe path under it, so `make lint` asserts a leaf key cannot
  be committed. Verified by breaking `*.key` and the directory rule separately —
  each alone still covers the key — and then together, where lint fails.
  Redundancy that is tested is redundancy; redundancy that is assumed is one
  rename away from being nothing.
- **`REPO_ROOT` exists because `PKI_DIR` is already `ca/`.** Relative arithmetic
  off it lands back inside `ca/` with one `..` too few, and outside the
  repository with one too many. Both were written while settling this decision,
  and both looked correct on the page — which is the argument for a normalised
  constant over a relative hop, and for `cd`/`pwd` so a path printed by `die`
  reads cleanly.

---

## 0.2-8 · The lab mimics enterprise practice, and names what it is skipping

**Decided:** where a design has a convenient lab answer and a different
real-world answer, take the real-world one. Where the single host genuinely
cannot supply it, build the half that carries the lesson and write down which
half is missing.

**Rejected:** "simplest thing that works, we can do it properly later." Later is
a rewrite, and the instinct built in the meantime is the wrong one — which for a
repository whose stated purpose is learning is the only cost that actually
matters.

**Why:** the shortcut and the real pattern usually cost the same to *write*. They
differ in what they teach. Terminating Vault's TLS at the proxy is one fewer
certificate and one fewer profile; it also makes 3.1's central lesson —
that `VAULT_ADDR` propagates further than any other address in the lab —
unlearnable, because the cleartext hop it warns about is exactly the hop the
shortcut creates. That example stopped being hypothetical: 2.5-1 took the
shortcut anyway and 3.4-1 reversed it, on the grounds this paragraph had already
written down.

**What this does not mean.** Not every enterprise mechanism is in scope. A second
Vault node, an HSM, a real load balancer, SPIFFE — those need hardware or scale
this lab does not have. The rule is not "build all of it"; it is **build the part
that carries the lesson, and state plainly which part is missing** rather than
letting the scaled-down version pass as complete.

**How it shows up in practice — the mapping, kept in one place:**

| Lab does | Enterprise does | What is deferred |
|---|---|---|
| profile table in a bash script | Vault PKI role, ADCS template, ACM PCA template | server-side enforcement of what may be issued |
| one multi-SAN proxy certificate | per-service certificates chosen by SNI | automated issuance, which is 3.4 |
| `issue-leaf.sh` writes to a bind mount | vault-agent / cert-manager / SPIRE deliver | the delivery agent; key still touches disk |
| `tls.crt` / `tls.key` | `tls.crt` / `tls.key` | nothing — `kubernetes.io/tls` mandates these |
| single Vault, terminating its own TLS on `:8200` | NLB doing TCP passthrough to a Vault cluster | the balancing half, and the passthrough tier; no second node and nothing in front (3.4-1) |
| passphrase file in `/root` | HSM, KMS, or Shamir across real holders | see 2.3-3 and 3.1's own honesty note |

**Related:** 2.3-3 already worked this way without naming it — "offline" was
defined as the passphrase rather than pretending an air gap existed. This entry
makes that the standing rule rather than a one-off.

---

## 2.4-6 · `issue-leaf.sh` takes no arguments

> **AMENDED by [3.4-1](#34-1--vault-is-the-issuing-ca-the-openssl-intermediate-issues-exactly-one-certificate).**
> The conclusion holds and the premise does not. "TLS terminates in one place, so
> there is one certificate" is false now that Vault terminates its own; the
> reason there is one certificate is that there is one thing to bootstrap. The
> multi-SAN debt recorded below never accrues — there is a single name — and the
> per-service certificates it defers are what Vault issuing per service *is*.

**Decided:** like `root-ca-create.sh` and `intermediate-ca-create.sh`, this
script takes no arguments. The CN, the SAN list and the destination directory are
constants at the top of the file.

**Rejected:** `issue-leaf.sh <name> [alt-name ...]`, the original skeleton's
shape — a free-form name typed by the operator.

**Rejected:** `issue-leaf.sh <profile>`, an enum selecting one of several named
certificates. This was decided and then reversed within the same session when
2.5-1 put Vault behind the proxy; the reasoning is kept because it is the shape
to return to if a second pre-3.4 consumer ever appears.

**Why:** TLS terminates in exactly one place (2.5-1), so there is exactly one
certificate, carrying every host-tier name as a SAN, read by one consumer. A
value that has one possible answer is a constant, not an argument.

**What taking no argument deletes.** A free-form name is untrusted input and
needs a syntax rule, a check against X.509's 64-character CN bound, lowercase
normalisation so `Test.lab.test` and `test.lab.test` do not become two key files
for one name, and a policy for IP arguments — `DNS:192.168.122.1` is a
syntactically valid SAN that no client will ever match against an IP connection,
so it would pass every check in this script and fail only in a browser. None of
those checks teach anything about the CSR flow, which is what 2.4 is for. An
enum deleted them too, by being exhaustively checked by its own `case`; a
constant deletes the question entirely.

**Enterprise equivalent:** a CA role. Vault PKI roles, AWS Private CA templates
and Microsoft ADCS certificate templates express server-side and *enforce* what
this file states as constants — `allowed_domains`, `max_ttl`, permitted key
usage, whether the requester may specify SANs at all. The client asks for a name;
the CA decides whether it may have it. Closing that gap is precisely what
build-order 3.4 does, which is the strongest argument for not over-building here:
this issuance path is scheduled for deletion.

**The multi-SAN certificate is a deliberate debt.** Enterprise practice is
per-service certificates selected by SNI, not one certificate carrying six names.
nginx and Envoy both hold many certs and choose by the hostname in the handshake.
Multi-SAN is an anti-pattern at scale for two reasons: adding a seventh name
reissues and redeploys the certificate the other six depend on, and one key
compromise is a compromise of every name on it. Taken here because per-service
certificates are only cheap once issuance is automated — which is 3.4 — and six
certificates by hand is busywork rather than learning. Recorded so it reads as a
decision rather than an oversight.

**Reversal trigger:** a consumer that arrives *before* 3.4 and genuinely cannot
sit behind the proxy. There is none now, and after 3.4 there cannot be one. If
one appears, the shape is the rejected enum, not a free-form name.

**Consequences:**

- Filenames follow `kubernetes.io/tls`: `tls.crt`, `tls.key`, plus a `bundle.crt`
  for serving. cert-manager writes exactly `tls.crt`/`tls.key`, so the consumer's
  configuration survives 3.4 unchanged — only the thing writing the files
  changes.
- The SAN list and `lab.test.zone.tmpl`'s A records are one decision. A name in a
  certificate with no A record is a certificate for something unreachable; an A
  record with no SAN is a padlock warning. `proxy`, `test` and `grafana` are
  missing from the zone as of this entry.
- `check_existing` gains a wrinkle the two CA scripts do not have: adding a name
  to the SAN list *must* reissue, and a refusing `check_existing` will not. With
  a multi-SAN certificate that is a routine event, not an exceptional one, so the
  reissue path has to be documented rather than assumed.

---

## 2.5-1 · TLS terminates once, at the proxy — Vault included

> **SUPERSEDED by [3.4-1](#34-1--vault-is-the-issuing-ca-the-openssl-intermediate-issues-exactly-one-certificate).**
> Vault is no longer behind the proxy: it terminates its own TLS on `:8200`, and
> the proxy moves after 3.4 so its certificate comes from Vault. The four
> accepted costs below were the argument against this entry and are now avoided
> rather than accepted. Kept in full because the *reasoning* still applies to
> every service that genuinely does sit behind the proxy, and because the
> passthrough analysis is what 3.4-1 builds on.

**Decided:** one L7 nginx terminates TLS for every host-tier name —
`cloudstack`, `gitea`, `minio`, `grafana` **and `vault`** — routing by Host
header. The hop from proxy to each backend is plain HTTP on the host, which is
the decision build-order 2.5 explicitly asks to be made and written down.

**Rejected:** Vault beside the proxy rather than behind it, holding its own
certificate, with an nginx `stream` block using `ssl_preread` to route
`vault.lab.test` past the L7 server as raw TCP. Decided first, then reversed in
favour of the simpler design.

**Why the simpler design wins here:** it is one certificate, one profile, one
renewal, one port. `issue-leaf.sh` takes no arguments and stays structurally
identical to its two siblings (2.4-6). Phase 2.5 gains no second listener and no
port-ownership shuffle. For a lab whose next milestone is *"`curl --cacert
root.pem https://test.lab.test` succeeds with no `-k`"*, that is a large amount
of machinery deferred for a benefit that is real but not yet load-bearing.

**The argument that does NOT justify passthrough, recorded because it is
tempting and wrong:** that terminating at the proxy puts secrets on the network
in cleartext. It does not. k3s on the backend VM reaches the host over TLS; the
plaintext hop is proxy-to-Vault on a bridge inside one kernel. Anyone reaching
for "otherwise it crosses the VPC in the clear" has the topology wrong.

**Accepted costs, which are real and are being taken knowingly:**

1. **The host is a hypervisor.** That plaintext hop shares a bridge with a
   machine spawning CloudStack guests, so Vault traffic is readable by anything
   on the host that can open a raw socket. Mitigated only by the guests being
   ours.
2. **The proxy sees every token.** nginx holds `X-Vault-Token` in memory on every
   request and is one `log_format` change from holding it on disk. A routing
   component is now also a secret-handling component; its configuration should
   be reviewed in that light, and its access log format is no longer a cosmetic
   choice.
3. **Audit attribution is lost.** 3.3's audit device will name the proxy as the
   client for every request, so the log answers *what was read* and *when* but
   not *by whom* — the one thing that matters after an incident. Recoverable
   later with PROXY protocol or a trusted `X-Forwarded-For`, and 3.3 should
   revisit it rather than discovering it.
4. **Vault's TLS certificate auth method becomes unavailable**, not merely
   unused, for as long as this stands.

**Enterprise equivalent, deferred rather than denied.** A secrets store sits
behind an L4 load balancer doing TCP passthrough, never an L7 proxy doing
termination — HashiCorp's own reference architecture is an NLB in front of Vault
nodes that terminate TLS themselves. Per 0.2-8 the gap is named rather than
pretended: the mechanism is an nginx `stream` block (a top-level context, sibling
of `http`, not inside it) with `ssl_preread on`, which reads the SNI out of the
ClientHello — the one plaintext part of a TLS handshake — and forwards the
connection without holding a key. The official nginx image already ships
`--with-stream_ssl_preread_module`, so adopting it later is configuration, not a
rebuild. The lab could never supply the *balancing* half regardless: one Vault,
nothing to balance across.

**The same shape appears twice more later**, and recognising it is the point:
CloudStack's VPC load balancer (HAProxy on the VPC router) does L4 between tiers
in Phase 4, and Gateway API's `TLSRoute` does SNI-based passthrough to pods that
terminate their own TLS in the cluster.

**Practical trap this creates, same class as 2.5's Gitea `ROOT_URL` war story:**
a service behind a terminating proxy must be told how clients actually reach it.
Vault's `api_addr` has to be `https://vault.lab.test`, not the internal
`http://127.0.0.1:8200`, or cluster redirects and `VAULT_ADDR`-derived links
point at an address no client can use. Same failure mode as the Gitea cookie
loop: not an error, just something that quietly does not work. nginx's default
`proxy_read_timeout` of 60s is the other one — Vault's blocking queries outlive
it.

**Revisit at:** 3.1, when Vault is actually installed and cost 3 becomes
concrete; and 3.3, when the audit device makes the missing attribution visible.

**Open:** how the backend tier reaches the proxy at all. Frontend talks to
backend only through the tunnel VM via wg0/wg1, and the proxy is on the host,
outside the VPC. Either the backend reaches the host directly through the VPC
router — in which case the tunnel is not the only path out, and that should be
explicit — or that traffic traverses the tunnel and is already inside WireGuard,
which would retire accepted cost 1 entirely. Settle before 3.4; it decides
whether `VAULT_ADDR` is routable from the cluster at all.

---

## L-1 · The install transcript is a local file, written by `bootstrap.sh` itself

**Decided:** `bootstrap.sh` redirects its own stdout and stderr through `tee` to
a timestamped file under `/var/log/`, once, before any step runs. Skeleton and
open decisions are `TODO L-1.x` in the script.

**Rejected:** teeing each installer call site. It reads more explicit and it
misses the output that matters — children inherit file descriptors, so one
`exec` at the top captures `ca-install-all.sh`, `coredns-installer.sh` and the
2,700-line vendored CloudStack installer for free. Per-call-site teeing captures
only the scripts we wrote, which are the ones least likely to surprise us.

**Rejected:** `script(1)`. It captures a pty faithfully, including every carriage
return and progress-bar redraw, which is what you want for a demo recording and
not what you want for a file that will be grepped after a failure.

**Rejected:** shipping install-time logs anywhere. See L-3.

**Why:** one run is forty minutes of unattended installation of software we did
not write. Without a transcript the only record is whatever is still in the
scrollback of a terminal that may have been closed — and 1.3-6 already
established that this installer rewrites the host's network under itself, so
"re-run it and watch more carefully" is not always available.

**The traps, all four verified as real before being written down:**

- **ANSI in the file.** `common.sh`'s `log`/`warn`/`die` emit colour. Strip it on
  the *file* branch only. The obvious fix — making `log()` conditional on
  `[[ -t 1 ]]` — **is wrong here**: after the `exec`, stdout is a pipe, so the
  test is false and colour disappears from the terminal as well.
- **Truncation on failure.** Process substitution can outlive the script, so a
  `die` can exit before `tee` flushes — losing the log exactly when it is the
  only thing you have. The `$!` PID must be waited on in an `EXIT` trap.
- **`sed -u`.** Without unbuffered output the tail is lost on a crash, which is
  the same bug wearing different clothes.
- **Unreadable without timestamps.** The vendored installer emits none. `ts`
  (moreutils) is *not* installed on this host, so this is a dependency decision
  rather than a formatting one.

**`set -x` is a separate decision, and it has a security cost.** `BASH_XTRACEFD`
can send trace to the file and never to the terminal, which is genuinely useful
for a post-mortem. But `cloudstack-install.sh:1148` runs
`cloudstack-setup-databases cloud:cloud@localhost --deploy-as=root:`, so trace
puts that credential in a file permanently. The CA scripts are safe — the
passphrase goes `openssl rand > file` and never through an echoed variable — but
the vendored installer is not ours and has not been audited for this. If trace is
enabled, the log file's mode stops being housekeeping and becomes a control.

**Enterprise equivalent:** a configuration-management run produces a structured
run record — an Ansible callback plugin emitting JSON per task, a Terraform plan
artifact — keyed by a run ID and shipped to a collector, with secrets redacted by
the tool rather than by the operator remembering. Per 0.2-8 the gap is named: we
get an unstructured transcript with human-readable timestamps, and redaction is
"do not enable `set -x`" rather than a filter. The run ID exists (the filename);
the structure does not.

---

## L-2 · Runtime logs land in journald, containers included

**Decided:** Docker's log driver is set to `journald` in `/etc/docker/daemon.json`
so container output and systemd unit output share one store, one query tool and
one retention policy. Each compose file sets a `CONTAINER_TAG` so services are
queried by a stable name.

**Rejected:** leaving the default `json-file` driver. It writes to
`/var/lib/docker/containers/<id>/*-json.log` with **no size limit by default**,
so every container log grows without bound. On a host already carrying 22 GB
under `/var/lib/containerd`, that is a disk-fill waiting to happen, and the fix
would be per-container `log-opts` repeated in every compose file — the same
copy-paste drift that `exports.d` avoided in 1.3-5.

**Rejected:** a second log directory per service under `/var/log/`. Two stores
means two retention policies, two rotation configs, and a correlation problem
every time an incident spans a container and a host unit.

**Why journald specifically:** the split is not optional. CloudStack management,
MySQL, libvirtd and NFS are systemd units and are *already* in journald; CoreDNS,
Vault, Gitea and MinIO are containers. Moving the containers is the only way to
get one store. `docker logs` continues to work — journald is one of the drivers
that supports read-back — so nothing in the normal workflow changes.

**Host state as of this entry, which changes what needs doing:** `/var/log/journal`
exists, so the journal is already persistent rather than volatile — 573 MB in
use. But **no retention limits are set at all**; it is running on defaults. A
`/etc/systemd/journald.conf.d/` drop-in with `SystemMaxUse` and `MaxRetentionSec`
follows 1.3-3's numbering convention.

**Vault's audit device is explicitly NOT part of this.** 3.3 turns it on and 13.4
draws the line: operational logs answer *what happened*, audit logs answer *who
did what*. Vault stops serving requests if it cannot write its audit log — that is
deliberate — so pointing it at a shared, rotating sink couples Vault's
availability to a rotation policy written for CoreDNS. It gets its own path and
its own retention.

**Sequencing:** the driver change belongs in the next edit of `daemon.json`, and
must land before Phase 5 — MinIO is the first service that generates log volume
worth the name. `CONTAINER_TAG` is added per compose file as each is written.

---

## L-3 · Nothing ships anywhere until 13.2, and the transcript never ships itself

**Decided:** no log shipper, no collector, no Loki before Phase 13.2. Everything
written under L-1 and L-2 is local and stays local.

**Why — the structural reason, not impatience:** `bootstrap.sh` runs on a bare
host at Phase 0. Loki is Phase 13.2. A transcript that pushed to a collector
would depend on thirteen phases of infrastructure that do not exist while it is
being written, and would fail hardest during exactly the installs whose output
matters most. This is 1.3-6's rule restated: **a record must not depend on the
thing it records.** It is also why the netplan snapshot is a local copy rather
than an object in MinIO.

**Why the syllabus already agrees:** 13.2 specifies a host agent that pushes
*through the cluster Gateway over the WireGuard overlay* — reusing the hop the
web tier already has rather than opening a new one — and that buffers to a
**write-ahead log**, "which is what makes it safe to start before Loki exists".
Both details are load-bearing and neither can be designed now, because the
overlay is Phase 8.3 and the Gateway is Phase 9.5.

**What this buys the earlier phases:** L-1 writes a plain text file with
human-readable timestamps and no invented format, and L-2 puts everything else in
journald. Both are things a Promtail/Alloy-shaped agent ingests as-is. The
decision to defer costs nothing at 13.2 precisely because neither earlier
decision invented a format that would then need converting.

**Accepted cost:** between Phase 0 and Phase 13 there is no cross-service
correlation. Diagnosing something that spans CloudStack and a container means two
`journalctl` invocations and reading timestamps by eye. That is tolerable on one
host with one operator, and it is the cost being deferred rather than avoided.

---

## 3.4-1 · Vault is the issuing CA; the openssl intermediate issues exactly one certificate

**Decided:** the offline root and the openssl intermediate exist to bootstrap one
thing — Vault's own serving certificate. Every other certificate in the lab is
issued by Vault's PKI engine after 3.4. `issue-leaf.sh` issues `vault.lab.test`
and nothing else, and Vault terminates its own TLS on `:8200` rather than sitting
behind the proxy.

**Supersedes [2.5-1](#25-1--tls-terminates-once-at-the-proxy--vault-included).**
Amends [2.4-6](#24-6--issue-leafsh-takes-no-arguments) and
[0.2-8](#02-8--the-lab-mimics-enterprise-practice-and-names-what-it-is-skipping).

**What forced it was the phase order, not taste.** 3.4 lands *before* Gitea
(4.1), MinIO (5.1) and Grafana (13.1). Every one of those can therefore be issued
by Vault. The only names needing a certificate before Vault is a CA were Vault's
own and the proxy's — and deferring the proxy removes the second, leaving the
openssl intermediate with exactly one job. A six-name SAN was issuing
certificates for services that arrive after the thing meant to issue them.

**The old design contradicted three things already written down.** 0.2-8 names
*"terminating Vault's TLS at the proxy"* as its worked example of the shortcut to
reject, because it makes 3.1's central lesson unlearnable — the cleartext hop 3.1
warns about is precisely the hop the shortcut creates. 0.2-8's own mapping table
then describes the lab as doing *"single Vault, TCP passthrough in nginx."*
Build-order 3.1 says *"Vault in a container using a certificate from Phase 2"* —
a container holding a certificate, not a backend behind a terminator. 2.5-1 did
none of those and none of them was updated, so three places said one thing while
the decision said another. That is the failure this file exists to prevent.

**The build order changes in exactly one place.** 2.5 — the reverse proxy — moves
after 3.4, so its certificate comes from Vault:

```
1     CloudStack        creates cloudbr0; UI on http://<bridge>:8080
2.1   CoreDNS           binds the bridge
2.3   root CA
2.4   intermediate  ->  issues ONE leaf: vault.lab.test
2.6   distribute the root
3.1   Vault on :8200, its own certificate
3.4   Vault PKI intermediate, CSR signed by the offline root
----  everything below is issued by Vault  --------------------------
2.5   the proxy
4.1   Gitea    5.1 MinIO    13.1 Grafana
```

2.6 stays in Phase 2: distributing the *root* is independent of who issues
leaves, and the root has to be trusted before Vault's certificate means anything.

**Rejected: Vault first, then CloudStack.** The obvious reading of "bootstrap the
CA service before anything needs it", and impossible here. The vendored installer
rebuilds the host's network underneath itself, converting the NIC into
`cloudbr0` — 1.3-6 snapshots `/etc/netplan` because of it, and 1.3-2 installs a
temporary resolver floor for the window in which DNS does not work. CoreDNS binds
`cloudbr0` and is the one service that cannot take `0.0.0.0`, because
systemd-resolved already holds `:53`. No bridge, no DNS, no name to put in a
certificate. CloudStack being first is a constraint, not an ordering preference.

**Rejected: nginx `stream` + `ssl_preread` fronting Vault on `:443`.** 2.5-1
weighed this against termination and called it machinery. It still is, and it is
now unnecessary: with the proxy arriving after 3.4 nothing contends for `:443`
when Vault comes up. Vault on its own port is simpler than *both* designs 2.5-1
considered — no second listener, no SNI inspection, no port-ownership shuffle.
That third option was never on the table when 2.5-1 was decided.

**`:8200`, and the port in the URL is not the interesting part.**
`VAULT_ADDR=https://vault.lab.test:8200`. 3.1's lesson is that this address
propagates further than any other in the lab — into CI variables, a
`cluster-vars` ConfigMap, and the ClusterSecretStore — so what matters is that it
is a *name*, not whether it carries a port. 8200 is Vault's documented default
and every client already expects it.

**What this buys that the superseded design could not:**

- **3.3's audit device names real clients.** Under termination every request was
  attributed to the proxy, so the log answered *what* and *when* but never *by
  whom* — the one question an audit log exists for.
- **Vault's TLS certificate auth method stays available** rather than being
  structurally unreachable.
- **Nothing but Vault ever holds `X-Vault-Token`.** 2.5-1 accepted nginx holding
  it in memory on every request, one `log_format` change from holding it on disk.
- **After 3.4 Vault issues its own replacement certificate.** The openssl leaf
  becomes a genuine bootstrap artifact: 397 days, one consumer, no successor.

**Accepted costs, and they are real:**

1. **CloudStack's UI is plain HTTP until the proxy exists**, now Phase 3½ rather
   than 2.5. It is a bridge-local port on a single host, and Phase 1 leaves it
   that way regardless — this defers the fix rather than creating the exposure.
2. **2.5's lesson arrives later.** Arguably better placed: "where TLS terminates"
   is chosen with Vault already outside the proxy as the worked counter-example,
   which is the distinction 2.5-1 was reaching for and could not draw while being
   the thing it was arguing against.
3. **Vault binds `0.0.0.0:8200`** per 0.4-1, so it answers on every interface —
   eight on this host, including four Docker bridges and `cloud0`. That cost is
   small for CoreDNS and larger for a secrets store with nothing in front of it.
   Revisit at 3.1 whether Vault is the one service that pins the bridge address;
   0.4-1 records that the reference was already inconsistent here, in exactly
   this direction.

**2.4-6 keeps its conclusion and loses its reasoning.** `issue-leaf.sh` still
takes no arguments, but no longer because "TLS terminates in one place so there
is one certificate" — that premise is now false. The reason is stronger: there is
one certificate because there is one thing to bootstrap. 2.4-6's *reversal
trigger* — a second pre-3.4 consumer — is correspondingly harder to hit, since
the window between the CA existing and Vault taking over is now two phases with
nothing in it.

**2.4-6's multi-SAN debt is retired rather than paid.** The "deliberate debt" of
one certificate carrying six names does not arise: there is one name. Per-service
certificates selected by SNI, which 2.4-6 called the enterprise pattern being
deferred, is what Vault issuing per service *is*.

**`test.lab.test` is deleted.** It existed only as 2.4's acceptance scaffold, and
2.4's check becomes real: `curl --cacert root.pem https://vault.lab.test:8200/v1/sys/health`
against a running service rather than a static page proving nothing but itself.

---

## 3.4-2 · `issue-leaf.sh` does not verify what it just issued

**Decided:** no `verify_leaf`. The script creates the key, the request, the
certificate and the bundle, and stops. The one check worth keeping — does the
leaf still chain to the CA on disk — moves into `check_existing`, where it is
answering a question that can actually have a different answer.

**Written, tested, and then removed**, which is the part worth recording. It
asserted five things: the chain verified, the key matched the certificate, the
bundle carried the intermediate, the SAN held every requested name, and
`basicConstraints` was `CA:FALSE`. All five passed. Three of them *could not have
failed*:

| Assertion | Why it cannot fail here |
|---|---|
| chain verifies | `sign_csr` signed it with that intermediate, moments earlier |
| key matches certificate | the CSR was built from that key |
| bundle carries the intermediate | `build_bundle` is a `cat` of those two files |

A check that cannot fail on the path that produces it is not coverage, it is the
appearance of coverage — and the more of them there are, the more the two look
alike. The remaining two (SAN, `CA:FALSE`) test the *config* rather than the run,
and `2.4-2` already documents what `[ leaf_ext ]` must contain.

**Rejected: keeping it because `root-ca-create.sh` has `verify_root`.** The
symmetry is real and the situations are not. `verify_root` asserts `CA:TRUE` and
`Certificate Sign` on a self-signed root, where the extensions come from a config
section that nothing else exercises and a mistake is silent for twenty years. A
leaf is re-issued every 397 days by a script whose next step is a service that
fails loudly if the certificate is wrong.

**Rejected: keeping the SAN assertion alone.** It was the strongest of the five —
`$ENV::LEAF_SAN` is dereferenced when the config *loads*, so a typo yields a
certificate with no SAN that looks entirely well-formed under `openssl x509
-text`. What retires it is 3.4-1: with one name, a missing SAN is total and
immediate rather than partial and quiet. Under the superseded six-name design
one absent SAN broke one service while five kept working, and *that* is the
failure an assertion earns its place against.

**What must not be lost with it.** `check_existing` still has to ask whether an
existing leaf chains to the intermediate *currently* on disk. That is
[2.4-3](#24-3--an-existing-intermediate-is-verified-against-the-root-not-counted)
one level down, and it is the one question whose answer changes between runs:
re-mint the intermediate and a leaf that "exists" is no longer usable. TODO 2.3
now carries that call, and says plainly that it is the only place the chain is
checked.

**The general rule this is an instance of:** verify at the boundary where state
can have changed, not at the end of the code that just set it. The creation path
is deterministic; the re-run path is not.

---

## 3.4-3 · Mechanics `issue-leaf.sh` no longer explains in place

`issue-leaf.sh` was written as a teaching skeleton and its comments grew to three
times the code. Cut back to the one-line function headers the two CA scripts use,
the same move [2.3-5](#23-5--the-passphrase-is-generated-not-typed-and-lives-outside-the-repo)
made for `root-ca-create.sh`. What the comments carried is recorded here, because
every item below is something openssl accepts in silence.

**The CN and the SAN are coupled by us, not by openssl.** `[ leaf_pol ]` sets
`commonName = supplied`, so a CSR without a CN is refused outright — verified. A
CN that is *absent from the SAN* is accepted without a word, and then rejected by
every client, since none has read CN for identity since roughly 2017. That is why
`sign_csr` builds the SAN by seeding it with `LEAF_CN` and appending
`LEAF_ALT_NAMES`: the rule is structural rather than remembered. `LEAF_CN` is
deliberately absent from the array, because listing it twice yields
`DNS:vault.lab.test` twice, which openssl also accepts without complaint.
`LEAF_ALT_NAMES` stays as an empty array rather than being deleted — it is what
the union iterates, and removing it would make adding a name a change of shape.

**`create_csr` must not load `intermediate-ca.cnf`, for two independent reasons.**
Its `[ req ]` sets `distinguished_name = ca_dn`, whose `commonName` is
`"lab.test Issuing CA"` — the request would name itself the CA. And the file
dereferences `$ENV::CA_DIR` (line 22) and `$ENV::LEAF_SAN` (line 51) when it
*loads*, whether or not the sections holding them are used, so passing it fails
with `variable has no value` unless both are exported. `-subj` alone yields a DN
encoded as `UTF8STRING`, matching what the CA's own `utf8only` produces, so
`[ leaf_pol ]`'s `match` on domainComponent and organizationName is satisfied —
verified rather than assumed. That config belongs to the CA; only `openssl ca`
reads it.

**The SAN is applied at signing, never requested in the CSR.**
`copy_extensions = none` (2.4-1) means the CA discards every extension a request
asks for. A SAN placed in the CSR is dropped in silence and the leaf comes back
with none, while `openssl x509 -text` still looks entirely reasonable.

**Two variables ride on the `openssl ca` command line and both fail quietly.**
`CA_DIR` must be the *intermediate's* directory: point it at the root's and
openssl signs happily, then records the issuance in the wrong CA's `index.txt`
and allocates from the wrong `newcerts/`, with no error. `LEAF_SAN` is openssl's
spelling of the names. Neither is exported, because `$ENV::` expands at config
load and keeping them on the call puts the values beside the file that reads
them. `-extensions leaf_ext` is redundant — `[ intermediate_ca ]` already sets
it — and passed anyway, matching `root-ca-create.sh`: what a certificate is
*allowed to be* should be visible at the call site. No `-days`, because
`default_days = 397` lives in the config where 2.4-2 explains it.

**`require_intermediate_ca`'s required set is read off `[ intermediate_ca ]`, and
`serial` is deliberately not in it.** `rand_serial = yes` means openssl never
reads that file — verified. `index.txt` and `newcerts/` *are* checked, because
openssl's own complaint about a missing database names a path without saying
which step should have created it.

**The leaf key is unencrypted, reversing 2.3-5 on purpose.** Vault starts
unattended; an encrypted key makes every boot a prompt. The CA keys can afford a
passphrase because they are used twice in twenty years by a human. What protects
this one instead: mode `0400 root:root`, two independent `.gitignore` rules that
`make lint` asserts (2.3-6), a 397-day life, and a blast radius of one
certificate. Stated plainly because 2.3-5's *"a copy of the tree carries an
encrypted key and no way in"* stops being true the moment this file exists.

**RSA-4096 is a simplicity choice, not a security one.** 2.3-2's argument was
about a twenty-year trust anchor facing clients of unknown vintage and does not
transfer to a 397-day server key; 2048 would be ample and cheaper per handshake.
Taken for one algorithm and one size across the chain, at a handshake rate where
the difference is unmeasurable.

**`genpkey` creates its output `0600` itself, before any `chmod`, under any
umask** — verified. That is why `create_key` needs no `umask 077` subshell while
the CA scripts' passphrase files do: those are written by a shell redirect, which
obeys umask, and `-out` does not. The directory is `0755` because `tls.crt` and
`bundle.crt` are public and `ca/root`'s `0700` already demonstrated what happens
when a public certificate needs `sudo` to read.

**`LEAF_DIR` is resolved off `REPO_ROOT`, not by a `../` hop off `PKI_DIR`.**
`PKI_DIR` is already `ca/`, so relative arithmetic from it lands back inside `ca/`
with one `..` too few and outside the repository with one too many. Both were
written while settling 2.4-5 and both looked correct on the page.

**`bundle.crt` is leaf + intermediate and is not `ca/intermediate/ca-chain.crt`,**
which is intermediate + root. The first is what a server sends; the second is
what a verifier trusts. The root is excluded deliberately: a client either
already trusts it, in which case sending it changes nothing, or does not, in
which case receiving it does not help. Omitting the *intermediate* is the failure
build-order 2.4 asks you to reproduce — fine in a browser that cached it, broken
in `curl` on a clean machine.

**The CSR is declared with the other paths and deleted by `sign_csr`,** on the
success path only, so a failed signing leaves the request to be inspected.
Transience is expressed by the deletion; the declaration only says where it went.
