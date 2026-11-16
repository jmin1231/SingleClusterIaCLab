variable "base_image_url" {
  description = "Ubuntu 24.04 cloud image"
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "ssh_public_key_file" {
  description = "lab SSH public key for the VMs (bootstrap publishes it from Vault)"
  type        = string
  default     = "/etc/lab-runner/ssh.pub"
}

variable "lab_ca_cert_file" {
  description = "lab.test CA certificate (PEM) the VMs trust"
  type        = string
  default     = "/etc/lab-runner/ca.pem"
}