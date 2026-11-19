# lab-pipeline: the CI runner's jobs (AppRole). Anything not listed is denied, including
# sys/* and auth/*, so a job cannot widen its own access. Later phases add their paths
# in the step that needs them (app secrets, break-glass kubeconfig, Transit).

# Pipeline credentials: the SSH key now; jobs also write some later (WireGuard public keys).
path "kv/data/lab/pipeline/*" {
  capabilities = ["create", "read", "update"]
}
