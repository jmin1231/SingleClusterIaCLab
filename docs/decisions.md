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

- **Does `bootstrap.sh` disable the host's swap?** — Phase 3.1, and it is the
  real half of a decision already half-made. `disable_mlock = true` is forced
  (3.1-1): the image sets `cap_ipc_lock` on the binary only when running as root,
  and the `user:` pin skips that, so Vault cannot lock its memory and exits at
  startup unless mlock is disabled. That is not "silencing a warning" — it is
  accepting that plaintext secrets can reach disk, and moving the control
  host-side. **This host has 8 GB of swap enabled**, and a fresh Ubuntu VM ships
  with it on. k3s wants swap off at Phase 9 regardless, so the question is
  whether `bootstrap.sh` does it now and records it as the mitigation, or Phase 9
  does it later for an unrelated reason and the gap goes unnamed until then.

- **Which of the installer's in-place edits still cannot be undone once
  `/etc/netplan` is snapshotted?** — settled alongside T-4. The snapshot of
  1.3-6 covers netplan, `libvirtd.conf` and the `/etc/default` files. What it
  does not cover is anything *appended* to a file that also has legitimate
  non-lab content: `NEED_STATD=yes` in `/etc/default/nfs-common` (installer line
  1343) and `LIBVIRTD_ARGS="--listen"` in `/etc/default/libvirtd` (line 1425)
  are both appended only when absent, so a present one cannot be attributed.
  Sentinel comments around every appended block would settle it; whether that is
  worth patching the vendored installer for is the open part.

- **There is no reverse DNS anywhere in the lab.** — Phase 2.1 owns the zone;
  14.0-1 is what made the absence matter. `lab.test.zone.tmpl` is A records only,
  CoreDNS serves no `in-addr.arpa` zone, and `network-plan.md` does not mention
  PTR records at all. Nothing has needed them yet, which is exactly why it went
  unnoticed: forward-only DNS is invisible until something does a reverse lookup
  and compares the answer.

  Kerberos is that something, and it is not the only one. Service principals are
  derived from hostnames, and a mismatched or absent PTR surfaces as an error
  naming the *principal*, so the search starts in Kerberos and the fault is in
  DNS. Outside Kerberos: `sshd`'s `UseDNS`, some TLS clients logging peer names,
  and mail-shaped software all do it. Settle it if 14.0-1 is ever built, and
  record it now either way — a range nothing configures is the same class of
  problem 0.4's "derived" rows exist for.

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
not just the key fetch — but it reverses [0.4-2](#04-2--cloudstack-creates-the-bridge-we-verify-rather-than-configure) and moves real work back
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

> **AMENDED by [L-4](#l-4--l-1-as-built--four-corrections-to-the-note).** Built, and
> three of the notes below were wrong in ways only building found: where the
> redirect goes, which tool timestamps, and that `tee` is not the writer.

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

> **No longer implemented.** `bootstrap.sh` no longer sets Docker's journald
> log driver — see L-7. Containers use the default `json-file`, so
> `journalctl -t <name>` does not work and an agent discovers files instead.

> **AMENDED by [L-5](#l-5--journald-retention-as-built-and-three-findings).** The
> premise below — "no retention limits are set at all" — is true of the config and
> false of the behaviour. Defaults are a 4G cap. Two other findings there.

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

---

## 3.1-1 · A leaf key is written locked; its consumer's installer opens it

**Decided:** `issue-leaf.sh` writes `tls.key` as `0400 root:root` and stops.
`vault-installer.sh` sets ownership before starting the container, in one step
covering both the certificate directory and the storage directory. Group, not
owner: `chown root:<gid>` with `0440`. The UID/GID is pinned in
`docker-compose.yml` as well, so the number the installer chowns to is one the
repository controls.

**Rejected:** `chown` in `issue-leaf.sh`. It is the shorter fix and it puts a
consumer's UID inside a CA script — which would then need a second one for MinIO
at 5.1, a third for whatever follows, and an edit in `ca/` every time a container
image changes its user.

**Rejected:** running the container as root. It makes the symptom vanish by
removing the reason it existed.

**Rejected:** `0444`. World-readable is not a permission model, it is the absence
of one, and this is the first unencrypted private key in the repository (2.4-5).

**The mechanics, because the failure gives no hint of them.** A bind mount is not
a copy — the container sees the same inode, same owner, same mode. And Linux
compares **numbers**, not names: the container's `/etc/passwd` calls uid 100
"vault" and the host's calls it something else, and the kernel reads neither when
deciding `open()`. A process at uid 100 opening a `0400` file owned by uid 0
matches no owner bit, no group bit, and `---` for other. `EACCES`.

**Where it lands, and why that matters:** Vault fails while **loading its
listener**, not while initialising storage. That is earlier than the
bind-mount-ownership failure 3.1 warns about, and it means `operator init` never
runs — so the symptom the syllabus tells you to expect never appears. Meanwhile
`ls -l` on the host shows a root-owned `0400` private key, which is exactly what
a private key is supposed to look like. Everything reads as correct.

**Why group rather than owner.** Owner carries the right to `chmod`, so `chown`
to Vault's UID would let a compromised Vault rewrite its own key and certificate.
Group-read is the minimum that works. `:ro` on the mount does defend this today,
but that is a compose-level promise a later edit can drop, and the file mode is
the layer that does not depend on remembering.

**Amended at implementation — group is the WRONG answer on this host, and the
reason is the same fact this entry is built on.** Group-read has to be gid 1000,
because that is the container's group. On this host `getent group 1000` is
**`user`** — the interactive login account. So widening the group is not a
smaller grant than widening the owner; it is a much larger one, handing a human
account Vault's TLS private key.

The correct form is `chown 100:1000` with mode **0400** — uid 100 as owner, no
group bits at all. The only reader is then `dhcpcd`, a system account with
`/bin/false` for a shell, and gid 1000 meaning `user` stops mattering because the
group bits grant nothing. Same for the storage directory at 0700.

The cost accepted is the one this entry originally rejected: Vault owns the file
and could `chmod` it. That is blocked by the `:ro` mount, and it is a smaller
risk than a readable private key. Worth stating why the original reasoning was
wrong rather than deleting it — it was right about ownership carrying `chmod`,
and wrong to assume "group" is always the narrower grant. **Whether it is depends
entirely on what that gid means on the host**, which is the same "only the number
is real" point the mechanics paragraph above makes, arriving from the other side.

MinIO at 5.1 inherits this: check what its gid resolves to on the host before
reusing the pattern, rather than copying the numbers.

**Amended again, and this one supersedes the arithmetic above: Vault does not run
as the image's UID at all.** `user: "65100:65100"`, and the bind mounts are
chowned to match.

The previous two versions of this entry both asked "given uid 100 and gid 1000,
which door do we open?" — and both answers were host-dependent, because the
question was. Checked against the stock `ubuntu:24.04` image: **the highest
assigned system uid in a fresh install is 42** (`_apt`). Ubuntu reserves 0-99 for
static accounts and **100-999 for dynamic allocation at package-install time**,
so on a fresh VM that whole range is empty and uid 100 is claimed by whichever
package `bootstrap.sh` installs first — in an order apt does not guarantee.

Two consequences, and the second is the one that decided this:

1. "Who else can read `tls.key`?" has a different answer on every host, and on
   this one it happened to be `dhcpcd` — which is why the earlier reasoning
   sounded conclusive and was not.
2. **The answer can change after the chown.** If uid 100 is still free when
   `start_vault` runs, a package installed later is assigned it and inherits read
   access to Vault's private key. Nothing warns, because the chown already
   succeeded and still looks correct.

**65100 is outside every allocator's range** — above the human range, below
`nobody` (65534), and not in 100-999. No account maps to it, on this host or any
other, so nothing can be that UID except the process we tell to be it. The
question the two earlier amendments were arguing about stops existing.

**Vault does not need its image UID.** Every path it writes is a bind mount we
own and chown; `/vault/logs` is neither mounted nor used. Pinning `user:` already
skipped the entrypoint's root-gated chown and setcap, so nothing in the image
expects to be 100. This is the OpenShift arbitrary-UID pattern named in the
enterprise note above — an image that works as any UID, given ownership it can
use — applied on purpose rather than discovered.

**What survives from the earlier reasoning:** ownership is still pinned rather
than discovered, still duplicated in exactly two places that must agree
(`VAULT_UID`/`VAULT_GID` and compose's `user:`), and the `getent` check in
`start_vault` is now a much stronger signal — a hit means something genuinely
unexpected has claimed 65100, rather than "a package was installed".

**Confirmed on the first real run.** Vault starts cleanly as a UID the image
never heard of: `docker inspect -f '{{.Config.User}}' vault` reports
`65100:65100` and `id` inside the container agrees, with the bind mounts chowned
to match. The reasoning above — the entrypoint's root-gated chown and setcap are
skipped by pinning `user:`, and every path Vault writes is a mount we own — held.

**And the `getent` guard this entry describes is now real.** It was written up
here before it was written down in code, and `start_vault` asserted nothing for
several phases. It exists as of 5.1, added when `minio-installer.sh` needed the
same check and the claim was found to be untrue. The lesson is the one 2.3-6
already recorded from the other direction: a rule that lives only in prose is a
rule nothing enforces.

**MinIO at 5.1 inherits the pattern, not the number** — pick another reserved-range
UID for it rather than reusing 65100, so the two services cannot read each other's
material.

**Enterprise equivalent:** this is a gap in Compose rather than a lab shortcut.
Kubernetes solves it with `fsGroup` — the kubelet chowns the volume's group to
the pod's `fsGroup` and applies setgid, which is precisely the fix above,
automated and declared by the *consumer*. That is the design being copied: the
pod declares the ownership it needs and the issuer never knows who reads its
output. Further along, the file stops existing on the host at all — cert-manager
writes a Secret mounted as tmpfs, or a vault-agent sidecar templates it into a
shared volume as the same UID as the app, or SPIFFE/SPIRE hands the workload an
SVID over a socket. Per 0.2-8, what is skipped is the delivery mechanism; the
ownership model is the real one.

**Worth knowing, because it inverts the problem:** OpenShift assigns each
namespace an arbitrary UID and runs containers as it, so images must work as
*any* user. The convention that makes that possible is files owned by `root:0`
with group permissions, because an arbitrary UID is always placed in gid 0. A
lab that establishes "group, not owner" now produces images that survive that
platform; one that chowns to a fixed UID does not.

**Verified against the image rather than argued from memory** — `hashicorp/vault:2.0.4`,
pulled apart through the registry API because the docker socket was unreadable:

- `/etc/passwd` says `vault:x:100:1000`, so `user: "100:1000"` is the real pair.
- `Cmd` is `["server", "-dev"]`. The dev-mode risk is a fact, not a caution.
- The image declares `/vault/config`, `/vault/file`, `/vault/logs`.

**And the entrypoint changes the shape of this decision.** It contains a chown
block covering `/vault/config`, `/vault/logs` and `/vault/file` — gated on
`[ "$(id -u)" != '0' ]`, so it runs only when PID 1 is root, after which it
`su-exec`s down to vault. Two things follow:

1. **It never touches `/vault/certs`.** That directory is not in its list, so the
   certificate problem this entry exists for is unsolved by the image on *either*
   path. Nothing about pinning the user made it worse.
2. **Pinning the user turns off the storage half too.** With `user: "100:1000"`
   the chown block is skipped, so `/vault/file` also becomes the host's problem.
   That is accepted deliberately: it makes ownership one step in
   `vault-installer.sh` covering both directories, rather than one directory
   handled by the host and another by a container briefly running as root. The
   rejected alternative — dropping `user:` and letting the entrypoint do it — is
   the "container fixes its own permissions using root" pattern that `fsGroup`
   exists to replace, and it would still leave the certs.

**One consequence reaches into `vault.hcl`, and was not anticipated.** The same
root gate wraps `setcap cap_ipc_lock=+ep` on the vault binary. `cap_add:
IPC_LOCK` grants the *container* the capability, but a non-root process needs the
*file* capability to exercise it, and only root can set that. So with the user
pinned, mlock cannot work and Vault exits at startup unless `disable_mlock = true`.
That makes compose's `user:` and `vault.hcl`'s `disable_mlock` one decision
(TODO 1.6), and moves the real mitigation host-side: **this host has 8 GB of swap
enabled**, and disabling it is what actually keeps key material off disk.

**Consequences:**

- The rule generalises without touching `ca/`: MinIO at 5.1 has the same problem
  with a different number and solves it in its own installer.
- It survives 3.4. When Vault's PKI engine replaces `issue-leaf.sh` as the writer,
  the consumer-side ownership logic is already where it belongs — only the
  producer changes.
- `docker-compose.yml` must pin `user:` explicitly rather than inheriting the
  image's. An image update that changes the UID would otherwise leave the chown
  correct and the container unable to read anything, with no diff to explain it.
- This is a fourth reason for 2.4-5's "leaves live with their consumer", and the
  only one that is functional rather than organisational — the other three were
  about encryption posture, directory modes, and retirement at 3.4.

---

## 3.1-2 · Vault's listener is not a decision; publishing is

**Decided:** `config/vault.hcl` is a committed file, not a template. Its listener
is `0.0.0.0:8200`. Compose publishes on the bridge only —
`${CLOUDBR0_IP}:8200:8200` — with `.env` generated by `vault-installer.sh`, the
same arrangement `docker/coredns` already uses.

**The part that was never a choice.** Vault binds inside the container's network
namespace, where the cloudbr0 address does not exist on any interface. Binding it
there is impossible rather than unwise, so `0.0.0.0` is the only value the
listener can take. TODO 1.3 read as a question about `vault.hcl` for as long as
the two layers were conflated; it is a question about `ports:`.

**Which settles whether the file is a template.** `listener` is fixed, `api_addr`
is a name, `storage` is a container path, `disable_mlock` follows from 3.1-1 —
nothing varies per host, so a `.tmpl`, a `render_config` step for it, and a
gitignore rule would be machinery in exchange for nothing. `render_config` still
exists; it writes `.env`. The per-host artifact moved to where the per-host
decision is.

**Rejected:** publishing on `0.0.0.0`, which is what 0.4-1 decided for services
generally. Kept as the rule; Vault is the exception, and 0.4-1 named its own
accepted cost in terms that stop applying here — "services answer on every
interface — eight on this host... on an isolated single-host lab that is
acceptable." Acceptable for a UI or an artifact store. Not for the service that
holds every credential in the lab and becomes its CA at 3.4. 0.4-1 also records
the reference being inconsistent in this direction, and it was inconsistent the
right way: `VAULT_BIND_IP` exists there and `bootstrap.sh` sets it to cloudbr0.

**Why cloudbr0 rather than loopback:** the k3s cluster on the backend VM reaches
Vault for the ClusterSecretStore. cloudbr0 is that path. Pinning drops the four
Docker bridges and `cloud0` and keeps the one interface that is actually used.

**What it costs:** `docker compose up` by hand now needs `.env` to exist, so the
installer has to have run. Already true of CoreDNS, so the pattern and its cost
are established rather than new.

**A consequence found while writing this, which would have surfaced as an unseal
failure.** `VAULT_ADDR=https://127.0.0.1:8200` cannot work: the certificate names
`vault.lab.test`, and TLS verifies the name, not the socket. Two fixes, both
needed:

- `VAULT_ADDR=https://vault.lab.test:8200` with an `extra_hosts` entry mapping
  that name to `127.0.0.1`, so traffic stays on loopback while the name matches.
- `VAULT_CACERT` — the container trusts nothing of ours. `bundle.crt` is leaf +
  intermediate and verifies nothing; **a client needs the root**. `issue-leaf.sh`
  now writes it alongside as `ca.crt`, which is the third key of a
  `kubernetes.io/tls` secret and exactly what cert-manager will write at 3.4.

The general shape: a serving bundle and a trust bundle are different files with
different contents, and reaching for the wrong one fails at verification rather
than at load — 2.4's lesson, arriving from the client side.

---

## 3.1-3 · Two tiers of credential, and there is no master password file

**Decided:** exactly one file-based credential store exists in this lab —
`docker/vault/secrets/`, holding only what is needed to *open* Vault. Every other
credential in the lab lives in Vault's KV store, written by `ensure`-style
scripts (3.6). The number of files in tier 1 is a design constraint, not an
accident of what has been built so far.

**Rejected:** one file listing every service's username and password. It is the
obvious thing to want, and it is a secrets store implemented as a text file —
the anti-pattern build-order 13.1 names as what started this whole line of work.
Building Vault and then keeping a parallel copy of everything beside it means
maintaining two stores, of which only one is audited, versioned, policy-controlled
and revocable.

**Tier 1 — cannot live in Vault, because it opens Vault:**

- the unseal key
- the root token

That is the whole list, and the fact that it is two items is the point. Anything
added here is a credential *not* protected by the thing built to protect
credentials. If this grows, something upstream is wrong.

**Tier 2 — everything else, in Vault KV**, and the syllabus already schedules it:
CloudStack's API key at 3.6, Gitea and MinIO and the CI role at 5.4, authentik's
bootstrap admin at 14.1 — that last one stated in build-order as "seeded into
Vault via your `ensure` pattern". So the file holding every credential *is* Vault.

**Where Vault's own admin userpass is created: 3.2, not 3.1.** 3.1 has no
policies, so an admin created there could only be bound to `root` — which is not
an admin account but a second root token with a password: long-lived,
interactive, and strictly worse than the token that already exists. 3.2 is where
policies arrive, and a userpass admin bound to a real one belongs with them.
`vault-installer.sh` therefore stays four steps.

That credential also has a short life. 14.3 puts Vault behind OIDC, after which
local userpass is break-glass rather than a daily login — worth knowing before
investing in it.

**Generated, not typed** — 2.3-5's rule, transferred unchanged. `openssl rand`.
Prefer `-hex` over `-base64` for anything that will be pasted into a URL or a
shell one-liner: base64's `/` and `+` cost more in escaping than the entropy
difference is worth.

**Usernames are not generated.** A username is an identity, not a secret: it is
readable from Vault's own API to anyone already authenticated, and 14.x replaces
it with an authentik identity regardless. Randomising it costs a lookup at every
login and buys obscurity rather than a control — the control against guessing is
Vault's built-in `user_lockout`. Rejected deliberately, because it is the kind of
thing that looks like security and is not.

**Write-once and rotatable material go in separate files.** The unseal key and
root token can never be regenerated; an admin password is routine to rotate. In
one file, every rotation rewrites the file holding the irreplaceable thing, and
the whole Vault is one bad redirect away from unrecoverable. This settles the
format half of `vault-installer.sh` TODO 3.3: `operator init -format=json` into
its own file, mode 0400, and nothing else ever appended to it.

**Rejected:** keeping the reference lab's arrangement. Its `docker/vault/.env` is
committed, describes itself as "portable across machines", and contains
`VAULT_ADMIN_USER=admin` / `VAULT_ADMIN_PASS=password`. Three separate problems in
two lines — a credential in Git, a credential in a file that also holds
configuration, and a default that survives to production because nothing forces
the change.

---

## 3.1-4 · Vault restarts automatically and comes back sealed; unsealing is its own script

**Decided:** `restart: unless-stopped`, matching CoreDNS. Unsealing is a separate
script, `vault-unseal.sh`, called by `vault-installer.sh` and runnable by hand.

**Rejected:** `restart: "no"`, so that a restart is noticed immediately rather
than presenting as a running-but-useless Vault.

**Why the trap is real, and taken anyway.** Seal and unseal are not stop and
start. A restarted Vault is running, listening, and answers every request with
503 — `docker ps` says healthy, the port accepts connections, and the first
symptom is some other service failing to read a secret. `unless-stopped` on a
stateless service like CoreDNS is self-healing; on Vault it is half-healing, and
the half it does is the half that looks fine.

Taken because the alternative is worse in the way that matters. `restart: "no"`
means a host reboot leaves Vault *down*, and a down Vault is only marginally more
diagnosable than a sealed one — while costing availability on every restart that
would otherwise have recovered on its own. Coming back sealed is a state we can
detect and fix in one command; not coming back at all is a state that needs a
person.

**What makes it acceptable is the separate script**, and this is the load-bearing
half of the decision. Unsealing being its own executable means:

- it runs on every bootstrap, because unsealing an unsealed Vault is a no-op
- it runs after a reboot, by hand or from a unit, without re-running an installer
  that would also try to `operator init`
- it is the same command in a 15.x recovery drill as in normal operation, which
  is the property that makes a drill worth practising

An unseal step buried inside the installer has none of those. It would only ever
execute as part of a full install, which is exactly when it is least needed.

**Consequence: step 3's output format becomes an interface.** A hand-runnable
unsealer has to locate and read the unseal key itself, so the path and the format
are now a contract between two scripts rather than a private detail of one. That
settles the remaining half of `vault-installer.sh` TODO 3.3 in favour of
`operator init -format=json`: a consumer running `jq -r '.unseal_keys_b64[0]'` is
reading a documented structure, while one parsing the human-readable output is
guessing at text that exists to be read by a person.

**Open, for 15.x:** whether a systemd unit runs the unseal script at boot. That
would make the lab self-recovering and would also mean the unseal key is read
automatically by an unattended process — which is most of the way to not having
a seal at all. Worth deciding as a security posture rather than as a convenience,
and 3.1's own honesty note about `-key-shares=1` is the right frame for it.

---

## 3.1-5 · Storage is integrated raft, chosen for the backup story

**Decided:** `storage "raft"` at `/vault/data`, `node_id = "vault-1"`.

**Rejected:** the `file` backend, which is simpler, has no cluster machinery, and
can never accidentally become a cluster.

**Why — and it is not the clustering.** For one node, raft's consensus is
inert: quorum is 1, the node elects itself, every write commits as soon as it
reaches local disk. What raft actually buys here is
`vault operator raft snapshot save` and its matching `restore` — online,
consistent, one file. That exists because log compaction is part of the
algorithm, not because someone added a backup feature.

The file backend's equivalent is "stop Vault and tar a directory". There is no
snapshot primitive and no consistency guarantee across files if you copy it
live. Phase 15.1 backs up everything stateful and this is the first item in that
category, so the difference is the whole decision. `vault-installer.sh` TODO 1.5
asked for what a backup means before choosing; this is that answer.

**What it costs for one node:** a `node_id`, a `cluster_addr`, a second bound
port (8201, nothing published until there is a peer), and an `fsync` per commit.
All negligible at lab volume.

**What it teaches, which is a real second reason.** k3s's embedded datastore is
**etcd, which is also raft** — same terms, same quorum arithmetic, same
odd-node rule. Phase 9.2 adds two agents and meets quorum for real; having seen
the algorithm somewhere it cannot hurt you is worth the config stanza.

**A consequence that closed an argument elsewhere:** `/vault/data` is **not** one
of the three directories the image's entrypoint chowns even when running as root
— that list is `/vault/config`, `/vault/logs`, `/vault/file`. So storage
ownership is the host's job regardless of the `user:` pin, which removed the last
reason to consider dropping the pin. See 3.1-1.

---

## 14.0-1 · Directory services are a third identity plane, and the lab has none

**Not scheduled.** This entry settles the *shape* of the thing and where it would
go, so that the gap is a decision rather than an oversight. Building it is gated
on the resource question below.

**Decided, and it is the part worth having in writing: authentik is not a
directory service.** authentik and Keycloak are OIDC/SAML providers for
*applications* — browser SSO into Grafana, Gitea, the CloudStack UI. They have no
KDC, no machine enrolment, no host keytabs. A VM cannot be joined to authentik.
Phase 14 is called "Identity" and delivers one plane of three:

| Plane | Principal → resource | Mechanism | Phase |
|---|---|---|---|
| Application SSO | humans → apps | OIDC / SAML | 14, authentik |
| Workload identity | services → secrets, PKI | AppRole, k8s auth | 3.x, 11.x, Vault |
| **Host identity** | **humans + machines → hosts** | **LDAP + Kerberos** | **absent** |

The third is what Active Directory is, and what FreeIPA or a Samba AD DC would
supply. Today the tier VMs have local accounts reached over SSH keys placed by
Ansible: no central account, no central sudo policy, and no answer to "who may
log into the backend tier" other than who holds a key.

**What Active Directory actually bundles**, because conflating these is where the
confusion starts: an LDAP directory (users, groups, computers), a Kerberos KDC
(tickets, SSO), DNS (clients discover controllers through `SRV` records), and
Group Policy. Optionally ADCS for PKI. What makes it a *domain* rather than a
directory is that **machines get identities too** — the same idea as an AppRole
or a ServiceAccount, one layer down.

**What "realm join" means concretely.** The host gets a principal —
`host/backend.lab.test@LAB.TEST` — and a keytab at `/etc/krb5.keytab` proving it.
After that: `id alice` resolves with no local account, `ssh alice@backend`
authenticates against the KDC rather than `/etc/shadow`, one `kinit` gives SSO to
every joined host over GSSAPI, sudo rules come from the directory, and HBAC can
express which humans reach which tier — which is a genuinely interesting thing to
have given the frontend/tunnel/backend split already exists.

**Decided, if built: FreeIPA with `--no-ca`, on its own VM, at 14.0.**

- **`--no-ca`.** FreeIPA ships Dogtag, its own CA, and 3.4-1 has already made
  Vault the issuing CA. The alternative — `--external-ca`, chaining Dogtag to the
  offline root as a *third* sibling intermediate — works and is defensible, and
  it means two issuing CAs to reason about for no lesson that 3.4 does not
  already teach. Dropping Dogtag also removes roughly 1 GB and a JVM.
- **Its own VM, not a container on the host.** FreeIPA expects systemd, and a
  domain controller running on the hypervisor is not how anyone deploys one. It
  also does not package for Ubuntu — it is RHEL-family — so this host cannot run
  the server regardless. A Rocky or Fedora guest in the zone is both the workable
  option and the realistic one. Samba AD DC is the alternative that *does* run
  here and speaks AD's own protocols, at under 1 GB.
- **14.0, before authentik.** Phase 14's preamble already assumes clocks are
  synchronised and TLS is universal, which is most of the prerequisite. It also
  puts the two planes side by side, where the distinction is easiest to see, and
  authentik can federate against the directory rather than duplicating it.

**Rejected as the primary answer, but recorded because it is the cheap version:**
authentik's LDAP outpost serving POSIX attributes, consumed by SSSD on the tier
VMs. That buys central users, groups and sudo for about zero extra memory, from a
component already being built. What it skips is Kerberos — no tickets, no SSO, no
host keytabs, no GSSAPI. Per 0.2-8 that gap is named rather than papered over:
**LDAP is the directory, Kerberos is the authentication, and the pair is what a
domain means.** The cheap version teaches nsswitch, PAM and SSSD; it does not
teach why a domain differs from a user database.

**Four obstacles, all real:**

1. **`SRV` records.** Clients find the KDC through `_kerberos._udp.lab.test`,
   `_ldap._tcp.lab.test`, `_kpasswd._udp`. The zone is A records only. Addable —
   we own it — but FreeIPA normally wants to run DNS itself, so the choice is
   between adding the records by hand and delegating a subdomain to it.
2. **Reverse DNS does not exist.** See the open question above. Kerberos derives
   service principals from hostnames and reverse-resolves; a missing PTR fails
   with an error naming the principal, so the search starts in the wrong place.
3. **Time stops being hygiene.** Kerberos rejects tickets outside five minutes of
   skew. 0.3 already installs chrony and build-order already warns the clock will
   return "with certificates, JWTs and SAML assertions" — Kerberos belongs on
   that list and is the least forgiving item on it.
4. **Memory, which is what gates this.** Baseline is ~20 GB; agents and authentik
   put it near 28. FreeIPA without Dogtag is 1.5–2 GB and pushes past the
   ceiling. So this needs a stop-order line in `resource-budget.md` before it
   needs a single line of code, and the honest options are a Samba AD DC instead,
   or accepting that 14.0 and 14.1 never run at the same time.

**Why record an unscheduled phase at all.** Because "the lab has no host identity"
currently reads as a thing nobody thought of, and it is not — it is a plane that
costs 2 GB against a hard ceiling, on a host that cannot run the server anyway.
That is a decision, and 0.2-8 says name what is being skipped rather than let the
scaled-down version pass as complete.

---

## L-4 · L-1 as built — four corrections to the note

**Built** as `start_transcript` / `close_transcript` in `bootstrap.sh`. The shape
L-1 described survived; four of its details did not.

**1. The redirect does not go "before any step runs".** L-1.1 said file scope.
That places it above `require_root`, so a non-root invocation dies on
`install: cannot create '/var/log/lab': Permission denied` instead of the
readable `bootstrap.sh must be run as root: sudo ./bootstrap.sh`. It is called
from `main()` immediately after `require_root` instead. The cost is that the
root check itself is not in the transcript, which is acceptable — that failure
is immediate and on the terminal.

**2. `tee` is not the writer, and `tee >(…)` would have been a bug.** The
obvious build is `exec > >(tee >(strip >>"$LOG"))` — `tee` to the terminal,
nested substitution to the file. It is wrong: `$!` is the *outer* process, so
`close_transcript` could only wait for `tee` while the inner stripper was still
draining — reintroducing precisely the truncation L-1.3 exists to prevent.

The build instead saves the terminal on **fd 3** and uses one substitution
containing a pipeline. A pipeline's subshell waits for all its members, so the
single `wait "$TRANSCRIPT_PID"` covers everything.

**3. `ts` was the wrong dependency question.** L-1.5 framed it as moreutils'
`ts` versus `awk`/`strftime`. Both are wrong: `ts` is not installed, and
`strftime` is a **gawk extension**. `awk` on the development host is gawk, so it
worked — but a fresh Ubuntu defaults to **mawk**, and this would have been a
fresh-VM failure discovered on the machine it was written to serve.

Bash's `printf '%(%Y-%m-%dT%H:%M:%SZ)T'` is a builtin: no package, and no fork
per line across a forty-minute install. `TZ=UTC` is exported inside the
subshell only, so nothing else in the run sees a changed timezone.

**4. `set -x` is decided NO, and that decides the mode.** `cloudstack-install.sh:1148`
runs `cloudstack-setup-databases cloud:cloud@localhost`; trace would put that
credential in a file permanently, and the vendored installer has not been
audited for others. Recorded as a decision so it reads as a control. Because it
is off, L-1.4's `0640 root:adm` is convention rather than a control — `adm` is
the Debian log-reader group (`/var/log/syslog` is `640 syslog:adm`) and the
primary user is in it, so reading a transcript needs no `sudo`.

**Also settled:** `/var/log/lab/bootstrap-<UTC>.log`, newest 20 kept, swept by
the script that writes them — a logrotate drop-in would be a second mechanism
for one concern. Filenames sort chronologically, so retention orders by name
rather than mtime, which a copy or a restore would rewrite.

**Verified, not assumed:** without the `EXIT` trap the file was empty at the
moment the parent exited and filled a second later; with it, complete. A failing
run exits 1 with the `die` message in the file.

---

## L-5 · journald retention as built, and three findings

> **No longer implemented.** `bootstrap.sh` no longer writes the journald
> drop-in — see L-7. Retention is whatever Ubuntu ships, and the host has no
> configured local sink to fall back on.

**Built** as `configure_journald`, writing `/etc/systemd/journald.conf.d/10-lab.conf`
with `Storage=persistent`, `SystemMaxUse=2G`, `SystemKeepFree=20G`,
`MaxRetentionSec=1month`.

**Finding 1 — L-2's premise is wrong.** It says "no retention limits are set at
all", which reads as unbounded growth. The defaults are a **4G size cap with no
time cap**: `SystemMaxUse` and `SystemKeepFree` are each a percentage of the
filesystem *capped at 4G*, so a 457 GB disk and a 200 GB disk produce the same
4G. The journal was never going to fill the disk. What it could never do is tell
you how many days it holds — so this file buys **predictable history, not disk
safety**. That changes what the change is for.

**Finding 2 — persistence is inherited, not configured.** `Storage=auto` means
"persistent if `/var/log/journal` exists, volatile otherwise — the existence of
the directory controls the storage mode". Nothing guarantees that directory: no
package owns it (`dpkg -S` finds nothing) and the tmpfiles rule is `z`
(adjust-if-present), not `d` (create). On a fresh VM it is a coin flip, and
losing it is silent — a volatile journald ignores every `System*` key, because
`Runtime*` governs volatile storage, and the whole install history goes at the
first reboot. `Storage=persistent` is the line that earns the file.

**Finding 3 — `SystemKeepFree`'s default protects the wrong party.** It reserves
space for everything that is *not* the journal. 4G free on a 200 GB disk shared
with CloudStack primary and secondary storage, Docker images and containerd
describes a lab that has already failed. Sized at 20G against what CloudStack
needs, not what journald would like.

**`MaxRetentionSec=1month` is aligned deliberately** with logrotate's
`rotate 4, weekly` for `/var/log/syslog`. Two stores whose horizons would
otherwise drift; this is the cheapest coordination available and it is not
coincidence.

**`ForwardToSyslog` is left as Ubuntu ships it.** The distro drop-in
`/usr/lib/systemd/journald.conf.d/syslog.conf` sets it to `yes` with rsyslog
active, so every entry is already on disk twice — the two-store arrangement L-2
rejected on design grounds *without noticing the distro had already chosen it*.
Measured before deciding: **~20 MB/month and 4 MB of rsyslog memory**, neither
worth acting on against 200 GB. Masking it would also empty `/var/log/auth.log`,
where sshd, sudo and su land and where fail2ban and CIS-shaped checks look. Per
0.2-8 the deviation is named rather than left to read as an oversight.

**REVISIT when the Docker log driver lands.** Container output then gets
forwarded too, and CoreDNS's `log` plugin logs every query — thousands a minute
during an image pull. 20 MB/month is not the steady state after that.

**And the reversal does not work the obvious way.** `ForwardToSyslog=no` in
`10-lab.conf` is ignored: drop-ins sort by **filename across all four search
directories**, not by directory precedence, so `syslog.conf` sorts after
`10-lab.conf` and wins from `/usr/lib`. `/etc` outranks `/usr/lib` only when the
two files share a name — which is the documented fix: symlink
`/etc/systemd/journald.conf.d/syslog.conf` to `/dev/null`. Same trap as 1.3-3,
direction reversed: 1.3-3 warned that a high number can outrank what should
replace it; here no number is high enough.

**Two assertions, because they fail differently.** The first greps journald's
own log for *our file's path* — systemd's parser names the offending file in
every complaint, so silence is success and the check does not depend on error
wording upstream can reword. The second checks `/var/log/journal` exists, which
is the outcome the first cannot see: a file can parse perfectly and still leave
storage volatile.

**A trap worth recording from writing that first assertion.** It was briefly
`journalctl … | grep -qF "$path"`. Under `set -o pipefail` that **fails open**:
`grep -q` exits on first match, the producer takes `SIGPIPE`, and the pipeline
reports failure — so the `if` reads false *on a match* and the assertion never
fires. It is a race on output length, so it passes on a quiet host. Capture into
a variable and test with a here-string.


---

## 2.5-2 · The proxy terminates TLS for what cannot, and refuses everything else

**Decided:** one nginx at the edge, routing by Host header, holding certificates
issued by Vault's PKI engine. CloudStack and Gitea sit behind it; **Vault does
not** (3.4-1). Built after 3.4 rather than in Phase 2, so its certificate comes
from Vault rather than from `issue-leaf.sh`.

**Why a proxy at all, since Vault proves a service can terminate its own TLS:**
CloudStack cannot, usefully. Its management UI is plain HTTP on `:8080` with no
HTTPS listener, and giving it one means Tomcat keystore configuration inside a
vendored installer we drive rather than maintain (1.1). Until this existed, the
admin password crossed `cloudbr0` in clear text on every login. That is the
whole justification; the rest is convenience.

The convenience is real at the second service, though: five names will want
certificates, and at the PKI role's TTL that is one renewal job and one reload
mechanism instead of five.

**Rejected: letting the first `server` block be the default.** nginx silently
promotes the first block on an address to `default_server`, so with one vhost the
proxy answered for **every** name that resolved to the host — measured:
`vault.lab.test`, `minio.lab.test` and `gitea.lab.test` all returned CloudStack's
application, presented with CloudStack's certificate. A name mismatch is only a
warning, and warnings get clicked through. That is how `https://vault.lab.test/`
— no port, so `:443` — appeared to "redirect to CloudStack".

An explicit default server with `ssl_reject_handshake on` now refuses at the TLS
layer: no certificate is offered at all, so an unknown name fails to *connect*
rather than failing to *validate*. Verified — unknown names return curl exit 35
and `no peer certificate available`.

**Accepted cost, stated rather than discovered:** the hop behind the proxy is
unencrypted. Fine over a loopback bridge on one host; not fine at Phase 7 when
the tiers are real VMs on real networks. That is why 2.5 says to decide where TLS
terminates rather than let it happen.

**The operational trap, hit twice.** nginx reads its configuration once at start,
and `docker compose up -d` leaves a running container alone when the compose spec
has not changed. So a re-rendered vhost or a reissued certificate sits on disk,
visible inside the container, ignored. Both times the symptom pointed elsewhere —
`nginx -t` passed, the config was correct, the certificates were correct. The
installer now runs `nginx -s reload` after `nginx -t` passes: validate first, so
a bad configuration can never take the proxy down. This is exactly the incident
3.5 names — *"the certificate renewed but the site serves the old one"* — met
before 3.5 was built.

---

## 3.4-4 · Vault as the issuing CA, as built

**Decided:** `ca/scripts/sign-vault-intermediate.sh` is a **filter** — CSR on
stdin, certificate on stdout, diagnostics on stderr — and it is a separate script
because it is the only step in the PKI flow that needs the offline root's
passphrase. That keeps `grep -rl root-ca.pass ca/` an honest answer to "what can
use the crown jewel", and the filter shape is what an air gap looks like if this
ever moves to its own host (2.3-3).

Its caller, `docker/vault/scripts/vault-configure.sh`, owns re-runnability: it
skips provisioning when the `pki` mount already has a signing issuer **whose
certificate chains to our root** — not merely when the mount exists. A mount can
exist with no issuer, and an issuer can chain somewhere else; both pass a weaker
check and both leave the lab unable to issue anything trusted.

**`match` is unsatisfiable for a Vault CSR on EVERY field, for two independent
reasons.** This is why `[ vault_intermediate_pol ]` exists alongside
`intermediate_pol` rather than replacing it:

1. Vault's PKI engine has no `domainComponent` parameter at all. Its DN
   vocabulary is `common_name`, `organization`, `ou`, `country`, `locality`,
   `province`, `street_address`, `postal_code`, `serial_number` — and nothing
   else. `match` on a field the requester cannot emit is unsatisfiable, not
   merely unmet.
2. `match` compares the ASN.1 **string type**, not just the characters.
   `root-ca.cnf` sets `string_mask = utf8only`, so the root's DN is
   `UTF8String`; Vault uses Go's `crypto/x509`, which emits `PrintableString`
   whenever the characters allow. The failure reads *"The organizationName field
   is different between CA certificate (SingleClusterIaCLab) and the request
   (SingleClusterIaCLab)"* — two identical strings declared different, with no
   mention of encoding.

Re-encoding the CSR is not a way out: the subject is covered by the CSR's own
self-signature, and re-signing needs the private key, which never leaves Vault.

**Rejected: one relaxed policy for both producers.** Tried, then reverted. It
would have given up `organizationName = match` on `openssl req`-generated CSRs,
where it still works, to accommodate a producer that cannot meet it on any field.

**What actually constrains Vault is not the DN policy.** It is
`intermediate_ca_ext` with `copy_extensions = none`: whatever the CSR requests is
discarded and the root stamps `CA:true, pathlen:0`. Vault gets exactly the
authority the root decides to give it and can never mint a sub-CA — which matters
more here than for the openssl intermediate, because Vault holds that key
**online for the rest of the lab's life**.

**Two `openssl ca` behaviours found by trying, both now load-bearing:**

- **It exits 0 when it REFUSES a CSR whose self-signature does not verify.** No
  certificate written, no `index.txt` row, exit **0**. A *policy* failure exits 1;
  a *signature* failure does not. So `|| die` cannot be trusted alone, and the
  only reliable evidence of signing is output existing. That single
  `[[ -s "${CRT_FILE}" ]]` is the one hand-rolled check in the script, and it is
  the one that fired on a real failure.
- **It prepends a human-readable dump before the PEM** unless given `-notext` —
  5579 bytes instead of 1545, starting with `Certificate:`. Harmless in a file a
  human reads; corruption for a script whose stdout *is* the certificate.

**Rejected: a preflight, and a CSR inspection step.** Both were written and both
were removed. openssl already reports a missing CA file, a bad DN and an
unverifiable signature better than a hand-rolled check does — measured, every
case exits 1 naming the path. What survived is only what nothing else covers:
`[[ ! -t 0 ]]`, because with no stdin the script hangs silently and openssl is
never reached.

**Accepted hole, named per 0.2-8:** openssl does not check key strength. A
1024-bit CSR signs into a valid `CA:true, pathlen:0` certificate that chains and
verifies. That is narrow here — the CSR comes from our own `vault-configure.sh`
with `key_bits=4096` — so reaching it means editing that value, not feeding the
script something hostile. Revisit if this ever signs a CSR produced outside this
repo.

**And a gap re-keying leaves behind.** Disabling and re-provisioning the `pki`
mount mints a new intermediate; the superseded one stays marked `V` in
`ca/root/index.txt` with its private key destroyed. The database then claims a
certificate is valid that nobody can use. Revoking it is a manual step, not
automated: the script cannot distinguish "superseded" from "still in use
elsewhere", which is the same ambiguity that kept a duplicate-subject check out of
the signer.

---

## 3.6-1 · Two directions for a secret, and why neither rotates

**Decided:** every credential is either **captured** into Vault or **generated**
in it, chosen per secret and written down. Both directions are `ensure`-shaped:
create if absent, leave alone if present, never rotate silently.

| Direction | Origin | Example |
|---|---|---|
| **capture** | the service mints it | CloudStack's API key |
| **generate** | Vault is the origin, the service is told | Gitea's admin and database passwords |

**The trap, made concrete.** `cloudmonkey-install.sh` called
`registerUserKeys` unconditionally, and `registerUserKeys` is not a read — it
mints new keys and invalidates the old ones. Calling it twice silently rotated a
live credential. On this host it would have done real damage immediately:
`~/.cmk/config` carried **no** api key and authenticated by password, while
CloudStack already held an 86-character key from an earlier run. The old code
would have destroyed it to fix a problem that did not exist.

`getUserKeys` is the read that makes capture possible, and it is why 3.6's wording
is *"generates **or captures**"*. The function is now split by what it does:
`capture_` (read-only, returns 1 when there are none — a normal first-run state,
not a failure), `register_` (rotates, and warns that it does), and `ensure_`
(capture first, register only when there is nothing to capture).

**Four states, and only one is "do nothing":**

| Vault | far side | action |
|---|---|---|
| empty | has a credential | capture |
| empty | has none | generate or register |
| holds it | matches | **already present** |
| holds it | **differs** | **refuse** |

**The fourth is the one worth the paragraph.** CloudStack's admin account is
recreated whenever its database is redeployed, which invalidates the stored key
while Vault goes on serving it happily — every consumer then fails with a 401
that says nothing about the cause. The script refuses rather than fixing it: it
cannot tell a rebuild from a key someone else is still using, and rotating on a
guess has a blast radius. The error names the reseed path, because a refusal
without one is just a wall.

**Generate-direction secrets have no fourth state**, and that asymmetry is the
point. Gitea does not exist when `vault-ensure-gitea.sh` first runs — that is why
it runs first — so there is nothing to compare against and "present" is the whole
check.

---

## 4.1-1 · Gitea's credentials are generated in Vault before Gitea exists

**Decided:** `vault-ensure-gitea.sh` generates the database and admin passwords
in Vault, and `gitea-installer.sh` reads them back out. Nothing is typed into a
setup form, and no default exists anywhere — the compose file has no fallback
values, only `${VAR:?}` that fails loudly if the `.env` was not rendered.

**Rejected:** the reference lab's arrangement, which takes its admin password
from a committed `.env` default. A default password in a repository is a password
in the repository.

**Why generate rather than capture here:** Gitea has nothing to capture at
install time. Running the generator *first* is what makes the credential exist
before the service that uses it, which is the same ordering argument the whole
build order rests on.

**`ROOT_URL` is `https://` only because the proxy genuinely terminates TLS.**
2.5's war story is the reference lab setting it to `http` with the comment that an
`https` ROOT_URL marks cookies `Secure` and the HTTP login silently loops. That
setting is not right or wrong in itself — it is correct here *because* the thing
in front of Gitea really does serve HTTPS, and it would be wrong the moment that
stopped being true.

**The admin user is create-if-missing, not ensure-matches.** Gitea will not read a
password back after creation, so there is nothing to compare against — the same
limitation that makes its API tokens uncapturable, which 4.1 flags and 4.2 will
have to answer.

---

## 1.2-2 · `admin` is break-glass; automation gets its own CloudStack account

**Decided:** `admin` keeps its account and role, moves off its shipped
`admin`/`password` to a generated secret in Vault, and is used by **nothing
automated**. A separate account, `svc-terraform`, carries the credentials
Terraform will use at 7.1.

**The model is AWS's root account, and it transfers operationally but not
structurally.** AWS root is special: it cannot be deleted, cannot be restricted by
any policy, and can do things no IAM user can — so its compromise is both
unbounded and unmitigable. CloudStack's `admin` is none of that; it is a normal
user in a normal account with a normal role, closer to AWS's *first IAM admin*
than to root. What transfers is the discipline: **the identity you cannot afford
to lose is not the identity you work as.**

**Rejected: disabling `admin`.** There is exactly one other user. Disabling the
only fallback before the replacement is proven means recovery through MySQL
directly, and the gain over an `admin` whose password is a 48-character
Vault-held secret is small on a single host. `admin` is instead what 14.5's
break-glass drill is *about*. A break-glass account at its factory default is not
break-glass, which is the whole content of the rotation.

**`createAccount`, not `createUser`** — and this is the part that is easy to get
wrong. The **role lives on the account**, and so do resource ownership and
event-log attribution. A user created inside `admin`'s account would be a second
key to the same identity, not a separate one, and 13.4 calls CloudStack's event
log *"the only record of changes to the zone"*.

**Root Admin for now, narrowed at 7.1.** Scoping the role before the consumer
exists means guessing which APIs Terraform calls; being wrong surfaces as a
permission failure part-way through an apply. So today this buys **attribution
and habit, not least privilege** — and the honest reason to build it now rather
than at 7.1 is that once Terraform is configured with `admin`'s key, changing it
later is a task nobody prioritises. That is how AWS accounts end up still using
root keys.

**Write Vault before CloudStack, always.** The two failure modes are not
symmetric: CloudStack-first loses the password entirely if the write then fails —
it would exist only in a dead shell, and the UI would be locked. Vault-first
leaves Vault holding a password CloudStack has not accepted, which is recoverable
with `vault kv delete` and a re-run. Every `die` on that path names the command.

**Credentials never reach `argv`.** `cmk update user password=…` would put the new
password on a command line visible to every user via `ps` (2.3-5). Both the login
and the `updateUser` call go through the HTTP API with `curl --data @-`, so the
credential travels in the request body — the same rule that moved `vault-unseal.sh`
off Vault's CLI.

**Two CloudStack behaviours found by hitting them:**

- **`listall=true` is required to see another account's users, even as Root
  Admin.** `list users` defaults to the caller's own account, so the lookup
  returned nothing for a user that plainly existed and the script concluded
  `createAccount` had lied.
- **`login` returns `.loginresponse` on failure too**, carrying `errorcode: 531`
  instead of a session key. "Did a response come back" is not "did it work" —
  assert on `.loginresponse.sessionkey`, which exists only on success. Getting
  this wrong made a working password change look like a no-op.

**Left at its default deliberately:** nothing else. This was the last credential
in the lab still shipping as documented.

---

## 0.2-9 · `lib/vault.sh`, factored on drift rather than on count

**Decided:** `vault_()`, `vault_authenticate()`, `vault_field()` and
`new_password()` live in `lib/vault.sh`, sourced by the six scripts that talk to
Vault. Separate from `lib/common.sh` because `ca/` and `cloudstack/` never talk to
Vault, and a helper they cannot use does not belong in the file they all source.

**What forced it was not the sixth caller.** 0.2-5 allows repetition and names two
triggers; this was the second one — *"the guard logic needs to change in more than
one place at once."* The six `vault_()` bodies were identical, but the six
`authenticate()` bodies had **six different hashes**, and two of them —
`gitea-installer.sh` and `proxy-installer.sh` — had no `vault status` check. A
sealed Vault therefore produced empty reads and an error naming the wrong script:
it sent you to seed a secret that was already there, when the answer was to
unseal. Verified after factoring: both now report *"Vault is not answering, or is
sealed"* against a genuinely sealed Vault.

`new_password()` had the same shape rather than the same size. Two callers, the
same non-obvious choice — hex rather than base64, because these values land in
PostgreSQL connection strings, URL form bodies and environment variables where
`+` and `/` are meaningful — and the reasoning recorded in only one of them. The
other looked like an arbitrary command someone could have "improved".

**The lib locates Vault from its own position, not the caller's.** The six callers
sit at four different depths and each carried its own relative path to the same
compose file; moving `docker/vault/` would have broken them one at a time.
`_VAULT_LIB_DIR` is underscore-prefixed for a reason this repo has already paid
for once: **sourcing another of its scripts clobbers `SOURCE_SCRIPT`**, because
the sourced file sets it from its own `BASH_SOURCE[0]`. Every path defined after
that source resolves under the wrong directory, and the symptom is a `die` naming
a path that never existed.

**`vault-unseal.sh` deliberately does not use it.** `vault_authenticate()` dies
when Vault is sealed, which is exactly when that script must work. Its header
already claimed to be self-contained; this is what makes that concrete rather than
incidental.

**Precedent worth keeping:** the same morning, five identical `[[ -x ]] || die`
guards in `bootstrap.sh` hit 0.2-5's *count* trigger. Factoring them into a
`run_script()` helper was the obvious move and would have been the worse one —
reading the sibling all-in-one scripts first turned up a stronger answer, a single
validation loop at file scope that fails **before anything runs**. Waiting until
duplication causes something has now twice produced a better abstraction than
acting on the count.

---

## L-6 · Loki runs in the backend tier; Alloy runs on both sides; Wazuh is rejected on budget

> **Superseded by L-7** on placement and budget. Its rejection of Wazuh still
> stands; what changed is that both of its premises were removed from
> `bootstrap.sh`.

**Decided:** at 13.2, Loki runs **inside the backend tier** in single-binary mode
with filesystem storage (~0.5 GB, already in the budget). Alloy runs in **two**
places: one in k3s for pod logs (~0.15 GB, budgeted) and one **on the host VM**
scraping journald (~0.15 GB, *not* previously budgeted — the Control plane line
goes ~1.5 → ~1.65 GB). Wazuh is not deployed.

Extends [L-3](#l-3--nothing-ships-anywhere-until-132-and-the-transcript-never-ships-itself),
which deferred shipping without saying where the collector would live.

**The host agent is nearly free because of [L-2](#l-2--runtime-logs-land-in-journald-containers-included).**
Docker's `log-driver: journald` with `tag: {{.Name}}` already puts Vault, Gitea,
CoreDNS and the proxy in journald. One Alloy scraping journald therefore collects
the bootstrap transcript *and* every container with no per-container
configuration. Had the containers been left on `json-file`, this would have meant
a file-discovery config per service — the second time L-2 has paid for itself.

**journald stays the host's primary sink, not a way-station.** Loki lives in the
backend tier, and the backend tier is a thing that can fail — at which point Loki
is where you would look to find out why. The 2 GB `SystemMaxUse` cap
([L-5](#l-5--journald-retention-as-built-and-three-findings)) means host-side
forensics survive losing the cluster. Ship *and* retain; never ship *and* forget.
This is [1.3-6](#13-6--etcnetplan-is-snapshotted-whole-before-the-installer-runs) again: a record must not depend on the thing it records.

**Rejected: Wazuh, on arithmetic rather than merit.** The agent/server split is
the right shape and the agents are cheap (~100 MB each). The server stack is not:
the indexer is an OpenSearch fork wanting ~4 GB on its own. The backend tier is
5 GB *in total* and already allocated, so a Wazuh server there evicts Prometheus,
Loki, Grafana and Kyverno to run one scanner. On the host it takes ~4 GB from a
2 GB reserve. Neither is a tuning problem, and
[rule 4](resource-budget.md) already establishes that even the ~2 GB monitoring
stack cannot coexist with authentik.

**The escape hatch, named so it is not rediscovered:** a Wazuh server on the
*development host* (125 GB) with agents reporting outward is architecturally
clean and is how it would really be done. It is rejected because the lab must be
runnable on a fresh VM ([T-3](#t-3--a-fresh-vm-is-assumed-so-nothing-records-what-was-installed)), and this would make it depend on
something outside itself. Revisit only if that requirement is dropped.

**What replaces it, and what is genuinely lost.** Trivy at build time gates the
template; `unattended-upgrades` baked into the image handles drift afterwards;
`apt list --upgradable` as a Prometheus textfile metric (~0 MB) answers "which
VMs have pending security updates" on the Grafana already being built. That is
most of Wazuh's vulnerability value at zero residency. **Not** covered: file
integrity monitoring, and CIS/SCA benchmark scoring. Those are real gaps and are
recorded here as gaps rather than quietly treated as covered — per
[0.2-8](#02-8--the-lab-mimics-enterprise-practice-and-names-what-it-is-skipping).

---

## 4.3-1 · The toolbox image is built on this host and never published

`toolbox-installer.sh` builds `toolbox:latest` on the machine that runs jobs.
Nothing pushes it to Gitea's registry, and nothing pulls it.

**The reason is a loop, not a preference.** The toolbox is the image every
pipeline job runs *inside*. A pipeline that builds and pushes it would need it to
already exist. So the first toolbox image can never come from CI — it has to be
built out of band. That is not a lab shortcut: hosted runners work the same way,
with the runner image provisioned alongside the host rather than pulled by the
first job. Building locally is therefore the seed step that a registry-based flow
would still need underneath it.

**Rejected, for now: push to Gitea and pull at job time.** It is the better
end state — an immutable tag, a digest a job can cite, and an image that
[4.6](build-order.md)'s scan gate actually covers. It is rejected *here* because
it drags [9.3](build-order.md)'s work into Phase 4: the daemon that starts job
containers would need registry trust configured, and 9.3's own warning is that
registry trust "has to exist in three places or this fails in ways that look like
workflow bugs". Phase 4's job is a working isolated runner. Debugging that and
registry trust at once means two unfamiliar failure modes that present
identically.

**This constrains 4.4, which is why it is written down now.** 4.4 forbids
mounting the host Docker socket. That matters here: with the socket mounted, the
daemon that starts jobs is the host daemon and already holds this image. A DinD
service has its own image store and will not see it. So whatever isolation 4.4
picks has to answer "how does the image get to the daemon that runs jobs" — by
seeding it (`docker save` piped to `docker load`, or a shared image volume), or
by accepting the registry work above. The choice cannot be deferred past 4.4.

**One footgun, named so it is not met at 2am.** `force_pull: true` against an
unqualified tag like `toolbox:latest` resolves to `docker.io/library/toolbox` and
goes to Docker Hub. The reference lab sets `force_pull: false` for exactly this
reason. The day this does move to a registry, the label must carry the fully
qualified name.

**What is skipped, per
[0.2-8](#02-8--the-lab-mimics-enterprise-practice-and-names-what-it-is-skipping).**
Provenance: no job can prove which toolbox it ran in, because a local tag is
mutable and there is no digest to cite. And 4.6's scan-before-push gate never
applies to this image, since it is never pushed — trivy can still be pointed at
it locally, but nothing enforces that. Both are real gaps, recorded as gaps.

## 4.3-2 · No multi-stage build, on measurement

The Dockerfile carried a TODO to split into a builder stage that downloads and
verifies and a final stage that copies out the binaries. Measured, then dropped.

**The premise was wrong.** It assumed the downloaded archives were sitting in
layers. They are not: every tool's `RUN` downloads, checksums, installs and
deletes within one layer, so no archive is ever committed. The only thing a
builder stage would actually remove is three apt packages — curl 523 KB, unzip
375 KB, gnupg 509 KB, about 1.4 MB together.

**Against what stays:** vault 537 MB, terraform 117 MB, packer 108 MB, qemu and
git around 80 MB. Under one percent, in an image whose size is one large binary
and a decision no build topology changes. `curl` is also plausibly wanted at job
time, so removing it is not free.

**Revisit if** the image is ever published ([4.3-1](#43-1--the-toolbox-image-is-built-on-this-host-and-never-published)),
where pull time starts costing something on every runner, or if a builder-only
dependency turns large enough to matter on its own.

## 4.4-1 · The runner keeps the host socket; jobs get a rootless dind instead

**Decided:** act_runner mounts `/var/run/docker.sock` and creates job containers
on the host daemon. `container.docker_host: "-"` in `runner/config.yaml` stops
that socket being mounted *into* those containers. Jobs that need a daemon —
6.1's image builds — get `docker:dind-rootless` on the `ci` network, reached
through `DOCKER_HOST` injected by `runner.envs`.

**What this closes.** The reference lab leaves `docker_host: ""`, the default,
which mounts the host socket into every job container; its `docker-ci` then runs
`docker login`, `build`, `push` and `run` against the host daemon. A pull request
that edits a workflow file can add `docker run --privileged -v /:/host` and has
root on the hypervisor. One line, no exploit. Its `privileged: false` and
`valid_volumes: []` read as mitigations but are not: the socket arrives through
the runner's own mount, not through a workflow-requested volume, so restricting
what workflows may ask for does not touch it.

**The deviation, named rather than presented as compliance.** Build-order 4.4
says *"Register a runner that does not mount the host Docker socket."* This
runner does. All three of its **done-when** criteria are met — a job runs,
`docker ps` inside it lists dind's containers rather than the host's, and a job
can open `/dev/kvm` — but the runner process itself retains host root.

**Rejected: full DinD**, with act_runner pointed at dind and the host socket
mounted nowhere. It satisfies the sentence literally and is the better end state.
Rejected on two costs that are concrete rather than aesthetic:

- `/dev/kvm` would have to nest — passed into the dind container, then permitted
  again by its device cgroup for each job container. 4.4 already calls that
  passthrough harder than it looks; this is the version that does it twice.
- `toolbox:latest` would have to be seeded into dind's image store and kept
  there across restarts. Keeping job containers on the host daemon answers
  [4.3-1](#43-1--the-toolbox-image-is-built-on-this-host-and-never-published)'s
  open question — *how does the image reach the daemon that runs jobs* — with
  "it is already there".

**Rejected: ephemeral one-shot runners.** They solve the *other* problem 4.4
names — a persistent runner carrying the previous job's secrets and caches into
the next — and nothing about socket exposure. They compose with this design
rather than replacing it, and are not built.

**What is skipped, per
[0.2-8](#02-8--the-lab-mimics-enterprise-practice-and-names-what-it-is-skipping).**
Two residuals, both real:

- *The runner process holds host root.* The boundary is now act_runner's own
  correctness — that it honours `docker_host: "-"` and `valid_volumes: []`. A bug
  there, or a later config edit that looks harmless, reopens the path this
  entry exists to close.
- *dind's container is privileged, and `dockerd` inside it runs as root.* The
  rootless variant was built first and does not run on this host: Ubuntu 24.04
  ships `kernel.apparmor_restrict_unprivileged_userns=1`, and RootlessKit needs
  exactly the user namespace that blocks — it failed `fork/exec /proc/self/exe:
  operation not permitted` in a restart loop. `privileged: true` does not help,
  because privileged sets AppArmor to *unconfined*, which is what the
  restriction targets, while the entrypoint drops to uid 1000 and so holds no
  `CAP_SYS_ADMIN` to be exempted by.

  Disabling that sysctl host-wide was rejected: it trades a broad protection on
  the hypervisor for one container's isolation. So the honest position is that a
  job which compromises `dockerd` — rather than merely using it — holds root in
  a privileged container, which is escapable. This is the weakest point in 4.4
  and it is not mitigated, only bounded by the network the daemon sits on.

  **The fix is to stop needing a daemon.** Rootless BuildKit builds images
  without `--privileged` and without a user namespace, so the restriction above
  does not apply to it. At 6.1 that is the recommended path rather than an
  option, because it is the only one that lowers this privilege.

Job containers reach `gitea` to clone and `dind` to build. They are not attached
to the network Postgres is on, so Gitea's database is not merely unauthenticated
to them — it is unreachable.

**The way out, named so it is not rediscovered:** stop needing a daemon at all.
Rootless BuildKit builds images without `--privileged`, which removes the one
privileged container in the lab. The cost is workflows using `docker buildx
--driver remote` rather than plain `docker build`, plus reworking `docker push`
and `docker login`. Revisit at 6.1, when those workflows are written and the
cost is visible.

---

## 9.1-1 · Cilium replaces flannel, for observability rather than for features

**Decided:** k3s installs with `--flannel-backend=none --disable-network-policy`
and Cilium provides pod networking and NetworkPolicy enforcement. Chosen at 9.1
because a CNI cannot be swapped afterwards without rebuilding the cluster.

**What this buys, and it is one thing.** k3s's default flannel plus its
kube-router-based policy controller already *enforce* NetworkPolicy correctly.
They are not wrong; they are silent. A denied packet produces no event, no log
line and no counter, so a policy that is broken and a policy that is working
look the same from outside. Cilium's Hubble makes the drop visible — you watch
the verdict rather than infer it from a timeout. 9.6 is the step that needs
that, and without it 9.6 degrades into curling a port and believing the result.

**The cost is a budget cost, not a complexity one.** The agent runs on every
node, and 9.2's agents are sized at ~1 GB because 0.5 rule 3 says there is no
6 GB to give them. A few hundred megabytes of CNI on a 1 GB node is a large
fraction of that node. This is the first component in the plan whose per-node
cost is chosen before it is measured, so 9.1's *done-when* requires writing the
measured figure into the budget rather than trusting this entry.

**Rejected: Calico — held as the fallback rather than dismissed.** Mature,
lighter per node, `GlobalNetworkPolicy` covers what this lab needs, and its
rule-level logging is a real answer to the observability problem, just a
coarser one than a live flow view. If the measurement at 9.1 says Cilium does
not fit, Calico is the next thing to try, and neither choice changes anything
above Phase 9.

**Rejected: keeping flannel and the built-in controller.** Free, already there,
and enforces policy properly. It is the right answer for a lab that wants
segmentation to *work*, and the wrong one for a lab that wants to *see* it. If
both alternatives above fail on budget, this is where it lands — and 9.6's
*done-when* has to be weakened to say so, rather than left claiming a
verification that cannot be performed.

**Where this connects.** 7.2 builds deny-by-default ACLs on the CloudStack VPC
tiers; 9.6 builds deny-by-default NetworkPolicy on the pods inside them. Same
three tiers, two enforcement points, two different rule models — ordered and
first-match on the VPC, allow-only and additive in Kubernetes. Whichever sits
closer to the packet is the one that refuses it, which is why the two have to be
read together rather than assumed to agree.

---

## L-7 · Loki moves to the host; kube-prometheus-stack keeps the cluster

**Decided:** metrics and logs split across the boundary deliberately.
**kube-prometheus-stack** runs in k3s in the backend tier and owns every metric,
including the VMs' via node-exporter. **Loki** runs **on the host**, single-binary
with filesystem storage, as another host service in the pattern already there — a
compose stack, a Vault-issued certificate, a CoreDNS name, a proxy vhost.
**Alloy** runs on the host, on each provisioned VM, and as a DaemonSet in k3s.
Everything pushes to Loki.

**Why L-6 no longer holds.** It put Loki in the backend tier and rested on two
things since removed from `bootstrap.sh`: L-2's journald log driver, which made the
host agent nearly free because every container was already in the journal, and
L-5's journald retention, which was the host's durable sink when the cluster was
the thing that failed. Without them, keeping Loki inside the cluster leaves the
only log store living in the thing whose failures you need logs to diagnose.
Moving it to the host restores 1.3-6 — *a record must not depend on the thing it
records* — by a different route: not a second copy on the host, but the store
itself outside the cluster.

**Push out, pull in, and they need opposite rules.** Alloy pushes to Loki, so no VM
needs an inbound path. Prometheus scrapes, so it needs 9100 inbound on every VM
from the backend tier. Under 7.2's deny-by-default ACLs that is the awkward half —
the cluster reaching back into all three tiers. Write the log rules first; they go
one direction and they work.

**What it costs, as arithmetic rather than a shrug.** The backend tier drops 0.5 GB
and is resized 5.1 → 4.6. The host gains 0.5 GB, and Alloy on the frontend and
tunnel tiers adds 0.3 GB never previously budgeted. Net **+0.3 GB against a budget
with no headroom**, taking the lab to ~16.3 of 16. `resource-budget.md` names three
ways to close it; dropping Alloy on the tunnel tier is cheapest and loses least —
it routes, and its journal is sshd and WireGuard.

**The trade accepted rather than discovered later.** Grafana ships inside
kube-prometheus-stack, so it dies with the cluster while Loki does not. The logs
survive; the UI for reading them does not. `logcli` is the answer, and 13.2's *Done
when* now requires proving it with the cluster stopped. A second Grafana on the
host was rejected: real memory, in a budget already over, for a rare case that has
a working CLI.

**Unchanged from L-6:** Wazuh stays rejected on the same arithmetic. Loki stays
single-binary on filesystem storage — the scalable mode wants object storage, and
although MinIO exists, that is a Phase 5 dependency this does not need.

---

## S-1 · Five cuts, to make the lab fit and to shorten it

**Decided:** five things leave the plan. Together they remove ~3.9 GB and eleven
steps, and take the budget from 0.3 GB over to ~15.9 GB of 16.

| Cut | Saves | Depended on by |
|---|---|---|
| Phase 14, identity (6 steps) | ~2.0 GB | nothing |
| Kyverno + signature admission (11.3, 11.4) | ~0.4 GB | nothing |
| The two-tier openssl CA (2.3, 2.4) | 0 GB, ~858 lines | 3.4, rewritten |
| MinIO (5.1) | ~0.3 GB, 424 lines | 5.2, rewritten |
| Default multi-node k3s (9.2) | ~1.5 GB | nothing |

**The CA is the interesting one, because the obvious version of it is wrong.**
Removing "the CA" saves **no memory at all** — it is openssl scripts that run four
times and exit, not a service. What it would cost is every TLS thread in the lab:
Vault's serving certificate, the proxy, Gitea, cert-manager at 9.4. So the
certificates stay and only the *implementation* goes. Vault's PKI becomes a
self-signed root at 3.4 and issues everything; `ca/`, `root-ca.cnf`,
`intermediate-ca.cnf`, `index.txt` and the serial file are deleted. What is lost
is the offline-root lesson — genuinely valuable, and the most ceremonial part of
the lab.

**MinIO's replacement is not Gitea alone.** Gitea's registries take Terraform
state and container images. They do **not** take Packer's CloudStack templates
well: `registerTemplate` pulls by URL, and a private Gitea package needs
credentials embedded in that URL, which then live in CloudStack's database and its
logs. Templates are served instead as static files by the proxy that already
exists — `images.lab.test`, TLS from Vault, a name in CoreDNS. One vhost, no new
service, no credential in a URL.

**What was considered and kept.** CloudStack is the largest single weight at
~4.0 GB across the management server, MySQL, two system VMs and the virtual
router — and it is 73 references, all of Phase 1, Phase 7's provider, and the
VPC/tier/ACL thread this lab is partly for. Removing it is not a cut but the
libvirt rewrite, which was tried and reverted. It becomes worth revisiting only on
an actual 16 GB VM. Vault, DNS, the proxy and Phase 13 stay: they are the
load-bearing, transferable parts, and cutting them would make a lighter lab that
teaches less.

**Cost:** the plan loses its identity story entirely, its admission-control story,
and the offline-root ceremony. Scheduling becomes something you arrange
deliberately rather than something the cluster shows you by default. Each is a
real loss and each was chosen over the alternative of not fitting.
