"""Install QEMU/KVM and libvirt for the runner's Terraform jobs."""

import logging
import subprocess

from src.lib.system import apt_install, apt_purge, systemctl_ok

log = logging.getLogger(__name__)

PACKAGES = ["libvirt-daemon-system", "libvirt-daemon-driver-qemu", "libvirt-clients",
            "qemu-system-x86", "qemu-utils"]
SOCKET = "libvirtd.socket"
URI = "qemu:///system"


def up() -> None:
    """Install the virtualization tools, enable the socket and verify connectivity."""
    if apt_install(PACKAGES):
        log.info("KVM and libvirt installed")
    else:
        log.info("KVM and libvirt already installed")

    if systemctl_ok("is-enabled", SOCKET) and systemctl_ok("is-active", SOCKET):
        log.info("%s is already enabled and active", SOCKET)
    else:
        subprocess.run(["systemctl", "enable", "--now", SOCKET], check=True)
        log.info("%s enabled and active", SOCKET)

    subprocess.run(
        ["virsh", "--connect", URI, "list", "--all"],
        capture_output=True, text=True, check=True, timeout=30,
    )
    log.info("libvirt is ready at %s", URI)


def down() -> None:
    """Purge the host packages; VM and volume teardown belongs to Terraform."""
    apt_purge(PACKAGES)
    log.info("KVM and libvirt removed")
