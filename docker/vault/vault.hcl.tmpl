# vault.hcl — Vault's server configuration.
#
# SKELETON. Comments only; every directive below is a TODO in vault-installer.sh
# step 1. Rendered to vault.hcl by render_config, which is why this is a .tmpl:
# one value here is discovered per host and must not be committed, the same
# arrangement docker/coredns/zones/lab.test.zone.tmpl uses.
#
# Read the installer's step 1 for the reasoning. This file is the shape.
#
#   listener "tcp" {
#     address        = ...   TODO 1.3  0.0.0.0 per 0.4-1, or the bridge address
#                            as the one exception 3.4-1 cost 3 defers to here
#     tls_cert_file  = ...   TODO 1.1  bundle.crt — leaf + intermediate, NOT
#                            tls.crt. A bare leaf works in a browser that cached
#                            the intermediate and fails in curl.
#     tls_key_file   = ...             tls.key
#   }
#                            TODO 1.2  no tls_client_ca_file — that is for
#                            verifying certificates clients present (mutual TLS)
#
#   storage "..." { ... }    TODO 1.5  file or raft; say what a backup means
#
#   api_addr = ...           TODO 1.4  https://vault.lab.test:8200. A NAME, and
#                            the address that propagates furthest in the lab
#
#   disable_mlock = ...      TODO 1.6  or cap_add IPC_LOCK in compose instead;
#                            this decides whether secrets can reach swap
#
#   ui = ...                 TODO 1.7
#
# One thing NOT to put here: anything secret. This file is rendered, readable by
# the container, and — unlike the unseal key — has no reason to be protected.
# If a value needs protecting it does not belong in a config file at all, which
# is the argument Vault itself exists to make.
