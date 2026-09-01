"""What `python -m lab` runs.

This file existing is the only reason `python -m lab` works at all; without it
the interpreter reports `No module named lab.__main__`.
"""

import argparse

from lab import __version__


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
    parser.parse_args()

    # Nothing else to do yet. Subcommands arrive at 1.4 with `lab install web`.
    parser.print_help()


# Inside __main__.py, __name__ genuinely is "__main__", so this looks redundant.
# It is not: `import lab.__main__` would otherwise run main() as a side effect of
# being imported.
if __name__ == "__main__":
    main()
