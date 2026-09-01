# vault.hcl — Vault's server configuration.
#
# Committed, not rendered: nothing here varies per host (3.1-2). Mounted :ro as
# part of config/, the directory `command: server` points the entrypoint at.
#
# Two pairs that look like one setting each. `address`/`cluster_address` are
# where Vault BINDS, inside the container's namespace. `api_addr`/`cluster_addr`
# are what it ADVERTISES; raft requires both, and getting them wrong sends
# clients somewhere they cannot reach.
#
# tls_cert_file is bundle.crt — leaf + intermediate. A bare tls.crt works in a
# browser that cached the intermediate and fails in curl on a clean machine.
#
# Nothing secret belongs here. This file is readable by the container and has no
# reason to be protected; a value that needs protecting does not belong in a
# config file at all, which is the argument Vault exists to make.

ui = true

disable_mlock = true

api_addr        = "https://vault.lab.test:8200"
cluster_addr    = "https://vault.lab.test:8201"

storage "raft" {
    path        = "/vault/data"
    node_id     = "vault-1"
}

listener "tcp" {
    address         = "0.0.0.0:8200"
    cluster_address = "0.0.0.0:8201"

    # ---- TLS Configuration -----
    tls_disable     = 0
    tls_cert_file   = "/vault/certs/bundle.crt"
    tls_key_file    = "/vault/certs/tls.key"
}
