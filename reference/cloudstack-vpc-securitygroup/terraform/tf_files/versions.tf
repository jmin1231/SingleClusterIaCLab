# versions.tf - Terraform + provider version pins (local state).

terraform {
  required_version = ">= 1.5"

  required_providers {
    cloudstack = {
      source  = "cloudstack/cloudstack"
      version = "~> 0.5"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "~> 1.3"
    }
  }
}
