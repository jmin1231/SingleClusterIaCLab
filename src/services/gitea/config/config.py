"""Gitea settings: API address, Vault paths, and the org and repo the pipeline builds from."""

# --- API ---
GITEA_API = "https://gitea.lab.test/api/v1"

# --- Vault (KV v2 API paths) ---
GITEA_ADMIN_KV = "kv/data/lab/bootstrap/gitea-admin"
GITEA_RUNNER_KV = "kv/data/lab/bootstrap/gitea-runner"

# --- Org and repo ---
GITEA_ORG = "lab"
GITEA_REPO = "lab"
