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
# What Terraform creates in libvirt (terraform/compute.tf, network.tf, storage.tf); kvm.down() removes it before the purge
LAB_DOMAINS = ["fe-1", "tun-1", "be-1"]
LAB_NETWORKS = ["site-a", "site-hub", "site-c", "wan"]
LAB_POOL = "lab"
LIBVIRT_SOCKET = "libvirtd.socket"
LIBVIRT_URI = "qemu:///system"

# --- Toolchain ---
BIN_DIR = Path("/usr/local/bin")  # on the default PATH, like gitea-runner

# --- Toolchain: Terraform ---
TERRAFORM_VERSION = "1.17.2"
TERRAFORM_URL = f"https://releases.hashicorp.com/terraform/{TERRAFORM_VERSION}/terraform_{TERRAFORM_VERSION}_linux_amd64.zip"
TERRAFORM_SHA256 = "e6f16b2f0b137ee5729caa8c4e79a3bae4ee261acd198a1fcfa8584a6296605b"

# --- Toolchain: Ansible ---
ANSIBLE_PACKAGES = ["ansible-core"]
ANSIBLE_GALAXY = Path("/usr/bin/ansible-galaxy")  # full path, so installed_version_ok can check it exists
CLOUD_TERRAFORM_VERSION = "4.0.0"
COLLECTIONS_DIR = Path("/usr/share/ansible/collections")  # on Ansible's default search path

# --- Toolchain: Node ---
NODE_VERSION = "24.22.3"
NODE_URL = f"https://nodejs.org/dist/v{NODE_VERSION}/node-v{NODE_VERSION}-linux-x64.tar.xz"
NODE_SHA256 = "4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb"
NODE_MEMBER = f"node-v{NODE_VERSION}-linux-x64/bin/node"  # the only file taken from the archive

# --- Toolchain: Trivy ---
TRIVY_VERSION = "0.76.2"
TRIVY_URL = f"https://github.com/aquasecurity/trivy/releases/download/v{TRIVY_VERSION}/trivy_{TRIVY_VERSION}_Linux-64bit.tar.gz"
TRIVY_SHA256 = "bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf"
TRIVY_MEMBER = "trivy"  # the only file taken from the archive

# --- VM firewall (vmfw) ---
# Preinstalled on Ubuntu; installed if missing, never purged
VMFW_PACKAGES = ["nftables"]
VMFW_NFT_SRC = FILES / "nftables-vmfw.nft"
VMFW_TABLES = ["bridge lab_vmfw_l2", "inet lab_vmfw"]  # must match the tables in VMFW_NFT_SRC
VMFW_MARKER = Path("/run/lab/vmfw.loaded")  # /run empties on reboot, like the rules; terraform.yml checks it

# --- Operator SSH access (ssh_access) ---
SSH_CONFIG_SRC = FILES / "60-lab-ssh.conf"
SSH_CONFIG_FILE = Path("/etc/ssh/ssh_config.d") / SSH_CONFIG_SRC.name  # /etc/ssh/ssh_config includes *.conf from here
OPERATOR_KEY_NAME = "lab_operator"  # ~/.ssh/<name> of the user who ran sudo; must match IdentityFile in SSH_CONFIG_SRC
