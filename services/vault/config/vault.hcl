ui = true

disable_mlock = true

api_addr        = "https://vault.lab.test:8200"
cluster_addr    = "https://vault.lab.test:8201"

storage "raft" {
    path    = "/vault/data"
    node_id = "vault-1"
}

listener "tcp" {
    address         = "0.0.0.0:8200"
    cluster_address = "0.0.0.0:8201"

    # TLS Configuration
    tls_disable     = 0
    tls_cert_file   = "/vault/certs/bundle.crt"
    tls_key_file    = "/vault/certs/tls.key"
}