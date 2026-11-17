"""Operator SSH access: a personal key for the user who ran sudo, and the host aliases fe-1, tun-1, be-1.

The VMs trust this key next to the pipeline key (runner.ensure_ssh_key); the pipeline key stays in Vault.
"""

import logging
import os
import pwd
import subprocess
from pathlib import Path

from src.host.config.config import OPERATOR_KEY_NAME, SSH_CONFIG_FILE, SSH_CONFIG_SRC
from src.lib.system import install_file

log = logging.getLogger(__name__)


def operator_key() -> Path:
    """The private key in the sudo user's ~/.ssh."""
    home = pwd.getpwuid(int(os.environ["SUDO_UID"])).pw_dir
    return Path(home) / ".ssh" / OPERATOR_KEY_NAME


def public_key() -> str:
    """The operator's public key line, derived from the private key (a missing or stale .pub cannot matter)."""
    return subprocess.run(["ssh-keygen", "-y", "-f", str(operator_key())],
                          capture_output=True, text=True, check=True).stdout.strip()


def up() -> None:
    """Create the operator key once, owned by the user like any personal key, and install the host aliases."""
    key = operator_key()
    if key.exists():
        log.info("operator SSH key already at %s", key)
    else:
        uid, gid = int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"])
        if not key.parent.exists():
            key.parent.mkdir(mode=0o700)
            os.chown(key.parent, uid, gid)
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-q",
                        "-C", "lab-operator", "-f", str(key)],
                       check=True, user=uid, group=gid)
        log.info("created operator SSH key %s", key)

    if install_file(SSH_CONFIG_SRC, SSH_CONFIG_FILE, 0o644):
        log.info("SSH aliases fe-1, tun-1, be-1 installed at %s", SSH_CONFIG_FILE)
    else:
        log.info("SSH aliases already at %s", SSH_CONFIG_FILE)


def down() -> None:
    """Remove the host aliases; keep the operator key, a personal key the next up reuses."""
    SSH_CONFIG_FILE.unlink(missing_ok=True)
    log.info("SSH aliases removed; operator key kept at %s (delete by hand if unwanted)", operator_key())
