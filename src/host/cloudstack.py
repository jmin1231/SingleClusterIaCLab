"""CloudStack 4.22 on this host, set up step by step from the official Installation Guide."""

import ipaddress
import logging
import secrets
import string
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from src.host.preflight import detect_network
from src.lib.system import (
    apt_install, install_file, ip_json, missing_packages, systemctl_ok, write_file,
)
from src.services.vault import vault

log = logging.getLogger(__name__)

FILES = Path(__file__).parent / "files"
PACKAGES = ["mysql-server", "nfs-kernel-server", "cloudstack-management", "cloudstack-agent"]
CS_VERSION = "4.22.1.1"  # must match files/lab-cloudstack.pref

KEY_URL = "https://download.cloudstack.org/release.asc"
KEYRING = Path("/etc/apt/keyrings/cloudstack.asc")  # .asc: apt reads it as is, no gpg --dearmor
SOURCE = Path("/etc/apt/sources.list.d/lab-cloudstack.list")
PIN = Path("/etc/apt/preferences.d/lab-cloudstack")
MYSQL_CNF = Path("/etc/mysql/conf.d/cloudstack.cnf")
EXPORT_ROOT = Path("/export")
EXPORTS = Path("/etc/exports.d/lab-cloudstack.exports")  # our own file; never edit /etc/exports
EXPORT_OPTIONS = "rw,async,no_root_squash,no_subtree_check"  # the guide's options, verbatim
LAN_BRIDGE = "cloudbr0"  # the guide's name; config.BRIDGE is cloudbr1, the host-only one
LAN_NETPLAN = Path("/etc/netplan/60-lab-cloudbr0.yaml")  # 60-: after 50-cloud-init.yaml, so it wins
BRIDGE_TIMEOUT = 60  # seconds for cloudbr0 to hold HOST_IP and reach the gateway after apply
CS_SECRETS = "kv/data/lab/bootstrap/cloudstack"  # Vault KV v2: kv/data/<path>
CS_SECRET_NAMES = ("db_password", "management_key", "database_key")
CS_DATABASES = ("cloud", "cloud_usage")
MGMT_URL = "http://127.0.0.1:8080/client/"
MGMT_TIMEOUT = 600  # seconds; the first start builds the database tables
LIMITS = Path("/etc/security/limits.conf")
LIMITS_LINES = ("cloud soft nproc -1", "cloud hard nproc -1")  # appended by cloudstack-setup-management


def repo() -> bool:
    """Download CloudStack's key, add its source (signed-by that key only) and the version pin.

    Returns True if anything changed, so the caller knows apt's package lists are stale.
    """
    key = urllib.request.urlopen(KEY_URL, timeout=30).read()

    changed = not KEYRING.exists() or KEYRING.read_bytes() != key
    if changed:
        KEYRING.write_bytes(key)
        KEYRING.chmod(0o644)

    changed |= install_file(FILES / "lab-cloudstack.list", SOURCE, 0o644)
    changed |= install_file(FILES / "lab-cloudstack.pref", PIN, 0o644)

    if changed:
        log.info("CloudStack 4.22 apt repository configured")
    else:
        log.info("CloudStack 4.22 apt repository is already configured")
    return changed


def check_version() -> None:
    """Stop unless the installed CloudStack is exactly the pinned version."""
    version = subprocess.run(["dpkg-query", "-W", "-f=${Version}", "cloudstack-management"],
                             capture_output=True, text=True, check=True).stdout
    if version != CS_VERSION:
        log.error("cloudstack-management %s is installed, but the lab pins %s; "
                  "run destroy, then up", version, CS_VERSION)
        sys.exit(1)


def mysql() -> None:
    """MySQL settings for CloudStack; restart MySQL only if they changed."""
    if install_file(FILES / "cloudstack-mysql.conf", MYSQL_CNF, 0o644):
        try:
            subprocess.run(["systemctl", "restart", "mysql"], check=True)
        except BaseException:
            MYSQL_CNF.unlink(missing_ok=True)
            raise
        log.info("MySQL configured for CloudStack and restarted")
    else:
        log.info("MySQL is already configured for CloudStack")


def nfs() -> None:
    """Share /export (primary and secondary storage) with the LAN subnet only."""
    net = detect_network()
    subnet = ipaddress.ip_interface(f"{net['host_ip']}/{net['prefix']}").network

    for name in ("primary", "secondary"):
        (EXPORT_ROOT / name).mkdir(parents=True, exist_ok=True)
    EXPORTS.parent.mkdir(exist_ok=True)  # /etc/exports.d doesn't exist on a fresh host

    line = f"{EXPORT_ROOT} {subnet}({EXPORT_OPTIONS})\n"
    if write_file(line.encode(), EXPORTS, 0o644):
        try:
            subprocess.run(["exportfs", "-ra"], check=True)  # -r also drops lines no longer there
        except BaseException:
            EXPORTS.unlink(missing_ok=True)
            raise
        log.info("NFS: %s exported to %s", EXPORT_ROOT, subnet)
    else:
        log.info("NFS: %s is already exported to %s", EXPORT_ROOT, subnet)


def lan_card(net: dict) -> str:
    """Return the physical LAN card, both before and after it becomes a port of cloudbr0."""
    card = net["card"]
    if card != LAN_BRIDGE:
        return card

    for port in sorted(Path("/sys/class/net", LAN_BRIDGE, "brif").iterdir()):
        if Path("/sys/class/net", port.name, "device").exists():
            return port.name

    log.error("%s holds the default route but has no physical card as a port", LAN_BRIDGE)
    sys.exit(1)


def netplan_yaml(card: str, mac: str) -> str:
    """Fill in the cloudbr0 netplan template for a DHCP host."""
    template = FILES / "cloudbr0-dhcp.yaml.tmpl"
    return string.Template(template.read_text()).substitute(card=card, mac=mac)


def restore_netplan(previous: bytes | None) -> None:
    """Put LAN_NETPLAN back as it was before this run (absent if it was absent) and apply it."""
    if previous is None:
        LAN_NETPLAN.unlink(missing_ok=True)
    else:
        write_file(previous, LAN_NETPLAN, 0o600)
    subprocess.run(["netplan", "apply"], check=True)


def bridge_ready(host_ip: str, gateway: str) -> bool:
    """Tell whether cloudbr0 holds the host's address and can reach the gateway."""
    try:
        links = ip_json("-4", "addr", "show", "dev", LAN_BRIDGE)
    except subprocess.CalledProcessError:
        return False

    if not any(addr["local"] == host_ip for link in links for addr in link["addr_info"]):
        return False
    return subprocess.run(["ping", "-c1", "-W2", gateway], capture_output=True).returncode == 0


def bridge() -> None:
    """Move the host's LAN address from its card onto cloudbr0, rolling back if the LAN is lost."""
    net = detect_network()
    card = lan_card(net)
    mac = Path("/sys/class/net", card, "address").read_text().strip()
    host_ip = net["host_ip"]
    gateway = net["gateway"]

    profile = subprocess.run(["nmcli", "-g", "GENERAL.CONNECTION", "device", "show", card],
                             capture_output=True, text=True, check=True).stdout.strip()
    if profile != f"netplan-{card}":
        log.error("%s is managed by NetworkManager profile %r, not netplan-%s: "
                  "not bridging it", card, profile, card)
        sys.exit(1)
    if not net["dhcp"]:
        log.error("%s has a static address: the lab bridges DHCP hosts only (a later netplan "
                  "file cannot remove the card's own address); not bridging it", card)
        sys.exit(1)

    previous = LAN_NETPLAN.read_bytes() if LAN_NETPLAN.exists() else None
    changed = write_file(netplan_yaml(card, mac).encode(), LAN_NETPLAN, 0o600)
    if not changed and bridge_ready(host_ip, gateway):
        log.info("%s is already up with %s", LAN_BRIDGE, host_ip)
        return

    try:
        subprocess.run(["netplan", "apply"], check=True)
        deadline = time.monotonic() + BRIDGE_TIMEOUT
        while not bridge_ready(host_ip, gateway):
            if time.monotonic() > deadline:
                raise TimeoutError(f"no {host_ip} on {LAN_BRIDGE} or no answer from {gateway} "
                                   f"within {BRIDGE_TIMEOUT}s")
            time.sleep(1)
    except BaseException as err:
        restore_netplan(previous)
        log.error("%s did not come up (%s); rolled back %s", LAN_BRIDGE, err or "interrupted",
                  LAN_NETPLAN)
        if isinstance(err, Exception):
            sys.exit(1)
        raise
    log.info("%s is up with %s (port %s)", LAN_BRIDGE, host_ip, card)


def cs_credentials(token: str, create: bool) -> dict | None:
    """Return CloudStack's database password and encryption keys from Vault.

    Creates them (once, never replaced) only when `create` is True; otherwise returns None
    when Vault has none.
    """
    resp = vault.api("GET", CS_SECRETS, token=token)
    if resp:
        return resp["data"]["data"]

    if not create:
        return None

    creds = {name: secrets.token_urlsafe(32) for name in CS_SECRET_NAMES}
    vault.api("POST", CS_SECRETS, {"data": creds}, token=token)
    log.info("stored new CloudStack credentials in %s", CS_SECRETS.replace("/data/", "/", 1))
    return creds


def databases(token: str) -> None:
    """Create CloudStack's databases (cloud, cloud_usage) once; refuse a broken or foreign deploy."""
    out = subprocess.run(
        ["mysql", "-N", "-B", "-e",
         "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA "
         "WHERE SCHEMA_NAME IN ('cloud', 'cloud_usage')"],
        capture_output=True, text=True, check=True).stdout
    existing = set(out.split())

    if existing == set(CS_DATABASES):
        version = subprocess.run(
            ["mysql", "-N", "-B", "-e", "SELECT version FROM cloud.version ORDER BY id DESC LIMIT 1"],
            capture_output=True, text=True).stdout.strip()
        if version != CS_VERSION:
            log.error("the cloud database is at version %s, not %s: a failed or foreign deploy; "
                      "run destroy, then up", version or "(none)", CS_VERSION)
            sys.exit(1)
        if cs_credentials(token, create=False) is None:
            log.error("CloudStack databases exist but Vault has no credentials for them; "
                      "run destroy, then up")
            sys.exit(1)
        log.info("CloudStack databases are already deployed")
        return

    if existing:
        log.error("only %s exists: a half-finished CloudStack database deploy; "
                  "run destroy, then up", ", ".join(sorted(existing)))
        sys.exit(1)

    creds = cs_credentials(token, create=True)
    subprocess.run(["systemctl", "stop", "cloudstack-management"], check=True)

    host_ip = detect_network()["host_ip"]
    result = subprocess.run([
        "cloudstack-setup-databases",
        f"cloud:{creds['db_password']}@localhost",
        "--deploy-as=root:",
        "-e", "file",
        "-m", creds["management_key"],
        "-k", creds["database_key"],
        "-i", host_ip,
    ])
    if result.returncode != 0:
        log.error("cloudstack-setup-databases failed (exit %d); see its output above",
                  result.returncode)
        sys.exit(1)

    log.info("CloudStack databases deployed (management server %s)", host_ip)


def mgmt_ready() -> bool:
    """Tell whether the management server answers HTTP 200 on port 8080."""
    try:
        with urllib.request.urlopen(MGMT_URL, timeout=5) as resp:
            return resp.status == 200
    except (urllib.error.URLError, ConnectionError, TimeoutError):
        return False


def setup_done() -> bool:
    """Tell whether cloudstack-setup-management has run: it appends LIMITS_LINES to limits.conf."""
    lines = LIMITS.read_text().splitlines() if LIMITS.exists() else []
    return all(line in lines for line in LIMITS_LINES)


def management() -> None:
    """Run cloudstack-setup-management until it has completed once, start the server, wait for it.

    The setup tool is safe to re-run (it skips lines already in limits.conf), so an interrupted
    setup is simply run again on the next up.
    """
    if not setup_done():
        subprocess.run(["cloudstack-setup-management"], check=True)
    elif not systemctl_ok("is-active", "cloudstack-management"):
        subprocess.run(["systemctl", "start", "cloudstack-management"], check=True)

    start = time.monotonic()
    next_note = start + 60
    while not mgmt_ready():
        now = time.monotonic()
        if now - start > MGMT_TIMEOUT:
            log.error("CloudStack management server did not answer on %s within %ds; "
                      "see /var/log/cloudstack/management/management-server.log",
                      MGMT_URL, MGMT_TIMEOUT)
            sys.exit(1)
        if now > next_note:
            log.info("still waiting for the CloudStack management server (%ds)", now - start)
            next_note = now + 60
        time.sleep(5)
    log.info("CloudStack management server answering on %s", MGMT_URL)


def down() -> None:
    """Stop the management server and remove its databases, its MySQL user and its limits.

    First version: covers what part 4 creates, so part 4 can be reset and re-run.
    """
    subprocess.run(["systemctl", "disable", "--now", "cloudstack-management"], capture_output=True)

    if missing_packages(["mysql-server"]):
        log.info("MySQL is not installed; no CloudStack databases to remove")
    else:
        if not systemctl_ok("is-active", "mysql"):
            subprocess.run(["systemctl", "start", "mysql"], check=True)
        subprocess.run(["mysql", "-e",
                        "DROP DATABASE IF EXISTS cloud; DROP DATABASE IF EXISTS cloud_usage; "
                        "DROP USER IF EXISTS 'cloud'@'localhost', 'cloud'@'%';"], check=True)
        log.info("CloudStack databases and MySQL user cloud removed")

    if LIMITS.exists():
        lines = LIMITS.read_text().splitlines(keepends=True)
        kept = [line for line in lines if line.strip() not in LIMITS_LINES]
        if kept != lines:
            LIMITS.write_text("".join(kept))
            log.info("removed the cloud user's lines from %s", LIMITS)

    log.info("CloudStack management server stopped and disabled")


def up() -> None:
    """Install CloudStack 4.22.1.1 and its dependencies; a re-run changes nothing."""
    repo()
    if not apt_install(PACKAGES):
        log.info("CloudStack packages are already installed")
    check_version()
    mysql()
    nfs()
    bridge()
    databases(vault.login())
    management()