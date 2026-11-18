"""Install Podman 6 (pinned home:alvistack repo) and Compose, and enable the API socket Compose talks to."""

import logging
import shutil
import subprocess
import urllib.request

from src.lib.system import apt_install, apt_purge, install_file, missing_packages, systemctl_ok
from src.services.podman.config import config

log = logging.getLogger(__name__)


def repo() -> None:
    """Add the home:alvistack key, source and pin (Podman packages only); a re-run changes nothing."""
    key = urllib.request.urlopen(config.KEY_URL, timeout=30).read()
    changed = not config.KEYRING.exists() or config.KEYRING.read_bytes() != key
    if changed:
        config.KEYRING.write_bytes(key)
        config.KEYRING.chmod(0o644)
    changed |= install_file(config.FILES / "lab-alvistack.list", config.SOURCE, 0o644)
    changed |= install_file(config.FILES / "lab-alvistack.pref", config.PIN, 0o644)

    if changed:
        log.info("Podman apt repository (home:alvistack) configured")
    else:
        log.info("Podman apt repository is already configured")


def socket_ready() -> bool:
    return systemctl_ok("is-enabled", config.SOCKET) and systemctl_ok("is-active", config.SOCKET)


def check() -> bool:
    return not missing_packages(config.PACKAGES) and socket_ready()


def up() -> None:
    """Install what is missing and enable the socket; a re-run changes nothing."""
    repo()
    if not apt_install(config.PACKAGES):
        log.info("Podman and Compose are already installed")

    if socket_ready():
        log.info("%s is already enabled and active", config.SOCKET)
    else:
        subprocess.run(["systemctl", "enable", "--now", config.SOCKET], check=True)
        log.info("%s enabled and active", config.SOCKET)


def down() -> None:
    """Remove every container, image and volume, disable the socket, purge the packages and the repo."""
    if shutil.which("podman"):
        subprocess.run(["systemctl", "disable", "--now", config.SOCKET], check=True)
        # The official wipe: stops containers and unmounts storage before deleting it
        subprocess.run(["podman", "system", "reset", "--force"], check=True)
    shutil.rmtree("/var/lib/containers", ignore_errors=True)
    # Only what is installed: once the repo is gone, apt no longer knows names like podman-netavark
    lab_packages = config.PACKAGES + config.DEPENDENCIES
    missing = missing_packages(lab_packages)
    installed = [pkg for pkg in lab_packages if pkg not in missing]
    if installed:
        apt_purge(installed)
    for path in (config.KEYRING, config.SOURCE, config.PIN):
        path.unlink(missing_ok=True)
    log.info("Podman, its containers, images, packages and apt repository removed")
