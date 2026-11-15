resource libvirt_pool "lab" {
    name = "lab"
    type = "dir"
    target = {
        path = "/var/lib/lab/pool"
    }
}

resource "libvirt_volume" "base" {
    name = "ubuntu-24.04-20261017.qcow2"
    pool = libvirt_pool.lab.name
    target = {
        format = {
            type = "qcow2"
        }
    }
    create = {
        content = {
            url = var.base_image_url
        }
    }
}