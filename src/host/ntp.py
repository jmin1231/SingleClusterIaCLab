"""chrony: syncs the host's clock and serves time to the VMs on 10.250.0.1."""

import logging
import subprocess
from pathlib import Path

from src.lib.config import VMNET
from src.lib.system import apt_install, apt_purge, install_file, systemctl_ok

log = logging.getLogger(__name__)

PACKAGES = ["chrony"]  # apt package names
SERVICE = "chrony"     # systemd unit name
CONFIG = "chrony-lab.conf"
CONF_SRC = Path(__file__).parent / "files" / CONFIG
CONF_DEST = Path("/etc/chrony/conf.d") / CONFIG


def up() -> None:
    """Install chrony and the lab's config, and make sure it's serving; a re-run changes nothing."""
    apt_install(PACKAGES)  # chrony replaces systemd-timesyncd

    if install_file(CONF_SRC, CONF_DEST, 0o644):
        # allow and bindaddress are read only at startup, and the unit has no reload
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        log.info("chrony serving time to %s on %s", VMNET.network, VMNET.ip)
    elif not systemctl_ok("is-active", SERVICE):
        subprocess.run(["systemctl", "enable", "--now", SERVICE], check=True)
        log.info("chrony was stopped; started it, serving time on %s", VMNET.ip)
    else:
        log.info("chrony is already serving time on %s", VMNET.ip)


def down() -> None:
    """Remove chrony and the lab's config, and restore systemd-timesyncd (which chrony replaced)."""
    CONF_DEST.unlink(missing_ok=True)
    apt_purge(PACKAGES)
    apt_install(["systemd-timesyncd"])
    log.info("chrony removed; systemd-timesyncd restored")
