# Failure Log

Real failures from running the previous build of this lab, kept because the
diagnosis is the part worth carrying forward. Each entry records what was seen,
what it actually was, and what changed as a result.

The pattern most of these share: a fault at one layer surfaces as a plausible
bug at every layer above it. Writing down where the search *should* have started
is the only way that knowledge survives.

Format: newest at the bottom.

---

## 2026-08-20 · A hung NIC that looked like six different bugs

**What was seen,** in the order it appeared over about ninety minutes:

1. An Ansible play failed on all three tier VMs at once with
   `<urlopen error [Errno -3] Temporary failure in name resolution]`, fetching a
   public apt key — after thirty-odd tasks in the same run had succeeded.
2. `terraform destroy` failed five times with CloudStack error 530,
   `Failed to delete port forwarding rule`.
3. `cmk reconnect host` refused: *unable to disconnect host because it is not
   connected to this server*.
4. The KVM host sat in state `Alert` while `cmk` still reported all three VMs
   `Running`.
5. `cmk destroy virtualmachine` failed with `Unable to stop VM instance`.
6. The management agent connected and was dropped every 17 seconds, forever.

**What it actually was:** the host's onboard Intel NIC wedged. The kernel logged
`e1000e … Detected Hardware Unit Hang` 241 times between 13:16:51 and 13:24:51,
never successfully reset the adapter, and the machine died uncleanly at 13:24:51
— `last -x` shows the boot ending with no matching `shutdown` record. It came
back at 13:26:21.

**The chain, top to bottom:**

- `eno1` is the physical port the bridge is built on. With its transmit ring
  hung the interface still reports `UP` with carrier, and packets simply never
  reach the wire.
- Traffic *inside* the bridge — CI runner to VMs, VMs to the virtual router — is
  switched in software and never touches that ring. So SSH kept working and the
  play kept passing tasks.
- External name resolution does not stay inside the bridge. The VMs asked the
  VPC router, its dnsmasq forwarded upstream, and the forward had to leave
  through `eno1`. Nothing came back, so glibc returned `EAI_AGAIN` — reported as
  *Temporary failure in name resolution* on all three tiers simultaneously.
- The reboot killed every guest, including the virtual router and both system
  VMs. CloudStack's database kept reporting them `Running`, because the agent
  was gone and nothing reconciled it.
- The agent never re-attached afterwards, so the host stayed in `Alert`, and the
  management server could not send a command to the hypervisor. Every operation
  needing the router or a guest — deleting a port forward, stopping a VM —
  failed. Those were the 530s.

One hardware fault; six symptoms, none of which pointed at it.

**Where the search should have started.** Every early hypothesis was a software
one — a resolver misconfiguration, WireGuard capturing a route, a DHCP client
rewriting `resolv.conf`, an orphaned Terraform resource, a hung NFS mount. Each
was plausible from the symptom and each was wrong. The evidence that settled it
was `journalctl -b -1`, which nobody had read for the first hour.

Order to work in, next time:

1. **Is the platform healthy?** Host state, hypervisor agent, virtual router.
   `cmk list hosts` before anything else — a host in `Alert` explains every
   downstream failure at once and makes the rest of the search pointless.
2. **Is the host healthy?** `last -x reboot`, `journalctl --list-boots`,
   `journalctl -b -1 -p err`, `dmesg`. A boot that ended with no `shutdown`
   record is a crash, and the last lines of the previous boot usually name it.
3. **Only then, the software.**

**A control plane reports its database, not reality.** `cmk` described three
running VMs for an hour after they had ceased to exist, and both Terraform and
Ansible believed it. Treat the API's view as a claim to verify, not a fact —
this is the same management/data plane separation that Phase 15.6 injects on
purpose, seen from the other side.

**What changed:**

- Disable TCP/generic segmentation and receive offload on the bridged uplink,
  and verify the link survives sustained egress before trusting the host with a
  build — see Phase 0.3.
- Add a platform-health preflight to the provisioning pipeline, so an unhealthy
  host is named in seconds rather than surfacing as a DNS error thirty tasks
  deep — see Phase 8.1.
- Two unrelated defects surfaced during the diagnosis and are recorded below.

### Defect: two Terraform resources, one port-forward ID

The previous lab declared SSH forwards with `for_each` over the tiers, then
declared the two `:80` forwards as separate resources pointing at the same
public IPs. On destroy, two pairs of resources printed *identical* Terraform IDs.

`cloudstack_port_forward` is keyed by `ip_address_id` — the resource's ID *is*
the IP's ID, and the resource owns that IP's entire rule set. Splitting the
rules on one IP across two resources gives two Terraform addresses the same
identity: they race to own the same rules on refresh, and on destroy each tears
down an IP the other is also tearing down.

**The rule:** one `cloudstack_port_forward` resource per public IP, every rule
for that IP expressed as a `forward` block inside it. Phase 7.3 states this as a
constraint.

This was not the cause of the 530s — the first delete failed before any
double-delete could occur — but it would have corrupted state eventually.

### Defect: the installer tracker records presence, not value

The vendored CloudStack installer decides what to skip with:

```bash
is_step_tracked() { [[ -n "${tracker_values[$key]:-}" ]]; }
```

That tests whether the key has a **non-empty value**, not whether it says `yes`.
So `db_deployed=no` reads as *done* and the step is skipped. Two full installer
runs were lost to editing `yes` into `no` and watching nothing happen.

To genuinely re-run a step, **delete its line** from the tracker file; an empty
value works too. And note the database step carries a second, independent guard
that queries MySQL directly and re-marks the tracker `yes` if the `cloud`
database exists — deliberate, per its comment, so a wiped tracker cannot destroy
a working deployment. Rebuilding the database therefore means dropping it first;
the tracker alone cannot express that intent.

Phase 1.3 covers both traps.
