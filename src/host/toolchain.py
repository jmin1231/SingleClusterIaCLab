"""Install all of the necesary tools for the lab"""

import hashlib
import io
import logging
import os
import subprocess
import urllib.request
import zipfile
from pathlib import Path

from src.host.config import config
from src.lib.system import write_file

log = logging.getLogger(__name__)


def installed_version_ok(cmd: list[str], version: str) -> bool:
    """Check if the installed tool version is correct"""
    if not Path(cmd[0]).exists():
        return False

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ, "CHECKPOINT_DISABLE": "1"},
        )
    except OSError:
        return False

    if result.returncode != 0:
        return False

    return version in result.stdout.split()


def install_binary(tool: str, url: str, sha256: str, version_cmd: list[str], version: str) -> None:
    """Install tool from a pinned version, unless the version is already installed."""
    if installed_version_ok(version_cmd, version):
        log.info("%s %s already installed.", tool, version)
        return

    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()

    if hashlib.sha256(data).hexdigest() != sha256:
        raise RuntimeError(f"{url}: sha256 mismatch")

    binary = zipfile.ZipFile(io.BytesIO(data)).read(tool)

    write_file(binary, config.BIN_DIR / tool, 0o755)

    log.info("%s %s installed at %s", tool, version, config.BIN_DIR)


def up() -> None:
    install_binary("terraform", config.TERRAFORM_URL, config.TERRAFORM_SHA256,
                   [str(config.BIN_DIR / "terraform"), "version"], f"v{config.TERRAFORM_VERSION}")