# inventory.tf - the Ansible inventory as resources, read from state by the
# cloud.terraform.terraform_provider plugin. Each VM's security groups become its
# Ansible groups, so group membership is what the security group rules resolve
# against (a rule "from sg_web" matches every host in the sg_web group).

resource "ansible_group" "lab" {
  name = "lab"
  variables = {
    vpc_cidr  = var.vpc_cidr
    mgmt_cidr = var.mgmt_cidr
  }
}

resource "ansible_host" "vm" {
  for_each = local.vms

  name   = each.key
  groups = concat([ansible_group.lab.name], each.value.security_groups)
  variables = {
    ansible_host = cloudstack_instance.vm[each.key].ip_address
    tier         = each.value.tier
    tier_ip      = cloudstack_nic.tier[each.key].ip_address
    tier_gateway = cloudstack_network.tier[each.value.tier].gateway
  }
}
