# Request flow

How one request to the Lab Todo app travels from the browser to the database, matching
`request-flow.drawio` in this folder. The response follows the same path back.

## Where things are

| Box | Address | What it does |
|---|---|---|
| User | LAN client, or the host's own browser | Opens `https://app.lab.test`. The lab's CoreDNS answers with `HOST_IP`. |
| Host | `HOST_IP` | nftables DNATs `HOST_IP:443` to fe-1 (`198.51.100.11`, its `wan` address). |
| KVM / libvirt | | The "VPC": three isolated libvirt networks built by Terraform, site-a `10.1.1.0/24`, site-hub `10.2.1.0/24`, site-c `10.3.1.0/24`. |
| fe-1 | `10.1.1.10` | The `frontend` container: Flask behind gunicorn, TLS on `:443` with the `app.lab.test` cert. |
| tun-1 | `10.2.1.10` | WireGuard hub. Forwards only fe-1 → be-1 tcp 8000 (wg0 → wg1) and its replies. |
| be-1 | `10.3.1.10` | k3s. In namespace `db`: PostgREST (LoadBalancer `:8000`) and postgres `:5432`. |

## Hop by hop

| # | From → to | Port | What happens |
|---|---|---|---|
| 1 | Browser → `HOST_IP` | 443 | HTTPS to the address CoreDNS gave for `app.lab.test`. |
| 2 | Host → fe-1 | 443 | nftables DNATs the connection to `198.51.100.11:443`. gunicorn ends TLS and Flask handles the request. |
| 3 | fe-1 → tun-1 | wg0 | Flask calls `http://10.3.1.10:8000/items`. The call goes into WireGuard `wg0` to the hub. |
| 4 | tun-1 → be-1 | wg1 | The hub's filter allows this one flow and sends it on through WireGuard `wg1` to PostgREST on `10.3.1.10:8000`. |
| 5 | PostgREST → postgres | 5432 | PostgREST logs in as `authenticator`, switches to `web_anon` and runs the SQL on `todo.items`. |

## Two layers of encryption

- **TLS** covers browser → fe-1 (hops 1 and 2). It ends at gunicorn on fe-1.
- **WireGuard** covers fe-1 → tun-1 (`wg0`) and tun-1 → be-1 (`wg1`). The call inside is
  plain HTTP; tun-1 decrypts and re-encrypts it between the two tunnels.

## What is blocked

| Path | Why it fails |
|---|---|
| fe-1 → be-1 directly | The host's bridge filter lets the VMs talk only WireGuard to tun-1. Through the hub, only tcp 8000 passes; `:5432`, `:22`, `:6443` and be-1 → fe-1 are dropped. |
| VMs → internet | The host drops VM traffic headed out. Downloads go only through Squid (`10.250.0.1:3128`). |
