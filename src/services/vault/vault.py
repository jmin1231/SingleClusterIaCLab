"""Vault: the secrets and encryption service, running in Podman on 10.250.0.1:8200."""

import json
import logging
import os
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from src.host import podman
from src.lib.config import (
    APPROLES, LAB_CA_CERT, LAB_DIR,
    VAULT_ADDR, VAULT_APPROLE_FILE, VAULT_INIT_FILE, VAULT_POLICY_DIR,
)
from src.lib.system import compose

log = logging.getLogger(__name__)


def api(method: str, path: str, body: dict | None = None, token: str | None = None) -> dict:
    """Call Vault's HTTP API, verifying TLS against lab.test CA. Secrets travel in the body, never argv.

    A GET of something that does not exist returns {}; every other HTTP error raises.
    """
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'X-Vault-Token': token} if token is not None else {}
    )
    ctx = ssl.create_default_context(cafile=LAB_CA_CERT)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            data = resp.read()
    except urllib.error.HTTPError as err:
        if method == "GET" and err.code == 404:
            return {}
        raise
    return json.loads(data) if data else {}


def init() -> None:
    """Initialize Vault once; the unseal key and root token go to vault-init.json (0600, never overwritten)."""
    initialized = api("GET", "sys/init")["initialized"]
    if initialized and VAULT_INIT_FILE.exists():
        log.info("Vault is already initialized")
        return
    if initialized:
        log.error("Vault is initialized but %s is missing: the unseal key is lost", VAULT_INIT_FILE)
        sys.exit(1)
    if VAULT_INIT_FILE.exists():
        log.error("%s exists but Vault is new: it belongs to an older Vault; move it away and re-run", VAULT_INIT_FILE)
        sys.exit(1)

    keys = api("PUT", "sys/init", {"secret_shares": 1, "secret_threshold": 1})
    LAB_DIR.mkdir(0o755, parents=True, exist_ok=True)
    fd = os.open(VAULT_INIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(keys, file)
        file.flush()
        os.fsync(file.fileno())
    log.info("Vault initialized; unseal key and root token in %s", VAULT_INIT_FILE)


def mount(token: str, path: str, body: dict) -> None:
    """Enable a secrets engine at <path>/ unless it is already mounted."""
    if f"{path}/" in api("GET", "sys/mounts", token=token)["data"]:
        log.info("%s/ is already mounted", path)
        return
    api("POST", f"sys/mounts/{path}", body, token=token)
    log.info("enabled %s/", path)


def unseal(key: str, timeout: int = 30) -> None:
    """Unseal Vault if it is sealed (after every restart), then wait until it is active."""
    if not api("GET", "sys/seal-status")["sealed"]:
        log.info("Vault is already unsealed")
        return
    if api("PUT", "sys/unseal", {"key": key})["sealed"]:
        log.error("Vault is still sealed after the unseal")
        sys.exit(1)

    deadline = time.monotonic() + timeout
    while True:
        try:
            api("GET", "sys/health")
            break
        except urllib.error.HTTPError:
            if time.monotonic() > deadline:
                log.error("Vault was unsealed but did not become active within %ds", timeout)
                sys.exit(1)
            time.sleep(1)
    log.info("Vault unsealed")


def ssh_key(token: str) -> None:
    """Store the lab SSH keypair at kv/lab/pipeline/ssh once; never replace it."""
    path = "kv/data/lab/pipeline/ssh"

    if api("GET", path, token=token):
        log.info("SSH key pair already exists")
        return

    with tempfile.TemporaryDirectory() as tmp:
        key = Path(tmp) / "id_ed25519"
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "",
                        "-C", "lab", "-q", "-f", str(key)], check=True)
        private = key.read_text()
        public = key.with_suffix(".pub").read_text()

    api("POST", path, {"data": {"private_key": private, "public_key": public}}, token=token)
    log.info("stored a new SSH key pair in kv/lab/pipeline/ssh")


def policy(token: str) -> None:
    """Upload every policies/*.hcl as the Vault policy named after the file; skip unchanged ones."""
    for file in sorted(VAULT_POLICY_DIR.glob("*.hcl")):
        path = f"sys/policies/acl/{file.stem}"
        text = file.read_text()

        if api("GET", path, token=token).get("data", {}).get("policy") == text:
            log.info("policy %s unchanged", file.stem)
            continue

        api("PUT", path, {"policy": text}, token=token)
        log.info("policy %s written", file.stem)


def enable_approle(token: str) -> None:
    """Enable the AppRole auth method unless it's already enabled."""
    if "approle/" in api("GET", "sys/auth", token=token)["data"]:
        log.info("approle/ is already enabled")
        return
    
    api("POST", "sys/auth/approle", {"type": "approle"}, token=token)
    log.info("approle/ enabled")


def approle(token: str, role: str, out: Path, owner: tuple[int, int]) -> None:
    """Create AppRole <role> with policy <role>, and write its role_id + secret_id to <out> once."""
    if out.exists() and out.stat().st_uid == owner[0]:
        log.info("AppRole %s already set up", role)
        return
    
    path = f"auth/approle/role/{role}"
    api("POST", path, {"token_policies": [role], "token_ttl": "1h",
                       "secret_id_ttl": "8760h"}, token=token)
    role_id = api("GET", f"{path}/role-id", token=token)["data"]["role_id"]
    secret_id = api("POST", f"{path}/secret-id", token=token)["data"]["secret_id"]

    out.parent.mkdir(0o755, parents=True, exist_ok=True)  # the file's 0600 protects the secret
    out.unlink(missing_ok=True)  # a file left with the wrong owner by a crash before chown
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump({"role_id": role_id, "secret_id": secret_id}, file)
        file.flush()
        os.fsync(file.fileno())
    os.chown(out, *owner)
    log.info("AppRole %s created; credentials in %s", role, out)


def login(creds_file: Path = VAULT_APPROLE_FILE) -> str:
    """Log in with an AppRole credentials file written by approle(); returns a token (1 h).

    The default is lab-bootstrap's file; a CI job passes its own (lab-pipeline, 2.10).
    """
    creds = json.loads(creds_file.read_text())
    return api("POST", "auth/approle/login", creds)["auth"]["client_token"]


def revoke_root(root: str) -> None:
    """Revoke the initial root token; does nothing if it is already revoked."""
    try:
        api("POST", "auth/token/revoke-self", token=root)
        log.info("root token revoked")
    except urllib.error.HTTPError as err:
        if err.code != 403:  # a revoked token is "permission denied"
            raise
        log.info("root token is already revoked")


def up(certs_changed: bool) -> None:
    """Start, init and unseal Vault, then configure it as lab-bootstrap; a re-run changes nothing.

    The first run uses the root token to create AppRole lab-bootstrap, then revokes it.
    """
    # --wait returns once the healthcheck passes, which it does while sealed.
    compose("vault", "up", "-d", "--wait", "--wait-timeout", "60",
            *(["--force-recreate"] if certs_changed else ["--no-recreate"]))
    init()
    keys = json.loads(VAULT_INIT_FILE.read_text())
    unseal(keys["keys_base64"][0])

    if not VAULT_APPROLE_FILE.exists():  # first run: the root token's last job
        root = keys["root_token"]
        policy(root)  # AppRole lab-bootstrap's tokens get policy lab-bootstrap
        enable_approle(root)
        approle(root, "lab-bootstrap", *APPROLES["lab-bootstrap"])
    token = login()
    revoke_root(keys["root_token"])  # only once login() works, so a broken AppRole never locks us out

    mount(token, "kv", {"type": "kv", "options": {"version": "2"}})
    mount(token, "transit", {"type": "transit"})
    policy(token)
    for role, (out, owner) in APPROLES.items():
        approle(token, role, out, owner)
    ssh_key(token)
    log.info("Vault ready on %s", VAULT_ADDR)


def down() -> None:
    """Remove the Vault container, its data, its unseal key and every AppRole credentials file."""
    if podman.check():
        compose("vault", "down", "--volumes")
    else:
        log.info("Podman is not set up; no Vault container to remove")
    VAULT_INIT_FILE.unlink(missing_ok=True)  # the keys are useless once the data is gone
    for out, _ in APPROLES.values():
        out.unlink(missing_ok=True)
    log.info("Vault removed: container, data, unseal key and AppRole credentials")