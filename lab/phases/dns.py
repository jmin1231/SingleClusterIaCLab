"""CoreDNS: answers lab.test, forwards everything else to the host's upstream DNS."""

import logging

from lab.lib.config import VMNET
from lab.lib.system import compose
from lab.phases.preflight import detect_network

log = logging.getLogger(__name__)


def up() -> None:
    """Start CoreDNS, or leave it alone if it's already running unchanged."""
    host_ip = detect_network()["host_ip"]
    compose("coredns", "up", "-d", env={"HOST_IP": host_ip})
    log.info("CoreDNS answering lab.test on %s and %s", VMNET.ip, host_ip)


def down() -> None:
    """Remove the CoreDNS container; does nothing if it isn't there."""
    compose("coredns", "down", env={"HOST_IP": detect_network()["host_ip"]})
    log.info("CoreDNS stopped and removed")