"""Lab settings shared by more than one module. Imports nothing from src.host or src.services."""

import ipaddress
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[2]  # src/lib/config.py -> src/lib -> src -> repo root

# Host-only bridge between the host and the VMs; the host holds VMNET's address on it.
BRIDGE = "cloudbr1"
VMNET = ipaddress.ip_interface("10.250.0.1/24")

APT_ENV = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}

COMPOSE = "/usr/libexec/docker/cli-plugins/docker-compose"
DOCKER_HOST = "unix:///run/podman/podman.sock"
SERVICES_DIR = BASE_DIR / "src" / "services"
