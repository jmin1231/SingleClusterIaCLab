"""Console output for the lab.

Not the `logging` module: this needs the same three prefixes and the same
stdout/stderr split as bootstrap.sh, and three functions are less work than
bending a Formatter into that shape. Revisit if anything ever needs log levels
or a second destination.

flush=True on every call is not decoration. stderr is unbuffered and stdout is
not, so without it a warning jumps ahead of the progress lines around it the
moment output is piped or redirected — which is exactly when you are reading it.
"""

import sys
from typing import NoReturn

# RESET is not optional: without it the colour bleeds into whatever prints next,
# including the shell prompt after the program exits.
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"


def info(message: str) -> None:
    """Progress, on stdout."""
    print(f"{GREEN}[+]{RESET} {message}", file=sys.stdout, flush=True)


def warn(message: str) -> None:
    """Something worth knowing, on stderr. Does not stop the program."""
    print(f"{YELLOW}[!]{RESET} {message}", file=sys.stderr, flush=True)


def fail(message: str) -> NoReturn:
    """Print and exit non-zero. Never returns."""
    print(f"{RED}[x]{RESET} {message}", file=sys.stderr, flush=True)
    # SystemExit does not inherit from Exception, so `except Exception:` will not
    # swallow this. A bare `except:` will.
    sys.exit(1)
