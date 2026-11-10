"""Logging: '[+]/[!]/[x] message' on the console, timestamped lines in state/bootstrap.log."""

import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import override

PREFIX: dict[int, str] = {
    logging.INFO: "[+]",
    logging.WARNING: "[!]",
    logging.ERROR: "[x]",
}

BASE_DIR = Path(__file__).resolve().parents[2]  # lab/lib/log.py -> lab/lib -> lab -> repo root
LOG_FILE = BASE_DIR / "state" / "bootstrap.log"


class ConsoleFormatter(logging.Formatter):
    """Format a record as '<prefix> message'."""

    @override
    def format(self, record: logging.LogRecord) -> str:
        prefix = PREFIX.get(record.levelno, "[?]")
        return f"{prefix} {record.getMessage()}"


class FileFormatter(logging.Formatter):
    """Format a record as '<ISO timestamp> <prefix> message'."""

    @override
    def format(self, record: logging.LogRecord) -> str:
        prefix = PREFIX.get(record.levelno, "[?]")
        when = datetime.fromtimestamp(record.created).astimezone()
        return f"{when.isoformat(timespec='seconds')} {prefix} {record.getMessage()}"


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
