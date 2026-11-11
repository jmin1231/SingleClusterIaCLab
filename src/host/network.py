"""Create the host-only bridge cloudbr1 that the VMs use to reach the host.

The host also asks CoreDNS (on cloudbr1) for lab.test names, and nothing else.
"""

import ipaddress
import json
import logging
import subprocess
import sys
import time
from pathlib import Path

from src.lib.config import BRIDGE, VMNET
from src.lib.system import ip_json

log = logging.getLogger(__name__)

ANCHOR = "cloudbr1-anchor"  # the bridge's always-up port; see the netplan file
NETPLAN_SRC = Path(__file__).parent / "files" / "60-lab-cloudbr1.yaml"
NETPLAN_FILE = Path("/etc/netplan") / NETPLAN_SRC.name
UP_TIMEOUT = 30  # seconds; NetworkManager activates the bridge after netplan apply returns


def vmnet_conflicts() -> list[str]:
    """Routes on the host, other than cloudbr1's own, that overlap the VM network."""
    conflicts = []
    for route in ip_json("-4", "route", "show"):
        if route["dst"] == "default" or route.get("dev") == BRIDGE:
            continue
        if ipaddress.ip_network(route["dst"], strict=False).overlaps(VMNET.network):
            conflicts.append(f"{route['dst']} on {route.get('dev', '?')}")
    return conflicts


def check() -> bool:
    """cloudbr1 exists and holds the host's VM-network address."""
    result = subprocess.run(["ip", "-j", "-4", "addr", "show", "dev", BRIDGE],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return False
    return any(addr["local"] == str(VMNET.ip)
               for link in json.loads(result.stdout) for addr in link["addr_info"])


def up() -> None:
    """Install the lab's netplan file and create cloudbr1; a re-run changes nothing."""
    netplan = NETPLAN_SRC.read_bytes()
    if NETPLAN_FILE.exists() and NETPLAN_FILE.read_bytes() == netplan and check():
        log.info("%s is already up with %s", BRIDGE, VMNET)
        return

    conflicts = vmnet_conflicts()
    if conflicts:
        log.error("%s is already in use: %s", VMNET.network, ", ".join(conflicts))
        sys.exit(1)

    NETPLAN_FILE.write_bytes(netplan)
    NETPLAN_FILE.chmod(0o600)
    subprocess.run(["netplan", "apply"], check=True)

    # netplan apply returns once NetworkManager restarts; the address appears a moment later
    deadline = time.monotonic() + UP_TIMEOUT
    while not check():
        if time.monotonic() > deadline:
            log.error("%s did not come up with %s within %ds of netplan apply",
                      BRIDGE, VMNET, UP_TIMEOUT)
            sys.exit(1)
        time.sleep(1)
    log.info("%s is up with %s", BRIDGE, VMNET)


def down() -> None:
    """Remove the file, the bridge and its anchor port (networkd leaves removed devices in place)."""
    NETPLAN_FILE.unlink(missing_ok=True)
    subprocess.run(["netplan", "apply"], check=True)
    for dev in (BRIDGE, ANCHOR):
        if Path("/sys/class/net", dev).exists():
            subprocess.run(["ip", "link", "delete", dev], check=True)
    log.info("%s and %s removed", BRIDGE, NETPLAN_FILE)
