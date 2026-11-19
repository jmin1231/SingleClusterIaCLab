# Backend cluster

What each box in `backend-k3s.drawio` is, in words.

## be-1 and its networks

be-1 is an Ubuntu 24.04 KVM guest (2 vCPU, 4 GiB RAM, 40 GiB disk) created by Terraform
(`terraform/compute.tf`). It runs single-node k3s `v1.37.2+k3s1` with `node-ip: 10.3.1.10`
and the bundled Traefik disabled; ServiceLB stays on. Pods get addresses from
`10.42.0.0/16`, services from `10.43.0.0/16` (k3s defaults, not set in the config). be-1
has no nftables ruleset of its own: the hub filter on tun-1 and the host's `vmfw` decide
what reaches it.

| Network | be-1 address | Used for |
|---|---|---|
| site-c `10.3.1.0/24` (isolated libvirt network) | eth0 `10.3.1.10` | The "VPC" address. k3s uses it as node-ip, and frontend requests are addressed to `10.3.1.10:8000`. No other VM is on this network. |
| wan `198.51.100.0/24` | eth1 `198.51.100.13` | The default route. Carries the WireGuard UDP to tun-1 `198.51.100.12:51821`. |
| WireGuard wg1 `10.99.1.0/24` | `10.99.1.2` | Frontend requests from fe-1 (source `10.1.1.10`) arrive through tun-1. The tun-1 hub filter forwards only `10.1.1.10 → 10.3.1.10` tcp 8000 (new connections plus replies), so fe-1 cannot reach `:5432`, `:22` or `:6443`. |
| mgmt `10.250.0.0/24` (cloudbr1) | eth2 `10.250.0.112` | Talking to the host at `10.250.0.1`. In: SSH 22 (Ansible). Out: Gitea via Traefik 443 (Flux; the host's `vmfw` lets only be-1 through on 443), Squid `proxy.lab.test:3128` (apt, k3s installer, Flux CLI, container images), and DNS 53. be-1 never talks to Vault. |

## k3s namespaces

| Namespace | What it is |
|---|---|
| flux-system | Flux v2.10.0 (source and kustomize controllers). Pulls `kubernetes/apps` from Gitea (`https://gitea.lab.test/lab/lab.git`, branch `main`) and applies it. Ansible places Flux in the k3s manifests folder. |
| kube-system | What k3s ships with: ServiceLB (opens `:8000` on the node for PostgREST's LoadBalancer Service), CoreDNS and the local-path volume provisioner. Only the bundled Traefik is disabled. |
| app (ns `db`) | The app, applied by Flux from `kubernetes/apps/db`. |

## App

| Part | What it does |
|---|---|
| PostgREST | REST API over table `todo.items`, reached at `10.3.1.10:8000` (Service type LoadBalancer). Logs in to Postgres as `authenticator` and switches to `web_anon` for anonymous CRUD. |
| postgres | PostgreSQL 18 on `:5432`, inside the cluster only (ClusterIP). Database `todo`, data on a 1 GiB volume. Its passwords come from Secret `app-db`, which Ansible writes from Vault. |
