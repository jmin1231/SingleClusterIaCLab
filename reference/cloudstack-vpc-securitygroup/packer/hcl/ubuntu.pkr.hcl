locals {
  image_password_hash = bcrypt(var.image_password)
}

source "qemu" "ubuntu" {
  accelerator    = "kvm"
  headless       = var.headless
  cpus           = 2
  memory         = 2048
  disk_size      = "20480M"
  disk_interface = "virtio"
  net_device     = "virtio-net"
  format         = "qcow2"

  iso_url      = "https://releases.ubuntu.com/24.04.3/ubuntu-24.04.3-live-server-amd64.iso"
  iso_checksum = "sha256:c3514bf0056180d09376462a7a1b4f213c1d6e8ea67fae5c25099c6fd3d8274b"

  boot_wait         = "10s"
  boot_key_interval = "150ms"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz quiet autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ --- <enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  http_content = {
    "/meta-data" = file("${path.root}/../http/meta-data")
    "/user-data" = templatefile("${path.root}/../http/user-data", {
      image_username      = var.image_username
      image_password_hash = local.image_password_hash
    })
  }

  communicator = "ssh"
  ssh_username = var.image_username
  ssh_password = var.image_password
  ssh_timeout  = "90m"

  output_directory = "${path.root}/../../builds/ubuntu-24.04-qemu"
  vm_name          = "ubuntu-24.04.qcow2"
  shutdown_command = "sudo /sbin/shutdown -h now"
}

build {
  sources = ["source.qemu.ubuntu"]

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo env {{ .Vars }} {{ .Path }}"
    inline = [
      "mkdir -p /etc/cloud/cloud.cfg.d",
      "cat > /etc/cloud/cloud.cfg.d/99_cloudstack.cfg << 'CLOUDCFG'",
      "datasource_list: [ ConfigDrive, None ]",
      "system_info:",
      "  default_user:",
      "    name: ${var.image_username}",
      "    lock_passwd: false",
      "CLOUDCFG",
      "echo 'policy: enabled' > /etc/cloud/ds-identify.cfg",

      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update",
      "apt-get install -y dhcpcd5",
      "rm -f /etc/netplan/00-installer-config.yaml /etc/netplan/50-cloud-init.yaml",
      "systemctl disable systemd-networkd.service systemd-networkd.socket || true",
      "systemctl enable dhcpcd.service",
      "printf 'network: {config: disabled}\\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg",

      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
      "ln -sf /etc/machine-id /var/lib/dbus/machine-id",
      "rm -f /root/.ssh/authorized_keys",
      "cloud-init clean --logs --seed"
    ]
  }
}
