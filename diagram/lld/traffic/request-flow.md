# Request flow

How one customer request travels from the browser to the database, matching
`request-flow.drawio` in this folder. The response follows the same path back.

## Where things are

| Box | Address | Notes |
|---|---|---|
| fe-1 | eth0 `10.0.1.10`, wg0 `10.99.0.2` | Caddy listens on 443; the frontend listens only on `127.0.0.1:8080`. |
| tun-1 (WireGuard hub) | eth0 `10.0.2.10`, wg0 `10.99.0.1`, wg1 `10.99.1.1` | Forwards one flow: `10.99.0.2` → `10.99.1.2:8000`. Logs and drops the rest. |
| be-1 | eth0 `10.0.3.10`, wg1 `10.99.1.2`, eth1 `10.250.0.112` | The Istio Gateway (ns ingress) on 8000; api (ns app) and postgres (ns db) in the mesh. |
| Host | `HOST_IP` on the LAN (cloudbr0), `10.250.0.1` on the mgmt network (cloudbr1) | The mgmt network `10.250.0.0/24` is a host-only bridge. |
| Vault | `10.250.0.1:8200` | Its Transit engine encrypts card numbers. |

## Hop by hop

| # | From → to | Port | What happens |
|---|---|---|---|
| 1 | User's browser → Caddy on fe-1 | 443 | The user opens `https://app.lab.test`. The name resolves to the VPC's public IP, which forwards port 443 to fe-1. |
| 2 | Caddy → frontend | 8080 | Caddy passes the request to the frontend on the same VM, over loopback (`127.0.0.1`). |
| 3 | frontend → tun-1 | 8000 | The frontend calls the backend at `10.99.1.2:8000`. The call goes through the WireGuard tunnel `wg0` to tun-1. |
| 4 | tun-1 → be-1 | 8000 | tun-1 forwards only this one flow, through the WireGuard tunnel `wg1`, to be-1. Anything else is logged and dropped. |
| 5 | Istio Gateway → api | 8000 | The gateway checks the frontend's client certificate, then lets the request into the mesh. |
| 6 | api → Vault | 8200 | The api asks Vault on the host to encrypt the card number. This goes over be-1's management NIC (`eth1`). |
| 7 | api → postgres | 5432 | The api stores only the encrypted value in the database. |

## Two layers of encryption on hops 3 and 4

WireGuard is not mTLS. They are separate layers, and hops 3 and 4 use both:

- **WireGuard** is the tunnel between machines: fe-1 ↔ tun-1 (`wg0`) and tun-1 ↔ be-1
  (`wg1`). Each machine authenticates its peer by its WireGuard public key, and each tunnel
  ends at tun-1.
- **mTLS** is the connection from the frontend to the Istio Gateway, using certificates
  from Vault. Both sides present a certificate. It runs **inside** the tunnels and ends
  only at the gateway.

So tun-1 decrypts WireGuard but sees only TLS ciphertext: it forwards the request without
being able to read it.

## What is blocked

| Path | Why it fails |
|---|---|
| fe-1 → be-1 directly | No network rule between the two tiers allows it, so the tunnel is the only path. |
| Anything else through tun-1 | tun-1 forwards one flow (frontend → backend gateway, port 8000) and drops the rest. |
| VPC tiers → internet | The tiers have no route to the internet. |
| LAN → host consoles (443) | The host firewall drops it, and the consoles' address (`10.250.0.1`) cannot be reached from the LAN at all. |
