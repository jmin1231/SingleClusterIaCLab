# lab-pipeline: the CI runner's jobs (AppRole, 2.10). Anything not listed is denied,
# including kv/lab/bootstrap/* and sys/policies/*, so a job cannot widen its own access.
# Paths for k3s auth and k3s-creds, and the verify job's transit/keys/verify-* keys,
# are added in the steps that create them.

# Pipeline credentials: SSH key, API keys, TLS keys; jobs also write some (WireGuard public keys).
path "kv/data/lab/pipeline/*" {
  capabilities = ["create", "read", "update"]
}

# Application secrets the pipeline deploys.
path "kv/data/app/*" {
  capabilities = ["create", "read", "update"]
}

# Break-glass kubeconfig: deposit only, never read it back.
path "kv/data/lab/breakglass/k3s-admin" {
  capabilities = ["create", "update"]
}

# The app's Transit key: create it, then encrypt, decrypt and rewrap with it (operations are POSTs).
path "transit/keys/customers" {
  capabilities = ["create", "read", "update"]
}
path "transit/encrypt/customers" {
  capabilities = ["update"]
}
path "transit/decrypt/customers" {
  capabilities = ["update"]
}
path "transit/rewrap/customers" {
  capabilities = ["update"]
}

# Vault backups.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
