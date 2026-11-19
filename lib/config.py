"""Lab settings shared by more than one module. Imports nothing from host/ or the service folders."""

import ipaddress
import os
from pathlib import Path

# --- Lab ---
LAB_ADMIN = "labadmin"

# --- Paths ---
BASE_DIR = Path(__file__).resolve().parents[1]
STATE_DIR = BASE_DIR / "state"
LAB_DIR = Path("/var/lib/lab")
SERVICES_DIR = BASE_DIR  # each service is a folder at the repo root

# --- Network ---
BRIDGE = "cloudbr1"
VMNET = ipaddress.ip_interface("10.250.0.1/24")

# --- Apt ---
APT_ENV = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}

# --- Podman / Compose ---
COMPOSE = "/usr/libexec/docker/cli-plugins/docker-compose"
DOCKER_HOST = "unix:///run/podman/podman.sock"

# --- PKI ---
CFSSL_DIR = BASE_DIR / "lib" / "cfssl"
PKI_DIR = STATE_DIR / "pki"
LAB_CA = "ca"
LAB_CA_CERT = PKI_DIR / f"{LAB_CA}.pem"

# Every certificate is signed by LAB_CA.
CERTS: dict[str, tuple[str, list[str], tuple[int, int]]] = {
    # name:     (profile,  hosts,                                            key owner (uid, gid))
    "vault":    ("server", ["vault.lab.test", str(VMNET.ip), "127.0.0.1"],  (100, 1000)),
    "gateway":  ("server", ["gitea.lab.test", "grafana.lab.test", "prometheus.lab.test", "loki.lab.test"], (0, 0)),
    "app-edge": ("server", ["app.lab.test"],                                 (0, 0)),
}

# --- Vault ---
VAULT_PORT = 8200
VAULT_ADDR = f"https://{VMNET.ip}:{VAULT_PORT}"
VAULT_INIT_FILE = LAB_DIR / "vault-init.json"
VAULT_POLICY_DIR = SERVICES_DIR / "vault" / "policies"
VAULT_APPROLE_FILE = LAB_DIR / "approle.json"

