"""Vault: the secrets and encryption service, running in Podman on 10.250.0.1:8200."""

import json
import logging
import os
import shutil
import ssl
import subprocess
import sys
import urllib.request
from pathlib import Path

from src.host import podman
from src.lib.config import BASE_DIR, VMNET
from src.lib.system import apt_install, apt_purge, compose, missing_packages

PACKAGES = ["golang-cfssl"]
CFSSL_DIR = Path(__file__).parent / "cfssl"
TLS_DIR = BASE_DIR / "state" / "vault" / "tls"
VAULT_UID = 100
VAULT_GID = 1000

VAULT_ADDR = f"https://{VMNET.ip}:8200"
LAB_DIR = Path("/var/lib/lab")
INIT_FILE = LAB_DIR / "vault-init.json"  # unseal key + root token

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


def api(method: str, path: str, body: dict | None = None) -> dict:
    """Call Vault's HTTP API, verifying TLS against the bootstrap CA. Secrets travel in the body, never argv."""
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
    )
    ctx = ssl.create_default_context(cafile=TLS_DIR / "ca.pem")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        data = resp.read()
    return json.loads(data) if data else {}


def init() -> None:
    """Initialize Vault once; the unseal key and root token go to vault-init.json (0600, never overwritten)."""
    initialized = api("GET", "sys/init")["initialized"]
    if initialized and INIT_FILE.exists():
        log.info("Vault is already initialized")
        return
    if initialized:
        log.error("Vault is initialized but %s is missing: the unseal key is lost", INIT_FILE)
        sys.exit(1)
    if INIT_FILE.exists():
        log.error("%s exists but Vault is new: it belongs to an older Vault; move it away and re-run", INIT_FILE)
        sys.exit(1)

    keys = api("PUT", "sys/init", {"secret_shares": 1, "secret_threshold": 1})
    LAB_DIR.mkdir(0o755, parents=True, exist_ok=True)
    fd = os.open(INIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(keys, file)
        file.flush()
        os.fsync(file.fileno())
    log.info("Vault initialized; unseal key and root token in %s", INIT_FILE)


def unseal() -> None:
    """Unseal Vault with the key from vault-init.json if it is sealed (after every restart)."""
    if not api("GET", "sys/seal-status")["sealed"]:
        log.info("Vault is already unsealed")
        return
    key = json.loads(INIT_FILE.read_text())["keys_base64"][0]
    if api("PUT", "sys/unseal", {"key": key})["sealed"]:
        log.error("Vault is still sealed after the unseal")
        sys.exit(1)
    log.info("Vault unsealed")


def up() -> None:
    """Start Vault, then init and unseal it; a re-run changes nothing."""
    missing = missing_packages(PACKAGES)
    if missing:
        log.info("installing %s", ", ".join(missing))
        apt_install(missing)
    else:
        log.info("cfssl is already installed")
    changed = bootstrap_cert()
    compose("vault", "up", "-d", "--wait", "--wait-timeout", "60",
            *(["--force-recreate"] if changed else []))
    init()
    unseal()
    log.info("Vault ready on %s", VAULT_ADDR)


def down() -> None:
    """Remove the Vault container, its data and keys, its bootstrap cert, and cfssl."""
    if podman.check():
        compose("vault", "down", "--volumes")
    else:
        log.info("Podman is not set up; no Vault container to remove")
    shutil.rmtree(BASE_DIR / "state" / "vault", ignore_errors=True)
    INIT_FILE.unlink(missing_ok=True)  # the keys are useless once the data is gone
    apt_purge(PACKAGES)
    log.info("Vault removed: container, data, keys, bootstrap cert and cfssl")
