# Build Plan

**This is the current plan.** [`build-order.md`](build-order.md) is the original
sixteen-phase syllabus, written before any of it existed; it is kept because its
per-step *Learning* notes are still the best explanation of why each piece is
there. Where the two disagree, this file wins.

It differs from that document in three ways:

1. **Phases 0–5 *of that document* are already built.** This plan starts from a
   running lab, so its first phase is *refactoring what exists*, not building it.
   Its own phase numbers start again from 0.
2. **Five things were cut** — see decision S-1. Identity, admission control, the
   two-tier openssl CA, MinIO, and multi-node k3s by default.
3. **Three designs changed** since the original: Loki moves to the host (L-7),
   Cilium replaces flannel (9.1-1), and NetworkPolicy becomes an explicit step.

**On the numbering.** `decisions.md` entry IDs follow `build-order.md`'s steps —
`9.1-1` is a decision about *that* document's 9.1, which is this plan's 5.1. The
IDs are not renumbered, for the same reason decisions are never renumbered: the
identifier is how they are cited.

Effort: **S** an evening · **M** a weekend · **L** split it.

---

## Where this starts

Verified on the host, not assumed:

| | State |
|---|---|
| CloudStack | `Zone1` configured, system VMs live, management + agent + usage enabled |
| CA | root and intermediate on disk, issuing |
| CoreDNS | zone rendered, host resolver pointed at it |
| Proxy | nginx with Vault-issued certificates, vhosts for the lab's names |
| Vault | initialised, storage and unseal secrets present, PKI engine configured |
| Gitea | data, credentials, and a registered runner with CI history |
| MinIO | buckets, policies, scoped keys |
| Packer · Terraform · Ansible · k3s · Flux | **nothing** |

**Nothing is running right now.** The service containers are all stopped; only
CloudStack is up under systemd. Step 0.1 is bringing them back.

---

# Phase 0 · Get back to a known-good lab

Before changing anything, prove what exists still works.

### 0.1 Bring the service layer up · `S` · **done**
`sudo SKIP_HOST_PREP=1 ./bootstrap.sh`, from a terminal **outside VS Code** — or
via `systemd-run`, which lands outside the `vscode` AppArmor profile. That
confinement is what blocked MySQL's postinst during the last attempt; the symptom
was a timeout three layers away from the cause.
**Done when:** CoreDNS answers, Vault is unsealed, Gitea loads over HTTPS, and the
proxy serves every configured name.

### 0.2 Write down what actually came back · `S`
Not everything survives a stop. Vault comes back **sealed** by design; CoreDNS's
`.env` holds the address discovered when it was last rendered.
**Learn:** the difference between a service that restarts and a service that
*recovers*.
**Done when:** you have a list of everything that needed a hand, and why.

---

# Phase 1 · Refactor what is already built

The cuts from S-1 applied to a running lab. Each step removes something that
works, so each one ends by proving the thing it replaced is not missed.

### 1.1 Vault's PKI becomes the root · `M` · **done**
Today the chain is: offline openssl root → intermediate → Vault's PKI. Replace it
with a **self-signed root inside Vault**, issuing directly.
**Learn:** what the two-tier design bought, by removing it — an offline root is
compromise containment, and this lab has nowhere genuinely offline to keep one.
**Watch for:** every certificate currently in use chains to the old root. Nothing
breaks until something renews, which is the worst way to find out.
**Done when:** `vault write pki/issue/...` returns a certificate that verifies
against the new root, and the old root is out of the host trust store.

### 1.2 Re-issue every live certificate · `M` · **done**
The proxy's vhosts and Vault's own serving certificate, from the new root. Then
distribute the new root and remove the old.
**Done when:** `curl https://git.lab.test` succeeds with **no** `-k`, and
`openssl s_client` shows a chain ending at the Vault root.

### 1.3 Delete the openssl CA · `S` · **done**
`ca/` entirely — scripts, `root-ca.cnf`, `intermediate-ca.cnf`, `index.txt`, the
serial file, `newcerts/`. Remove `install_ca` from `bootstrap.sh`.
**Done when:** `git rm` is committed, `bootstrap.sh` runs clean, and 1.2's checks
still pass with the directory gone.

### 1.4 Move Terraform state and images to Gitea · `M`
Gitea's Terraform state registry and container registry replace MinIO's two jobs.
**Done when:** `terraform init` migrates state to Gitea with locking working, and
a `docker push` to Gitea round-trips.

### 1.5 Serve templates from the proxy · `S`
Packer's CloudStack templates become static files behind the existing proxy at
`images.lab.test`. **Not Gitea** — `registerTemplate` pulls by URL, and a private
package needs credentials embedded in it, which then live in CloudStack's database
and logs. See S-1.
**Done when:** CloudStack registers a template from an `https://images.lab.test/`
URL with no credential in it.

### 1.6 Delete MinIO · `S` · **done**
The compose stack, the installer, the provisioner, the policies, the data. Remove
its wrappers from `bootstrap.sh` and its secrets from Vault.
**Done when:** `bootstrap.sh` has no MinIO step and 1.4 and 1.5 still pass.

> **Drill 1** — `sudo ./bootstrap.sh` on the lab as it now stands. Every step is a
> no-op or a repair; nothing errors. This is the first time the script and the
> host have agreed all day.

---

# Phase 2 · Images

### 2.1 A Packer build · `L` — split: any image first, then the customisation
An Ubuntu image built by Packer against CloudStack.
**Learn:** why a golden image beats configuring at boot, and where that stops
being true.
**Done when:** the build completes unattended and produces a qcow2.

### 2.2 Publish and register it · `M`
The image to `images.lab.test`, registered as a CloudStack template, checksummed.
**Done when:** a VM boots from your template.

### 2.3 The toolbox image · `M`
One image holding `terraform`, `ansible`, `kubectl`, `packer` and nothing
installed at job time. Every version pinned, every download checksummed. Pushed to
Gitea's container registry.
**Learn:** why a pipeline that `apt-get`s its own tools is slower every run and
trusts whatever the network served that minute.
**Done when:** `docker run --rm toolbox terraform version` works and a rebuild with
an unchanged Dockerfile is all cache hits.

### 2.4 Both builds in CI · `M`
**Done when:** a push rebuilds the toolbox and a tag rebuilds the template.

---

# Phase 3 · Infrastructure as code

### 3.1 Provider, offerings, one tier, one VM · `M`
**Learn:** state, providers, and that Terraform's view of the world is a file that
can disagree with reality.
**Done when:** `apply` creates a VM and `destroy` removes it.

### 3.2 Three tiers with deny-by-default ACLs · `L` — split: networks, then rules
frontend · app · data as VPC tiers, each with an ACL that denies by default.
**Learn:** this is the thing CloudStack gives you that libvirt does not. Write the
allow rules for exactly the paths Phase 6's application needs, and no others.
**Done when:** app reaches data, frontend does not, and you can point at the rule.

### 3.3 VMs, addresses, and DNS · `M`
Terraform outputs feed CoreDNS records.
**Learn:** an address Terraform already knows should never be typed by a human.
**Done when:** `dig app.lab.test` answers, and nothing in Phase 4 contains an IP.

### 3.4 Remote state in Gitea · `M`
**Done when:** state is in Gitea with locking, and the local file is gone.

### 3.5 Terraform in CI, with drift detection · `M`
**Done when:** a merge plans and applies, and a hand-made change is reported.

---

# Phase 4 · Configuration management

### 4.1 Ansible, one task, dynamic inventory · `M`
Inventory generated from Terraform outputs.
**Done when:** a play runs against all three tiers with no address written down.

### 4.2 A base role · `M`
Users, resolver, the Vault root in the trust store, time, hardening.
**Done when:** a rebuilt VM is indistinguishable from its siblings.

### 4.3 Ansible in CI · `S`
**Done when:** a merge converges the estate.

---

# Phase 5 · Kubernetes

### 5.1 k3s, single node, with Cilium · `M`
Install with `--flannel-backend=none --disable-network-policy`, then Cilium.
**Decided here** because a CNI cannot be swapped afterwards without rebuilding.
k3s's default flannel enforces NetworkPolicy correctly but shows you nothing when
it denies — see 9.1-1. Expect `NotReady` until the CNI is up.
**Single node by default** (S-1): agents are a scheduled exercise, not a
permanent cost.
**Done when:** `kubectl get nodes` works, `cilium status` is green, and the
per-node memory cost is written into the budget.

### 5.2 Deploy something, and reach it · `M`
A workload, a Service, and Gateway API with an HTTPS listener.
**Done when:** the app answers over HTTPS at a real name.

### 5.3 Certificates, issued automatically · `M`
cert-manager issuing from Vault's PKI.
**Done when:** a certificate appears without you asking for one, and renews.

### 5.4 Registry trust · `S`
The cluster pulls from Gitea.
**Done when:** a pod runs an image you built, and you have written down every
place trust had to be configured.

### 5.5 Segment the cluster, deny by default · `M`
Phase 3.2's exercise one layer up. Default-deny, then allow web → api → data.
**Learn:** NetworkPolicy is **allow-only and additive** — there is no deny rule,
which is the opposite of how a VPC ACL reads. Egress deny breaks DNS first; a
`podSelector` typo is a silent no-op; `podSelector: {}` means *every* pod.
**Done when:** web cannot reach Postgres, DNS still works, and you watched the
drop in Hubble rather than inferring it from a timeout.

---

# Phase 6 · GitOps and the application

### 6.1 Flux, pointed at Gitea · `M`
**Done when:** the cluster reconciles itself from a repository.

### 6.2 Base and overlays · `M`
**Done when:** one change lands in one environment and not the other.

### 6.3 Vault Kubernetes auth and External Secrets · `M`
**Learn:** the loop that Vault opened, finally closing — a pod proves who it is
to Vault and receives a credential nobody ever wrote down.
**Done when:** the app runs with no secret in any manifest.

### 6.4 Postgres, an API, a web tier · `L` — split: data, then app, then web
The three tiers Phase 3.2's ACLs and 5.5's policies were written for.
**Done when:** the app works end to end, and both segmentation layers still hold.

### 6.5 Break something by hand, watch it heal · `S`
**Done when:** you delete a deployment and it comes back.

---

# Phase 7 · Seeing it

### 7.1 kube-prometheus-stack · `M`
Prometheus, Alertmanager, Grafana, kube-state-metrics and node-exporter, in one
chart, pinned. Retention and scrape interval set **before** install, not tuned
after an OOM.
**Learn:** the pull model, and that Prometheus needs 9100 inbound on every VM —
which is a rule in Phase 3.2's ACLs, in the awkward direction.
**Done when:** Grafana loads over HTTPS and shows metrics from all three tiers.

### 7.2 Loki on the host, Alloy everywhere · `L` — split: Loki + host agent, then VMs
Loki runs **on the host** as another host service — compose stack, Vault
certificate, CoreDNS name, proxy vhost. Alloy on the host, on each VM, and as a
DaemonSet in k3s. Everything **pushes**. See L-7.
**Learn:** logs push and metrics pull, so they need opposite firewall rules. And
that Grafana lives in the cluster while Loki does not — deliberately.
**Done when:** one dashboard shows metrics and logs for the same host, **and**
`logcli` returns the same lines with the cluster stopped.

### 7.3 One alert that arrives · `S`
**Done when:** you break something and are told, by something that is not a
dashboard you happened to be looking at.

---

# Phase 8 · Operations

### 8.1 Back up everything stateful · `M`
Gitea's Postgres and data, Vault's storage and unseal key, the Terraform state,
the CloudStack database.
**Decide the destination first** — a copy on the host you are backing up is not a
backup, and 8.3 wipes that host.

### 8.2 Restore, for real · `M`
**Done when:** a restore produces a working service, not a directory of files.

### 8.3 Rebuild from zero · `L` — split: rebuild, then eliminate the manual steps
Fresh Ubuntu. `sudo ./bootstrap.sh`, then Terraform, Ansible, Flux.
**Done when:** the lab comes back, and every manual step you needed is either
automated or written down as a deliberate exception.

### 8.4 Failure injection · `M`
Pull a tier's ACL, stop Vault, fill a disk. Practise the order from
`failure-log.md`: platform, then machine, then software.
**Done when:** you diagnosed one failure faster because you had logs on the host
rather than in the cluster that failed.

---

## Not in this plan

Named so they are choices, not omissions, and all of them from S-1: identity and
SSO, Kyverno admission policies, image signature verification at admission,
MinIO, the offline root CA, and multi-node k3s as a default. WireGuard between
tiers is also out — VPC tiers already separate them, and the overlay was a second
network layer to debug.

Each is a project on its own. Add one later if you want it; by then you will know
where it goes.

## If a step is too big

Say which one and it gets split. That is a plan defect, not a you defect.
