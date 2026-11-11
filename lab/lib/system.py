"""Helpers for running host commands, shared by more than one phase."""

import json
import os
import subprocess

from lab.lib.log import BASE_DIR

COMPOSE = "/usr/libexec/docker/cli-plugins/docker-compose"
DOCKER_HOST = "unix:///run/podman/podman.sock"
SERVICES_DIR = BASE_DIR / "services"


def ip_json(*args: str) -> list[dict]:
    """Run `ip -j <args>` and return its parsed JSON output."""
    out = subprocess.run(["ip", "-j", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def compose(service: str, *args: str, env: dict[str, str] | None = None) -> None:
    """docker-compose -f services/<service>/compose.yaml <args>"""
    result_env = {**os.environ, "DOCKER_HOST": DOCKER_HOST, **(env or {})}
    subprocess.run(
        [COMPOSE, "-f", SERVICES_DIR / service / "compose.yaml", *args],
        env=result_env,
        check=True,
    )
