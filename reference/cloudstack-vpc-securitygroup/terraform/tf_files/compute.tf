# compute.tf - one dual-homed VM per tier (mgmt NIC for Ansible/SSH + one VPC-tier
# NIC for application traffic), with the SSH key injected via cloud-init ConfigDrive
# userdata. Each VM's security groups are attached here, in vm.security_groups.

locals {
  user_data = <<-EOT
    #cloud-config
    users:
      - name: ubuntu
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        shell: /bin/bash
        ssh_authorized_keys:
          - ${var.ssh_public_key}
  EOT

  # VM name -> the tier it sits in and the security groups attached to it.
  vms = {
    web = { tier = "web", security_groups = ["sg_admin", "sg_web"] }
    app = { tier = "app", security_groups = ["sg_admin", "sg_app"] }
    db  = { tier = "db", security_groups = ["sg_admin", "sg_db"] }
  }
}

resource "cloudstack_instance" "vm" {
  for_each = local.vms

  name             = each.key
  display_name     = each.key
  service_offering = var.service_offering
  template         = var.template
  zone             = var.zone

  network_id = var.mgmt_network_id
  user_data  = local.user_data
  expunge    = true
}

resource "cloudstack_nic" "tier" {
  for_each = local.vms

  network_id         = cloudstack_network.tier[each.value.tier].id
  virtual_machine_id = cloudstack_instance.vm[each.key].id
}
