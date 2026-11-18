"""Run Gitea behind Traefik, set up its admin, org, repo, runner token and Actions secrets, and push and follow pipeline runs."""

import base64
import json
import logging
import os
import pwd
import re
import ssl
import subprocess
import sys
import time
import urllib.request, urllib.error
from datetime import datetime

from src.lib import config as lab_config
from src.lib.system import compose
from src.services.gitea.config import config
from src.services.podman import podman
from src.services.vault import vault

log = logging.getLogger(__name__)


def gitea_api(creds: dict, method: str, path: str, body: dict | None = None, raw: bool = False) -> dict | str:
    """Call Gitea's API as the admin over HTTPS (lab CA); a GET that 404s returns {}; raw=True returns the text."""
    credentials = base64.b64encode(
        f"{creds['username']}:{creds['password']}".encode()
    ).decode("ascii")

    request = urllib.request.Request(
        f"{config.GITEA_API}/{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
                "Authorization":f"Basic {credentials}", 
                "Content-Type": "application/json"
        }
    )
    ctx = ssl.create_default_context(cafile=lab_config.LAB_CA_CERT)
    try:
        with urllib.request.urlopen(request, context=ctx, timeout=10) as resp:
            data = resp.read()
    except urllib.error.HTTPError as err:
        if method == "GET" and err.code == 404:
            return {}
        raise
    if raw:
        return data.decode(errors="replace")
    return json.loads(data) if data else {}


def gitea_admin(token: str) -> dict:
    """Create Gitea's admin once, store its password in Vault, and return the credentials."""
    saved = vault.vault_api("GET", config.GITEA_ADMIN_KV, token=token)
    if saved:
        log.info("Gitea admin %s already exists", lab_config.LAB_ADMIN)
        return saved["data"]["data"]

    result = subprocess.run(
        ["podman", "exec", "gitea", "gitea", "admin", "user", "create",
         "--admin", "--username", lab_config.LAB_ADMIN, "--email", f"{lab_config.LAB_ADMIN}@lab.test",
         "--random-password", "--must-change-password=false"],
        capture_output=True, text=True, check=True,
    )
    password = re.search(r"generated random password is '(.+)'", result.stdout)
    if not password:
        log.error("Could not find the generated password in Gitea's output; user %s may now "
                  "exist without a stored password (delete it with 'gitea admin user delete')",
                  lab_config.LAB_ADMIN)
        sys.exit(1)

    creds = {"username": lab_config.LAB_ADMIN, "password": password.group(1)}
    vault.vault_api("POST", config.GITEA_ADMIN_KV, {"data": creds}, token=token)
    log.info("Created Gitea admin %s; password stored in Vault", lab_config.LAB_ADMIN)
    return creds


def ensure_org(creds: dict) -> None:
    """Find or create the public lab organization."""
    org = gitea_api(creds, "GET", f"orgs/{config.GITEA_ORG}")
    if org:
        log.info("Gitea organization %s already exists", config.GITEA_ORG)
        return

    gitea_api(creds, "POST", "orgs", {"username": config.GITEA_ORG, "visibility": "public"})
    log.info("Created public Gitea organization %s", config.GITEA_ORG)


def ensure_repo(creds: dict) -> None:
    """Find or create the private lab/lab repository."""
    full_name = f"{config.GITEA_ORG}/{config.GITEA_REPO}"
    repo = gitea_api(creds, "GET", f"repos/{full_name}")
    if repo:
        log.info("Gitea repository %s already exists", full_name)
        return

    gitea_api(creds, "POST", f"orgs/{config.GITEA_ORG}/repos", {
        "name": config.GITEA_REPO,
        "private": True,
        "auto_init": False,
        "default_branch": "main",
    })
    log.info("Created private Gitea repository %s", full_name)


def runner_registration_token(token: str, creds: dict) -> None:
    """Store an instance-wide runner registration token in Vault once."""
    if vault.vault_api("GET", config.GITEA_RUNNER_KV, token=token):
        log.info("Gitea runner token already exists in vault")
        return

    response = gitea_api(creds, "POST", "admin/actions/runners/registration-token")
    vault.vault_api("POST", config.GITEA_RUNNER_KV,
              {"data": {"token": response["token"]}}, token=token)
    log.info("Stored the runner registration token in Vault")


def pipeline_secrets(token: str, creds: dict) -> None:
    """Store lab-pipeline's AppRole Login as gitea secrets"""
    url = f"repos/{config.GITEA_ORG}/{config.GITEA_REPO}/actions/secrets"

    results = []
    for secret in gitea_api(creds, "GET", url):
        results.append(secret["name"])

    if "VAULT_ROLE_ID" in results and "VAULT_SECRET_ID" in results:
        log.info("Gitea Actions secrets for vault already set")
        return

    result = vault.approle_credentials(token, "lab-pipeline")
    gitea_api(creds, "PUT", f"{url}/VAULT_ROLE_ID", {"data": result["role_id"]})
    gitea_api(creds, "PUT", f"{url}/VAULT_SECRET_ID", {"data": result["secret_id"]})

    log.info("Gitea Action Secrets stored")


def flux_token(token: str, creds: dict) -> None:
    """Store a read-only Gitea token for Flux in Vault once."""
    if vault.vault_api("GET", config.GITEA_FLUX_KV, token=token):
        log.info("Flux's Gitea token already exists in Vault")
        return

    response = gitea_api(creds, "POST", f"users/{lab_config.LAB_ADMIN}/tokens",
                         {"name": "flux", "scopes": ["read:repository"]})
    vault.vault_api("POST", config.GITEA_FLUX_KV,
                    {"data": {"username": lab_config.LAB_ADMIN, "token": response["sha1"]}},
                    token=token)
    log.info("Stored Flux's read-only Gitea token in Vault")


def push(creds: dict) -> str:
    """Push the checked-out commit to Gitea's main and return it; the pipeline then builds the commit platform_up() applied."""
    credentials = base64.b64encode(
        f"{creds['username']}:{creds['password']}".encode()
    ).decode("ascii")

    env = {
        **os.environ,
        "GIT_SSL_CAINFO": str(lab_config.LAB_CA_CERT),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "http.extraHeader",
        "GIT_CONFIG_VALUE_0": f"Authorization: Basic {credentials}",
    }
    subprocess.run(
        ["git", "-C", str(lab_config.BASE_DIR),
         "push", config.GITEA_REPO_URL, "HEAD:refs/heads/main"],
        env=env, check=True,
    )
    sha = git("rev-parse", "HEAD")
    log.info("pushed %s to Gitea's main; the push starts %s", sha[:7], config.GITEA_WORKFLOW)
    return sha


def git(*args: str) -> str:
    """Run git in the lab checkout as the user who ran sudo, so .git stays theirs; return stdout, errors reach the terminal.

    bootstrap.sh refuses to start without SUDO_UID. HOME is theirs too: sudo sets it to /root, which they cannot read.
    """
    uid, gid = int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"])
    return subprocess.run(
        ["git", "-C", str(lab_config.BASE_DIR), *args],
        stdout=subprocess.PIPE, text=True, check=True,
        user=uid, group=gid, env={**os.environ, "HOME": pwd.getpwuid(uid).pw_dir},
    ).stdout.strip()


def commit_changes() -> None:
    """Commit every edit in the checkout (git add -A; .gitignore respected), as Gitea's next change."""
    if not git("status", "--porcelain"):
        log.info("no uncommitted changes")
        return
    git("add", "-A")
    git(*config.COMMIT_IDENTITY, "commit", "-q", "-m", f"update {datetime.now():%Y-%m-%d %H:%M}")
    log.info("committed local changes as %s", git("rev-parse", "--short", "HEAD"))


def main_differs(creds: dict) -> bool:
    """True if the checked-out commit and Gitea's main differ.

    Usually local is ahead (a push sends it); if it is behind or diverged, the push
    (no --force) is rejected and update stops.
    """
    branch = gitea_api(creds, "GET", f"repos/{config.GITEA_ORG}/{config.GITEA_REPO}/branches/main")
    return git("rev-parse", "HEAD") != branch.get("commit", {}).get("id")


def dispatch(creds: dict) -> int:
    """Start one deploy.yml run on main without a push (nothing new, e.g. after a reboot); returns its id."""
    details = gitea_api(
        creds, "POST",
        f"repos/{config.GITEA_ORG}/{config.GITEA_REPO}/actions/workflows/{config.GITEA_WORKFLOW}/dispatches?return_run_details=true",
        {"ref": "main"},
    )
    log.info("nothing new to push; started %s on main", config.GITEA_WORKFLOW)
    return details["workflow_run_id"]


def wait_for_run(creds: dict, sha: str) -> int:
    """The id of the run the push of sha to main started; exit 1 if none starts in time.

    Only deploy.yml triggers on push, and main never held sha before this push,
    so the run with this commit and event is ours, whatever else runs meanwhile.
    """
    query = f"head_sha={sha}&event=push&branch=main&limit=1"
    deadline = time.monotonic() + config.RUN_START_TIMEOUT
    while True:
        runs = gitea_api(creds, "GET", f"repos/{config.GITEA_ORG}/{config.GITEA_REPO}/actions/runs?{query}")
        if runs.get("workflow_runs"):
            return runs["workflow_runs"][0]["id"]
        if time.monotonic() > deadline:
            log.error("no run started for %s; does deploy.yml trigger on push to main?", sha[:7])
            sys.exit(1)
        time.sleep(config.RUN_POLL_SECONDS)


def follow_run(creds: dict, run_id: int) -> None:
    """Wait for the run to finish and print each job's result; for a failure, the end of its log, then exit 1."""
    url = f"repos/{config.GITEA_ORG}/{config.GITEA_REPO}/actions/runs/{run_id}"
    run = gitea_api(creds, "GET", url)
    log.info("run #%s started; waiting for it to finish: %s", run["run_number"], run["html_url"])
    deadline = time.monotonic() + config.RUN_TIMEOUT
    while run["status"] != "completed":
        if time.monotonic() > deadline:
            log.error("run #%s timed out; is lab-runner running?", run["run_number"])
            sys.exit(1)
        time.sleep(config.RUN_POLL_SECONDS)
        run = gitea_api(creds, "GET", url)

    for job in gitea_api(creds, "GET", f"{url}/jobs").get("jobs", []):
        log.info("  %s: %s", job["name"], job["conclusion"])
        if job["conclusion"] == "failure":
            try:
                text = gitea_api(creds, "GET", f"repos/{config.GITEA_ORG}/{config.GITEA_REPO}/actions/jobs/{job['id']}/logs", raw=True)
            except OSError:
                text = None
            lines = text.splitlines()[-config.RUN_LOG_LINES:] if isinstance(text, str) else ["(log not available)"]
            for line in lines:
                print(f"    {line}", file=sys.stderr)

    if run["conclusion"] != "success":
        log.error("run #%s failed", run["run_number"])
        sys.exit(1)
    log.info("run #%s succeeded", run["run_number"])


def start_run(creds: dict) -> int:
    """Push the checked-out commit if Gitea's main differs (an empty repo has no main), else dispatch; returns the run id."""
    if main_differs(creds):
        return wait_for_run(creds, push(creds))
    return dispatch(creds)


def up() -> None:
    """Start Gitea, wait for its healthcheck, then ensure admin, org, repo, runner token, pipeline secrets and Flux token; a re-run changes nothing."""
    compose("gitea", "up", "-d", "--wait", "--wait-timeout", "120")
    token = vault.login()
    creds = gitea_admin(token)
    ensure_org(creds)
    ensure_repo(creds)
    runner_registration_token(token, creds)
    pipeline_secrets(token, creds)
    flux_token(token, creds)
    log.info("Gitea ready at https://gitea.lab.test")


def down() -> None:
    """Remove the Gitea container and its volumes."""
    if not podman.check():
        log.info("Podman is not set up; no Gitea container to remove")
        return
    compose("gitea", "down", "--volumes")
    log.info("Gitea removed: container and data")
