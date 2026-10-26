# Security groups in a VPC

**Implementing security groups in a CloudStack VPC.**

## Overview

This builds a small, self-contained private cloud on a single machine: a VPC with three
tiers (web, app and database), one server in each, and security groups that decide
exactly which server may talk to which. Everything is automated: one command builds
the whole environment, one shows it working, and one removes it and returns the machine
to its original state.

```
                  Host machine (Ubuntu 24.04 + Apache CloudStack)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                                                                          │
 │            │ port 80 from anyone                                         │
 │  ┌─────────┼──────────────────────────────────────────────────────────┐  │
 │  │         │                 VPC "iac-vpc"  10.0.0.0/16               │  │
 │  │         │         network ACL: any traffic inside the VPC          │  │
 │  │         ▼                                                          │  │
 │  │  ┌──────────────┐        ┌──────────────┐        ┌──────────────┐  │  │
 │  │  │ web tier     │        │ app tier     │        │ db tier      │  │  │
 │  │  │ 10.0.1.0/24  │        │ 10.0.2.0/24  │        │ 10.0.3.0/24  │  │  │
 │  │  │ sg_web       ├─:8080─►│ sg_app       ├─:5432─►│ sg_db        │  │  │
 │  │  │ sg_admin     │        │ sg_admin     │        │ sg_admin     │  │  │
 │  │  └──────┬───────┘        └──────────────┘        └──────────────┘  │  │
 │  │         │                                               ▲          │  │
 │  │         └──────── :5432 ✗ web is not in sg_app ─────────┘          │  │
 │  └────────────────────────────────────────────────────────────────────┘  │
 │ ════════════════════════════════════════════════════════════════════════ │
 │ Management network (cloudbr0): every VM has a NIC here; SSH from the     │
 │ host is allowed by sg_admin                                              │
 └──────────────────────────────────────────────────────────────────────────┘
```

- **VPC**: a private network space in the cloud, split into three **tiers** (subnets),
  one per layer of a typical application, each holding one server.
- **Network ACL**: the tier-level rule on the VPC. Here it is deliberately broad and
  lets any traffic move inside the VPC, so the security groups do all the filtering.
- **Security groups**: named sets of allow rules attached to each server. Anything they
  don't allow is dropped. `web` accepts port 80 from anyone, `app` accepts port 8080
  only from servers in `sg_web`, and `db` accepts port 5432 only from servers in
  `sg_app`. `sg_admin` on every server allows SSH from the host.
- **Management network**: a separate network on the host, used to configure the
  servers.

## Requirements

A single **throwaway** host (physical or virtual) — it is wiped and rebuilt during the
process, so do not use a machine with anything else on it.

| Need | Minimum | Recommended |
|---|---|---|
| Operating system | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| CPU | 4 cores, 64-bit, **hardware virtualization enabled** | 8 cores |
| Memory (RAM) | 16 GB | 32 GB |
| Free disk space | 100 GB | 200 GB |
| Network | Internet access (downloads several GB of software and an OS image) | — |
| Access | Administrator (root) access | — |

Everything else the environment needs is installed automatically during the build — no
manual setup beyond the above.

## How the objective is met

A **security group** is a virtual firewall attached to a server rather than to a
network. It holds a list of **allow** rules for incoming traffic, and anything not
allowed is dropped. One server can have several groups, and a rule can name another
group as its source instead of an IP address, so "the app tier accepts traffic from the
web tier" is written exactly like that and stays true as servers come and go.

The cloud platform is **Apache CloudStack** and the whole setup is defined **as code**:

- **Terraform** creates the VPC, its tiers, and the servers, and **attaches** each
  server's security groups (`terraform/tf_files/compute.tf`).
- The groups and their rules live in one file (`ansible/group_vars/all.yml`):

  | Group | Attached to | Allows in |
  |---|---|---|
  | `sg_admin` | every server | SSH and ping from the management network |
  | `sg_web` | `web` | port 80 from anyone |
  | `sg_app` | `app` | port 8080 from members of `sg_web` |
  | `sg_db` | `db` | port 5432 from members of `sg_app` |

- **Ansible** turns each server's attached groups into its firewall rules (nftables).
  "Members of `sg_web`" becomes a set of the addresses of every server attached to
  `sg_web`, filled in from Terraform, so attaching the group to another server opens
  the path for it with no rule changes.

The rules behave the way cloud security groups do:

- **Default deny inbound**: a port that no attached group allows is dropped, even if a
  service is listening on it.
- **Stateful**: replies to an allowed connection always get back in, so rules only
  describe who may start a connection.
- **Allow-only, combined**: a server's groups add up; there are no deny rules to order.
- **Outbound open**: servers may start any outgoing connection.

**Security groups versus the network ACL.** The VPC also has a **network ACL**, which
applies to a whole tier (subnet) rather than to a server. Here the ACL lets anything
inside the VPC through, so the security groups do all the filtering. The self-check
proves this: it switches off `db`'s security groups for a moment and shows that `web`
can then reach the database, so the block seen the rest of the time comes from the
security group, not from the network.

**Why the groups are enforced on the servers.** CloudStack offers built-in security
groups only on networks *outside* a VPC; VPC tiers get network ACLs. To have real
security groups inside a VPC, this lab enforces them on each server, with the same
model as the cloud versions: named groups attached to servers, rules that reference
other groups, stateful, and default deny.

## Seeing it in action

Three commands drive everything:

```bash
sudo ./bootstrap.sh up      # build the entire environment from scratch
sudo ./bootstrap.sh demo    # show that it works
sudo ./bootstrap.sh down    # remove everything and restore the machine
```

### `up`

`up` builds the whole environment in order, with no further input. A first run takes
roughly **45–60 minutes** in total; most of that is the cloud platform install and the
server image build.

| Step | What happens | Approx. time |
|---|---|---|
| 1. Host software | Installs the tools the build uses (Terraform, Packer, Ansible, Docker, QEMU, the CloudStack CLI) and checks the package sources are healthy | ~5 min |
| 2. Cloud platform | Backs up the host's network config (so `down` can restore it), prepares the host to act as the cloud's compute node, installs Apache CloudStack, waits for it to come up, creates the zone, and adds the server sizes the lab uses | ~15–25 min |
| 3. Server image | Starts a local file store (MinIO), builds an Ubuntu 24.04 server image with Packer, uploads it, and registers it with CloudStack as a template | ~15–20 min |
| 4. VPC and servers | Terraform creates the VPC, its three tiers and their network ACL, a management network, and one server in each tier with its security groups attached | ~3–6 min |
| 5. Security groups | Ansible routes each server's VPC traffic through the VPC router, then turns each server's attached security groups into firewall rules | ~1 min |
| 6. Self-check | Tries every path between the tiers and checks that only the ones the security groups allow get through; stops with an error if any check fails | ~1 min |

These times come from build logs on a well-resourced host (128 GB RAM, fast internet).
A machine closer to the minimum requirements, or a slower connection, will take longer,
mostly in steps 2 and 3. Each step remembers what it has already done, so re-running
`up` after a failure skips finished work and picks up where it stopped. A re-run with
everything already in place finishes in a couple of minutes.

### `demo`

`demo` runs a short proof against the running environment, using the same checks as the
self-check at the end of `up`. It leaves the environment as it found it. During the
check it starts temporary test services on each server, briefly switches off `db`'s
security groups and turns them back on, then removes the test services.

```
  [✓] sg_web:   anyone reaches web on port 80
  [✓] sg_app:   web reaches app on port 8080
  [✓] sg_db:    app reaches db on port 5432
  [✓] sg_db:    web cannot skip the app tier to reach db
  [✓] sg_app:   db is not in sg_web, so it cannot reach app
  [✓] sg_app:   app is not reachable from outside the VPC
  [✓] default:  a listening port no group allows is dropped
  [✓] network:  with db's groups off, web reaches db (SG did it)

  allowed paths: OPEN ✓ · everything else: BLOCKED ✓ · enforced by the security group ✓
```

In plain terms:

- **Allowed paths open**: the public reaches the web server, the web server reaches the
  application, and the application reaches the database.
- **Everything else blocked**: no tier can skip a layer, nothing outside reaches the
  application or the database, and an open port that no group allows is refused.
- **Enforced by the security group**: with the database's groups off, the same blocked
  connection goes through, so it is the security group doing the blocking.

### `down`

`down` reverses everything `up` did. It asks you to type `YES` before it starts, then:

1. destroys the servers, the VPC and its networks,
2. removes the MinIO file store and its data,
3. uninstalls CloudStack, its database and storage, and deletes all generated
   credentials,
4. restores the host's original network configuration,
5. reboots the machine to finish the revert.

This takes about 5 minutes, plus the reboot.

## Manual verification

To check the security groups by hand instead of using `demo`, list the server addresses
(run on the host):

```bash
terraform -chdir=terraform/tf_files output -json vms | jq
```

See the rules a server's groups produced, for example on `app` (the key is protected, so
use `sudo`):

```bash
sudo ssh -i state/lab_ssh_key ubuntu@<app mgmt_ip> sudo nft list ruleset
```

Start a test service on `db`, then try to reach it from `app` (allowed) and from `web`
(blocked), using `db`'s `tier_ip`:

```bash
sudo ssh -i state/lab_ssh_key ubuntu@<db mgmt_ip> \
    sudo systemd-run --unit=manual-db python3 -m http.server 5432

sudo ssh -i state/lab_ssh_key ubuntu@<app mgmt_ip> \
    "curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://<db tier_ip>:5432"   # 200
sudo ssh -i state/lab_ssh_key ubuntu@<web mgmt_ip> \
    "curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://<db tier_ip>:5432"   # 000 (dropped)

sudo ssh -i state/lab_ssh_key ubuntu@<db mgmt_ip> sudo systemctl stop manual-db
```

To see a group reference at work, add `sg_web` to `db`'s `security_groups` in
`terraform/tf_files/compute.tf` and run `up` again: `db` can now reach `app` on port
8080, and no rule was edited.

## Cleanup

`down` fully removes the environment and restores the machine to the way it was before —
no leftover configuration, no leftover credentials.
