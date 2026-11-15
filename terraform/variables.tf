variable "base_image_url" {
  description = "Ubuntu 24.04 cloud image"
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "ssh_public_key" {
  description = "ssh public key for vms"
  type        = string
}

variable "lab_ca_cert" {
  description = "lab.test CA certificate (PEM) trusted by the VMs"
  type        = string
}