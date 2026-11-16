locals {
  vms = {
    "fe-1" = {
      group    = "frontend"
      vcpu     = 1
      memory   = 1024
      disk_gb  = 10
      network  = libvirt_network.site_a.name
      vpc_ip   = "10.1.1.10"
      wan_ip   = "198.51.100.11"
      mgmt_ip  = "10.250.0.110"
      vpc_mac  = "52:54:00:01:00:10"
      wan_mac  = "52:54:00:fb:01:10"
      mgmt_mac = "52:54:00:fa:01:10"
    }
    "tun-1" = {
      group    = "hub"
      vcpu     = 1
      memory   = 512 # WireGuard only
      disk_gb  = 10
      network  = libvirt_network.site_hub.name
      vpc_ip   = "10.2.1.10"
      wan_ip   = "198.51.100.12"
      mgmt_ip  = "10.250.0.111"
      vpc_mac  = "52:54:00:02:00:10"
      wan_mac  = "52:54:00:fb:02:10"
      mgmt_mac = "52:54:00:fa:02:10"
    }
    "be-1" = {
      group    = "backend"
      vcpu     = 2 # k3s minimum; the host has 4 cores
      memory   = 4096
      disk_gb  = 40
      network  = libvirt_network.site_c.name
      vpc_ip   = "10.3.1.10"
      wan_ip   = "198.51.100.13"
      mgmt_ip  = "10.250.0.112"
      vpc_mac  = "52:54:00:03:00:10"
      wan_mac  = "52:54:00:fb:03:10"
      mgmt_mac = "52:54:00:fa:03:10"
    }
  }
}

# Each VM's own disk
resource "libvirt_volume" "disk" {
  for_each      = local.vms
  name          = "${each.key}-${each.value.disk_gb}g.qcow2"
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

  lifecycle {
    replace_triggered_by = [libvirt_volume.base, libvirt_volume.seed[each.key]]
  }
}

# Cloud-init seed
resource "libvirt_cloudinit_disk" "seed" {
  for_each = local.vms
  name     = "${each.key}-seed"
  user_data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    ssh_public_key = trimspace(file(var.ssh_public_key_file))
    lab_ca_cert    = file(var.lab_ca_cert_file)
  })
  meta_data      = yamlencode({ instance-id = each.key, local-hostname = each.key })
  network_config = templatefile("${path.module}/cloud-init/network-config.yaml.tftpl", each.value)
}

# cloud-init seed volume
resource "libvirt_volume" "seed" {
  for_each = local.vms
  name     = "${each.key}-seed.iso"
  pool     = libvirt_pool.lab.name
  target   = { format = { type = "iso" } }
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
  autostart   = false # vmfw rules vanish on reboot; no VM boots before `bootstrap up` reloads them

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
    # File paths, not pool volumes: libvirt's AppArmor helper only allows disks it sees as files.
    disks = [
      {
        source = {
          file = {
            file = libvirt_volume.disk[each.key].path
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
          file = {
            file = libvirt_volume.seed[each.key].path
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]
    interfaces = [
      { # eth0: the site's private network
        model  = { type = "virtio" }
        mac    = { address = each.value.vpc_mac }
        source = { network = { network = each.value.network } }
        target = { dev = "${each.key}-vpc" }
      },
      { # eth1: wan
        model  = { type = "virtio" }
        mac    = { address = each.value.wan_mac }
        source = { network = { network = libvirt_network.wan.name } }
        target = { dev = "${each.key}-wan" }
      },
      { # eth2: mgmt
        model  = { type = "virtio" }
        mac    = { address = each.value.mgmt_mac }
        source = { bridge = { bridge = "cloudbr1" } }
        target = { dev = "${each.key}-mgmt" }
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

  # A new overlay means a new VM (the overlay keeps its name, so nothing else would tell Terraform).
  lifecycle {
    replace_triggered_by = [libvirt_volume.disk[each.key]]
  }
}
