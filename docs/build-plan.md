# Build Plan

A single-host infrastructure lab, **written by you, from nothing**, on a fresh
Ubuntu 24.04 VM.

This is a syllabus, not a runbook. Every step says what to build, the decisions
inside it, the traps that are not obvious, and a *Done when* you can run. It does
not contain the code — writing that is the exercise.

---

## How this works

**The reference sits in [`reference/`](../reference/)** — a complete, working
version of this lab: CloudStack, CoreDNS, a self-signed CA inside Vault, Gitea
with a runner, a reverse proxy, a CI toolbox, all from one `bootstrap.sh`.

**The rule, and it is the whole method:** attempt the step, get your *Done when*
passing, *then* open the reference to see what you missed. Never before. What you
are practising is deciding, and a decision you read is not one you made.

That rule is doing real work, because a file you can open is a file you will
copy. If you find yourself reaching for `reference/` before you have written
anything, read it from history instead, where it is inconvenient enough to be
deliberate:

```sh
git show 91b02cf:bootstrap.sh
```

**Nothing in `reference/` runs.** Its containers are stopped and nothing at the
root depends on it. You write in the root; it stays where it is until Phase 13,
when you delete it and the lab still comes up.

**Two documents are yours to keep writing as you go:**

| | |
|---|---|
| `decisions.md` | what you chose, what you rejected, why. One entry per real choice. Keep them short — the previous log reached 3,148 lines and stopped being read |
| `failure-log.md` | write an entry when a failure costs more than an hour, or when the symptom pointed somewhere other than the cause |

Both already exist and are worth reading before you start. They are the previous
build's, and they are the most useful thing in the repo.

---

## What you need

| | Minimum |
|---|---|
| OS | Ubuntu 24.04 LTS, x86_64 |
| CPU | 12 cores, VT-x/AMD-V enabled |
| RAM | 16 GB — a ceiling, see `resource-budget.md` |
| Disk | 200 GB SSD |
| Virtualization | `/dev/kvm` present; **nested virt on**, set on the hypervisor |

Nested virtualization cannot be fixed from inside the guest. Check before you
build anything:

```sh
egrep -c '(vmx|svm)' /proc/cpuinfo   # > 0
ls -l /dev/kvm                       # exists
```

**Never run your installer from an IDE's integrated terminal.** VS Code's
AppArmor profile blocks MySQL's post-install script from signalling its own
temporary server; the run stalls with a timeout three layers from the cause.

Effort: **S** an evening · **M** a weekend · **L** split it.

---

# Phase 0 · What never gets committed · `S`

No build tooling — no Makefile, no linter, no hooks. The one thing worth deciding
before there is anything to decide it about is what must never reach git.

**Build:** a repo and a `.gitignore`.

**The decision:** three categories, and write the rule at the top of the file so
the next entry has somewhere obvious to go.

| | |
|---|---|
| **Committed config** | non-secret settings that make the lab portable — ports, hostnames, image tags. Clone it elsewhere and it stands up the same |
| **Machine-local state** | real but not portable: container data, rendered files, anything holding an address discovered on this host |
| **Secrets** | never, on any branch. If one lands in history, rotating the secret is the fix — deleting the file is not |

**Why now, when nothing generates secrets until Phase 4:** because the first run
that writes a private key must not also be the run that decides whether it is
ignored. This repo has come within one `git add -A` of committing a CA key twice,
both times during a directory move.

**Traps:**

- **Patterns containing a slash are relative to the `.gitignore`'s own
  directory.** `docker/vault/certs/` in a root `.gitignore` stops matching the
  moment that tree moves. Moving the `.gitignore` with it keeps every rule
  working — that is why `reference/.gitignore` still protects `reference/`.
- **A rule that matches nothing looks exactly like no rule.** `git check-ignore`
  answers for a path whether or not it exists, so assert on the paths you care
  about rather than reading the file and believing it.
- **`git status` will not warn you.** A root-owned `0700` directory is invisible
  to it, so the only thing between a token and a commit can be a permission bit.

**Done when:** `git check-ignore -q <path>` succeeds for a file that does not
exist yet — the key, the env file, the data directory — for every one you can
name in advance.

# Phase 1 · The host · `M`

**Build:** `bootstrap.sh` — bare Ubuntu to a machine that can run containers.

**In order:** refuse to run as non-root · verify KVM · sync the clock · install
CLI tools · install Docker · add your user to the `docker` group.

**The decisions:**

- **Where the guards go.** One `require_root` at the top, or a check in every
  function? Pick and be consistent.
- **What "verify" means versus "install".** `check_kvm` cannot fix anything, so
  it fails fast. That is a different kind of step and worth separating.
- **A skip flag.** You will re-run this a hundred times, and the host layer
  changes far less than the services. Decide what a skip flag skips — the steps
  that *mutate*, not everything before the services.

**Traps, and these are the ones that cost time:**

- **The clock comes before apt.** A host with a skewed clock fails
  `apt-get update` with `Release file is not valid yet`, which reads like a
  network problem. Sync first, and wait for it — `timedatectl` reports
  `NTPSynchronized` and there is a window where it is not yet true.
- **`command -v docker` proves almost nothing.** It proves a binary is on PATH.
  It does not prove the daemon runs, and `apt install docker.io` gives you a
  daemon with no compose plugin at all. Assert on `docker info` and
  `docker compose version`.
- **Group membership is fixed when a session starts.** Adding yourself to
  `docker` does nothing for the shell that ran the command. Say so in the output
  or you will debug it later.
- **`$USER` is `root` under `sudo`.** The variable that knows who invoked you is
  `SUDO_USER`, and it is unset in a real root shell — which is a case to handle,
  not assume away.
- **A trailing colon in `chown user:` means the user's own login group.**
  Spelling the group as the username assumes a `useradd` default that is not
  universal, and `chown` failing under `set -e` kills the script after the work.

**Done when:** `docker run hello-world` works, `timedatectl` says synchronised,
and running the whole script twice changes nothing the second time.

**Check yourself:** `git show 91b02cf:bootstrap.sh`

---

# Phase 2 · The cloud · `L` — split: install, then read back what it built

**Build:** a wrapper around CloudStack's all-in-one installer that makes an
unattended install reproducible.

CloudStack's own installer is ~2,700 lines you did not write. **Do not rewrite
it.** Vendor it, and write the wrapper: prepare the host, pin the repository,
run it, verify what it produced.

**The decisions:**

- **What you own and what you vendor.** Keep the vendored file out of your
  own tooling. If you ever add a formatter, exclude it — reformatting vendored
  code turns a small patch into an unreadable one — and guard that exclusion,
  because one matching nothing looks exactly like none.
- **A bootstrap resolver.** While the installer rebuilds host networking, no link
  supplies DNS. Something has to provide it, and Phase 3 has to retire it.
- **Where the root password comes from.** The installer needs root SSH to add
  the KVM host — even when that host is itself. Decide whether that is an
  argument, an environment variable, or a generated value.

**Traps:**

- **Pin the apt component.** The installer's own default has been broken
  upstream. Prove the repository yields an installable package *before* the
  40-minute install, not during it.
- **Assert on what `sshd` concluded, not the file you wrote.** `sshd -T` prints
  the effective config after every drop-in merges, and it takes the **first**
  value for each keyword — so a lower-numbered drop-in silently outranks yours.
  Nothing else detects that.
- **Bridge netfilter.** With it on, iptables sees bridged frames and VPC port
  forwards drop them **silently** — no error, no log line. Disable it and check.
- **`clear` fails without a usable `TERM`,** and under `set -e` that turns a
  successful install into a non-zero exit. If you wrap anything in a cleanup
  handler, this will find you.

**Done when:** the management UI loads, a zone exists, and re-running the wrapper
reports every step already done.

---

# Phase 3 · Names · `M`

**Build:** CoreDNS in a container, authoritative for `lab.test`, forwarding
everything else. Plus whatever renders its zone file.

**The decisions:**

- **Generate the records or template them.** A template you edit by hand grows
  entries for services you deleted. Generating from a list means adding a service
  is a list entry.
- **How the serial advances.** RFC 1912 says `YYYYMMDDnn`; epoch seconds is
  monotonic and unreadable. Either is defensible — a serial that never changes is
  not, and nothing in this lab will ever complain about it.
- **Where the host's address comes from.** It differs per host, so discover it.
  Ask the kernel which source address it would use to reach the outside world,
  rather than naming an interface — an interface name is a per-host fact wearing
  a constant's clothing.

**Traps:**

- **Docker publishes TCP by default.** DNS is UDP, so a bare `53:53` looks
  completely dead. You need both, and you need TCP anyway for responses over 512
  bytes.
- **Bind a specific address.** `0.0.0.0:53` collides with `systemd-resolved` on
  `127.0.0.53` and makes you an open resolver for anything that can route to you.
- **`DNS=` accumulates across `resolved` drop-ins.** Writing a higher-numbered
  file does not replace a lower one — both answer, and `lab.test` fails
  intermittently. Delete the one you are replacing.
- **`Domains=~lab.test`.** The `~` routes only that domain. Without it you get a
  search suffix; without `Domains=` at all you have made a lab VM the resolver
  for your whole machine.
- **Never forward to `127.0.0.53`.** That is `systemd-resolved`, which you are
  about to point at CoreDNS. The loop answers nothing and logs nothing.
- **Zone files:** a name without a trailing dot gets `$ORIGIN` appended, so
  `ns.lab.test` quietly becomes `ns.lab.test.lab.test`. And if you substitute
  variables with `envsubst`, restrict it — it will otherwise eat `$ORIGIN` and
  `$TTL`, which are directives, not variables.

**Done when:** `dig gitea.lab.test @<host>` answers, `github.com` still resolves,
and rendering twice produces a higher serial.

---

# Phase 4 · Trust and secrets · `L` — split: Vault running, then its CA

**The most important phase, and the one where the obvious order is wrong.**

**Build:** Vault, behind its own TLS, initialised, unsealed, with an audit
device, a KV store, and a PKI engine that becomes the lab's only CA.

**Start here:** Vault needs a certificate to start. Vault is what issues
certificates. Solve that before writing anything — it determines the shape of the
whole phase. There is more than one answer; the one this lab took is two passes,
a self-signed certificate to get the listener up and a real one once the PKI
exists.

**The decisions:**

- **One CA or two.** A two-tier PKI exists so the root can be kept **offline**.
  If both tiers live in the same Vault, you have the shape without the property.
  Decide honestly and write down which you chose.
- **Where the unseal key lives.** It cannot live in Vault — it is what decrypts
  Vault. So: which directory, what mode, and is it mounted into the container?
- **Certificate lifetimes.** One TTL will not fit both the services and Vault's
  own certificate, because you have no renewal automation yet. A 30-day
  certificate on the thing everything authenticates to expires unattended.

**Traps:**

- **The image's default command is `server -dev`** — in memory, self-unsealing,
  indistinguishable from success until a restart loses everything.
- **Pin a uid nothing else will claim.** Ubuntu hands uid 100–999 to whichever
  package installs first, so the image's own default means a different daemon on
  every machine — and that daemon could read Vault's key.
- **Ownership before the container.** Docker creates a missing bind-mount source
  as **root**; fixing it afterwards is a repair and a race.
- **Vault stops serving if it cannot write its audit log.** That mount is
  load-bearing in a way the data directory is not.
- **Seal is not stop.** A restarted Vault is running, listening, and answering
  everything `503`. Unsealing must therefore be a separate thing you can run
  after a reboot with nothing else present.
- **`operator init` happens once, ever,** and returns the key exactly once. Guard
  it against the four states, not two: cross-check Vault's health against whether
  your key file exists. An emptied data directory reports "uninitialised"
  exactly like a fresh one, and re-initialising there abandons real data.
- **A no-healthcheck decision.** `docker ps` looks identical for a sealed, an
  unreachable, and a working Vault. Ask Vault, not Docker.
- **Bind versus advertise.** `address` is where it listens; `api_addr` is what it
  tells clients. Wrong second value and it works while sending clients nowhere.
- **Serve the leaf plus its chain, verify against the CA alone.** Two different
  files, two different jobs. A bare leaf works in a browser that cached the
  issuer and fails in `curl` on a clean machine.

**Then secrets.** Store the credentials the later phases need, and notice they
arrive in **three different shapes**:

| | |
|---|---|
| **Captured** | the service already has it and will show it to you again |
| **Generated** | you create it in Vault *before* the service exists. Vault is the origin |
| **Minted once** | the service creates it and will never show it again — so the only guard available is whether it still *works* |

Know which one a secret is before you write code for it. The captured case has a
specific danger: the API that reads a key back may be one character away from the
API that **replaces** it, silently invalidating every existing holder.

**Done when:** `vault status` says unsealed over HTTPS with no `-k`, a role
refuses a name outside your domain, and a restart leaves it sealed but
recoverable.

**Check yourself:** `docs/vault-lesson.md` is a seven-lesson walkthrough of the
finished version — read it *after* your *Done when* passes.

---

# Phase 5 · Serving it · `M`

**Build:** Gitea with a database, and a reverse proxy terminating TLS for
everything, with certificates from Phase 4.

**The decisions:**

- **What publishes ports.** If the proxy is the only way in, nothing else needs a
  published port at all. That is a smaller attack surface and one place that
  holds certificates.
- **Where Gitea's credentials come from.** They are the *generated* case — create
  them in Vault before Gitea exists, and nobody ever chooses a password.

**Traps:**

- **nginx promotes the first server block to the default.** Without an explicit
  one it answers for every name that resolves to the host and presents the wrong
  certificate — a warning users click through.
- **The ordering here is a genuine cycle**, and it was a real bug in the previous
  build that went unnoticed for months: the proxy must start after Gitea (it
  joins Gitea's network and resolves a container name at startup), but anything
  talking to Gitea's *API* needs the proxy, because Gitea publishes no ports.
  There is exactly one point in the sequence that breaks it. Find it.
- **It works when you test it, because the proxy is already running.** A cycle
  like this only appears on a cold start. Test by stopping everything.

**Done when:** your service loads over HTTPS with **no** `-k`, an unknown name
fails to *connect* rather than serving the wrong site, and the whole thing comes
up from nothing in one command.

---

# Phase 6 · CI · `M`

**Build:** push the repo to Gitea, mint an API token, build a toolbox image, and
register a runner.

**The decisions:**

- **What the runner may reach.** This is the security decision of the phase.
  Anyone who can open a pull request can change what a workflow does. A runner
  holding the host's Docker socket means one line of YAML is root on the
  hypervisor.
- **Whether the toolbox is published.** It is the image every job runs in, so it
  cannot be built by a job.

**Traps:**

- **Credentials in a git remote URL** land in `.git/config` and survive every
  clone. A credential on a command line is visible in `ps` to every user on the
  host. Neither is where it belongs; there is a third way.
- **Run git as the repository's owner, not root,** or `.git/` fills with
  root-owned objects and the next ordinary push fails.
- **Only committed history pushes.** Obvious until the twenty minutes spent
  wondering why a fix visible in your editor had no effect.
- **Gitea Actions reads `.gitea/workflows/` and nowhere else.** Anywhere else and
  CI is silently dead — registered, idle, and green because it ran nothing.
- **A branch protection rule can deadlock you.** Requiring a status check that no
  pipeline yet produces, plus blocking direct pushes, makes `main` unreachable
  both ways.

**Done when:** a push runs a job in your toolbox image, and a broken commit shows
red.

> **Drill 6** — this is where the one-command build ends. Delete every container
> and run it again. Everything comes back, in order, with no manual step. That is
> the claim the rest of the lab rests on.

---

> **Phases 7–13 exist in no version of this lab.** They are the plan, and they
> get sharper as you reach them. Everything above has a reference at `91b02cf`;
> nothing below does.

# Phase 7 · Images · `L`
Build an image with Packer, publish it, register it as a template. Serve it as a
static file behind the proxy you already have — a template is fetched **by URL**,
so a private registry means a credential inside that URL, which then lives in the
control plane's database and logs.

# Phase 8 · Infrastructure as code · `L`
Terraform against CloudStack: provider, offerings, **three tiers with
deny-by-default ACLs**, VMs, and DNS records fed from outputs. Settle the state
backend *before* the first apply — migrating state is a real operation and there
is no reason to perform it on a lab you could have configured correctly. Then
prove the locking, with two applies at once.

# Phase 9 · Configuration management · `M`
Ansible with inventory generated from Terraform outputs, and a base role: users,
resolver, your CA in every trust store, time. Never type an address Terraform
already knows.

# Phase 10 · Kubernetes · `L`
k3s, and **choose the CNI at install time** — it cannot be swapped without
rebuilding the cluster. The default enforces NetworkPolicy correctly and shows
you nothing when it denies, which matters because the last step of this phase is
segmentation. Then Gateway API, and cert-manager issuing from Vault.

Finish with default-deny NetworkPolicy. It is **allow-only and additive** — the
opposite of an ordered ACL list. Egress deny breaks DNS first, and every symptom
looks like an application bug.

# Phase 11 · GitOps and the application · `L`
Flux pointed at Gitea, base and overlays, Vault Kubernetes auth and External
Secrets — a pod proves who it is and receives a credential nobody wrote down.
Then Postgres, an API and a web tier across the three tiers you segmented twice.

# Phase 12 · Seeing it · `M`
Metrics in the cluster; **logs on the host**, so they survive the cluster dying.
Note what that costs: the dashboard dies with the cluster, so practise reading
logs without it before you need to.

# Phase 13 · Operations · `L`
Back up everything stateful — including the unseal key, without which the backup
is ciphertext. Restore it for real. Then rebuild from zero and count the manual
steps; each one is either automated or written down as a deliberate exception.

---

## Not in this plan

Named so they are choices: identity and SSO, admission control policies, image
signature verification, an object store, an offline root CA, multi-node
Kubernetes by default, and an encrypted overlay between tiers.

## If a step is too big

Say which one and it gets split. That is a plan defect, not a you defect.
