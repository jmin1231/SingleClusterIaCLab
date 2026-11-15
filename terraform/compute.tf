locals {
  vms = {
    "fe-1" = {
      group    = "frontend"
      vcpu     = 1
      memory   = 1024
      disk_gb  = 10
      network  = libvirt_network.frontend.name
      tier_ip  = "10.0.1.10"
      gateway  = "10.0.1.1"
      mgmt_ip  = "10.250.0.110"
      tier_mac = "52:54:00:01:00:10"
      mgmt_mac = "52:54:00:fa:01:10"
    }
    "tun-1" = {
      group    = "hub"
      vcpu     = 1
      memory   = 1024
      disk_gb  = 10
      network  = libvirt_network.tunnel.name
      tier_ip  = "10.0.2.10"
      gateway  = "10.0.2.1"
      mgmt_ip  = "10.250.0.111"
      tier_mac = "52:54:00:02:00:10"
      mgmt_mac = "52:54:00:fa:02:10"
    }
    "be-1" = {
      group    = "backend"
      vcpu     = 4
      memory   = 6144
      disk_gb  = 40
      network  = libvirt_network.backend.name
      tier_ip  = "10.0.3.10"
      gateway  = "10.0.3.1"
      mgmt_ip  = "10.250.0.112"
      tier_mac = "52:54:00:03:00:10"
      mgmt_mac = "52:54:00:fa:03:10"
    }
  }
}

# Each VM's own disk
resource "libvirt_volume" "disk" {
  for_each      = local.vms
  name          = "${each.key}.qcow2"
  pool          = libvirt_pool.lab.name
  capacity      = each.value.disk_gb
  capacity_unit = "GiB"
  target = {
    format = {
      type = "qcow2"
    }
  }
  backing_store = {
    path = libvirt_volume.base.path
    format = {
      type = "qcow2"
    }
  }
}

# Cloud-init seed
resource "libvirt_cloudinit_disk" "seed" {
  for_each = local.vms
  name     = "${each.key}-seed"
  user_data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    hostname       = each.key
    ssh_public_key = var.ssh_public_key
    lab_ca_cert    = var.lab_ca_cert
  })
  meta_data      = yamlencode({ instance-id = each.key, local-hostname = each.key })
  network_config = templatefile("${path.module}/cloud-init/network-config.yaml.tftpl", each.value)
}

# cloud-init seed volume
resource "libvirt_volume" "seed" {
  for_each = local.vms
  name     = "${each.key}-seed.iso"
  pool     = libvirt_pool.lab.name
  target   = { format = { type = "raw" } }
  create   = { content = { url = libvirt_cloudinit_disk.seed[each.key].path } }
}

resource "libvirt_domain" "vm" {
  for_each    = local.vms
  name        = each.key
  type        = "kvm"
  vcpu        = each.value.vcpu
  memory      = each.value.memory
  memory_unit = "MiB"
  running     = true
  autostart   = true

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [
      {
        dev = "hd"
      }
    ]
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_pool.lab.name
            volume = libvirt_volume.disk[each.key].name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        driver = {
          name = "qemu"
          type = "qcow2"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_pool.lab.name
            volume = libvirt_volume.seed[each.key].name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      { # eth0: tier
        model  = { type = "virtio" }
        mac    = { address = each.value.tier_mac }
        source = { network = { network = each.value.network } }
      },
      { # eth1: mgmt
        model  = { type = "virtio" }
        mac    = { address = each.value.mgmt_mac }
        source = { bridge = { bridge = "cloudbr1" } }
      }
    ]
    serials = [
      {
        target = {
          port = 0
        }
      }
    ]
    consoles = [
      {
        target = {
          type = "serial"
          port = 0
        }
      }
    ]
  }
}