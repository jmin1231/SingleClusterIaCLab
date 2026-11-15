"""Install the Gitea Actions runner as a host systemd service."""

import hashlib
import logging
import lzma
import pwd
import shutil
import subprocess
import urllib.request

from src.lib.system import install_file, systemctl_ok, write_file
from src.services.gitea.runner.config.config import (
    BINARY, BINARY_SHA256, BINARY_URL, CA, CONFIG,
    CONFIG_DIR, FILES, GITEA_RUNNER_KV, HOME, INSTANCE,
    LAB_CA_CERT, NAME, SERVICE, SERVICE_FILE, UID, USER, VERSION,
)
from src.services.vault import vault

log = logging.getLogger(__name__)


def ensure_user() -> None:
    """Create the lab-runner system user for libvirt and Terraform; a re-run changes nothing."""
    try:
        pwd.getpwnam(USER)
        log.info("user %s already exists", USER)
    except KeyError:
        HOME.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["useradd", "--system", "--uid", str(UID), "--user-group",
             "--home-dir", str(HOME), "--create-home", "--shell", "/usr/sbin/nologin", USER],
            check=True,
        )
        log.info("user %s created", USER)

    subprocess.run(["usermod", "-aG", "libvirt", USER], check=True)


def ensure_binary() -> bool:
    """Ensure gitea runner binary exists"""
    if BINARY.exists():
        log.info("gitea runner already installed")
        return False

    # Download the binary and compare the sha
    data = urllib.request.urlopen(BINARY_URL, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != BINARY_SHA256:
        raise RuntimeError(f"{BINARY_URL}: sha256 mismatch")

    # Install the binary
    binary = lzma.decompress(data)
    changed = write_file(binary, BINARY, 0o755)

    log.info("gitea-runner %s installed", VERSION)
    return changed


def ensure_config() -> bool:
    """Install the runner config and the lab CA into /etc/lab-runner; returns True if either changed."""
    CONFIG_DIR.mkdir(mode=0o755, exist_ok=True)
    changed = install_file(FILES / "config.yaml", CONFIG, 0o644)
    changed |= install_file(LAB_CA_CERT, CA, 0o644)

    if changed:
        log.info("runner config and lab CA installed in %s", CONFIG_DIR)
    else:
        log.info("runner config and lab CA are already up to date")
    return changed


def ensure_registered(token: str) -> None:
    """Register the runner with Gitea once; the result is HOME/.runner."""
    runner_file = HOME / ".runner"
    if runner_file.exists():
        log.info("runner already registered (%s exists)", runner_file)
    else:
        reg_token = vault.api("GET", GITEA_RUNNER_KV, token=token)["data"]["data"]["token"]
        subprocess.run(
            [str(BINARY), "register", "--no-interactive",
             "--config", str(CONFIG), "--instance", INSTANCE, "--name", NAME,
             "--token-file", "/dev/stdin"],
            input=reg_token, text=True, check=True,
        )
        # register leaves a root-owned lock; the daemon recreates it as lab-runner
        (HOME / ".runner.lock").unlink(missing_ok=True)
        log.info("runner registered with %s as %s", INSTANCE, NAME)
    # Every run: the daemon runs as lab-runner and must own its credential
    shutil.chown(runner_file, USER, USER)
    runner_file.chmod(0o600)
    

def ensure_service(changed: bool) -> None:
    """Install the unit, enable and start the runner; restart it if its binary, config or unit changed."""
    if install_file(FILES / f"{SERVICE}.service", SERVICE_FILE, 0o644):
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        changed = True

    subprocess.run(["systemctl", "enable", SERVICE], check=True)
    if changed or not systemctl_ok("is-active", SERVICE):
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        log.info("%s (re)started", SERVICE)
    else:
        log.info("%s is already running", SERVICE)


def up() -> None:
    """Install, register and start the runner; a re-run changes nothing."""
    ensure_user()
    changed = ensure_binary()
    changed |= ensure_config()
    ensure_registered(vault.login())
    ensure_service(changed)


def down() -> None:
    """Stop the runner and remove its service, config, binary, user and home."""
    if SERVICE_FILE.exists():
        subprocess.run(["systemctl", "disable", "--now", SERVICE], check=True)
        SERVICE_FILE.unlink()
        subprocess.run(["systemctl", "daemon-reload"], check=True)
    shutil.rmtree(CONFIG_DIR, ignore_errors=True)
    BINARY.unlink(missing_ok=True)
    try:
        pwd.getpwnam(USER)
    except KeyError:
        pass
    else:
        subprocess.run(["userdel", "-r", USER], check=True)
    log.info("runner service, config, binary and user %s removed", USER)
