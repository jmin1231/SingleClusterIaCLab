"""Check that the host can run the lab before anything is installed."""

import logging
import os
import sys

log = logging.getLogger(__name__)


def check_host() -> None:
    """Stop unless /dev/kvm is usable."""
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        log.error("/dev/kvm is missing or not usable (is nested virtualization on?)")
        sys.exit(1)

    log.info("KVM is usable")


def up() -> None:
    check_host()
