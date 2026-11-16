from pathlib import Path

from src.lib.config import LAB_CA_CERT, RUNNER_UID
from src.services.gitea.config.config import GITEA_RUNNER_KV

FILES = Path(__file__).resolve().parent.parent / "files"

# gitea-runner release (only the .xz has a published sha256)
VERSION = "6.0.0"
BINARY_URL = f"https://gitea.com/gitea/runner/releases/download/v{VERSION}/gitea-runner-{VERSION}-linux-amd64.xz"
BINARY_SHA256 = "11e23c3a760afa7cf6572255e7204d7e581902e83494c45f7b260d5634c498f2"
BINARY = Path("/usr/local/bin/gitea-runner")

# Host service
USER = "lab-runner"
UID = RUNNER_UID
HOME = Path("/var/lib/lab/runner")
CONFIG_DIR = Path("/etc/lab-runner")
CONFIG = CONFIG_DIR / "config.yaml"
CA = CONFIG_DIR / "ca.pem"
SSH_PUB = CONFIG_DIR / "ssh.pub"  # the lab SSH public key; Terraform puts it on the VMs
SSH_KV = "kv/data/lab/pipeline/ssh"
SERVICE = "lab-runner"                                       # systemctl / journalctl name
SERVICE_FILE = Path(f"/etc/systemd/system/{SERVICE}.service")  # installed systemd unit

# Registration
INSTANCE = "https://gitea.lab.test"
NAME = "lab-host"
