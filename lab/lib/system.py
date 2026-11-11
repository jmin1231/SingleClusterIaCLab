"""Helpers for running host commands, shared by more than one phase."""

import json
import subprocess


def ip_json(*args: str) -> list[dict]:
    """Run `ip -j <args>` and return its parsed JSON output."""
    out = subprocess.run(["ip", "-j", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)
