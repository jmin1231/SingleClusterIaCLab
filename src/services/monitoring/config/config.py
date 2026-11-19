"""Monitoring settings: the config folders behind each container and the URLs that say the stack is ready."""

from pathlib import Path

from src.lib import config as lab_config

FILES_DIR = Path(__file__).parent.parent / "files"

# compose variable -> folder; a change in the folder changes the hash and recreates that container
CONF_HASHES = {
    "PROMETHEUS_CONF_HASH": FILES_DIR / "prometheus",
    "LOKI_CONF_HASH": FILES_DIR / "loki",
    "ALLOY_CONF_HASH": FILES_DIR / "alloy",
}

READY_URLS = [
    f"http://{lab_config.VMNET.ip}:9090/-/ready",
    f"http://{lab_config.VMNET.ip}:3100/ready",
]
READY_TRIES = 60  # 2 s apart: about two minutes
