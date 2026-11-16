"""Gitea settings: API address, Vault paths, and the org and repo the pipeline builds from."""

# --- Vault (KV v2 API paths) ---
GITEA_ADMIN_KV = "kv/data/lab/bootstrap/gitea-admin"
GITEA_RUNNER_KV = "kv/data/lab/bootstrap/gitea-runner"

# --- API and GIT URL ---
GITEA_URL = "https://gitea.lab.test"
GITEA_API = f"{GITEA_URL}/api/v1"

# --- Org and repo ---
GITEA_ORG = "lab"
GITEA_REPO = "lab"
GITEA_REPO_URL = f"{GITEA_URL}/{GITEA_ORG}/{GITEA_REPO}.git"
GITEA_WORKFLOW = "deploy.yml"
# Following a run from the terminal (the reviewer may only have SSH, not the Gitea UI)
RUN_POLL_SECONDS = 10
RUN_START_TIMEOUT = 60
RUN_TIMEOUT = 70 * 60
RUN_LOG_LINES = 30
COMMIT_IDENTITY = ["-c", "user.name=lab operator", "-c", "user.email=operator@lab.test"]

