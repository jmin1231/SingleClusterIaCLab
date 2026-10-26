# network.tf - a VPC with three tiers (web/app/db) behind one coarse network ACL,
# plus a shared mgmt network on cloudbr0 for Ansible. The ACL only draws the subnet
# boundary (anything inside the VPC may talk); the per-VM security groups decide
# which instance may reach which port.

resource "cloudstack_vpc" "lab" {
  name         = "iac-vpc"
  cidr         = var.vpc_cidr
  vpc_offering = var.vpc_offering
  zone         = var.zone
}

resource "cloudstack_network_acl" "vpc_internal" {
  name   = "vpc-internal-acl"
  vpc_id = cloudstack_vpc.lab.id
}

resource "cloudstack_network_acl_ruleset" "vpc_internal" {
  acl_id  = cloudstack_network_acl.vpc_internal.id
  managed = true

  rule {
    rule_number  = 10
    action       = "allow"
    protocol     = "all"
    cidr_list    = [var.vpc_cidr]
    traffic_type = "ingress"
  }

  rule {
    rule_number  = 20
    action       = "allow"
    protocol     = "all"
    cidr_list    = [var.vpc_cidr]
    traffic_type = "egress"
  }
}

resource "cloudstack_network" "tier" {
  for_each = var.tiers

  name             = "tier-${each.key}"
  cidr             = each.value
  gateway          = cidrhost(each.value, 1)
  network_offering = var.tier_offering
  vpc_id           = cloudstack_vpc.lab.id
  acl_id           = cloudstack_network_acl.vpc_internal.id
  zone             = var.zone
}