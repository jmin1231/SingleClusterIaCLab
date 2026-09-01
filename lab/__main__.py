"""What `python -m lab` runs.

This file existing is the only reason `python -m lab` works at all; without it
the interpreter reports `No module named lab.__main__`.
"""

import argparse
import subprocess

from lab import __version__
from lab.log import fail
from lab.install import SERVICES, install


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="lab",
        description="Build and manage the single-host lab.",
    )
    # action="version" prints and exits by itself — there is no branch to write.
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    install_cmd = sub.add_parser("install", help="install a service")
    install_cmd.add_argument("service", choices=sorted(SERVICES))

    args = parser.parse_args()

    # Libraries raise, the CLI catches. This is the one exception boundary in
    # the program, and it is here because this is the only edge: everything in
    # lab/ is importable from a test or another module, neither of which wants a
    # SystemExit thrown at it.
    #
    # run() has already printed the failing command's stderr, so all that is
    # left to do is replace a Python traceback with an exit code. A traceback is
    # a bug report; this is an error message.
    try:
        if args.command == "install":
            install(args.service)
    except subprocess.CalledProcessError as e:
        fail(f"{e.cmd[0]} exited {e.returncode}")
    except FileNotFoundError as e:
        # run() already rewrote this one to name the missing binary.
        fail(str(e))


# Inside __main__.py, __name__ genuinely is "__main__", so this looks redundant.
# It is not: `import lab.__main__` would otherwise run main() as a side effect of
# being imported.
if __name__ == "__main__":
    main()
