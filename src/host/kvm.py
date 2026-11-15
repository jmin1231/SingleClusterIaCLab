"""Install QEMU/KVM and libvirt for the runner's Terraform jobs."""

import logging
import subprocess

from src.host.config.config import KVM_PACKAGES, LIBVIRT_SOCKET, LIBVIRT_URI
from src.lib.system import apt_install, apt_purge, systemctl_ok

log = logging.getLogger(__name__)


def up() -> None:
    """Install the virtualization tools, enable the socket and verify connectivity."""
    if apt_install(KVM_PACKAGES):
        log.info("KVM and libvirt installed")
    else:
        log.info("KVM and libvirt already installed")

    if systemctl_ok("is-enabled", LIBVIRT_SOCKET) and systemctl_ok("is-active", LIBVIRT_SOCKET):
        log.info("%s is already enabled and active", LIBVIRT_SOCKET)
    else:
        subprocess.run(["systemctl", "enable", "--now", LIBVIRT_SOCKET], check=True)
        log.info("%s enabled and active", LIBVIRT_SOCKET)

    subprocess.run(
        ["virsh", "--connect", LIBVIRT_URI, "list", "--all"],
        capture_output=True, text=True, check=True, timeout=30,
    )
    log.info("libvirt is ready at %s", LIBVIRT_URI)


def down() -> None:
    """Purge the host packages; VM and volume teardown belongs to Terraform."""
    apt_purge(KVM_PACKAGES)
    log.info("KVM and libvirt removed")
