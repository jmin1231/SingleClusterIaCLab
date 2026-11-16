"""Run Gitea behind Traefik and set up its admin, org, repo and runner registration token."""

import base64
import json
import logging
import os
import re
import ssl
import subprocess
import sys
import urllib.request, urllib.error
from datetime import datetime

from src.lib.config import BASE_DIR, LAB_ADMIN, LAB_CA_CERT
from src.lib.system import compose
from src.services.podman import podman
from src.services.gitea.config.config import (
    GITEA_API, GITEA_ADMIN_KV, GITEA_RUNNER_KV, GITEA_ORG, GITEA_REPO, GITEA_REPO_URL, GITEA_URL,
    GITEA_WORKFLOW, COMMIT_IDENTITY,
)
from src.services.vault import vault

log = logging.getLogger(__name__)


def gitea_api(creds: dict, method: str, path: str, body: dict | None = None) -> dict:
    """Call Gitea's API as the admin over HTTPS (lab CA); a GET that 404s returns {}."""
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
    """Find or create the private lab/lab repository."""
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


def runner_registration_token(token: str, creds: dict) -> None:
    """Store an instance-wide runner registration token in Vault once."""
    if vault.api("GET", GITEA_RUNNER_KV, token=token):
        log.info("Gitea runner token already exists in vault")
        return

    response = gitea_api(creds, "POST", "admin/actions/runners/registration-token")
    vault.api("POST", GITEA_RUNNER_KV,
              {"data": {"token": response["token"]}}, token=token)
    log.info("Stored the runner registration token in Vault")


def push(creds: dict) -> None:
    """Push the checked-out commit to Gitea's main; once it succeeds, the pipeline builds the same commit platform_up() applied."""
    credentials = base64.b64encode(
        f"{creds['username']}:{creds['password']}".encode()
    ).decode("ascii")

    env = {
        **os.environ,
        "GIT_SSL_CAINFO": str(LAB_CA_CERT),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "http.extraHeader",
        "GIT_CONFIG_VALUE_0": f"Authorization: Basic {credentials}",
    }
    subprocess.run(
        ["git", "-C", str(BASE_DIR),
         "push", GITEA_REPO_URL, "HEAD:refs/heads/main"],
        env=env, check=True,
    )


def git(*args: str) -> str:
    """Run git in the lab checkout (as root, the infrastructure's owner); return stdout, errors reach the terminal."""
    return subprocess.run(
        ["git", "-C", str(BASE_DIR), *args],
        stdout=subprocess.PIPE, text=True, check=True,
    ).stdout.strip()


def commit_changes() -> None:
    """Commit every edit in the checkout (git add -A; .gitignore respected), as Gitea's next change."""
    if not git("status", "--porcelain"):
        log.info("no uncommitted changes")
        return
    git("add", "-A")
    git(*COMMIT_IDENTITY, "commit", "-q", "-m", f"update {datetime.now():%Y-%m-%d %H:%M}")
    log.info("committed local changes as %s", git("rev-parse", "--short", "HEAD"))


def main_differs(creds: dict) -> bool:
    """True if the checked-out commit and Gitea's main differ.

    Usually local is ahead (a push sends it); if it is behind or diverged, the push
    (no --force) is rejected and update stops.
    """
    branch = gitea_api(creds, "GET", f"repos/{GITEA_ORG}/{GITEA_REPO}/branches/main")
    return git("rev-parse", "HEAD") != branch.get("commit", {}).get("id")


def dispatch(creds: dict) -> None:
    """Start one deploy.yml run on main without a push (nothing new, e.g. after a reboot)."""
    gitea_api(creds, "POST",
              f"repos/{GITEA_ORG}/{GITEA_REPO}/actions/workflows/{GITEA_WORKFLOW}/dispatches",
              {"ref": "main"})
    log.info("Started %s; follow it at %s/%s/%s/actions",
             GITEA_WORKFLOW, GITEA_URL, GITEA_ORG, GITEA_REPO)


def initial_push(creds: dict) -> None:
    """Push main into the still-empty lab/lab once (later pushes come from update)."""
    full_name = f"{GITEA_ORG}/{GITEA_REPO}"

    repo = gitea_api(creds, "GET", f"repos/{full_name}")
    if not repo:
        log.error("Gitea repository %s is missing; ensure_repo should have created it", full_name)
        sys.exit(1)
    if not repo["empty"]:
        log.info("Gitea repository %s already has commits; nothing to push", full_name)
        return

    push(creds)
    log.info("Pushed main to %s; the push starts %s at %s/%s/actions",
             full_name, GITEA_WORKFLOW, GITEA_URL, full_name)


def up() -> None:
    """Start Gitea, wait for its healthcheck, then ensure admin, org, repo and runner token; a re-run changes nothing."""
    compose("gitea", "up", "-d", "--wait", "--wait-timeout", "120")
    token = vault.login()
    creds = gitea_admin(token)
    ensure_org(creds)
    ensure_repo(creds)
    runner_registration_token(token, creds)
    log.info("Gitea ready at https://gitea.lab.test")


def down() -> None:
    """Remove the Gitea container and its volumes."""
    if not podman.check():
        log.info("Podman is not set up; no Gitea container to remove")
        return
    compose("gitea", "down", "--volumes")
    log.info("Gitea removed: container and data")
