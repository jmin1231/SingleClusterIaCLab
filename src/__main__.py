"""Entry point: bootstrap.sh runs `python3 -B -m src <command>`."""

import argparse
import fcntl
import logging
import sys
from collections.abc import Callable

from src.host import network, ntp, podman, preflight
from src.lib.config import BASE_DIR
from src.lib.log import setup_logging
from src.services.coredns import dns
from src.services.vault import vault

log = logging.getLogger(__name__)

LOCK_FILE = BASE_DIR / "state" / "run.lock"


def cmd_up() -> None:
    preflight.up()
    network.up()
    ntp.up()
    podman.up()
    dns.up()
    vault.up()


def cmd_update() -> None:
    log.info("update: not implemented yet")


def cmd_teardown() -> None:
    log.info("teardown: not implemented yet")


def cmd_destroy() -> None:
    # Reverse of up: services before the Podman they run on, chrony and CoreDNS before cloudbr1
    vault.down()
    dns.down()
    podman.down()
    ntp.down()
    network.down()
    log.info("destroy complete: everything the lab installed is removed")


COMMANDS: dict[str, tuple[Callable[[], None], str]] = {
    "up": (cmd_up, "build the entire infrastructure"),
    "update": (cmd_update, "apply any changes made to the infrastructure"),
    "teardown": (cmd_teardown, "remove the VPC and its VMs, keep the host platform"),
    "destroy": (cmd_destroy, "destroy everything and restore the host to before"),
}


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    """Parse the command line arguments."""
    parser = argparse.ArgumentParser(
        prog="bootstrap.sh",
        description="Provision the entire infrastructure. See diagram/ for details.",
    )

    sub = parser.add_subparsers(dest="command", required=True, metavar="<command>")
    for name, (_, help_text) in COMMANDS.items():
        sub.add_parser(name, help=help_text)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Run a command and return the exit code."""
    args = parse_args(argv)

    setup_logging()

    # One run at a time: the kernel drops the lock when this process exits, even on a crash.
    with open(LOCK_FILE, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.error("another bootstrap.sh run is in progress")
            return 1

        func, _ = COMMANDS[args.command]
        func()

    return 0


if __name__ == "__main__":
    sys.exit(main())
