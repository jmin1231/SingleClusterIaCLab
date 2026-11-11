"""Install Podman and Compose from the Ubuntu archive, and enable the API socket Compose talks to."""

import logging
import os
import subprocess

log = logging.getLogger(__name__)

PACKAGES = ["podman", "netavark", "aardvark-dns", "docker-compose-v2"]
SOCKET = "podman.socket"
COMPOSE = "/usr/libexec/docker/cli-plugins/docker-compose"

APT_ENV = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}


def missing_packages() -> list[str]:
    """The packages in PACKAGES that are not installed."""
    missing = []
    for pkg in PACKAGES:
        result = subprocess.run(["dpkg-query", "-W", "-f=${db:Status-Status}", pkg],
                                capture_output=True, text=True)
        if result.stdout != "installed":
            missing.append(pkg)
    return missing


def socket_ready() -> bool:
    enabled = subprocess.run(["systemctl", "is-enabled", "--quiet", SOCKET]).returncode == 0
    active = subprocess.run(["systemctl", "is-active", "--quiet", SOCKET]).returncode == 0
    return enabled and active


def check() -> bool:
    return not missing_packages() and socket_ready()


def up() -> None:
    """Install what is missing and enable the socket; a re-run changes nothing."""
    missing = missing_packages()
    if missing:
        log.info("installing %s", ", ".join(missing))
        subprocess.run(["apt-get", "-qq", "update"], check=True, env=APT_ENV)
        subprocess.run(["apt-get", "install", "-y", "-qq", "-o", "DPkg::Lock::Timeout=120", *missing],
                       check=True, env=APT_ENV)
    else:
        log.info("Podman and Compose are already installed")

    if socket_ready():
        log.info("%s is already enabled and active", SOCKET)
    else:
        subprocess.run(["systemctl", "enable", "--now", SOCKET], check=True)
        log.info("%s enabled and active", SOCKET)


def down() -> None:
    """Disable the socket and purge the packages (destroy)."""
    subprocess.run(["systemctl", "disable", "--now", SOCKET], check=False)
    subprocess.run(["apt-get", "purge", "-y", "-qq", *PACKAGES], check=True, env=APT_ENV)
