"""Install the Gitea Actions runner as a host systemd service."""

import hashlib
import logging
import lzma
import os
import pwd
import shutil
import subprocess
import urllib.request

from src.host import ssh_access
from src.lib import config as lab_config
from src.lib.system import install_file, systemctl_ok, write_file
from src.services.gitea.config import config as gitea_config
from src.services.gitea.runner.config import config
from src.services.vault import vault

log = logging.getLogger(__name__)


def ensure_home() -> None:
    """Create the runner's data directory (registration file, job workdirs); jobs run as root."""
    config.HOME.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(config.HOME, 0, 0)
    config.HOME.chmod(0o700)


def ensure_binary() -> bool:
    """Ensure gitea runner binary exists"""
    if config.BINARY.exists():
        log.info("gitea runner already installed")
        return False

    # Download the binary and compare the sha
    data = urllib.request.urlopen(config.BINARY_URL, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != config.BINARY_SHA256:
        raise RuntimeError(f"{config.BINARY_URL}: sha256 mismatch")

    # Install the binary
    binary = lzma.decompress(data)
    changed = write_file(binary, config.BINARY, 0o755)

    log.info("gitea-runner %s installed", config.VERSION)
    return changed


def ensure_config() -> bool:
    """Install the runner config and the lab CA into /etc/lab-runner; returns True if either changed."""
    config.CONFIG_DIR.mkdir(mode=0o755, exist_ok=True)
    changed = install_file(config.FILES / "config.yaml", config.CONFIG, 0o644)
    changed |= install_file(lab_config.LAB_CA_CERT, config.CA, 0o644)

    if changed:
        log.info("runner config and lab CA installed in %s", config.CONFIG_DIR)
    else:
        log.info("runner config and lab CA are already up to date")
    return changed


def ensure_ssh_key(token: str) -> None:
    """Publish the VMs' authorized keys (public, so 0644) where Terraform reads them, one per line:
    the pipeline key (its private half stays in Vault) and the operator key (ssh_access)."""
    pipeline = vault.vault_api("GET", config.SSH_KV, token=token)["data"]["data"]["public_key"].strip()
    keys = f"{pipeline}\n{ssh_access.public_key()}\n"
    if write_file(keys.encode(), config.SSH_PUB, 0o644):
        log.info("VM SSH public keys (pipeline, operator) installed at %s", config.SSH_PUB)
    else:
        log.info("VM SSH public keys already at %s", config.SSH_PUB)


def ensure_registered(token: str) -> None:
    """Register the runner with Gitea once; the result is HOME/.runner."""
    runner_file = config.HOME / ".runner"
    if runner_file.exists():
        log.info("runner already registered (%s exists)", runner_file)
    else:
        reg_token = vault.vault_api("GET", gitea_config.GITEA_RUNNER_KV, token=token)["data"]["data"]["token"]
        subprocess.run(
            [str(config.BINARY), "register", "--no-interactive",
             "--config", str(config.CONFIG), "--instance", config.INSTANCE, "--name", config.NAME,
             "--token-file", "/dev/stdin"],
            input=reg_token, text=True, check=True,
        )
        log.info("runner registered with %s as %s", config.INSTANCE, config.NAME)
    runner_file.chmod(0o600)
    

def ensure_service(changed: bool) -> None:
    """Install the unit, enable and start the runner; restart it if its binary, config or unit changed."""
    if install_file(config.FILES / f"{config.SERVICE}.service", config.SERVICE_FILE, 0o644):
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        changed = True

    subprocess.run(["systemctl", "enable", config.SERVICE], check=True)
    if changed or not systemctl_ok("is-active", config.SERVICE):
        subprocess.run(["systemctl", "restart", config.SERVICE], check=True)
        log.info("%s (re)started", config.SERVICE)
    else:
        log.info("%s is already running", config.SERVICE)


def up() -> None:
    """Install, register and start the runner; a re-run changes nothing."""
    ensure_home()
    changed = ensure_binary()
    changed |= ensure_config()
    token = vault.login()
    ensure_ssh_key(token)
    ensure_registered(token)
    ensure_service(changed)


def down() -> None:
    """Stop the runner and remove its service, config, binary and data directory."""
    if config.SERVICE_FILE.exists():
        subprocess.run(["systemctl", "disable", "--now", config.SERVICE], check=True)
        config.SERVICE_FILE.unlink()
        subprocess.run(["systemctl", "daemon-reload"], check=True)
    shutil.rmtree(config.CONFIG_DIR, ignore_errors=True)
    config.BINARY.unlink(missing_ok=True)
    shutil.rmtree(config.HOME, ignore_errors=True)
    try:
        pwd.getpwnam(config.OLD_USER)
    except KeyError:
        pass
    else:
        subprocess.run(["userdel", config.OLD_USER], check=True)
    log.info("runner service, config, binary and data directory removed")
