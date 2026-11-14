"""Install gitea and gitea runner"""

import base64
import json
import logging
import re
import ssl
import subprocess
import sys
import urllib.request, urllib.error

from src.lib.config import LAB_ADMIN, LAB_CA_CERT
from src.lib.system import compose
from src.services.podman import podman
from src.services.vault import vault

GITEA_API = "https://gitea.lab.test/api/v1"
GITEA_ADMIN_KV = "kv/data/lab/bootstrap/gitea-admin"
GITEA_ORG = "lab"
GITEA_REPO = "lab"


log = logging.getLogger(__name__)


def gitea_api(creds: dict, method: str, path: str, body: dict | None = None) -> dict:
    """Authenticate to Gitea and return the current user's details."""
    credentials = base64.b64encode(
        f"{creds['username']}:{creds['password']}".encode()
    ).decode("ascii")

    request = urllib.request.Request(
        f"{GITEA_API}/{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
                "Authorization":f"Basic {credentials}", 
                "Content-Type": "application/json"
        }
    )
    ctx = ssl.create_default_context(cafile=LAB_CA_CERT)
    try:
        with urllib.request.urlopen(request, context=ctx, timeout=10) as resp:
            data = resp.read()
    except urllib.error.HTTPError as err:
        if method == "GET" and err.code == 404:
            return {}
        raise
    return json.loads(data) if data else {}


def gitea_admin(token: str) -> dict:
    """Create Gitea's admin once, store its password in Vault, and return the credentials."""
    saved = vault.api("GET", GITEA_ADMIN_KV, token=token)
    if saved:
        log.info("Gitea admin %s already exists", LAB_ADMIN)
        return saved["data"]["data"]

    result = subprocess.run(
        ["podman", "exec", "gitea", "gitea", "admin", "user", "create",
         "--admin", "--username", LAB_ADMIN, "--email", f"{LAB_ADMIN}@lab.test",
         "--random-password", "--must-change-password=false"],
        capture_output=True, text=True, check=True,
    )
    password = re.search(r"generated random password is '(.+)'", result.stdout)
    if not password:
        log.error("Could not find the generated password in Gitea's output; user %s may now "
                  "exist without a stored password (delete it with 'gitea admin user delete')",
                  LAB_ADMIN)
        sys.exit(1)

    creds = {"username": LAB_ADMIN, "password": password.group(1)}
    vault.api("POST", GITEA_ADMIN_KV, {"data": creds}, token=token)
    log.info("Created Gitea admin %s; password stored in Vault", LAB_ADMIN)
    return creds


def ensure_org(creds: dict) -> None:
    """Find or create the public lab organization."""
    org = gitea_api(creds, "GET", f"orgs/{GITEA_ORG}")
    if org:
        log.info("Gitea organization %s already exists", GITEA_ORG)
        return

    gitea_api(creds, "POST", "orgs", {"username": GITEA_ORG, "visibility": "public"})
    log.info("Created public Gitea organization %s", GITEA_ORG)


def ensure_repo(creds: dict) -> None:
    """Ensure the repo exists, creating it if it doesn't exist"""
    full_name = f"{GITEA_ORG}/{GITEA_REPO}"
    repo = gitea_api(creds, "GET", f"repos/{full_name}")
    if repo:
        log.info("Gitea repository %s already exists", full_name)
        return

    gitea_api(creds, "POST", f"orgs/{GITEA_ORG}/repos", {
        "name": GITEA_REPO,
        "private": True,
        "auto_init": False,
        "default_branch": "main",
    })
    log.info("Created private Gitea repository %s", full_name)


def up() -> None:
    """start Gitea and wait until its healthcheck passes"""
    compose("gitea", "up", "-d", "--wait", "--wait-timeout", "120")
    creds = gitea_admin(vault.login())
    ensure_org(creds)
    ensure_repo(creds)
    log.info("Gitea ready at https://gitea.lab.test")


def down() -> None:
    """REmove the Gitea container and its volumes."""
    if not podman.check():
        log.info("Podman is not setup; no Gitea container to remove")
        return
    compose("gitea", "down", "--volumes")
    log.info("Gitea removed; container and data")
