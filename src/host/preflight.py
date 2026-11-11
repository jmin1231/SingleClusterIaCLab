"""Check that the host can run the lab before anything is installed."""

import logging
import os
import sys

from src.lib.system import ip_json

log = logging.getLogger(__name__)


def check_host() -> None:
    """Stop unless /dev/kvm is usable."""
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        log.error("/dev/kvm is missing or not usable (is nested virtualization on?)")
        sys.exit(1)

    log.info("KVM is usable")


def detect_network() -> dict:
    """The host's LAN, read live: the default route's card and gateway, and that card's address."""
    route = ip_json("-4", "route", "show", "default")[0]
    card = route["dev"]
    gateway = route["gateway"]

    link = ip_json("-4", "addr", "show", "dev", card)[0]
    addr = link["addr_info"][0]

    return {
        "card": card,
        "host_ip": addr["local"],
        "prefix": addr["prefixlen"],
        "gateway": gateway,
        "dhcp": addr.get("dynamic", False),
    }


def log_network() -> None:
    """Log the host's LAN, so every run records what the lab is building on."""
    network = detect_network()
    log.info("LAN: %s on %s/%d, gateway %s (%s)",
             network["card"], network["host_ip"], network["prefix"], network["gateway"],
             "DHCP" if network["dhcp"] else "static")


def up() -> None:
    check_host()
    log_network()
