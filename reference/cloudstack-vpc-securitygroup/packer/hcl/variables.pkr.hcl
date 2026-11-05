variable "image_username" {
  description = "username created in the image"
  type        = string
  default     = "user"
}

variable "image_password" {
  description = "password for the account created in the image"
  type        = string
  sensitive   = true
  default     = "password"
}

variable "headless" {
  description = "Run QEMU without a display"
  type        = bool
  default     = true
}