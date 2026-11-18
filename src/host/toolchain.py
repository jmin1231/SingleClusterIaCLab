"""Install the tools the pipeline jobs need: Terraform, Ansible with cloud.terraform, Node and Trivy."""

import hashlib
import io
import logging
import os
import subprocess
import shutil
import tarfile
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


def download(url: str, sha256: str) -> bytes:
    """Download url into memory and check against its pinned sha256"""
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()

    if hashlib.sha256(data).hexdigest() != sha256:
        raise RuntimeError(f"{url}: sha256 mismatch")

    return data


def ensure_terraform() -> None:
    """Install the pinned terraform binary from HashiCorp's zip, unless that version is present."""
    terraform = config.BIN_DIR / "terraform"
    if installed_version_ok([str(terraform), "version"], f"v{config.TERRAFORM_VERSION}"):
        log.info("terraform %s already installed", config.TERRAFORM_VERSION)
        return

    data = download(config.TERRAFORM_URL, config.TERRAFORM_SHA256)
    binary = zipfile.ZipFile(io.BytesIO(data)).read("terraform")  # only this member is read
    write_file(binary, terraform, 0o755)
    log.info("terraform %s installed at %s", config.TERRAFORM_VERSION, terraform)


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


def ensure_node() -> None:
    """Install the pinned node binary (no npm) so the runner can run JavaScript actions, unless present."""
    node = config.BIN_DIR / "node"
    if installed_version_ok([str(node), "--version"], f"v{config.NODE_VERSION}"):
        log.info("node %s already installed", config.NODE_VERSION)
        return

    data = download(config.NODE_URL, config.NODE_SHA256)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as archive:
        binary = archive.extractfile(config.NODE_MEMBER).read()  # only this member is read
    write_file(binary, node, 0o755)
    log.info("node %s installed at %s", config.NODE_VERSION, node)


def ensure_trivy() -> None:
    """Install the pinned trivy binary so pipeline jobs can scan images and IaC, unless present."""
    trivy = config.BIN_DIR / "trivy"
    if installed_version_ok([str(trivy), "--version"], config.TRIVY_VERSION):
        log.info("trivy %s already installed", config.TRIVY_VERSION)
        return

    data = download(config.TRIVY_URL, config.TRIVY_SHA256)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        binary = archive.extractfile(config.TRIVY_MEMBER).read()
    write_file(binary, trivy, 0o755)
    log.info("trivy %s installed at %s", config.TRIVY_VERSION, trivy)


def up() -> None:
    """Install Terraform, Ansible with the cloud.terraform collection, Node and Trivy; a re-run changes nothing."""
    ensure_terraform()
    ensure_ansible()
    ensure_node()
    ensure_trivy()


def down() -> None:
    """Remove everything up() installed; safe to run twice."""
    (config.BIN_DIR / "terraform").unlink(missing_ok=True)
    (config.BIN_DIR / "node").unlink(missing_ok=True)
    (config.BIN_DIR / "trivy").unlink(missing_ok=True)
    shutil.rmtree(config.COLLECTIONS_DIR / "ansible_collections" / "cloud", ignore_errors=True)
    apt_purge(config.ANSIBLE_PACKAGES)
    log.info("toolchain removed")