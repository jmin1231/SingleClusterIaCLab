"""VM firewall: loads the bridge lab_vmfw_l2 and inet lab_vmfw nftables on every up (gone after a reboot)."""

import logging
import subprocess

from src.host.config.config import VMFW_MARKER, VMFW_NFT_SRC, VMFW_TABLES
from src.host.preflight import detect_network

log = logging.getLogger(__name__)


def render_rules(network: dict) -> bytes:
    """The nft file with this host's LAN card and IP defined on top, as nft will read it."""
    header = (
        f'define lan_card = "{network["card"]}"\n'
        f'define host_ip = {network["host_ip"]}\n'
    )
    return header.encode() + VMFW_NFT_SRC.read_bytes()


def up() -> None:
    """Check and load the rules (one atomic swap, safe to repeat), then leave the marker for setup."""
    network = detect_network()
    rules = render_rules(network)

    subprocess.run(["nft", "-c", "-f", "-"], input=rules, check=True)
    subprocess.run(["nft", "-f", "-"], input=rules, check=True)

    VMFW_MARKER.parent.mkdir(parents=True, exist_ok=True)
    VMFW_MARKER.touch()
    log.info("VM firewall loaded (%s; LAN card %s, host %s)",
             ", ".join(VMFW_TABLES), network["card"], network["host_ip"])


def down() -> None:
    """Remove the two tables and the marker; other tables (libvirt, Podman) are untouched."""
    for table in VMFW_TABLES:
        subprocess.run(["nft", "destroy", "table", *table.split()], check=True)
    VMFW_MARKER.unlink(missing_ok=True)
    log.info("VM firewall removed")
