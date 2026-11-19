"""Monitoring settings: the config folders behind each container and the URLs that say the stack is ready."""

from pathlib import Path


FILES_DIR = Path(__file__).parent.parent / "files"

# compose variable -> folder; a change in the folder changes the hash and recreates that container
CONF_HASHES = {
    "PROMETHEUS_CONF_HASH": FILES_DIR / "prometheus",
    "LOKI_CONF_HASH": FILES_DIR / "loki",
    "ALLOY_CONF_HASH": FILES_DIR / "alloy",
    "GRAFANA_CONF_HASH": FILES_DIR / "grafana",
}

# through Traefik, like the agents reach them
READY_URLS = [
    "https://prometheus.lab.test/-/ready",
    "https://loki.lab.test/ready",
]
GRAFANA_ADMIN_KV = "kv/data/lab/bootstrap/grafana-admin"

READY_TRIES = 60  # 2 s apart: about two minutes
