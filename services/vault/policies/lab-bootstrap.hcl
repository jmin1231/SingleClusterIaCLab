# lab-bootstrap: bootstrap.sh's own identity (AppRole), used by up and update once the
# root token is revoked. Broad by necessity, but every path is named: no "*" alone.
# Later phases add their paths in the step that needs them (Transit, k3s auth).

# Every KV secret: the SSH key, the Gitea admin and the runner token.
path "kv/data/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "kv/metadata/*" {
  capabilities = ["read", "list", "delete"]
}

# mount(): list the mounts, enable kv/ if missing.
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/kv" {
  capabilities = ["create", "read", "update"]
}

# policy(): only these two names, so this identity cannot create a stronger policy.
path "sys/policies/acl/lab-bootstrap" {
  capabilities = ["create", "read", "update"]
}
path "sys/policies/acl/lab-pipeline" {
  capabilities = ["create", "read", "update"]
}

# approle(): create roles, read role_ids, issue secret_ids.
path "sys/auth" {
  capabilities = ["read"]
}
path "auth/approle/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
