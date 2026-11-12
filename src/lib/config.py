"""Lab settings shared by more than one module. Imports nothing from src.host or src.services."""

import ipaddress
import os
from pathlib import Path

# --- Paths ---
BASE_DIR = Path(__file__).resolve().parents[2]
STATE_DIR = BASE_DIR / "state"
LAB_DIR = Path("/var/lib/lab")
SERVICES_DIR = BASE_DIR / "src" / "services"

# --- Network ---
BRIDGE = "cloudbr1"
VMNET = ipaddress.ip_interface("10.250.0.1/24")

# --- Apt ---
APT_ENV = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}

# --- Podman / Compose ---
COMPOSE = "/usr/libexec/docker/cli-plugins/docker-compose"
DOCKER_HOST = "unix:///run/podman/podman.sock"

# --- PKI ---
CFSSL_DIR = BASE_DIR / "src" / "cfssl"
PKI_DIR = STATE_DIR / "pki"
LAB_CA = "ca"
APP_ROOT = "app-root"
LAB_CA_CERT = PKI_DIR / f"{LAB_CA}.pem"

CERTS: dict[str, tuple[str, str, list[str], tuple[int, int]]] = {
    # name:            (root,     profile,  hosts,                                            key owner (uid, gid))
    "vault":           (LAB_CA,   "server", ["vault.lab.test", str(VMNET.ip), "127.0.0.1"],  (100, 1000)),
    "gateway":         (LAB_CA,   "server", ["gitea.lab.test", "minio.lab.test", "minio-console.lab.test",
                                             "cloudstack.lab.test", "grafana.lab.test",
                                             "prometheus.lab.test", "loki.lab.test"],        (0, 0)),
    "app-edge":        (LAB_CA,   "server", ["app.lab.test"],                                 (0, 0)),
    "backend-gw":      (APP_ROOT, "server", ["api.backend.lab.test"],                         (0, 0)),
    "frontend-client": (APP_ROOT, "client", ["frontend.app.lab.test"],                        (0, 0)),
}

# --- Vault ---
VAULT_PORT = 8200
VAULT_ADDR = f"https://{VMNET.ip}:{VAULT_PORT}"
VAULT_INIT_FILE = LAB_DIR / "vault-init.json"
VAULT_POLICY_DIR = SERVICES_DIR / "vault" / "policies"
VAULT_APPROLE_FILE = LAB_DIR / "approle.json"

APPROLES: dict[str, tuple[Path, tuple[int, int]]] = {
    # role (= policy name): (credentials file,  owner (uid, gid))
    "lab-bootstrap":         (VAULT_APPROLE_FILE, (0, 0)),
}
