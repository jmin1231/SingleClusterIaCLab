"""Host step settings, grouped by step. Shared lab settings (BRIDGE, VMNET) stay in src.lib.config."""

from pathlib import Path

FILES = Path(__file__).resolve().parent.parent / "files"

# --- Network (cloudbr1) ---
BRIDGE_ANCHOR = "cloudbr1-anchor"  # the bridge's always-up port; see the netplan file
NETPLAN_SRC = FILES / "60-lab-cloudbr1.yaml"
NETPLAN_FILE = Path("/etc/netplan") / NETPLAN_SRC.name
BRIDGE_UP_TIMEOUT = 30  # seconds; NetworkManager activates the bridge after netplan apply returns

# --- NTP (chrony) ---
CHRONY_PACKAGES = ["chrony"]  # apt package names
CHRONY_SERVICE = "chrony"     # systemd unit name
CHRONY_CONF_SRC = FILES / "chrony-lab.conf"
CHRONY_CONF_DEST = Path("/etc/chrony/conf.d") / CHRONY_CONF_SRC.name

# --- KVM and libvirt ---
KVM_PACKAGES = ["libvirt-daemon-system", "libvirt-daemon-driver-qemu", "libvirt-clients",
                "qemu-system-x86", "qemu-utils"]
LIBVIRT_SOCKET = "libvirtd.socket"
LIBVIRT_URI = "qemu:///system"

# --- Toolchain ---
BIN_DIR = Path("/usr/local/bin")  # on the default PATH, like gitea-runner
ANSIBLE_COMMANDS = ["ansible", "ansible-playbook", "ansible-inventory", "ansible-galaxy"]

# --- Toolchain: Terraform ---
TERRAFORM_VERSION = "1.17.2"
TERRAFORM_URL = f"https://releases.hashicorp.com/terraform/{TERRAFORM_VERSION}/terraform_{TERRAFORM_VERSION}_linux_amd64.zip"
TERRAFORM_SHA256 = "e6f16b2f0b137ee5729caa8c4e79a3bae4ee261acd198a1fcfa8584a6296605b"

# --- Toolchain: Ansible ---
ANSIBLE_CORE_VERSION = "2.21.6"     # 2.22 needs Python 3.13; Ubuntu 24.04 has 3.12
CLOUD_TERRAFORM_VERSION = "4.0.0"
ANSIBLE_VENV = Path("/opt/lab/ansible")
COLLECTIONS_DIR = Path("/usr/share/ansible/collections")
