resource "libvirt_network" "frontend" {
  name      = "tier-frontend"
  autostart = true

  forward = {
    mode = "route"
  }

  bridge = {
    name = "tier-fe"
  }

  ips = [
    {
      address = "10.0.1.1"
      prefix  = 24
    }
  ]

  dns = {
    enable = "no"
  }
}

resource "libvirt_network" "tunnel" {
  name      = "tier-tunnel"
  autostart = true

  forward = {
    mode = "route"
  }

  bridge = {
    name = "tier-tun"
  }

  ips = [
    {
      address = "10.0.2.1"
      prefix  = 24
    }
  ]

  dns = {
    enable = "no"
  }
}

resource "libvirt_network" "backend" {
  name      = "tier-backend"
  autostart = true

  forward = {
    mode = "route"
  }

  bridge = {
    name = "tier-be"
  }

  ips = [
    {
      address = "10.0.3.1"
      prefix  = 24
    }
  ]

  dns = {
    enable = "no"
  }
}