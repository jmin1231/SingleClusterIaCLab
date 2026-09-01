# Decisions

What was chosen, what was rejected, and why. One entry per real choice.

**Keep these short.** The previous version of this lab reached 3,148 lines and
became something nobody re-read. A decision that takes four paragraphs to explain
is usually two decisions. Aim for: what, why, what you rejected, what it costs.

Numbered sequentially in the order they were made. Do not renumber.

---

## 1 · Python, with one bash file

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
