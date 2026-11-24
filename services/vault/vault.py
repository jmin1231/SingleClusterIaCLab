"""Vault: the secrets service, running in Podman on 10.250.0.1:8200."""

import json
import logging
import os
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from podman import podman
from lib import config
from lib.system import compose

log = logging.getLogger(__name__)


def vault_api(method: str, path: str, body: dict | None = None, token: str | None = None) -> dict:
    """Call Vault's HTTP API, verifying TLS against lab.test CA. Secrets travel in the body, never argv.

    A GET of something that does not exist returns {}; every other HTTP error raises.
    """
    req = urllib.request.Request(
        f"{config.VAULT_ADDR}/v1/{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'X-Vault-Token': token} if token is not None else {}
    )
    ctx = ssl.create_default_context(cafile=config.LAB_CA_CERT)
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
    initialized = vault_api("GET", "sys/init")["initialized"]
    if initialized and config.VAULT_INIT_FILE.exists():
        log.info("Vault is already initialized")
        return
    if initialized:
        log.error("Vault is initialized but %s is missing: the unseal key is lost", config.VAULT_INIT_FILE)
        sys.exit(1)
    if config.VAULT_INIT_FILE.exists():
        log.error("%s exists but Vault is new: it belongs to an older Vault; move it away and re-run", config.VAULT_INIT_FILE)
        sys.exit(1)

    keys = vault_api("PUT", "sys/init", {"secret_shares": 1, "secret_threshold": 1})
    config.LAB_DIR.mkdir(0o755, parents=True, exist_ok=True)
    fd = os.open(config.VAULT_INIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(keys, file)
        file.flush()
        os.fsync(file.fileno())
    log.info("Vault initialized; unseal key and root token in %s", config.VAULT_INIT_FILE)


def mount(token: str, path: str, body: dict) -> None:
    """Enable a secrets engine at <path>/ unless it is already mounted."""
    if f"{path}/" in vault_api("GET", "sys/mounts", token=token)["data"]:
        log.info("%s/ is already mounted", path)
        return
    vault_api("POST", f"sys/mounts/{path}", body, token=token)
    log.info("enabled %s/", path)


def unseal(key: str, timeout: int = 30) -> None:
    """Unseal Vault if it is sealed (after every restart), then wait until it is active."""
    if not vault_api("GET", "sys/seal-status")["sealed"]:
        log.info("Vault is already unsealed")
        return
    if vault_api("PUT", "sys/unseal", {"key": key})["sealed"]:
        log.error("Vault is still sealed after the unseal")
        sys.exit(1)

    for _ in range(timeout):
        try:
            vault_api("GET", "sys/health")
            log.info("Vault unsealed")
            return
        except urllib.error.HTTPError:
            time.sleep(1)
    log.error("Vault was unsealed but did not become active within %ds", timeout)
    sys.exit(1)


def ssh_key(token: str) -> None:
    """Store the lab SSH keypair at kv/lab/pipeline/ssh once; never replace it."""
    path = "kv/data/lab/pipeline/ssh"

    if vault_api("GET", path, token=token):
        log.info("SSH key pair already exists")
        return

    with tempfile.TemporaryDirectory() as tmp:
        key = Path(tmp) / "id_ed25519"
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "",
                        "-C", "lab", "-q", "-f", str(key)], check=True)
        private = key.read_text()
        public = key.with_suffix(".pub").read_text()

    vault_api("POST", path, {"data": {"private_key": private, "public_key": public}}, token=token)
    log.info("stored a new SSH key pair in kv/lab/pipeline/ssh")


def app_db_passwords(token: str) -> None:
    """Store the app database's authenticator password at kv/lab/pipeline/app-db once; never replace it.

    CNPG's postgres superuser has no password (local peer auth only), so only PostgREST's login role is stored here.
    """
    path = "kv/data/lab/pipeline/app-db"

    if vault_api("GET", path, token=token):
        log.info("App database passwords already exist")
        return

    passwords = {
        "authenticator_password": secrets.token_urlsafe(24),
    }
    vault_api("POST", path, {"data": passwords}, token=token)
    log.info("stored new app database passwords in kv/lab/pipeline/app-db")


def app_edge_cert(token: str) -> None:
    """Copy the app-edge certificate and key from state/pki into kv/lab/pipeline/app-edge; rewrite only if they changed."""
    path = "kv/data/lab/pipeline/app-edge"
    cert = (config.PKI_DIR / "app-edge.pem").read_text()
    key = (config.PKI_DIR / "app-edge-key.pem").read_text()

    current = vault_api("GET", path, token=token).get("data", {}).get("data", {})
    if current.get("cert") == cert and current.get("key") == key:
        log.info("app-edge certificate in Vault is up to date")
        return

    vault_api("POST", path, {"data": {"cert": cert, "key": key}}, token=token)
    log.info("stored the app-edge certificate and key in kv/lab/pipeline/app-edge")


def policy(token: str) -> None:
    """Upload every policies/*.hcl as the Vault policy named after the file; skip unchanged ones."""
    for file in sorted(config.VAULT_POLICY_DIR.glob("*.hcl")):
        path = f"sys/policies/acl/{file.stem}"
        text = file.read_text()

        if vault_api("GET", path, token=token).get("data", {}).get("policy") == text:
            log.info("policy %s unchanged", file.stem)
            continue

        vault_api("PUT", path, {"policy": text}, token=token)
        log.info("policy %s written", file.stem)


def enable_approle(token: str) -> None:
    """Enable the AppRole auth method unless it's already enabled."""
    if "approle/" in vault_api("GET", "sys/auth", token=token)["data"]:
        log.info("approle/ is already enabled")
        return
    
    vault_api("POST", "sys/auth/approle", {"type": "approle"}, token=token)
    log.info("approle/ enabled")


def approle_credentials(token: str, role: str) -> dict:
    """Create AppRole <role> (policy <role>) if needed and issue a new secret_id; returns role_id and secret_id."""
    path = f"auth/approle/role/{role}"
    vault_api("POST", path, {"token_policies": [role], "token_ttl": "1h",
                             "secret_id_ttl": "8760h"}, token=token)
    role_id = vault_api("GET", f"{path}/role-id", token=token)["data"]["role_id"]
    secret_id = vault_api("POST", f"{path}/secret-id", token=token)["data"]["secret_id"]
    return {"role_id": role_id, "secret_id": secret_id}


def approle(token: str, role: str, creds_file: Path, owner: tuple[int, int]) -> None:
    """Create AppRole <role> with policy <role>, and write its role_id + secret_id to <creds_file> once."""
    if creds_file.exists() and creds_file.stat().st_uid == owner[0]:
        log.info("AppRole %s already set up", role)
        return

    creds = approle_credentials(token, role)

    creds_file.parent.mkdir(0o755, parents=True, exist_ok=True)  # the file's 0600 protects the secret
    creds_file.unlink(missing_ok=True)  # a file left with the wrong owner by a crash before chown
    fd = os.open(creds_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(creds, file)
        file.flush()
        os.fsync(file.fileno())
    os.chown(creds_file, *owner)
    log.info("AppRole %s created; credentials in %s", role, creds_file)


def login(creds_file: Path = config.VAULT_APPROLE_FILE) -> str:
    """Log in with an AppRole credentials file written by approle(); returns a token (1 h).

    The default is lab-bootstrap's file; CI jobs log in through Gitea secrets instead.
    """
    creds = json.loads(creds_file.read_text())
    return vault_api("POST", "auth/approle/login", creds)["auth"]["client_token"]


def revoke_root(root: str) -> None:
    """Revoke the initial root token; does nothing if it is already revoked."""
    try:
        vault_api("POST", "auth/token/revoke-self", token=root)
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
            *(["--force-recreate"] if certs_changed else []))
    init()
    keys = json.loads(config.VAULT_INIT_FILE.read_text())
    unseal(keys["keys_base64"][0])

    if not config.VAULT_APPROLE_FILE.exists():  # first run: the root token's last job
        root = keys["root_token"]
        policy(root)  # AppRole lab-bootstrap's tokens get policy lab-bootstrap
        enable_approle(root)
        approle(root, "lab-bootstrap", config.VAULT_APPROLE_FILE, (0, 0))
    token = login()
    revoke_root(keys["root_token"])  # only once login() works, so a broken AppRole never locks us out

    mount(token, "kv", {"type": "kv", "options": {"version": "2"}})
    policy(token)
    ssh_key(token)
    app_db_passwords(token)
    app_edge_cert(token)
    log.info("Vault ready on %s", config.VAULT_ADDR)


def down() -> None:
    """Remove the Vault container, its data, its unseal key and lab-bootstrap's AppRole credentials."""
    if not podman.check():
        log.info("Podman is not set up; Vault's data and unseal key are kept")
        return
    compose("vault", "down", "--volumes")
    config.VAULT_INIT_FILE.unlink(missing_ok=True)  # only once the data is gone: the key is what unlocks it
    config.VAULT_APPROLE_FILE.unlink(missing_ok=True)
    log.info("Vault removed: container, data, unseal key and AppRole credentials")