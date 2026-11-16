"""Entry point: bootstrap.sh runs `python3 -B -m src <command>`."""

import argparse
import fcntl
import logging
import sys
from collections.abc import Callable

from src.host import kvm, network, ntp, preflight, toolchain, vmfw
from src.lib import pki
from src.lib.config import STATE_DIR
from src.lib.log import setup_logging
from src.services.coredns import dns
from src.services.podman import podman
from src.services.traefik import traefik
from src.services.vault import vault
from src.services.gitea import gitea
from src.services.gitea.runner import runner

log = logging.getLogger(__name__)

LOCK_FILE = STATE_DIR / "run.lock"
INITIALIZED_MARKER = STATE_DIR / "initialized"  # written last by the first up; the lab exists from then on


def platform_up() -> None:
    """Bring the host and platform services to what the code describes; unchanged steps do nothing."""
    preflight.up()
    network.up()
    ntp.up()
    podman.up()
    kvm.up()
    vmfw.up()
    toolchain.up()
    dns.up()
    certs_changed = pki.up()
    vault.up(certs_changed)
    traefik.up(certs_changed)
    gitea.up()
    runner.up()


def platform_down() -> None:
    """Remove the host and platform services, in the order that keeps each removal possible."""
    runner.down()
    toolchain.down()
    vmfw.down()
    kvm.down()
    gitea.down()
    traefik.down()
    vault.down()
    pki.down()
    dns.down()
    podman.down()
    ntp.down()
    network.down()


def cmd_up() -> None:
    if INITIALIZED_MARKER.exists():
        log.info("initial infrastructure already initialized; use update")
        return
    platform_up()
    gitea.initial_push()
    INITIALIZED_MARKER.touch()  # last: if anything above failed, the next up carries on


def cmd_update() -> None:
    if not INITIALIZED_MARKER.exists():
        log.error("the lab is not initialized yet; run up first")
        sys.exit(1)
    platform_up()
    creds = gitea.gitea_admin(vault.login())
    gitea.push(creds)
    # 3.5b: gitea.dispatch(creds) when nothing new was pushed, then log the Actions URL


def cmd_teardown() -> None:
    log.info("teardown: not implemented yet")


def cmd_destroy() -> None:
    platform_down()
    INITIALIZED_MARKER.unlink(missing_ok=True)
    log.info("destroy complete: everything the lab installed is removed")


COMMANDS: dict[str, tuple[Callable[[], None], str]] = {
    "up": (cmd_up, "build the infrastructure once (later runs: use update)"),
    "update": (cmd_update, "re-apply host changes and re-run the pipeline"),
    "teardown": (cmd_teardown, "remove the VPC and its VMs, keep the host platform"),
    "destroy": (cmd_destroy, "destroy everything and restore the host to before"),
}


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    """Parse the command line arguments."""
    parser = argparse.ArgumentParser(
        prog="bootstrap.sh",
        description="Provision the entire infrastructure. See diagram/ for details.",
    )

    sub = parser.add_subparsers(dest="command", metavar="<command>")
    for name, (_, help_text) in COMMANDS.items():
        sub.add_parser(name, help=help_text)

    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        sys.exit(1)
    return args


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
        try:
            func()
        except KeyboardInterrupt:
            log.error("%s interrupted; run it again to continue", args.command)
            return 130

    return 0


if __name__ == "__main__":
    sys.exit(main())
