"""Create the host-only bridge cloudbr1 that the VMs use to reach the host.

The host also asks CoreDNS (on cloudbr1) for lab.test names, and nothing else.
"""

import ipaddress
import logging
import subprocess
import sys
import time
from pathlib import Path

from src.host.config import config
from src.lib import config as lab_config
from src.lib.system import install_file, ip_json

log = logging.getLogger(__name__)


def vmnet_conflicts() -> list[str]:
    """Routes on the host, other than cloudbr1's own, that overlap the VM network."""
    conflicts = []
    for route in ip_json("-4", "route", "show"):
        if route["dst"] == "default" or route.get("dev") == lab_config.BRIDGE:
            continue
        if ipaddress.ip_network(route["dst"], strict=False).overlaps(lab_config.VMNET.network):
            conflicts.append(f"{route['dst']} on {route.get('dev', '?')}")
    return conflicts


def check() -> bool:
    """cloudbr1 exists and holds the host's VM-network address."""
    return any(addr["local"] == str(lab_config.VMNET.ip)
               for link in ip_json("-4", "addr", "show") if link["ifname"] == lab_config.BRIDGE
               for addr in link["addr_info"])


def reattach_taps() -> None:
    """Put the running VMs' mgmt taps back on cloudbr1; netplan apply rebuilds the bridge without them."""
    links = {link["ifname"]: link for link in ip_json("link", "show")}
    for tap in (f"{vm}-mgmt" for vm in config.LAB_DOMAINS):  # terraform/compute.tf names them <vm>-mgmt
        if tap in links and links[tap].get("master") != lab_config.BRIDGE:
            subprocess.run(["ip", "link", "set", tap, "master", lab_config.BRIDGE], check=True)
            log.info("reattached %s to %s", tap, lab_config.BRIDGE)


def up() -> None:
    """Install the lab's netplan file and create cloudbr1; a re-run changes nothing."""
    conflicts = vmnet_conflicts()  # ignores cloudbr1's own route, so a re-run passes
    if conflicts:
        log.error("%s is already in use: %s", lab_config.VMNET.network, ", ".join(conflicts))
        sys.exit(1)

    if not install_file(config.NETPLAN_SRC, config.NETPLAN_FILE, 0o600) and check():
        reattach_taps()  # also repairs taps a crashed run or an outside netplan apply left detached
        log.info("%s is already up with %s", lab_config.BRIDGE, lab_config.VMNET)
        return
    subprocess.run(["netplan", "apply"], check=True)

    # netplan apply returns once NetworkManager restarts; the address appears a moment later
    deadline = time.monotonic() + config.BRIDGE_UP_TIMEOUT
    while not check():
        if time.monotonic() > deadline:
            log.error("%s did not come up with %s within %ds of netplan apply",
                      lab_config.BRIDGE, lab_config.VMNET, config.BRIDGE_UP_TIMEOUT)
            sys.exit(1)
        time.sleep(1)
    reattach_taps()
    log.info("%s is up with %s", lab_config.BRIDGE, lab_config.VMNET)


def down() -> None:
    """Remove the file, the bridge and its anchor port (networkd leaves removed devices in place)."""
    config.NETPLAN_FILE.unlink(missing_ok=True)
    subprocess.run(["netplan", "apply"], check=True)
    for dev in (lab_config.BRIDGE, config.BRIDGE_ANCHOR):
        if Path("/sys/class/net", dev).exists():
            subprocess.run(["ip", "link", "delete", dev], check=True)
    log.info("%s and %s removed", lab_config.BRIDGE, config.NETPLAN_FILE)
