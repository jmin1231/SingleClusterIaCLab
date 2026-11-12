"""Vault: the lab's CA, running in Podman on 10.250.0.1:8200."""

import json
import logging
import os
import shutil
import subprocess
from pathlib import Path

from src.host import podman
from src.lib.config import BASE_DIR, VMNET
from src.lib.system import apt_install, apt_purge, compose, missing_packages

PACKAGES = ["golang-cfssl"]
CFSSL_DIR = Path(__file__).parent / "cfssl"
TLS_DIR = BASE_DIR / "state" / "vault" / "tls"
VAULT_UID = 100
VAULT_GID = 1000

log = logging.getLogger(__name__)


def bootstrap_cert() -> bool:
    """Generate the bootstrap CA and Vault's cert if missing. Return True if new ones were made."""
    if (TLS_DIR / "vault.pem").exists():
        log.info("bootstrap cert exists; keeping %s", TLS_DIR)
        return False

    TLS_DIR.mkdir(0o755, parents=True, exist_ok=True)

    result = subprocess.run(["cfssl", "gencert", "-initca", CFSSL_DIR / "ca-csr.json"],
                            capture_output=True, text=True, check=True)
    ca = json.loads(result.stdout)

    (TLS_DIR / "ca.pem").write_text(ca["cert"])
    fd = os.open(TLS_DIR / "ca-key.pem", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(ca["key"])

    result = subprocess.run(
        ["cfssl", "gencert",
         "-ca", TLS_DIR / "ca.pem",
         "-ca-key", TLS_DIR / "ca-key.pem",
         "-config", CFSSL_DIR / "ca-config.json",
         CFSSL_DIR / "vault-csr.json"],
        capture_output=True, text=True, check=True,
    )

    leaf = json.loads(result.stdout)

    fd = os.open(TLS_DIR / "vault-key.pem", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(leaf["key"])
    os.chown(TLS_DIR / "vault-key.pem", VAULT_UID, VAULT_GID)  # the container's vault user

    (TLS_DIR / "vault.pem").write_text(leaf["cert"])

    log.info("bootstrap CA and Vault cert created in %s", TLS_DIR)
    return True


def up() -> None:
    """Create the bootstrap cert if missing and start Vault; a re-run changes nothing."""
    missing = missing_packages(PACKAGES)
    if missing:
        log.info("installing %s", ", ".join(missing))
        apt_install(missing)
    else:
        log.info("cfssl is already installed")

    changed = bootstrap_cert()

    # Vault reads its cert only at startup, so a new cert also needs a restart.
    compose("vault", "up", "-d")
    if changed:
        compose("vault", "restart")

    log.info("Vault started on %s:8200 (sealed until init/unseal)", VMNET.ip)


def down() -> None:
    """Remove the Vault container, its bootstrap cert, and cfssl."""
    if podman.check():
        compose("vault", "down")
    else:
        log.info("Podman is not set up; no Vault container to remove")
    shutil.rmtree(BASE_DIR / "state" / "vault", ignore_errors=True)
    apt_purge(PACKAGES)
    log.info("Vault removed: container, bootstrap cert and cfssl")
