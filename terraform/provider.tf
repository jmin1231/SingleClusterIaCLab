terraform {
    required_version = "= 1.17.2"

    required_providers {
        libvirt = {
            source = "dmacvicar/libvirt"
            version = "= 0.9.9"   
        }
    }

    backend "local" {
        path = "/var/lib/lab/tfstate/terraform.tfstate"
    }
}

provider "libvirt" {
    uri = "qemu:///system"
}