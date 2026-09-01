# Build Plan

A single-host infrastructure lab, built to be **understood**, in Python.

This replaces an earlier sixteen-phase plan, now in git history. That plan was
architecturally sound and pedagogically backwards: it built five phases of
foundations — a cloud, a CA, DNS, a secret store, a CI runner — before anything
you could open in a browser. Everything was justified, and none of it did
anything yet.

Its step descriptions for Kubernetes onward are longer than the sketches here; if
you want them, `git log -- docs/build-order.md` will find it.

Three changes:

1. **Something works at the end of Phase 1**, and at the end of every phase after.
2. **Python, with one bash file.**
3. **CloudStack is gone.** See below — it is the single largest simplification.

---

## The idea this is built on

The old plan's thesis was *build foundations first, so nothing has to be
reopened*. That is correct for production and wrong for learning, because it
means doing a great deal of work before you have any way to tell whether you
understood it.

This plan inverts it: **build something small that works, then feel what is
missing, then fix that.**

- You will type IP addresses until it annoys you. Then you build DNS.
- You will click through a browser warning. Then you build a CA.
- You will hardcode a password. Then you build Vault.

Each foundation arrives *after* the problem it solves, so you already know what
it is for. You will reopen a service or two along the way. **That is the
lesson, not a defect** — feeling why trust belongs before services is worth more
than being told it in a document.

---

## What happens to the old repo

**You start a new one, and the old one becomes something you are allowed to
read.**

The existing repository holds about 3,800 lines of working bash — CoreDNS, a
two-tier CA, Vault, Gitea with an isolated runner, a reverse proxy — and every
one of them is rebuilt here. Migrating in place is the cheaper-looking option and
it destroys the method: you cannot *feel* the problem at 2.1 if CoreDNS is
already answering, and 4.1 finds no hardcoded passwords in a repo that has
already moved them into Vault. **Every step in Phases 1–5 needs the absence of
the thing it builds.**

So the old tree lives at [`old/`](../old/) — moved aside rather than deleted, in
this same repository so git history stays continuous. Nothing in the new tree
imports from it, and nothing in it runs any more.

**The rule for reading it.** Attempt the step first, *then* open `old/` to check
yourself — never to find the answer. That is the distinction the previous plan
tried to draw and lost, because it pointed you at the reference *before* each
step rather than after.

**The documents already came with you.** `docs/` has been rewritten for this
plan. These are not artefacts to salvage — they are this lab's:

| | |
|---|---|
| `build-plan.md` | This file. |
| `decisions.md` | Reset to five entries, all about choices *this* plan makes. Add to it as you build, and keep entries short. |
| `network-plan.md` | Rewritten for libvirt. The CloudStack-derived ranges are gone; the k3s and Docker overlap check stays, because those still collide silently. |
| `resource-budget.md` | Rewritten. Where the memory and disk figures live, and where estimates get replaced by measurements. |
| `failure-log.md` | Reset to empty, keeping two lessons about *method*. Write an entry when a failure takes more than an hour. |

What stays in `old/` is the **code** — roughly 3,800 lines of bash implementing
services this plan rebuilds — and the 3,148-line decision log explaining it.

**The cost, stated:** you are discarding working, heavily-commented code and the
reasoning behind it. That is real. What you buy is the only thing this plan
sells — building each piece at the moment you understand why it exists.

---

## Why CloudStack is gone

It was the biggest source of complexity in the old lab, and it arrived first:

- a 2,704-line vendored installer nobody owns
- it rewrites host networking, installs MySQL and NFS, and enables root SSH
- ~4 GB of RAM before a single workload
- a management server whose database can disagree with reality — one entry in
  `failure-log.md` is ninety minutes of chasing six symptoms from one hung NIC

**Replaced by libvirt + `terraform-provider-libvirt`.** You still get real VMs,
real networks and real Terraform. You lose driving a commercial IaaS API and VPC
ACLs as a product feature — a genuine loss, and a fair trade for deleting the
single hardest thing to debug.

If you want CloudStack later, it slots in at Phase 6 as an alternative provider.
Nothing above Phase 6 depends on which one you chose.

---

## What it has to fit in

Target VM: **16 GB RAM · 12 vCPU · 200 GB disk**, and unlike the previous version
of this lab it fits with room to spare. CloudStack was ~4 GB of the old fixed
cost — a management JVM, MySQL, two system VMs and a virtual router — and that is
where the headroom came from.

The table, the disk figures and what the spare memory is *for* live in
[`resource-budget.md`](resource-budget.md). Build them there rather than here: a
number in two places drifts, and this one is going to be corrected with real
measurements as each component arrives.

---

## The language rule

**Python, except for one file.**

`bootstrap.sh` is about twenty lines: install `python3-venv`, build a venv,
install dependencies, hand over to Python. That is the only bash in the lab,
and it exists because Ubuntu refuses `pip install` system-wide (PEP 668) — so
something has to run before Python can.

Everything else is Python, including host work. `subprocess.run(["apt-get", ...])`
is not more elegant than bash, but it is *one* language to be fluent in, and it
can be tested.

You do not need to know bash to work through this plan.

---

## Two habits to keep, and one to drop

The old lab's best habit: **write down why.** Keep it. When you make a real
choice — a port, a UID, a file layout — record it in one short paragraph.

Its worst habit: **writing down everything.** `decisions.md` reached 3,148 lines
and comments regularly ran ten lines for three lines of code. That is a cost you
pay on every later read.

The rule: **a comment explains what the code cannot.** If it restates the line
below it, delete it.

---

## How to work

- **One step, one session.** Every step below is an evening or a weekend.
- **One step, one commit.**
- **Done when** is a command you run, not a feeling.
- If a step takes more than two sessions, it is too big — split it and tell me.

Effort: **S** an evening · **M** a weekend.

---

# Phase 0 · The workbench

Five small steps. No infrastructure — this is the toolbox you use for the next
twelve phases.

### 0.1 A repo, a venv, and one command · `S`
A new empty repo. `bootstrap.sh` (the twenty lines), `pyproject.toml`, and a
`lab/` package with a `main()` that prints a version.
**Learn:** virtual environments, why PEP 668 exists, `python -m`.
**Done when:** `sudo ./bootstrap.sh && python -m lab --version` prints something.

### 0.2 Logging · `S`
A `lab/log.py` with `info`, `warn`, `fail`. `fail` exits non-zero.
**Learn:** stdout vs stderr, exit codes, why a script that fails silently is worse
than one that crashes.
**Done when:** `echo $?` is 1 after a failure.

### 0.3 Running commands · `S`
A `lab/run.py` wrapping `subprocess.run` — raise on failure, capture output,
optionally echo the command.
**Learn:** this is the function you will use several hundred times. Shell
injection, why `shell=True` is avoided, and what a non-zero exit means.
**Done when:** a failing command raises with the command in the message.

### 0.4 Your first test · `S`
`pytest`, and one test for `lab/run.py`.
**Learn:** the thing bash could not give you. A test is how you find out you broke
something without redeploying.
**Done when:** `pytest` is green, and red when you break `run`.

### 0.5 Lint on every commit · `S`
`ruff` for linting and formatting, a `Makefile` with `lint`/`fmt`/`test`, and a
git pre-commit hook.
**Learn:** automation you cannot forget to run.
**Done when:** committing badly formatted code is refused.

> **Drill 0** — delete `.venv/`, re-run `bootstrap.sh`. Everything works again
> with no manual step.

---

# Phase 1 · Something running

The first phase that produces a thing you can look at.

### 1.1 Prepare the host, by hand · `S`
Time sync (`chrony`), base packages, Docker. Type the commands yourself and
write down what each one did.
**Learn:** what a host needs before anything runs on it. Clock drift breaks TLS
and every token you issue later, which is why time comes first.
**Done when:** `docker run hello-world` works and `timedatectl` says synchronised.

### 1.2 One container, by hand · `S`
`docker run` an nginx. No code yet.
**Learn:** images, ports, what `-p 8080:80` actually does.
**Done when:** you get a page on `http://<host-ip>:8080`.

### 1.3 The same container, from a compose file · `S`
**Learn:** why a file beats a remembered command line.
**Done when:** `docker compose up -d` gives you the same page.

### 1.4 Now automate all of it from Python · `M`
Everything you did by hand in 1.1–1.3: the packages, Docker, the compose file,
and starting it.
**Learn:** **idempotence** — the single most important idea in this lab. Running
it twice must not break anything, and the second run should say so rather than
silently redoing work. You are automating something you have now done by hand,
which is the only order that teaches you what the automation is for.
**Done when:** `python -m lab install web` twice, same result both times.

---

# Phase 2 · Names

You now have a service reachable only by IP. Fix that.

### 2.1 Feel the problem · `S`
Write down every place an IP is currently typed.
**Learn:** why hardcoded addresses spread.
**Done when:** you have the list, and it is longer than you expected.

### 2.2 CoreDNS · `M`
A container serving `lab.test`, with a zone file rendered from Python.
**Learn:** authoritative vs forwarding, A records, why DNS is a foundation.
**Done when:** `dig web.lab.test` answers from your server.

### 2.3 Point the host at it · `S`
**Learn:** `systemd-resolved`, `/etc/resolv.conf`, resolver order.
**Done when:** `curl http://web.lab.test:8080` works.

---

# Phase 3 · Trust

Five steps, and the most valuable phase in the plan.

### 3.1 A self-signed certificate · `S`
Generate one with `cryptography`, serve HTTPS, watch the browser refuse it.
**Learn:** what a certificate actually is. Why self-signed fails — not because it
is weak, but because nothing vouches for it.
**Done when:** it works with `curl -k` and fails without.

### 3.2 Your own CA · `M`
`lab/ca/` — a root key and self-signed root certificate.
**Learn:** `BasicConstraints(ca=True)`, key usage, why the root's key matters more
than anything else you will generate.
**Done when:** `openssl x509 -text` shows `CA:TRUE`.

### 3.3 Issue a certificate from it · `M`
A CSR, signed by your root, for `web.lab.test`.
**Learn:** subjects, SANs, why the CN is not enough any more. **Test it:** assert
the SAN contains the name.
**Done when:** `openssl verify -CAfile` passes.

### 3.4 Distribute trust · `S`
Install your root into the host trust store.
**Learn:** where trust actually lives. `/etc/ssl/certs`, and that Python, Node and
Go each look somewhere different.
**Done when:** `curl https://web.lab.test` works with **no** `-k`.

### 3.5 A reverse proxy · `M`
nginx terminating TLS for every service, routing by name — **and refusing names
it does not know**. nginx promotes the first server block to the default, so
without an explicit default it answers for every name that resolves to the host,
presenting the wrong certificate.
**Learn:** why one place holds certificates rather than every service, and why a
name mismatch is only a warning that users click through.
**Done when:** two names, one proxy, both HTTPS, and an unknown name fails to
*connect* rather than serving the wrong site.

> **Drill 3** — issue a certificate for a name you have not configured. The proxy
> should refuse the connection, not serve the wrong site.

---

# Phase 4 · Secrets

### 4.1 Find your hardcoded passwords · `S`
`grep` your own repo. There will be some.
**Learn:** why this is the problem before you meet the tool.
**Done when:** every one is listed, including the ones in compose files and the
ones you told yourself were temporary.

### 4.2 Vault, running · `M`
Single node, file storage, TLS from your own CA.
**Learn:** sealing and unsealing, why it starts sealed, what the unseal key is.
**Done when:** `vault status` says unsealed, over HTTPS.

### 4.3 Read a secret from Python · `S`
`hvac`. Write one, read it back.
**Learn:** KV v2, paths, tokens.
**Done when:** a test writes and reads a secret.

### 4.4 Move every credential into it · `M`
**Learn:** generate secrets rather than choosing them; a service is told its
password, never asked for one.
**Done when:** no password appears in any tracked file.

### 4.5 Vault becomes the issuing CA · `M`
Mount Vault's PKI engine, have it generate an intermediate CSR, sign that CSR
with your Phase 3 root, and import the result. Vault issues everything from here.

You have issued two certificates by hand by now, and you are about to need three
more — Gitea (5.1), libvirt (6.2), and one per name after that. Issuing by hand
is tolerable. Renewal is not: a certificate you issued by hand expires while you
are looking somewhere else.

**Learn:** the move here is not automation, it is *where policy lives*. A Python
script decided what it was willing to issue. A PKI **role** decides server-side —
a caller asks for a name and a TTL, and Vault refuses if the role does not allow
them. The client stops being trusted to restrain itself.

Note what does not change: the intermediate is signed by your Phase 3 root, so
the trust you distributed at 3.4 keeps working and nothing is re-trusted. That is
the payoff for having done 3.4 properly.

Your Python CA now issues exactly two things, ever — Vault's own serving
certificate (4.2) and this intermediate — and then never runs again.

**Done when:** `vault write pki/issue/<role> common_name=anything.lab.test`
returns a certificate that `openssl verify -CAfile <your Phase 3 root>` accepts,
**and** the same call for a name outside `lab.test` is refused by Vault rather
than by you.

---

# Phase 5 · Source of truth

### 5.1 Gitea · `M`
Behind the proxy, certificate issued by Vault (4.5), Postgres behind it.
**Done when:** you can browse to `https://git.lab.test`.

### 5.2 Push this repo, and mint an API token · `S`
The token is a credential — it goes into Vault (4.4), never into a file.
**Learn:** what the token can do. CI and the Terraform state backend both
authenticate with it later.
**Done when:** the repo is browsable in Gitea and the token is in Vault.

### 5.3 The toolbox image · `M`
One image holding every tool the lab uses: `terraform`, `ansible`, `kubectl`,
`packer`, and your own Python package. Every version pinned, every download
checksummed, nothing installed at job time.

**Learn:** why a pipeline that `apt-get`s its own tools is slower on every run,
not reproducible, and trusts whatever the network served that minute. This is
also the answer to "where does Terraform come from" — it is never installed on
the host.

**Done when:** `docker run --rm toolbox terraform version` works, and a rebuild
with an unchanged Dockerfile is all cache hits.

### 5.4 A CI runner · `M`
A runner that creates job containers from the toolbox image.

**Learn:** what a runner is, and why it must not be trusted with your host. The
job container is where untrusted code runs — anyone who can open a pull request
can change what a workflow does.

**Done when:** a job runs in the toolbox image and prints `terraform version`.

### 5.5 First pipeline: lint · `S`
Run `make lint` and `pytest` on every push.
**Done when:** a broken commit shows red in Gitea.

### 5.6 Make it a gate · `S`
**Done when:** a pull request with failing tests cannot be merged.

### 5.7 Turn on the registries · `S`
Gitea's package registry, for **container images** (6.x, 8.x) and **Terraform
state** (6.6).

**Learn:** this is why there is no MinIO in this plan. One service covers both
jobs, which is one fewer certificate, credential and compose file to own.

**Done when:** you can `docker push` an image to Gitea and pull it back.

---

# Phase 6 · Machines

Where infrastructure-as-code starts.

### 6.1 libvirt, and one VM by hand · `M`
Check `/dev/kvm` exists first — if this host is itself a VM, nested
virtualization has to be on, and the failure surfaces much later as an opaque
QEMU error.
**Learn:** KVM, qcow2, cloud-init, virtual networks. Images live at
`/var/lib/libvirt/images` on this host — there is no object store in this lab
and nothing needs one.
**Done when:** you SSH into a VM you made, and `egrep -c '(vmx|svm)' /proc/cpuinfo`
is greater than zero.

### 6.2 Let the toolbox reach libvirt · `M`
**The decision this phase turns on.** Terraform runs in the toolbox container
(5.3), but libvirt lives on the host. Two ways to bridge that:

- **Mount `/var/run/libvirt/libvirt-sock`.** Simple, works immediately, and hands
  the runner the ability to create VMs, attach any host disk, and define a
  storage pool pointing anywhere. That is host root by another name.
- **`libvirtd` over TLS**, with a certificate issued by Vault (4.5). The
  toolbox authenticates as a client over the network. More setup, a real
  boundary, and the first time your CA protects something other than a web page.

Take TLS. Write down which you chose and what the other would have cost.

**Learn:** why "the runner can provision infrastructure" and "the runner has your
host" are different sentences, and what separates them.
**Done when:** `virsh -c qemu+tls://host/system list` works **from inside the
toolbox container**, and the socket is not mounted anywhere.

### 6.3 Terraform, one VM · `M`
Run it from the toolbox, never from the host.
**Learn:** providers, resources, state, plan vs apply.
**Done when:** `terraform apply` makes it and `destroy` removes it.

### 6.4 A network and three VMs · `M`
frontend · app · data.
**Learn:** `for_each`, variables, outputs.
**Done when:** three VMs, one network, one `apply`.

### 6.5 Give them names · `S`
Terraform's outputs feed CoreDNS records, so the VMs are reachable by name.
**Learn:** the Phase 2 lesson applied to things that did not exist then. An
address Terraform already knows should never be typed by a human again.
**Done when:** `dig app.lab.test` answers, and nothing in Phase 7 contains an IP.

### 6.6 Remote state in Gitea · `M`
Terraform's `http` backend against Gitea's **Terraform State Registry** (needs
Gitea ≥ 1.26), authenticated with the token from 5.2.

**Learn:** why state is shared and why it is *sensitive* — it records every
resource attribute in plaintext, including anything cloud-init carries. What
locking prevents, and that `lock_address`/`unlock_address` are what provide it.

**Not** committing `terraform.tfstate` to the repo: that puts secrets in history
permanently, and JSON blobs do not merge. The registry is a blob store with an
API, not your git history — a different thing that happens to live in the same
service.

**Deviation to write down:** the registry is protected by Gitea's access control
and nothing else. A production estate encrypts state at rest with a customer-held
key and keeps it in a separate account.

**Done when:** state lives in Gitea, and two concurrent applies — start one, run
another — end with the second refused rather than both proceeding.

### 6.7 Terraform in CI · `M`
**Learn:** the runner now provisions infrastructure. Everything from 6.2 is what
makes that safe.
**Done when:** a merge plans and applies without you running anything.

---

> **Phases 7–12 are deliberately sketched.** They are six months out and the
> details will change once you have run 0–6. Each step names the concept and the
> tool; the *Done when* lines get written when you reach them. If they were as
> specific as Phase 3, most of that specificity would be wrong by the time you
> read it.

# Phase 7 · Configuration

### 7.1 Ansible, one task · `S`
### 7.2 Inventory generated from Terraform outputs · `M`
**Learn:** never type an IP that Terraform already knows.
### 7.3 A base role — users, packages, your CA, time · `M`
### 7.4 Ansible in CI · `S`

---

# Phase 8 · Kubernetes

### 8.1 k3s on one VM · `M`
**Done when:** `kubectl get nodes` from your host.
### 8.2 Deploy something · `M`
**Learn:** pod, deployment, service.
### 8.3 Ingress · `M`
**Learn:** getting traffic into the cluster by name.
### 8.4 Certificates, issued automatically · `M`
**Learn:** cert-manager issuing from Vault's PKI (4.5) — the CA reaching inside
the cluster, and the last place you stop issuing certificates by hand.
### 8.5 A second node · `S`
**Learn:** scheduling. Add it, watch placement, remove it.

---

# Phase 9 · GitOps

### 9.1 Flux, pointed at Gitea · `M`
### 9.2 Base and overlay · `M`
### 9.3 Break something by hand, watch it heal · `S`
**Done when:** you delete a deployment and it comes back.

---

# Phase 10 · The application

### 10.1 Postgres · `M`
### 10.2 An API and a schema migration · `M`
### 10.3 A web tier · `M`
### 10.4 Its secrets from Vault · `M`
**Learn:** External Secrets Operator — the loop from Phase 4 closing.
**Done when:** the app runs with no secret in any manifest.

---

# Phase 11 · Seeing it

### 11.1 Prometheus and Grafana · `M`
**Done when:** a dashboard shows your app's request rate.
### 11.2 One alert that arrives · `S`

---

# Phase 12 · Operations

### 12.1 Back up everything stateful · `M`
Gitea's Postgres and data directory, Vault's storage and unseal key, your CA's
root key, the Terraform state.

**Decide the destination first** — there is no object store in this lab, and a
copy on the host you are backing up is not a backup. A second disk, a NAS, or
another machine. Whatever you pick, it must survive the host being wiped, because
12.3 wipes it.

**Learn:** Gitea now holds your code, CI, images *and* Terraform state. That is
the simplicity you bought by dropping MinIO, and it means Gitea is the single
most valuable thing on this host.
**Done when:** the backup exists somewhere the host cannot reach by itself.

### 12.2 Restore it, for real · `M`
**Done when:** a restored Gitea serves the same repo, Vault unseals with the
backed-up key, and the CA root still verifies a certificate Vault issues after
the restore.
### 12.3 Rebuild from zero · `M`
**Done when:** a wiped host reaches a working application from `bootstrap.sh`
and one push.

---

## Not in this plan

Named so they are choices, not omissions: SSO and identity (authentik, OIDC,
SAML), log aggregation (Loki), Kyverno admission policies, image signing,
WireGuard between tiers, autoscaling, chaos drills, CloudStack, and **MinIO** —
Gitea's registries cover both jobs it would have done.

Each is a project on its own. Each is *integration* rather than construction, and
the lab is coherent without all of them. Add one later if you want it — by then
you will know where it goes.

## If you get stuck

The step is too big. Say which one and we will split it — that is a plan defect,
not a you defect.
