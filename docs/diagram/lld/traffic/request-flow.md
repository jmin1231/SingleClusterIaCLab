# Request flow

Companion to [request-flow.drawio](request-flow.drawio).
Updated 2026-11-18 from the current repository configuration. The frontend code
and deployment role exist; end-to-end deployment acceptance remains pending in
[build-order.md](../../../../build-order.md). This diagram does not claim a new
successful live deployment.

## Hop by hop

| # | From → to | Protocol / port | What happens |
|---|---|---|---|
| 1 | LAN browser → host LAN IP | HTTPS 443 | CoreDNS resolves `app.lab.test` to the detected host LAN IP. The client must use a resolver that knows the lab records. |
| 2 | Host → fe-1 WAN `198.51.100.11` | HTTPS 443 | Host nftables DNATs LAN-ingress traffic; it does not terminate TLS. fe-1 replies through WAN gateway `198.51.100.1`. |
| 3 | Gunicorn/Flask on fe-1 → tun-1 through `wg0` | HTTP to `10.3.1.10:8000` inside WireGuard | Gunicorn terminates browser TLS directly on 443. Flask calls PostgREST server-side, using source `10.1.1.10`. |
| 4 | tun-1 → be-1 through `wg1` | Same inner HTTP request | The hub decrypts the first tunnel, filters the private-address flow, and encrypts it into the second tunnel. |
| 5 | be-1 `10.3.1.10:8000` → PostgREST pod | HTTP 3000 | The LoadBalancer Service `postgrest` targets the pod's named `http` port in namespace `db`. |
| 6 | PostgREST → Service `postgres` | PostgreSQL 5432 | PostgREST connects to database `todo` as `authenticator`, then uses role `web_anon` for anonymous requests. |
| 7 | PostgreSQL → persistent data | Database operation | CRUD affects `todo.items` (`id`, `name`, `created_at`), backed by the 1 GiB PVC. |

Responses follow the same application path back. The browser talks only to the
frontend: Flask renders HTML and translates form submissions into PostgREST calls.
There is no browser-to-PostgREST connection, Caddy proxy, or loopback port-8080 hop.

## Addresses and tunnel transport

| VM | Private `eth0` | WAN `eth1` | Management `eth2` | Tunnel addresses |
|---|---|---|---|---|
| fe-1 | `10.1.1.10/24` | `198.51.100.11/24` | `10.250.0.110/24` | wg0 `10.99.0.2/24` |
| tun-1 | `10.2.1.10/24` | `198.51.100.12/24` | `10.250.0.111/24` | wg0 `10.99.0.1/24`; wg1 `10.99.1.1/24` |
| be-1 | `10.3.1.10/24` | `198.51.100.13/24` | `10.250.0.112/24` | wg1 `10.99.1.2/24` |

fe-1 initiates WireGuard to `198.51.100.12:51820`; be-1 initiates to
`198.51.100.12:51821`. The hub learns each spoke endpoint. The frontend route
to `10.3.0.0/16` selects `wg0` and source `10.1.1.10`; the backend has a return
route to `10.1.0.0/16` through `wg1`. There is no NAT within the tunnels.

## Encryption boundaries

Browser HTTPS terminates at Gunicorn on fe-1. The `app-edge` server certificate
is issued by the lab's cfssl CA, stored in Vault KV, and delivered through the
pipeline to `/etc/frontend/tls`. The container mounts those files read-only at
`/etc/app/tls`. Browser trust in the lab CA is a separate client prerequisite.

Flask's backend URL is **HTTP**, not HTTPS. WireGuard encrypts each link, but
tun-1 can read the HTTP payload between the two tunnels. There is no end-to-end
mTLS, Istio gateway, or mesh in this request path. The database manifests do not
configure PostgreSQL TLS.

Vault is not called for each request. The application stores todo items, not
Transit-encrypted card numbers. Vault supplies deployment secrets through CI.

## Separate management and delivery paths

The host's root runner builds the frontend image and saves it to
`/var/lib/lab/images/frontend.tar`. Ansible copies it over SSH to fe-1's
management address, loads it into Podman, and installs a Quadlet using host
networking. The frontend image runs as UID 65532 and listens on `0.0.0.0:443`.
Image delivery does not use a registry pull from fe-1.

The same runner reads database passwords from Vault at `10.250.0.1:8200` and
delivers `Secret/db/app-db` to be-1. Flux on be-1 independently fetches Git from
Gitea through host Traefik `10.250.0.1:443`. These are deployment paths, not
extra hops on a browser request.

## Filtering that exists today

| Path | Enforcement |
|---|---|
| LAN → frontend | Host DNAT and forwarding allowance for LAN-interface `HOST_IP:443` → fe-1 WAN 443 |
| Direct fe-1 ↔ be-1 WAN traffic | Host bridge filtering blocks it; only spoke/hub WireGuard exchanges and their required ARP are permitted |
| Guest → guest over management | Host bridge filtering blocks switching; host routed filtering blocks the relay path |
| Other new traffic through tun-1 | Hub forward chain permits only private-source frontend → private-destination backend TCP 8000; other traffic is counted and dropped |
| Direct guest internet access | Host routed filtering drops it, despite the guest WAN default route |
| Allowed guest downloads | Squid on management, with Ubuntu package domains for all VMs and additional k3s/image domains for be-1 |

There is no blanket LAN-console deny rule or general management-to-host service
allowlist in the current host input chain. Dedicated guest input policies for
fe-1 and be-1 are also absent. The PostgREST LoadBalancer is not itself restricted
to `wg1`; distinguish service publication from the filtering of the intended path.
Host-local requests to `HOST_IP:443` do not match the LAN-ingress DNAT rule.

Sources: [frontend application](../../../../frontend/app.py),
[frontend image](../../../../frontend/Dockerfile),
[frontend role](../../../../ansible/roles/frontend/),
[host firewall](../../../../src/host/files/nftables-vmfw.nft),
[WireGuard template](../../../../ansible/roles/wireguard/templates/wg.conf.j2),
[hub firewall](../../../../ansible/roles/wireguard/files/hub-forward.nft), and
[PostgREST manifest](../../../../kubernetes/apps/db/postgrest.yaml).
