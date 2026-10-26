# outputs.tf - per-VM addressing and security groups, read by verify-all.sh.

output "vms" {
  description = "mgmt IP (SSH target), tier IP, and attached security groups for each VM"
  value = {
    for name, vm in local.vms : name => {
      mgmt_ip         = cloudstack_instance.vm[name].ip_address
      tier            = vm.tier
      tier_ip         = cloudstack_nic.tier[name].ip_address
      tier_cidr       = var.tiers[vm.tier]
      security_groups = vm.security_groups
    }
  }
}
