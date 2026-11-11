"""Create the host-only bridge cloudbr1 that the VMs use to reach the host."""

import ipaddress
import json
import logging
import subprocess
import sys
import time
from pathlib import Path

log = logging.getLogger(__name__)

BRIDGE = "cloudbr1"
VMNET = ipaddress.ip_interface("10.250.0.1/24")
NETPLAN_FILE = Path("/etc/netplan/60-lab-cloudbr1.yaml")
UP_TIMEOUT = 30  # seconds; NetworkManager activates the bridge after netplan apply returns

NETPLAN = f"""\
network:
  version: 2
  bridges:
    {BRIDGE}:
      addresses: [{VMNET}]
      ignore-carrier: true
      parameters:
        stp: false
"""


def ip_json(*args: str) -> list[dict]:
    out = subprocess.run(["ip", "-j", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


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
    """Create cloudbr1 through netplan; a re-run changes nothing."""
    if NETPLAN_FILE.exists() and NETPLAN_FILE.read_text() == NETPLAN and check():
        log.info("%s is already up with %s", BRIDGE, VMNET)
        return

    conflicts = vmnet_conflicts()
    if conflicts:
        log.error("%s is already in use: %s", VMNET.network, ", ".join(conflicts))
        sys.exit(1)

    NETPLAN_FILE.write_text(NETPLAN)
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
    """Remove the file and the bridge (networkd leaves a removed bridge in place)."""
    NETPLAN_FILE.unlink(missing_ok=True)
    subprocess.run(["netplan", "apply"], check=True)
    if Path("/sys/class/net", BRIDGE).exists():
        subprocess.run(["ip", "link", "delete", BRIDGE], check=True)
