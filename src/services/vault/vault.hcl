# Hashicorp Vault - Infrastructure

ui              = true
disable_mlock   = true

storage "raft" {
    path    = "/vault/file"
    node_id = "vault-1"
}

listener "tcp" {
    address         = "0.0.0.0:8200"
    tls_cert_file   = "/vault/tls/vault.pem"
    tls_key_file    = "/vault/tls/vault-key.pem"
}

api_addr        = "https://vault.lab.test:8200"
cluster_addr    = "https://127.0.0.1:8201"
