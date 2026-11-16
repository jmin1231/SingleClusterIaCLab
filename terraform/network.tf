resource "libvirt_network" "site_a" {
  name      = "site-a"
  autostart = true

  bridge = {
    name = "site-a"
  }

  dns = {
    enable = "no"
  }
}

resource "libvirt_network" "site_hub" {
  name      = "site-hub"
  autostart = true

  bridge = {
    name = "site-hub"
  }

  dns = {
    enable = "no"
  }
}

resource "libvirt_network" "site_c" {
  name      = "site-c"
  autostart = true

  bridge = {
    name = "site-c"
  }

  dns = {
    enable = "no"
  }
}

resource "libvirt_network" "wan" {
  name      = "wan"
  autostart = true

  forward = {
    mode = "route"
  }

  bridge = {
    name = "wan"
  }

  ips = [
    {
      address = "198.51.100.1"
      prefix  = 24
    }
  ]

  dns = {
    enable = "no"
  }
}