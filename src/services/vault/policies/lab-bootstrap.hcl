# lab-bootstrap: bootstrap.sh's own identity (AppRole, 2.5e), used by up/update/teardown
# once the root token is revoked. Broad by necessity, but every path is named: no "*" alone.
# Paths for userpass (3.5c), k3s auth and k3s-creds (8.x) are added in the steps that create them.

# Every lab and app secret: seed (SSH key, console logins, ...), rotate, delete on teardown.
path "kv/data/lab/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "kv/metadata/lab/*" {
  capabilities = ["read", "list", "delete"]
}
path "kv/data/app/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "kv/metadata/app/*" {
  capabilities = ["read", "list", "delete"]
}

# mount(): list the mounts, enable kv/ and transit/ if missing.
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/kv" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/transit" {
  capabilities = ["create", "read", "update"]
}

# Transit: create, configure and delete keys; use them.
path "transit/keys/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "transit/encrypt/*" {
  capabilities = ["update"]
}
path "transit/decrypt/*" {
  capabilities = ["update"]
}
path "transit/rewrap/*" {
  capabilities = ["update"]
}

# The policy loader: only the named policies, so this identity cannot create new ones.
path "sys/policies/acl/lab-bootstrap" {
  capabilities = ["create", "read", "update"]
}
path "sys/policies/acl/lab-pipeline" {
  capabilities = ["create", "read", "update"]
}

# AppRoles (2.5e, 2.10): create roles, read role_ids, issue secret_ids before they expire.
path "sys/auth" {
  capabilities = ["read"]
}
path "auth/approle/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Vault backups.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
