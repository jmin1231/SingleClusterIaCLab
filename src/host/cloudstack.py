"""CloudStack 4.22 on this host, set up step by step from the official Installation Guide."""

import logging
import subprocess
import sys
import urllib.request
from pathlib import Path

from src.lib.system import apt_install, install_file

log = logging.getLogger(__name__)

FILES = Path(__file__).parent / "files"
PACKAGES = ["mysql-server", "nfs-kernel-server", "cloudstack-management", "cloudstack-agent"]

KEY_URL = "https://download.cloudstack.org/release.asc"
KEYRING = Path("/etc/apt/keyrings/cloudstack.asc")  # .asc: apt reads it as is, no gpg --dearmor
SOURCE = Path("/etc/apt/sources.list.d/lab-cloudstack.list")
PIN = Path("/etc/apt/preferences.d/lab-cloudstack")


def repo() -> bool:
    """Download CloudStack's key, add its source (signed-by that key only) and the version pin.

    Returns True if anything changed, so the caller knows apt's package lists are stale.
    """
    key = urllib.request.urlopen(KEY_URL, timeout=30).read()

    changed = not KEYRING.exists() or KEYRING.read_bytes() != key
    if changed:
        KEYRING.write_bytes(key)
        KEYRING.chmod(0o644)

    changed |= install_file(FILES / "lab-cloudstack.list", SOURCE, 0o644)
    changed |= install_file(FILES / "lab-cloudstack.pref", PIN, 0o644)

    if changed:
        log.info("CloudStack 4.22 apt repository configured")
    else:
        log.info("CloudStack 4.22 apt repository is already configured")
    return changed


def up() -> None:
    """Install CloudStack 4.22.1.1 and its dependencies; a re-run changes nothing."""
    repo()
    if not apt_install(PACKAGES):
        log.info("CloudStack packages are already installed")
