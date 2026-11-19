"""Squid: the VMs' only way to the internet, an allowlist proxy on 10.250.0.1:3128."""

import hashlib
import logging
from pathlib import Path

from lib import config
from lib.system import compose
from podman import podman

SQUID_CONF = Path(__file__).parent / "conf" / "squid.conf"

log = logging.getLogger(__name__)


def up() -> None:
    """Start Squid; a changed squid.conf recreates the container, an unchanged one leaves it alone."""
    conf_hash = hashlib.sha256(SQUID_CONF.read_bytes()).hexdigest()
    compose("squid", "up", "-d", env={"SQUID_CONF_HASH": conf_hash})
    log.info("Squid proxying the allowlist on %s:3128", config.VMNET.ip)


def down() -> None:
    """Remove the Squid container; does nothing if it isn't there."""
    if not podman.check():
        log.info("Podman is not set up; no Squid container to remove")
        return
    compose("squid", "down")
    log.info("Squid stopped and removed")
