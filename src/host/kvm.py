"""Install QEMU/KVM and libvirt for the runner's Terraform jobs."""

import logging
import shutil
import subprocess

from src.host.config import config
from src.lib.system import apt_install, apt_purge, systemctl_ok

log = logging.getLogger(__name__)


def up() -> None:
    """Install the virtualization tools, enable the socket and verify connectivity."""
    if apt_install(config.KVM_PACKAGES):
        log.info("KVM and libvirt installed")
    else:
        log.info("KVM and libvirt already installed")

    if systemctl_ok("is-enabled", config.LIBVIRT_SOCKET) and systemctl_ok("is-active", config.LIBVIRT_SOCKET):
        log.info("%s is already enabled and active", config.LIBVIRT_SOCKET)
    else:
        subprocess.run(["systemctl", "enable", "--now", config.LIBVIRT_SOCKET], check=True)
        log.info("%s enabled and active", config.LIBVIRT_SOCKET)

    subprocess.run(
        ["virsh", "--connect", config.LIBVIRT_URI, "list", "--all"],
        capture_output=True, text=True, check=True, timeout=30,
    )
    log.info("libvirt is ready at %s", config.LIBVIRT_URI)


def remove_lab_vms() -> None:
    """Stop and remove the lab's VMs, networks and pool; whatever is already gone is skipped."""
    steps = [("destroy", d) for d in config.LAB_DOMAINS] + [("undefine", d) for d in config.LAB_DOMAINS]
    steps += [("net-destroy", n) for n in config.LAB_NETWORKS] + [("net-undefine", n) for n in config.LAB_NETWORKS]
    steps += [("pool-destroy", config.LAB_POOL), ("pool-undefine", config.LAB_POOL)]
    for verb, name in steps:
        subprocess.run(["virsh", "--connect", config.LIBVIRT_URI, verb, name], capture_output=True)
    log.info("lab VMs, networks and pool removed from libvirt")


def down() -> None:
    """Remove the lab's VMs from libvirt, then purge the host packages; the disk files go with /var/lib/lab."""
    if shutil.which("virsh"):
        remove_lab_vms()
    apt_purge(config.KVM_PACKAGES)
    log.info("KVM and libvirt removed")
