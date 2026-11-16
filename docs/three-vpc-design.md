# Three VPCs with one VM each

Status: design for the next implementation, recorded 2026-11-15. This document
does not change `PLAN-enterprise.md` or claim that the topology is deployed.

## 1. Decision

Keep three VMs: `fe-1`, `tun-1`, and `be-1`. Each VM combines its workload with
its VPC's VPN gateway role. There are no additional router VMs.

Here, **host** means the Ubuntu machine running KVM; **guest** means one of
those three VMs. The guests are the VPC endpoints. The host supplies the simulated
WAN, external web ingress, management access, and firewall enforcement outside
the guests. It does not hold an address on any VPC's private network.

This models three sites connected through a hub. It is a local VPC simulation,
not an AWS VPC or Transit Gateway implementation. A workload and its router share
one operating system, so their failure and administrative boundaries coincide.

## 2. Topology

```text
LAN client -> HOST_IP:443
                   |
          host DNAT to 198.51.100.11:443
                   |
          host WAN address: 198.51.100.1
                   |
       wan bridge: 198.51.100.0/24
          |                  |                  |
      .11 eth1           .12 eth1           .13 eth1
        fe-1               tun-1              be-1
  frontend + VPN       VPN hub + policy    k3s + VPN
          |                  |                  |
   10.1.1.10 eth0      10.2.1.10 eth0      10.3.1.10 eth0
          |                  |                  |
      vpc-east            vpc-hub            vpc-west
    10.1.1.0/24         10.2.1.0/24         10.3.1.0/24
    reserved /16        reserved /16        reserved /16

WireGuard transport:
  fe-1  -> 198.51.100.12:51820 -> tun-1
  be-1  -> 198.51.100.12:51821 -> tun-1

Management, separate from the above:
  host 10.250.0.1 -- cloudbr1 -- eth2 on each VM
  guest-to-guest management traffic is blocked on the host bridge
```

The solid WAN connection makes the VPN endpoints reachable. It does not grant
permission for arbitrary VM-to-VM traffic. Host bridge filtering permits only
the selected WireGuard exchanges and the address-resolution traffic they need.

## 3. Networks and addresses

| Network | Reserved VPC range | Attached subnet | Host address | Guest address |
|---|---|---|---|---|
| `vpc-east` | `10.1.0.0/16` | `10.1.1.0/24` | None | fe-1 `10.1.1.10` |
| `vpc-hub` | `10.2.0.0/16` | `10.2.1.0/24` | None | tun-1 `10.2.1.10` |
| `vpc-west` | `10.3.0.0/16` | `10.3.1.0/24` | None | be-1 `10.3.1.10` |
| `wan` | — | `198.51.100.0/24` | `198.51.100.1` | fe-1 `.11`, tun-1 `.12`, be-1 `.13` |
| Existing `cloudbr1` | — | `10.250.0.0/24` | `10.250.0.1` | fe-1 `.110`, tun-1 `.111`, be-1 `.112` |

Each `/16` reserves space for its simulated VPC; only the listed `/24` is attached
today. Declaring a VPC range does not create all its possible subnets or routes.

`198.51.100.0/24` is TEST-NET-2, reserved for documentation, not globally usable
public addressing. It is retained here as the user's simulated WAN range; do
not advertise it onto the real LAN or internet. It is not a recommendation for
production addressing. [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737.html)

Before deployment, check every proposed range against host routes, the LAN,
Podman networks, and the Kubernetes pod/service ranges.

Terraform creates four libvirt networks:

- Three private networks with fixed bridge names matching their names, no
  `forward`, no host `ips`, no DHCP, and no DNS service.
- `wan`, bridge name `wan`, in `route` mode, with host address
  `198.51.100.1/24`, no DHCP, and DNS disabled. There is no source NAT or
  masquerading for guest internet access.

Management attaches directly to the existing `cloudbr1`; Terraform does not
create another management network. Omitting host gateway addresses on a private
libvirt network leaves guest communication on the bridge without making the host
its IP gateway. [Libvirt network format](https://libvirt.org/formatnetwork.html)

## 4. VM interfaces and resources

| NIC | Role | fe-1 | tun-1 | be-1 | Routing |
|---|---|---|---|---|---|
| `eth0` | Private VPC | `10.1.1.10/24` | `10.2.1.10/24` | `10.3.1.10/24` | No default gateway |
| `eth1` | WAN | `198.51.100.11/24` | `198.51.100.12/24` | `198.51.100.13/24` | Default via `198.51.100.1` |
| `eth2` | Management | `10.250.0.110/24` | `10.250.0.111/24` | `10.250.0.112/24` | No default gateway; DNS `10.250.0.1` |

All addresses are static. Cloud-init matches NICs by fixed MAC address and assigns
these names explicitly. Retain the existing private and management MACs and add
a unique WAN MAC per VM; the management NIC changes from `eth1` to `eth2`.

The default route gives WAN packets and web replies a next hop. The host firewall
still blocks unsolicited guest access to the LAN and internet. Packages and
images continue through the existing Squid service over management.

Keep the existing sizes: fe-1 and tun-1 each have 1 vCPU, 1 GiB RAM, and a 10 GiB
disk; be-1 has 4 vCPUs, 6 GiB RAM, and a 40 GiB disk. No extra guest RAM is needed
for separate routers because there are none.

## 5. WireGuard and application routing

Retain the two existing tunnel address ranges, but move the transport endpoints
to WAN addresses and carry private VPC ranges inside the tunnels.

| VM | Interface | Tunnel address | Listen port | Peer endpoint | Peer AllowedIPs |
|---|---|---|---|---|---|
| fe-1 | `wg0` | `10.99.0.2/24` | Automatic | `198.51.100.12:51820` | `10.99.0.1/32`, `10.2.0.0/16`, `10.3.0.0/16` |
| tun-1 | `wg0` | `10.99.0.1/24` | 51820 | Learned from fe-1 | `10.99.0.2/32`, `10.1.0.0/16` |
| tun-1 | `wg1` | `10.99.1.1/24` | 51821 | Learned from be-1 | `10.99.1.2/32`, `10.3.0.0/16` |
| be-1 | `wg1` | `10.99.1.2/24` | Automatic | `198.51.100.12:51821` | `10.99.1.1/32`, `10.1.0.0/16`, `10.2.0.0/16` |

Both spokes initiate their tunnel and use `PersistentKeepalive`. Keys remain
generated on the guests; only public keys are exchanged through the existing
Vault workflow. No WAN or management range belongs in `AllowedIPs`.

`AllowedIPs` identifies permitted source networks received from a peer and selects
the peer for outgoing destinations. Configure matching operating-system routes;
an AllowedIPs entry is not a TCP-port firewall rule. [WireGuard routing](https://www.wireguard.com/#cryptokey-routing)

The application flow becomes:

```text
frontend process on fe-1, source 10.1.1.10
  -> wg0 -> tun-1 -> wg1 -> be-1, destination 10.3.1.10:8000
```

The API name `api.backend.lab.test` must resolve to `10.3.1.10` in the frontend's
application configuration. The application stops targeting `10.99.1.2`; tunnel
addresses remain useful for tunnel diagnostics.

Because the application and VPN endpoint are the same VM, explicitly set the
preferred source of fe-1's remote-private routes to `10.1.1.10`. For example, the
route to `10.3.0.0/16` uses `wg0` with preferred source `10.1.1.10`. Otherwise Linux
may choose the tunnel address and miss the hub's private-source allow rule.
Configure the corresponding private preferred source on the other guests.

The route configuration must be persistent and reconciled when WireGuard starts;
verify `ip route get 10.3.1.10` on fe-1 reports `dev wg0 src 10.1.1.10`.
Do not NAT traffic inside the tunnels.

Only tun-1 forwards application traffic between the two WireGuard interfaces.
At the spokes, traffic generated by local applications uses `output`, and traffic
delivered to local applications uses `input`. Kubernetes service DNAT can instead
put backend traffic through `forward`, so be-1's policy must cover that path too.

Enable IPv4 forwarding on tun-1 for hub transit. Container runtimes may also
enable forwarding on the spokes; their rules must not allow WAN/management to
become alternative transit paths. The frontend keeps its host-network application
arrangement so the intended source address is not replaced by a container subnet.

## 6. Firewall ownership and isolation

There are two host tables in the planned nftables file: `inet lab_vpc` for routed
traffic and `bridge lab_vpc_l2` for bridged traffic. In-guest `inet lab` tables
provide the second layer. These are requirements for implementation, not a claim
that the current nftables file already provides them.

### Host bridge table: WAN and management

Traffic between guests on the same bridge is switched directly. With the lab's
bridge-to-iptables compatibility path disabled, it does not traverse the host's
IP forwarding rules. Native nftables bridge filtering handles that traffic;
bridge connection tracking is supported on modern Linux kernels.
[nftables bridge filtering](https://wiki.nftables.org/wiki-nftables/index.php/Bridge_filtering)

On `wan`, allow only:

- fe-1's WAN port to tun-1's WAN port, IPv4 UDP destination port 51820.
- be-1's WAN port to tun-1's WAN port, IPv4 UDP destination port 51821.
- Tracked replies for those permitted exchanges, constrained to the expected ports.
- Necessary ARP address resolution between the permitted peers and with the host.

Drop other guest-to-guest WAN traffic, including IPv6 and unexpected Ethernet
protocols. ARP requires explicit handling: a firewall containing only UDP rules
would prevent peers from discovering each other's Ethernet addresses.

Match host-side guest ports as well as addresses. Assign stable tap names such as
`lab-fe-wan`, `lab-tun-wan`, `lab-be-wan`, and corresponding `*-mgmt` names in the
domain definitions. Validate those names against actual domain XML. Libvirt
supports explicit target device names; avoid its reserved prefixes such as
`vnet` and `vif`. [Libvirt interface targets](https://libvirt.org/formatdomain.html#overriding-the-target-element)

Bind each WAN/management port to its assigned source MAC, IPv4 address, and ARP
sender identity before accepting traffic. Apply source checks to ingress toward
the host as well as ingress forwarded to another guest. An IP-only allow-list
does not justify the claim that guest root cannot impersonate another guest.

On `cloudbr1`, block guest-to-guest forwarding, including ARP and IPv6, while
preserving each guest's ARP and IP communication with the host. The three
management addresses and Ansible inventory stay unchanged. This extra bridge
rule closes the management bypass without creating more networks.

Scope these rules to the lab's bridges/ports so unrelated libvirt or Podman
networks are unaffected. Do not globally flush the host ruleset.

### Host inet table: external ingress and host services

- DNAT packets arriving on the detected LAN interface for `HOST_IP:443` to
  `198.51.100.11:443`. No second DNAT is needed: fe-1 itself runs Caddy.
- Permit that forwarded connection and its tracked replies. Preserve the real
  LAN client's source address; fe-1 replies through its WAN default gateway.
- Drop other routed traffic entering or leaving `wan`, including attempts to
  route guest-to-guest traffic through `198.51.100.1` to evade bridge filtering.
- Block new WAN-originated connections to services on the host, whichever host
  destination address the guest chooses. Required tracked replies may return.
- Block management-originated forwarding to other guests, the WAN, or LAN;
  management permits selected host services, not arbitrary transit. Preserve
  existing host-controlled service/container paths explicitly where required.
- Keep DNS, NTP, Vault, proxy, gateway, and administrative access on management,
  subject to the host's service allow-list.

The host's own requests to `HOST_IP:443` do not match the LAN-ingress rule and
continue to the host gateway. Internet-bound guest traffic is blocked even though
the WAN network is configured in libvirt `route` mode.

Load both host tables atomically from the same configuration. Install them before
guests start, including on host reboot with libvirt autostart enabled. Keep the
existing apply pre-check, and make service ordering enforce the same rule at boot.
Counters on the drops provide evidence for the isolation tests.

### Guest firewalls

| Guest | Intended application permissions |
|---|---|
| fe-1 | TCP 443 on WAN for external web traffic; UDP to hub port 51820; API traffic through `wg0`; management to/from host |
| tun-1 | UDP 51820 from fe-1 and 51821 from be-1 on WAN; forward `wg0` to `wg1` only from `10.1.1.10` to `10.3.1.10:8000`, plus replies |
| be-1 | UDP to hub port 51821; API TCP 8000 through `wg1` from `10.1.1.10`; management to/from host; required internal Kubernetes traffic |

Do not expose backend port 8000 on WAN or management just because a service binds
all addresses. For ServiceLB/hostPort DNAT, enforce the interface, original API
destination, source, and original port in the forwarding path. Mutual TLS between
the frontend and backend gateway remains required inside the tunnels.

Pin k3s's node IP to `10.3.1.10`, retain its management API access, and update any
CNI/interface settings that previously assumed the default-route NIC was private.
Move host-service and telemetry paths from guest `eth1` to `eth2`; the existing
management IPs and inventory groups do not change.

## 7. Files to change during implementation

| File or component | Intended change |
|---|---|
| `terraform/network.tf` | Three isolated private networks plus routed WAN; no host IP on private networks |
| `terraform/compute.tf` | Private/WAN/management addresses and MACs; three interfaces; stable host tap identities |
| `terraform/cloud-init/network-config.yaml.tftpl` | MAC matching for `eth0`/`eth1`/`eth2`; default route on WAN; DNS on management |
| `terraform/inventory.tf` | No address, username, or group change |
| `src/host/vpc.py` | Render detected host/LAN values and port identities; install/load both tables; enforce boot ordering and teardown |
| `src/host/files/nftables-vpc.nft` | WAN DNAT and routing rules; WAN and management bridge filtering; source identity checks |
| WireGuard roles | WAN endpoints, private AllowedIPs, preferred-source routes, and hub policy |
| Guest firewall roles | Three NIC roles; private API addresses; appropriate input/output/forward rules |
| k3s and application configuration | Private node IP, API destination, management interface references |
| Verification and teardown | Tests below; remove both host tables and the four Terraform networks safely |

Preserve the existing disk/seed replacement lifecycle. A cloud-init network change
must rebuild the relevant guest rather than assume an already-booted guest will
re-read its seed. Review the resulting plan for replacements before applying.

Implementation order: agree on addresses and port identities; prepare host
filtering; update and validate Terraform/templates; deploy under the firewall;
prove management and isolation; configure WireGuard; prove the application path.

## 8. Acceptance tests

| Test | Required result |
|---|---|
| Topology | Three guests, each with three NICs; three private bridges with no host IPv4/IPv6 gateway addresses; one WAN bridge |
| Routes before VPN | Only WAN has a default route; management DNS/SSH work; private cross-VPC traffic cannot pass |
| WAN peers | Both WireGuard handshakes succeed; direct fe-1 to be-1 WAN connections fail with bridge drop counters rising |
| Alternate routed path | A guest attempting to send another guest's private or WAN traffic through the host gateway is dropped |
| Management bypass | Guest-to-guest management communication fails even with the sender's guest firewall disabled; host administration remains available |
| Spoofing | A guest using another guest's IP, MAC, or ARP sender identity cannot obtain that guest's permitted path |
| IPv6 bypass | IPv6 guest-to-guest WAN/management traffic cannot bypass the IPv4 policy |
| Web ingress | A LAN client reaches Caddy through `HOST_IP:443`; Caddy sees the client IP; host-local access still reaches the host gateway |
| Private API | fe-1 reaches `10.3.1.10:8000` through both tunnels; hub counters rise; preferred source is `10.1.1.10` |
| Tunnel dependency | Stopping either tunnel breaks private API access without breaking management; fallback through WAN is dropped |
| Hub allow-list | New frontend connections to backend SSH or PostgreSQL fail; only the selected API flow passes |
| Egress | Direct guest internet access fails; allowed package downloads through Squid work |
| Persistence | Reboot and unchanged re-apply preserve isolation, address bindings, routes, and tunnel connectivity |

Use disposable listeners and controlled probes for the tests. Do not interpret
the absence of a listening service as proof that the firewall dropped a packet;
check counters and observe the intended interface path.

## 9. Q&A

**Why not keep one VPC with three tiers?**
The revised requirement is three sites. Each now has a separate private network
and VPN endpoint, rather than a shared host router with three private interfaces.

**Why combine the router and workload?**
There is one workload per VPC. Sharing the guest keeps the lab at three VMs while
demonstrating private addressing, public transport, site-to-site VPN routing, and
host-enforced isolation. Separate routers remain the expansion path for multiple
workloads or independently managed gateway appliances.

**Are the WAN addresses really public?**
No. They represent the public side of the simulation and are reachable only where
the lab explicitly permits them. The external user enters through the real host
LAN address and DNAT, not by routing TEST-NET-2 onto the LAN.

**Is this site-to-site VPN if each site contains one machine?**
It demonstrates site-prefix routing over VPNs, with each site's endpoint and
workload combined. Today the application packets originate and terminate on the
VPN endpoints; only the hub performs inter-tunnel transit. Adding another workload
would also require configuring its gateway and the site's local forwarding policy.

**Can root on fe-1 bypass the isolation?**
Guest root can change its guest firewall and compromise its own application and
VPN key. The intended host bridge policy, source checks, and management isolation
still constrain its network paths. This claim must pass the spoofing and bypass
tests; it is not established by matching source IP addresses alone. Compromise of
the host or the hub is outside that claim. This resembles external per-VM policy
enforcement, not the full behavior of AWS security groups.

**Why keep the shared management bridge?**
It preserves Ansible, DNS, Vault, and the existing management IPs. Host bridge
filtering prevents guest-to-guest switching, and routed filtering prevents using
the host as a relay. Guest-only management firewall rules would leave a bypass.

**What happens to the previous plan?**
`PLAN-enterprise.md` stays untouched. This document records the revised design and
the implementation differences; older tier addresses and two-NIC descriptions
remain historical until a separate reconciliation is requested.
