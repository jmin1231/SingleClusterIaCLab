"""Install Podman 6 (pinned home:alvistack repo) and Compose, and enable the API socket Compose talks to."""

import logging
import shutil
import subprocess
import urllib.request

from src.lib.system import apt_install, apt_purge, install_file, missing_packages, systemctl_ok
from src.services.podman.config.config import (
    FILES, PACKAGES, DEPENDENCIES, KEY_URL, KEYRING, SOURCE, PIN, SOCKET,
)

log = logging.getLogger(__name__)


def repo() -> None:
    """Add the home:alvistack key, source and pin (Podman packages only); a re-run changes nothing."""
    key = urllib.request.urlopen(KEY_URL, timeout=30).read()
    changed = not KEYRING.exists() or KEYRING.read_bytes() != key
    if changed:
        KEYRING.write_bytes(key)
        KEYRING.chmod(0o644)
    changed |= install_file(FILES / "lab-alvistack.list", SOURCE, 0o644)
    changed |= install_file(FILES / "lab-alvistack.pref", PIN, 0o644)

    if changed:
        log.info("Podman apt repository (home:alvistack) configured")
    else:
        log.info("Podman apt repository is already configured")


def socket_ready() -> bool:
    return systemctl_ok("is-enabled", SOCKET) and systemctl_ok("is-active", SOCKET)


def check() -> bool:
    return not missing_packages(PACKAGES) and socket_ready()


def up() -> None:
    """Install what is missing and enable the socket; a re-run changes nothing."""
    repo()
    if not apt_install(PACKAGES):
        log.info("Podman and Compose are already installed")

    if socket_ready():
        log.info("%s is already enabled and active", SOCKET)
    else:
        subprocess.run(["systemctl", "enable", "--now", SOCKET], check=True)
        log.info("%s enabled and active", SOCKET)


def down() -> None:
    """Remove every container, image and volume, disable the socket, purge the packages and the repo."""
    if shutil.which("podman"):
        subprocess.run(["systemctl", "disable", "--now", SOCKET], check=True)
        # The official wipe: stops containers and unmounts storage before deleting it
        subprocess.run(["podman", "system", "reset", "--force"], check=True)
    shutil.rmtree("/var/lib/containers", ignore_errors=True)
    # Only what is installed: once the repo is gone, apt no longer knows names like podman-netavark
    lab_packages = PACKAGES + DEPENDENCIES
    missing = missing_packages(lab_packages)
    installed = [pkg for pkg in lab_packages if pkg not in missing]
    if installed:
        apt_purge(installed)
    for path in (KEYRING, SOURCE, PIN):
        path.unlink(missing_ok=True)
    log.info("Podman, its containers, images, packages and apt repository removed")
