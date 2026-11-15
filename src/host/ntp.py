"""chrony: syncs the host's clock and serves time to the VMs on 10.250.0.1."""

import logging
import subprocess

from src.host.config.config import CHRONY_CONF_DEST, CHRONY_CONF_SRC, CHRONY_PACKAGES, CHRONY_SERVICE
from src.lib.config import VMNET
from src.lib.system import apt_install, apt_purge, install_file, systemctl_ok

log = logging.getLogger(__name__)


def up() -> None:
    """Install chrony and the lab's config, and make sure it's serving; a re-run changes nothing."""
    apt_install(CHRONY_PACKAGES)  # chrony replaces systemd-timesyncd

    if install_file(CHRONY_CONF_SRC, CHRONY_CONF_DEST, 0o644):
        # allow and bindaddress are read only at startup, and the unit has no reload
        subprocess.run(["systemctl", "restart", CHRONY_SERVICE], check=True)
        log.info("chrony serving time to %s on %s", VMNET.network, VMNET.ip)
    elif not systemctl_ok("is-active", CHRONY_SERVICE):
        subprocess.run(["systemctl", "enable", "--now", CHRONY_SERVICE], check=True)
        log.info("chrony was stopped; started it, serving time on %s", VMNET.ip)
    else:
        log.info("chrony is already serving time on %s", VMNET.ip)


def down() -> None:
    """Remove chrony and the lab's config, and restore systemd-timesyncd (which chrony replaced)."""
    CHRONY_CONF_DEST.unlink(missing_ok=True)
    apt_purge(CHRONY_PACKAGES)
    apt_install(["systemd-timesyncd"])
    log.info("chrony removed; systemd-timesyncd restored")
