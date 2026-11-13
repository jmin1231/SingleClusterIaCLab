"""Install Podman and Compose from the Ubuntu archive, and enable the API socket Compose talks to."""

import logging
import shutil
import subprocess

from src.lib.system import apt_install, apt_purge, missing_packages, systemctl_ok

log = logging.getLogger(__name__)

PACKAGES = ["podman", "netavark", "aardvark-dns", "docker-compose-v2"]
SOCKET = "podman.socket"


def socket_ready() -> bool:
    return systemctl_ok("is-enabled", SOCKET) and systemctl_ok("is-active", SOCKET)


def check() -> bool:
    return not missing_packages(PACKAGES) and socket_ready()


def up() -> None:
    """Install what is missing and enable the socket; a re-run changes nothing."""
    if not apt_install(PACKAGES):
        log.info("Podman and Compose are already installed")

    if socket_ready():
        log.info("%s is already enabled and active", SOCKET)
    else:
        subprocess.run(["systemctl", "enable", "--now", SOCKET], check=True)
        log.info("%s enabled and active", SOCKET)


def down() -> None:
    """Remove every container, image and volume, disable the socket and purge the packages."""
    if shutil.which("podman"):
        subprocess.run(["systemctl", "disable", "--now", SOCKET], check=True)
        # The official wipe: stops containers and unmounts storage before deleting it
        subprocess.run(["podman", "system", "reset", "--force"], check=True)
    shutil.rmtree("/var/lib/containers", ignore_errors=True)
    apt_purge(PACKAGES)
    log.info("Podman, its containers and images removed")
