resource "ansible_host" "vm" {
  for_each = local.vms
  name     = each.key
  groups   = [each.value.group]
  variables = {
    ansible_host = each.value.mgmt_ip
    ansible_user = "user"
  }
}