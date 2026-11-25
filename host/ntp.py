"""chrony: syncs the host's clock and serves time to the VMs on 10.250.0.1."""

import logging
import subprocess

from host.config import config
from lib import config as lab_config
from lib.system import apt_install, apt_purge, install_file, systemctl_ok

log = logging.getLogger(__name__)


def up() -> None:
    """Install chrony, the lab's config and the makestep drop-in, and make sure it's serving; a re-run changes nothing."""
    apt_install(config.CHRONY_PACKAGES)  # chrony replaces systemd-timesyncd

    conf_changed = install_file(config.CHRONY_CONF_SRC, config.CHRONY_CONF_DEST, 0o644)
    config.CHRONY_DROPIN_DEST.parent.mkdir(parents=True, exist_ok=True)
    dropin_changed = install_file(config.CHRONY_DROPIN_SRC, config.CHRONY_DROPIN_DEST, 0o644)
    if dropin_changed:
        subprocess.run(["systemctl", "daemon-reload"], check=True)

    if conf_changed or dropin_changed:
        # allow and bindaddress are read only at startup, the unit has no reload, and the drop-in runs on start
        subprocess.run(["systemctl", "restart", config.CHRONY_SERVICE], check=True)
        log.info("chrony serving time to %s on %s", lab_config.VMNET.network, lab_config.VMNET.ip)
    elif not systemctl_ok("is-active", config.CHRONY_SERVICE):
        subprocess.run(["systemctl", "enable", "--now", config.CHRONY_SERVICE], check=True)
        log.info("chrony was stopped; started it, serving time on %s", lab_config.VMNET.ip)
    else:
        log.info("chrony is already serving time on %s", lab_config.VMNET.ip)


def down() -> None:
    """Remove chrony, the lab's config and drop-in, and restore systemd-timesyncd (which chrony replaced)."""
    config.CHRONY_CONF_DEST.unlink(missing_ok=True)
    config.CHRONY_DROPIN_DEST.unlink(missing_ok=True)
    try:
        config.CHRONY_DROPIN_DEST.parent.rmdir()  # only if nothing else is in it
    except OSError:
        pass
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    apt_purge(config.CHRONY_PACKAGES)
    apt_install(["systemd-timesyncd"])
    log.info("chrony removed; systemd-timesyncd restored")
