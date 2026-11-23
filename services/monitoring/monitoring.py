"""Monitoring: Prometheus, Loki, Grafana and the host's Alloy agent; the stack the agents push to on 10.250.0.1."""

import hashlib
import logging
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from lib import config as lab_config
from lib.system import compose
from services.monitoring.config import config
from podman import podman
from services.vault import vault

log = logging.getLogger(__name__)


def conf_hash(folder: Path) -> str:
    """sha256 over the contents of every file in folder, in sorted order; editing any of them changes it."""
    config_files = sorted(path for path in folder.rglob("*") if path.is_file())
    contents = b"".join(config_file.read_bytes() for config_file in config_files)
    return hashlib.sha256(contents).hexdigest()


def grafana_admin(token: str) -> dict:
    """Grafana's admin credentials from Vault; created once with a random password, never replaced."""
    saved = vault.vault_api("GET", config.GRAFANA_ADMIN_KV, token=token)
    if saved:
        return saved["data"]["data"]
    creds = {"username": lab_config.LAB_ADMIN, "password": secrets.token_urlsafe(24)}
    vault.vault_api("POST", config.GRAFANA_ADMIN_KV, {"data": creds}, token=token)
    log.info("stored new Grafana admin password in Vault")
    return creds


def wait_ready() -> None:
    """Wait until Prometheus and Loki answer their ready URLs; stop with an error after about two minutes."""
    ctx = ssl.create_default_context(cafile=lab_config.LAB_CA_CERT)
    for _ in range(config.READY_TRIES):
        try:
            for ready_url in config.READY_URLS:
                urllib.request.urlopen(ready_url, context=ctx, timeout=5).close()
            return
        except urllib.error.URLError:
            time.sleep(2)
    log.error("Prometheus or Loki did not become ready")
    sys.exit(1)


def up() -> None:
    """Start the monitoring stack; a changed config folder recreates only that container. Wait until it is ready."""
    creds = grafana_admin(vault.login())
    env = {name: conf_hash(folder) for name, folder in config.CONF_HASHES.items()}
    env |= {"GRAFANA_ADMIN_USER": creds["username"], "GRAFANA_ADMIN_PASSWORD": creds["password"]}
    compose("monitoring", "up", "-d", env=env)
    wait_ready()
    log.info("Monitoring receiving metrics at https://prometheus.lab.test and logs at https://loki.lab.test")


def down() -> None:
    """Remove the monitoring containers and their volumes (stored metrics, logs and Grafana data)."""
    if not podman.check():
        log.info("Podman is not set up; no monitoring containers to remove")
        return
    compose("monitoring", "down", "--volumes")
    log.info("Monitoring removed: containers and data")
