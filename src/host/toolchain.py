"""Install all of the necesary tools for the lab"""

import hashlib
import io
import logging
import os
import subprocess
import shutil
import urllib.request
import zipfile
from pathlib import Path

from src.host.config import config
from src.lib.system import apt_install, apt_purge, write_file

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


def ensure_ansible() -> None:
    """Install ansible-core from Ubuntu and the pinned cloud.terraform collection, unless present."""
    if apt_install(config.ANSIBLE_PACKAGES):
        log.info("ansible-core installed")
    else:
        log.info("ansible-core already installed")

    list_cmd = [str(config.ANSIBLE_GALAXY), "collection", "list", "cloud.terraform",
                "-p", str(config.COLLECTIONS_DIR)]
    if installed_version_ok(list_cmd, config.CLOUD_TERRAFORM_VERSION):
        log.info("cloud.terraform %s already installed", config.CLOUD_TERRAFORM_VERSION)
        return

    subprocess.run(
        [str(config.ANSIBLE_GALAXY), "collection", "install",
         f"cloud.terraform:=={config.CLOUD_TERRAFORM_VERSION}",
         "-p", str(config.COLLECTIONS_DIR)],
        check=True
    )
    log.info("cloud.terraform %s installed in %s", config.CLOUD_TERRAFORM_VERSION, config.COLLECTIONS_DIR)


def up() -> None:
    """Install Terraform and Ansible with the cloud.terraform collection; a re-run changes nothing."""
    install_binary("terraform", config.TERRAFORM_URL, config.TERRAFORM_SHA256,
                   [str(config.BIN_DIR / "terraform"), "version"],
                   f"v{config.TERRAFORM_VERSION}")
    ensure_ansible()


def down() -> None:
    """Remove everything up() installed; safe to run twice."""
    (config.BIN_DIR / "terraform").unlink(missing_ok=True)
    shutil.rmtree(config.COLLECTIONS_DIR / "ansible_collections" / "cloud", ignore_errors=True)
    apt_purge(config.ANSIBLE_PACKAGES)
    log.info("toolchain removed")