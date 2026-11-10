"""Check that the host can run the lab before anything is installed."""

import logging
import os
import subprocess
import sys

log = logging.getLogger(__name__)


def check_host() -> None:
    """Stop unless /dev/kvm is usable and systemd-networkd runs the network."""
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        log.error("/dev/kvm is missing or not usable (is nested virtualization on?)")
        sys.exit(1)

    log.info("KVM is usable")

    # netplan must hand the network to systemd-networkd (Ubuntu Server), not NetworkManager
    if subprocess.run(["systemctl", "is-active", "--quiet", "systemd-networkd"]).returncode != 0:
        log.error("systemd-networkd is not active (Ubuntu Desktop? the lab needs Ubuntu Server)")
        sys.exit(1)

    log.info("systemd-networkd is active")


def up() -> None:
    check_host()
