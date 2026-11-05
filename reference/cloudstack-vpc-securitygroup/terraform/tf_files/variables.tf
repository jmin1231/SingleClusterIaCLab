# variables.tf - inputs for the VPC, tiers, mgmt network, and the three VMs.

variable "cloudstack_api_url" {
  description = "CloudStack API endpoint, e.g. http://<bridge-ip>:8080/client/api"
  type        = string
}

variable "cloudstack_api_key" {
  description = "API key minted for the admin user"
  type        = string
  sensitive   = true
}

variable "cloudstack_secret_key" {
  description = "Secret key minted for the admin user"
  type        = string
  sensitive   = true
}

variable "cloudstack_timeout" {
  description = "Provider API timeout in seconds (async jobs on a single host are slow)"
  type        = number
  default     = 300
}

variable "zone" {
  description = "CloudStack zone name"
  type        = string
  default     = "Zone1"
}

variable "template" {
  description = "Golden image template name registered in Phase 2"
  type        = string
  default     = "ubuntu-24.04"
}

variable "service_offering" {
  description = "Compute offering for the VMs (CloudStack ships 'Small Instance' by default)"
  type        = string
  default     = "Small Instance"
}

variable "vpc_offering" {
  description = "VPC offering created by ensure-offerings.sh"
  type        = string
  default     = "iac-vpc-offering"
}

variable "tier_offering" {
  description = "VPC tier network offering created by ensure-offerings.sh (ConfigDrive userdata)"
  type        = string
  default     = "iac-tier-offering"
}

variable "vpc_cidr" {
  description = "CIDR for the whole VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "tiers" {
  description = "VPC tiers (subnets), one per application layer; each must sit inside vpc_cidr"
  type        = map(string)
  default = {
    web = "10.0.1.0/24"
    app = "10.0.2.0/24"
    db  = "10.0.3.0/24"
  }
}

variable "mgmt_network_id" {
  description = "UUID of the mgmt shared network, created out-of-band by terraform-apply-all.sh (the provider cannot create an untagged shared network)"
  type        = string
  default     = ""
}

variable "mgmt_cidr" {
  description = "CIDR of the mgmt shared network; set automatically from cloudbr0 by terraform-apply-all.sh"
  type        = string
}

variable "mgmt_gateway" {
  description = "Gateway for the mgmt shared network; set automatically from the host default route"
  type        = string
}

variable "mgmt_startip" {
  description = "First IP of the reserved mgmt range for the VMs; set automatically from cloudbr0"
  type        = string
}

variable "mgmt_endip" {
  description = "Last IP of the reserved mgmt range for the VMs; set automatically from cloudbr0"
  type        = string
}

variable "ssh_public_key" {
  description = "Public key injected into the VMs via ConfigDrive userdata"
  type        = string
}
