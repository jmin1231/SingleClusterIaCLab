"""Installing a service.

SKELETON. The bodies are yours; the shape and the reasoning are here so the
finished code has something to be checked against.

Decision 8 shrank this step: apt, Docker and the group belong to bootstrap.sh.
What is left is finding a compose stack and bringing it up.
"""

import os
from pathlib import Path

from lab.log import fail, info
from lab.run import run

# TODO 1 -- the registry.
#
# `lab install web` implies `lab install gitea` by Phase 8 and half a dozen after
# it. A dict beats a chain of ifs well before then. Paths are relative to the
# repo root and joined below, so no entry has to know where the repo lives.
SERVICES: dict[str, str] = {
    "web": "docker/web",
}

# Every service uses the same filename, so it lives here rather than in each
# registry entry -- one place to change if a service ever needs a different one,
# and no entry that can disagree with the others.
COMPOSE_FILENAME = "compose.yaml"

# Relative to THIS FILE, never the working directory: `python -m lab install web`
# has to mean the same thing from your home directory, from cron and from CI.
REPO_ROOT = Path(__file__).resolve().parent.parent


def compose_file(service: str) -> Path:
    """Absolute path to a service's compose file.

    Fails on a name that is not registered. The CLI lists the valid names itself
    via argparse's choices=, so this does not repeat them.
    """
    directory = SERVICES.get(service)
    if directory is None:
        fail(f"unknown service: {service}")

    # REPO_ROOT / directory, not os.path.join: this is annotated to return a Path
    # and os.path.join hands back a str, which type checkers and callers both
    # have to work around.
    path = REPO_ROOT / directory / COMPOSE_FILENAME
    if not path.is_file():
        # The path we looked for, not just "no such file" -- a missing-file error
        # without the path in it is the one you read at midnight.
        fail(f"{service} has no compose file at {path}")

    return path


def converge(path: Path) -> None:
    """Bring the stack up.

    `docker compose up -d` is idempotent, so running this twice is safe: the
    second run finds the container already correct and leaves it alone.

    Deliberately not reported. An earlier draft returned True/False for whether
    anything changed -- Ansible's changed/ok, terraform's "No changes" -- which
    would also have given drift detection once there are several services. That
    was traded for four lines and nothing to parse. Compose still prints what it
    did; it is just read by a person rather than by this function.
    """
    # Not captured, so compose's own progress goes straight to the terminal.
    # -f with an absolute path rather than os.chdir: a function that leaves the
    # process somewhere else is one every later caller has to remember.
    run(["docker", "compose", "-f", str(path), "up", "-d"])


def install(service: str) -> None:
    """Install one service.

    Written out rather than left blank so the shape is visible -- change it
    freely, it is only the order the pieces go in.
    """
    # TODO 6 -- root check. Unlike bootstrap.sh this must NOT be root: compose
    # run as root creates root-owned volumes your own account cannot read, and
    # that surfaces three steps later as a permissions error nobody connects
    # back to here. Decide whether to warn or refuse.
    if os.geteuid() == 0:
        fail("lab install runs as your own user, not root")

    # No preflight. bootstrap.sh installs Docker, so "is it there" is answered
    # before this ever runs. The case that survives is a shell older than the
    # docker group, where the socket is unreadable -- run() surfaces that, in
    # Docker's words rather than ours.
    path = compose_file(service)
    info(f"Installing {service} from {path}")

    converge(path)
    info(f"{service} is up")


# --- TODO 7 -- wiring, in __main__.py ----------------------------------------
#
#   sub = parser.add_subparsers(dest="command", required=True)
#   install_cmd = sub.add_parser("install", help="install a service")
#   install_cmd.add_argument("service", choices=sorted(SERVICES))
#   ...
#   args = parser.parse_args()
#   if args.command == "install":
#       install(args.service)
#
# required=True matters: without it, `python -m lab` with no subcommand leaves
# command as None and falls through to whatever comes next.
#
# `choices=` gets you the known-names error for free at the CLI -- but keep the
# check in compose_file() too. The registry is also called from Python, and an
# argparse choices list does not protect that caller.

# --- TODO 8 -- the test you skipped at 0.4 -----------------------------------
#
# compose_file("webb") exiting non-zero is one assertion, needs no Docker, and is
# exactly what breaks silently when the registry moves.
