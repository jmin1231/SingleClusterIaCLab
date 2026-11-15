"""KVM and libvirt"""

import logging
import subprocess

from src.lib.system import apt_install, apt_purge, systemctl_ok

log = logging.getLogger(__name__)

PACKAGES = ["libvirt-daemon-system", "libvirt-clients", "qemu-system-x86", "qemu-utils"]
SOCKET = "libvirtd.socket"

def up() -> None:
    """Install kvm and libvirt"""
    if apt_install(PACKAGES):
        log.info("KVM and libvirt installed")
    else:
        log.info("KVM and libvirt already installed")

    if systemctl_ok("is-enabled", SOCKET) and systemctl_ok("is-active", SOCKET):
        log.info("%s is already enabled and active", SOCKET)
    else:
        subprocess.run(["systemclt", "enable", "--now", SOCKET], check=True)
        log.info("%s enabled and active", SOCKET)


def down() -> None:
    """Purge KVM and libvirt"""
    apt_purge(PACKAGES)
    log.info("KVM and libvirt removed")