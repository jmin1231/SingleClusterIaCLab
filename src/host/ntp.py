"""chrony: syncs the host's clock and serves time to the VMs on 10.250.0.1."""

import logging
import subprocess

from src.host.config import config
from src.lib import config as lab_config
from src.lib.system import apt_install, apt_purge, install_file, systemctl_ok

log = logging.getLogger(__name__)


def up() -> None:
    """Install chrony and the lab's config, and make sure it's serving; a re-run changes nothing."""
    apt_install(config.CHRONY_PACKAGES)  # chrony replaces systemd-timesyncd

    if install_file(config.CHRONY_CONF_SRC, config.CHRONY_CONF_DEST, 0o644):
        # allow and bindaddress are read only at startup, and the unit has no reload
        subprocess.run(["systemctl", "restart", config.CHRONY_SERVICE], check=True)
        log.info("chrony serving time to %s on %s", lab_config.VMNET.network, lab_config.VMNET.ip)
    elif not systemctl_ok("is-active", config.CHRONY_SERVICE):
        subprocess.run(["systemctl", "enable", "--now", config.CHRONY_SERVICE], check=True)
        log.info("chrony was stopped; started it, serving time on %s", lab_config.VMNET.ip)
    else:
        log.info("chrony is already serving time on %s", lab_config.VMNET.ip)


def down() -> None:
    """Remove chrony and the lab's config, and restore systemd-timesyncd (which chrony replaced)."""
    config.CHRONY_CONF_DEST.unlink(missing_ok=True)
    apt_purge(config.CHRONY_PACKAGES)
    apt_install(["systemd-timesyncd"])
    log.info("chrony removed; systemd-timesyncd restored")
