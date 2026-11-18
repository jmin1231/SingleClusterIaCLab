# Backend cluster

Companion to [backend-k3s.drawio](backend-k3s.drawio).
Updated 2026-11-18 from the current repository configuration, without a new
live-cluster verification.

## Node and interfaces

be-1 is an Ubuntu 24.04 VM with **2 vCPUs, 4 GiB RAM, and a 40 GiB disk**.
It runs a single k3s server with `node-ip: 10.3.1.10`. Bundled Traefik is disabled;
the manifests use a LoadBalancer Service for PostgREST rather than an Ingress.
The k3s default pod/service CIDRs (`10.42.0.0/16`, `10.43.0.0/16`) are not overridden.

| Interface | Address | Purpose |
|---|---|---|
| `eth0` | `10.3.1.10/24` | Private `site-c` address and frontend API destination |
| `eth1` | `198.51.100.13/24` | WAN; default via `198.51.100.1`; WireGuard transport to hub `.12:51821` |
| `eth2` | `10.250.0.112/24` | Host administration, DNS, Squid, and Git access |
| `wg1` | `10.99.1.2/24` | Tunnel to tun-1; carries frontend/hub private prefixes |

The frontend sends from `10.1.1.10` to `10.3.1.10:8000`. The destination is the
private node IP, not `10.99.1.2`. tun-1 allows this flow between its tunnels and
blocks other new forwarded connections, including frontend access to 22 or 5432.

## Kubernetes resources

| Namespace | Resource | Behavior |
|---|---|---|
| `flux-system` | source-controller | Fetches GitRepository `lab-repo`, branch `main`, from Gitea over HTTPS |
| `flux-system` | kustomize-controller | Reconciles Kustomization `lab-apps`, path `./kubernetes/apps`, with pruning and health checks |
| `db` | Service `postgrest` | LoadBalancer TCP 8000 → named target `http`, container port 3000 |
| `db` | Deployment `postgrest` | One PostgREST replica; HTTP 3000, admin 3001; readiness uses `/ready` on the admin port |
| `db` | Service `postgres` | ClusterIP TCP 5432 → named target `postgres` |
| `db` | Deployment `postgres` | One PostgreSQL replica, `Recreate` strategy; TCP readiness on `127.0.0.1:5432` |
| `db` | PVC `postgres-data` | 1 GiB, ReadWriteOnce; no explicit storage class, so it uses the cluster default |
| `db` | Generated ConfigMap `postgres-init-*` | Kustomize embeds `init.sh` and rewrites the Deployment's ConfigMap reference |
| `db` | Secret `app-db` | Ansible-managed database passwords, outside the Flux-managed manifests |

The node's k3s ServiceLB implements the LoadBalancer service. Its purpose here
is frontend access at the private node IP, but the Service does not itself
restrict exposure to `wg1`. Host/WAN isolation and the hub forwarding rule are
separate from Kubernetes service publication; there is no dedicated be-1 guest
input policy in this repository.

## Database and application path

```text
10.3.1.10:8000
  → Service/postgrest
  → PostgREST pod :3000
  → Service/postgres :5432
  → PostgreSQL pod, database todo, schema todo, table items
```

PostgREST logs in as `authenticator` and uses `web_anon` for anonymous requests.
The initialization script grants `web_anon` schema usage, CRUD on `todo.items`,
and sequence usage. The table holds `id`, `name`, and `created_at`. No card-number
encryption or Vault Transit call exists in this application.

PostgreSQL mounts the PVC at `/var/lib/postgresql`; the PostgreSQL 18 image uses
`/var/lib/postgresql/18/docker` as PGDATA. The initialization script is mounted
under `/docker-entrypoint-initdb.d` and runs only for an empty data directory.
Updating the ConfigMap does not migrate an existing database. The build uses a
plain Deployment and PVC, not CloudNativePG or a `postgres-rw` Service.

## Management and secrets

- Flux fetches `https://gitea.lab.test/lab/lab.git` through host Traefik at
  `10.250.0.1:443`. `flux-git-auth` contains its Git credentials and lab CA.
- Ansible reaches be-1 at `10.250.0.112:22`, installs k3s and Flux, and writes
  `Secret/db/app-db` into the k3s manifests directory. Passwords originate from
  Vault KV through the host runner, not from a Kubernetes Vault client.
- `POSTGRES_PASSWORD` and `AUTHENTICATOR_PASSWORD` are injected into PostgreSQL;
  PostgREST receives only `AUTHENTICATOR_PASSWORD` and constructs its connection URI.
- DNS goes to `10.250.0.1:53`; package and image egress uses Squid
  `10.250.0.1:3128`. The host firewall currently permits the be-1 → Gitea HTTPS
  DNAT path, not the Vault TCP 8200 DNAT path.

The current Ansible order is `k3s → fluxcd → app_secrets`. The Flux role waits for
the requested application revision before the Secret role runs. A fresh build
can therefore wait on workloads whose Secret has not been created yet. This
bootstrap ordering issue is not represented as a working dependency cycle in
the diagram; the final application wait should follow Secret delivery.

## Encryption and deferred components

WireGuard protects each inter-VM tunnel. The application sends HTTP through the
hub, with no inner TLS or mTLS. PostgreSQL TLS is not configured by these manifests.
There is no Istio gateway/ambient mesh, CNPG operator, VSO, Alloy, kube-state-metrics,
or node-exporter installed by this resource tree. Istio, VSO, and monitoring are
future work in [build-order.md](../../../../build-order.md), not current paths.

Sources: [k3s role](../../../../ansible/roles/k3s/),
[Flux role](../../../../ansible/roles/fluxcd/),
[database manifests](../../../../kubernetes/apps/db/),
[Secret delivery](../../../../ansible/roles/app_secrets/), and
[host firewall](../../../../src/host/files/nftables-vmfw.nft).
