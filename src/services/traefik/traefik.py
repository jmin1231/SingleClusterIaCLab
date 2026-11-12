"""Traefik: the HTTPS gateway on 10.250.0.1:443 for the control-plane web services."""

import logging

from src.host import podman
from src.lib.config import VMNET
from src.lib.system import compose

log = logging.getLogger(__name__)


def up(certs_changed: bool) -> None:
    """Start Traefik (and whoami until 2.8); recreate only when 2.5a issued new certificates."""
    compose("traefik", "up", "-d", *(["--force-recreate"] if certs_changed else ["--no-recreate"]))
    log.info("Traefik serving HTTPS on %s:443", VMNET.ip)


def down() -> None:
    """Remove the Traefik containers and the lab-backend network (Traefik keeps no state)."""
    if not podman.check():
        log.info("Podman is not set up; no Traefik container to remove")
        return
    compose("traefik", "down")
    log.info("Traefik removed")
