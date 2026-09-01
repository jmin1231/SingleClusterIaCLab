# Decisions

What was chosen, what was rejected, and why. One entry per real choice.

**Keep these short.** The previous version of this lab reached 3,148 lines and
became something nobody re-read. A decision that takes four paragraphs to explain
is usually two decisions. Aim for: what, why, what you rejected, what it costs.

Numbered sequentially in the order they were made. Do not renumber.

---

## 1 · Python, with one bash file

> **Superseded in part by entry 8.** The exception stands; "around twenty lines"
> does not. `bootstrap.sh` provisions the host. Left as written rather than
> edited, because what was decided at the time is the useful record.

**Decided:** everything is Python. `bootstrap.sh` is the single exception, around
twenty lines: install `python3-venv`, build a venv, install dependencies, hand
over to Python.

**Why:** one language to be fluent in, and code that can be tested. Ubuntu 24.04
refuses `pip install` system-wide (PEP 668), so *something* has to run before
Python can — that is the whole reason the exception exists.

**Rejected: bash everywhere.** It is what the previous build did. Its host-facing
code was fine; its CA and secret-store code was a collection of workarounds for
tools that misbehave — `openssl ca` exits 0 when it *refuses* a CSR, and the
Vault CLI refuses a pipe outright. Those disappear with real libraries.

**Rejected: Python everywhere, including bootstrap.** Impossible, per PEP 668.

**Cost:** `subprocess.run(["apt-get", ...])` is not more elegant than the shell
command it wraps, and you lose the ability to paste a line into a terminal while
debugging.

---

## 2 · No CloudStack

**Decided:** VMs come from libvirt, driven by `terraform-provider-libvirt`.

**Why:** CloudStack was a 2,704-line vendored installer that rewrote host
networking, installed MySQL and NFS, enabled root SSH, and cost ~4 GB before a
single workload ran — and it arrived in Phase 1, before anything worked.

**Cost, and it is real:** no commercial IaaS API, no VPC ACLs as a product
feature, no SAML integration later. Traded for deleting the hardest thing in the
lab to debug.

**Consequence:** provisioning is no longer an HTTP API call. libvirt is a unix
socket on the host, so the runner needs a deliberate route to it — see entry 5.

---

## 3 · No object store

**Decided:** Gitea's package registry holds container images, and Gitea's
Terraform State Registry holds state. There is no MinIO.

**Why:** MinIO existed to serve CloudStack's image storage and Terraform's state
backend. The first requirement vanished with entry 2 — libvirt images live at
`/var/lib/libvirt/images`. The second is covered by Gitea (≥ 1.26), with locking.

**Cost:** Gitea becomes the single most valuable thing on the host — code, CI,
images and state. Its backup matters more than anything else in Phase 12.

**Not:** committing `terraform.tfstate` to a git repository. State records every
resource attribute in plaintext and JSON blobs do not merge. The registry is a
blob store with an API, not the git history.

---

## 4 · Foundations arrive after the problem they solve

**Decided:** build something that works, feel what is missing, then fix it. DNS
after typing addresses; a CA after clicking through a warning; Vault after
hardcoding a password.

**Why:** the previous plan built five phases of foundations before anything was
observable. It was architecturally right — nothing had to be reopened — and
pedagogically backwards, because there was no way to tell whether any of it was
understood.

**Cost:** you will reopen a service or two. That is the lesson being paid for,
not an accident.

---

## 5 · The runner reaches libvirt over TLS, not through the socket

**Decided:** `libvirtd` listens on TCP with a certificate issued by the lab CA.
The toolbox container authenticates as a client.

**Why:** mounting `/var/run/libvirt/libvirt-sock` into a job container gives it
the ability to create VMs, attach any host disk, and define a storage pool
pointing anywhere — host root by another name, granted to the place untrusted
pull-request code runs.

**Cost:** more setup, and a certificate to renew. Decided in advance because the
socket is the path of least resistance and would never be revisited.

---

## 6 · systemd-timesyncd, not chrony

**Decided:** the host keeps time with `systemd-timesyncd`. `bootstrap.sh` enables
it with `timedatectl set-ntp true` and waits for `NTPSynchronized`.

**Why:** it is already installed and already enabled on Ubuntu 24.04, so time
sync costs zero packages. It is also what `timedatectl` drives — with chrony,
`set-ntp` starts failing while the clock syncs anyway, and the code stops
describing what actually happens.

**Rejected: chrony.** More accurate, recovers better from long offline periods,
and can serve time to other machines. Installing it masks timesyncd, so the two
are a choice rather than a pair.

**Cost:** timesyncd is an SNTP client only. If the lab VMs later need a time
source on the lab network rather than upstream, it cannot be one — that is the
point where this gets revisited.

---

## 7 · The old lab is decommissioned on the host, not removed

**Decided:** `cloudstack-management`, `cloudstack-agent` and `cloudstack-usage`
are stopped and disabled. `libvirtd` stays — entry 2 replaced CloudStack *with*
libvirt, so Phase 6 needs it. `mysql` is left running for now; it is CloudStack's
database and nothing in this plan uses it.

**Why:** the management server held ports 8080, 8250 and 9090, and 8080 is the
port step 1.2 publishes nginx on. Deciding CloudStack was gone did nothing to the
machine still running it.

**Not done, deliberately: `cloudbr0` stays.** The host's only global address
(`10.1.0.39/24`) and its default route are on that bridge, which the old
`prepare-kvm-host.sh` created. Removing it over SSH disconnects the host with no
route back. It is a known leftover that the host's networking now depends on, and
undoing it is a console operation, not a step in this plan.

**Cost:** the host is not a clean Ubuntu install and will not be. `cloud0` still
holds `169.254.0.1/16` — the link-local range `network-plan.md` lists in its own
collision check — and old Docker bridges occupy `172.20`, `172.21` and `172.24`.
None collide with the chosen `192.168.100.0/24`, which is why row 3 was chosen
rather than inherited.

---

## 8 · bootstrap.sh provisions the host; Python runs the lab

**Decided:** `bootstrap.sh` installs everything the host needs before the lab can
run — time sync, apt prerequisites, the Docker engine and its repository, group
membership, the venv and the lab package. Everything after that is Python.

The boundary, so this does not sprawl: **bootstrap installs, it never
configures.** The moment a function there writes a file containing a value — a
port, a name, a credential — it belongs in `lab/`.

**Why:** it is the split real infrastructure already makes. `bootstrap.sh` is the
cloud-init user-data or the Packer provisioner: bare host to "can run our
tooling". `lab install <service>` is the configuration-management layer that
converges state and reports on it. Two jobs, and the seam is already there —
bash before Python exists, Python after.

**Rejected: bash shrinks to the venv and Python installs Docker.** Truer to entry
1's language rule, and it needs Python running as root to apt-install the thing
it needs in order to do anything. The plan's own step 1.4 assumes it. Not taken
because the provisioning step is where a host is at its least Python-capable.

**Cost, and it is real:** entry 1's "one bash file, around twenty lines" is now
false — it is ~140 lines and installs Docker. Bash grows past the point where the
skipped step 0.4 would have tested it. The install-never-configure rule is what
caps the damage: install steps are guard-then-act and can be eyeballed, while
logic and templating stay where `run()` and tests are.

**Consequence: CLI toolchains stay off the host.** Terraform, Ansible, kubectl
and helm go in the Phase 7 toolbox image, pinned, so the host and CI run
identical versions. Installing them here would be the same convenience that makes
every long-lived host drift from every other one.

**Not addressed, deliberately:** patching. Nothing in this lab updates the host
after bootstrap — no `unattended-upgrades`, no reboot policy. Every real estate
has an answer; this one teaches building rather than operating, and the absence
is recorded so it is a choice rather than an oversight.
