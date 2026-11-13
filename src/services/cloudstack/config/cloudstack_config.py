"""CloudStack settings: package versions, file paths, URLs, Vault paths and timeouts."""

from pathlib import Path

FILES = Path(__file__).parents[1] / "files"

# --- Packages and apt ---
PACKAGES = ["mysql-server", "nfs-kernel-server", "cloudstack-management", "cloudstack-agent"]
CS_VERSION = "4.22.1.1"  # must match files/lab-cloudstack.pref
KEY_URL = "https://download.cloudstack.org/release.asc"
KEYRING = Path("/etc/apt/keyrings/cloudstack.asc")
SOURCE = Path("/etc/apt/sources.list.d/lab-cloudstack.list")
PIN = Path("/etc/apt/preferences.d/lab-cloudstack")

# --- MySQL and NFS ---
MYSQL_CNF = Path("/etc/mysql/conf.d/cloudstack.cnf")
EXPORT_ROOT = Path("/export")
EXPORTS = Path("/etc/exports.d/lab-cloudstack.exports")
EXPORT_OPTIONS = "rw,async,no_root_squash,no_subtree_check"

# --- cloudbr0 and bridge netfilter ---
LAN_BRIDGE = "cloudbr0"
LAN_NETPLAN = Path("/etc/netplan/60-lab-cloudbr0.yaml")
BRIDGE_TIMEOUT = 60
BRIDGE_NF_SYSCTL = Path("/etc/sysctl.d/90-lab-bridge-nf.conf")
BRIDGE_NF_UDEV = Path("/etc/udev/rules.d/90-lab-bridge-nf.rules")
BRIDGE_NF_KEYS = ("bridge-nf-call-arptables", "bridge-nf-call-ip6tables", "bridge-nf-call-iptables")

# --- Databases and management server ---
CS_SECRETS = "kv/data/lab/bootstrap/cloudstack"
CS_SECRET_NAMES = ("db_password", "management_key", "database_key")
CS_DATABASES = ("cloud", "cloud_usage")
MGMT_URL = "http://127.0.0.1:8080/client/"
MGMT_TIMEOUT = 600
LIMITS = Path("/etc/security/limits.conf")
LIMITS_LINES = ("cloud soft nproc -1", "cloud hard nproc -1")

# --- Admin login and API ---
CS_API = "http://127.0.0.1:8080/client/api"
CS_ADMIN = "kv/data/lab/bootstrap/cloudstack-admin"
CS_DEFAULT_PASSWORD = "password"
LOGIN_REFUSED = 531  # CloudStack's ACCOUNT_ERROR: wrong username or password
