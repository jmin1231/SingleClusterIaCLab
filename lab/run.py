"""Running external commands.

Everything this lab does to the host is a command: apt, docker, systemctl,
virsh, terraform. This wrapper exists because subprocess.run's defaults are the
opposite of what that needs — a failing command returns quietly, and captured
output arrives as bytes. bootstrap.sh gets that behaviour from `set -e`; Python
has no equivalent, so it lives here instead.
"""

import shlex
import subprocess

from lab.log import info, warn


def run(
    cmd: list[str],
    *,
    capture: bool = False,
    check: bool = True,
    echo: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run a command and return its result.

    cmd is a list, never a string: no shell means no quoting rules, no globbing,
    and no way for an argument containing ';' to become a second command.

    Always returns CompletedProcess, even when capturing. A function whose return
    type depends on an argument's value is a function you have to read twice —
    callers that want the text write `.stdout.strip()` and it is obvious why.
    """
    if echo:
        # The $ makes it read as a shell transcript. shlex.join, not " ".join:
        # it quotes anything containing a space, so the line printed here is one
        # you can paste back into a terminal to reproduce the step by hand.
        info(f"$ {shlex.join(cmd)}")

    try:
        return subprocess.run(
            cmd,
            check=check,
            capture_output=capture,
            # Without this, stdout is bytes — and `result.stdout == "hi\n"` is
            # then False with nothing to explain why.
            text=True,
        )
    except FileNotFoundError as e:
        # Not the same failure as a non-zero exit, and it has a different fix:
        # the binary is missing, so something needs installing. The stock message
        # is just the filename, with no hint of what was trying to run it.
        raise FileNotFoundError(f"{cmd[0]}: command not found") from e
    except subprocess.CalledProcessError as e:
        # With capture=True the failing command's stderr went into e.stderr
        # rather than to the terminal, so the exception arrives with no
        # explanation attached. Surface it before re-raising.
        if e.stderr:
            warn(e.stderr.rstrip())
        raise
