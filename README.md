# SingleClusterIaCLab

One Ubuntu 24.04 host becomes a small, enterprise-shaped private cloud:
CloudStack IaaS, a VPC with isolated tiers and a WireGuard site-to-site VPN, and a
k3s application platform with Vault as the encryption service and CA, all behind an
Istio ambient mesh.

**[`PLAN-enterprise.md`](PLAN-enterprise.md) is the plan, and the only one.**
It covers scope, addresses, secrets, phases, verification and teardown. Build from it.

## Usage

```sh
sudo ./bootstrap.sh up            # build everything (--core: required parts only)
sudo ./bootstrap.sh demo          # prove every requirement
sudo ./bootstrap.sh down          # remove it all and reboot
sudo ./bootstrap.sh revert-check  # after the reboot: host matches its baseline
```

Host: 8 cores, 32 GB RAM (the ceiling the lab is budgeted to), 250 GB disk, `/dev/kvm` (PLAN §5).

*This README is a stub; PLAN Phase 14.1 replaces it.*
