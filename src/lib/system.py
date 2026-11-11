"""Helpers for running host commands, shared by more than one module."""

import json
import os
import subprocess
from pathlib import Path

from src.lib.config import APT_ENV, COMPOSE, DOCKER_HOST, SERVICES_DIR


def ip_json(*args: str) -> list[dict]:
    """Run `ip -j <args>` and return its parsed JSON output."""
    out = subprocess.run(["ip", "-j", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def missing_packages(packages: list[str]) -> list[str]:
    """The packages in `packages` that are not installed."""
    missing = []
    for pkg in packages:
        result = subprocess.run(["dpkg-query", "-W", "-f=${db:Status-Status}", pkg],
                                capture_output=True, text=True)
        if result.stdout != "installed":
            missing.append(pkg)
    return missing


def apt_install(packages: list[str]) -> None:
    """Refresh the package lists and install `packages`, without prompts."""
    subprocess.run(["apt-get", "-qq", "update"], check=True, env=APT_ENV)
    subprocess.run(["apt-get", "install", "-y", "-qq", "-o", "DPkg::Lock::Timeout=120", *packages],
                   check=True, env=APT_ENV)


def apt_purge(packages: list[str]) -> None:
    """Purge `packages` (their files and config), without prompts."""
    subprocess.run(["apt-get", "purge", "-y", "-qq", "-o", "DPkg::Lock::Timeout=120", *packages],
                   check=True, env=APT_ENV)


def install_file(src: Path, dst: Path, mode: int) -> bool:
    """Copy src to dst if dst is missing or different. Returns True if it changed."""
    src_bytes = src.read_bytes()
    if dst.exists() and dst.read_bytes() == src_bytes:
        return False

    # Mode first, contents second: the file is never readable with looser permissions.
    dst.touch()
    dst.chmod(mode)
    dst.write_bytes(src_bytes)
    return True


def compose(service: str, *args: str, env: dict[str, str] | None = None) -> None:
    """docker-compose -f services/<service>/compose.yaml <args>"""
    result_env = {**os.environ, "DOCKER_HOST": DOCKER_HOST, **(env or {})}
    subprocess.run(
        [COMPOSE, "-f", SERVICES_DIR / service / "compose.yaml", *args],
        env=result_env,
        check=True,
    )
