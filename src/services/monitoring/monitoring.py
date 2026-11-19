"""Monitoring: Prometheus, Loki, Grafana and the host's Alloy agent; the stack the agents push to on 10.250.0.1."""

import hashlib
import logging
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from src.lib import config as lab_config
from src.lib.system import compose
from src.services.monitoring.config import config
from src.services.podman import podman

log = logging.getLogger(__name__)


def conf_hash(folder: Path) -> str:
    """sha256 over the contents of every file in folder, in sorted order; editing any of them changes it."""
    config_files = sorted(path for path in folder.rglob("*") if path.is_file())
    contents = b"".join(config_file.read_bytes() for config_file in config_files)
    return hashlib.sha256(contents).hexdigest()


def wait_ready() -> None:
    """Wait until Prometheus and Loki answer their ready URLs; stop with an error after about two minutes."""
    for _ in range(config.READY_TRIES):
        try:
            for ready_url in config.READY_URLS:
                urllib.request.urlopen(ready_url, timeout=5).close()
            return
        except urllib.error.URLError:
            time.sleep(2)
    log.error("Prometheus or Loki did not become ready")
    sys.exit(1)


def up() -> None:
    """Start the monitoring stack; a changed config folder recreates only that container. Wait until it is ready."""
    hashes = {name: conf_hash(folder) for name, folder in config.CONF_HASHES.items()}
    compose("monitoring", "up", "-d", env=hashes)
    wait_ready()
    log.info("Monitoring receiving metrics on %s:9090 and logs on %s:3100", lab_config.VMNET.ip, lab_config.VMNET.ip)


def down() -> None:
    """Remove the monitoring containers and their volumes (stored metrics, logs and Grafana data)."""
    if not podman.check():
        log.info("Podman is not set up; no monitoring containers to remove")
        return
    compose("monitoring", "down", "--volumes")
    log.info("Monitoring removed: containers and data")
