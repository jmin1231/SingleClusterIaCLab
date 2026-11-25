"""VM firewall: loads the bridge lab_sg (security groups) and inet lab_vmfw nftables on every up (gone after a reboot)."""

import logging
import subprocess

from host.config import config
from host.preflight import detect_network
from lib.system import apt_install

log = logging.getLogger(__name__)


def render_rules(network: dict) -> bytes:
    """The nft file with this host's LAN card and IP defined on top, as nft will read it."""
    header = (
        f'define lan_card = "{network["card"]}"\n'
        f'define host_ip = {network["host_ip"]}\n'
    )
    return header.encode() + config.VMFW_NFT_SRC.read_bytes()


def up() -> None:
    """Check and load the rules (one atomic swap, safe to repeat), then leave the marker for terraform.yml."""
    apt_install(config.VMFW_PACKAGES)
    # lab_sg's "ct state" rules use bridge conntrack. The kernel would load it with them (and nft refuses
    # the whole ruleset if it cannot); loading it here makes the dependency explicit and fails earlier
    subprocess.run(["modprobe", config.VMFW_BRIDGE_CT_MODULE], check=True)
    network = detect_network()
    rules = render_rules(network)

    subprocess.run(["nft", "-c", "-f", "-"], input=rules, check=True)
    subprocess.run(["nft", "-f", "-"], input=rules, check=True)

    config.VMFW_MARKER.parent.mkdir(parents=True, exist_ok=True)
    config.VMFW_MARKER.touch()
    log.info("VM firewall loaded (%s; LAN card %s, host %s)",
             ", ".join(config.VMFW_TABLES), network["card"], network["host_ip"])


def down() -> None:
    """Remove the lab's tables and the marker; libvirt's and Podman's stay."""
    for table in config.VMFW_TABLES:
        subprocess.run(["nft", "destroy", "table", *table.split()], check=True)
    config.VMFW_MARKER.unlink(missing_ok=True)
    log.info("VM firewall removed")
