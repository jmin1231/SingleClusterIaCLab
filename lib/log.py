"""Logging: '[+]/[!]/[x] message' on the console, timestamped lines in state/bootstrap.log."""

import logging
import sys
from datetime import datetime
from typing import override

from lib import config

PREFIX: dict[int, str] = {
    logging.INFO: "[+]",
    logging.WARNING: "[!]",
    logging.ERROR: "[x]",
}

LOG_FILE = config.STATE_DIR / "bootstrap.log"


class ConsoleFormatter(logging.Formatter):
    """Format a record as '<prefix> message'."""

    @override
    def format(self, record: logging.LogRecord) -> str:
        prefix = PREFIX.get(record.levelno, "[?]")
        return f"{prefix} {record.getMessage()}"


class FileFormatter(ConsoleFormatter):
    """Format a record as '<ISO timestamp> <prefix> message', plus the traceback if one is attached."""

    @override
    def format(self, record: logging.LogRecord) -> str:
        when = datetime.fromtimestamp(record.created).astimezone()
        line = f"{when.isoformat(timespec='seconds')} {super().format(record)}"
        if record.exc_info:
            line += "\n" + self.formatException(record.exc_info)
        return line


def setup_logging() -> None:
    """Send messages to the console (stderr) and to the log file."""
    root = logging.getLogger()
    if root.handlers:
        return

    console = logging.StreamHandler(sys.stderr)
    console.setFormatter(ConsoleFormatter())

    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    logfile = logging.FileHandler(LOG_FILE, encoding="utf-8")
    logfile.setFormatter(FileFormatter())

    root.setLevel(logging.INFO)
    root.addHandler(console)
    root.addHandler(logfile)
