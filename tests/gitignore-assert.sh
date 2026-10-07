#!/usr/bin/env bash
#
# tests/gitignore-assert.sh
#   Asserts the .gitignore rules that matter, in both directions.
#
#   This exists because a rule that matches nothing looks exactly like no rule.
#   Reading .gitignore and believing it is not a check; `git check-ignore`
#   answers for a path whether or not that path exists, which is the only way
#   to assert on a key BEFORE the run that would write it.
#
#   Both directions are checked, and the second is the one people forget:
#
#     MUST_IGNORE    a secret or a machine-local file. A miss here means a
#                    credential is one `git add -A` from being published.
#     MUST_COMMIT    committed config. A miss here means the lab silently
#                    stops being portable - a provider lock file or a template
#                    that never reaches the clone, discovered by someone else
#                    on a fresh machine.
#
#   Wired into `make lint` at Phase 7.2. Runs standalone until then.
#
#   Usage: tests/gitignore-assert.sh

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Paths that must be ignored. None of these need exist; that is the point.
MUST_IGNORE=(
    # Vault's two tier-1 credentials, in separate files.
    docker/vault/vault-init.json
    docker/vault/unseal-key
    docker/vault/root-token

    # TLS private keys and the certificates beside them.
    docker/vault/certs/tls.key
    docker/vault/certs/bundle.crt
    docker/minio/certs/private.key
    docker/minio/certs/public.crt
    docker/proxy/certs/proxy.lab.test.key

    # Vault AppRole - both halves are credentials.
    state/approle-role-id
    state/approle-secret-id

    # Rendered env files. Every one holds a generated password.
    docker/gitea/.env
    docker/vault/.env
    docker/minio/.env

    # Single-use runner registration, exchanged for this file.
    docker/gitea/runner/.runner

    # SSH and WireGuard private keys. A .wgkey here means the "generated on
    # the VM, never moved" rule in the wireguard role was broken.
    state/lab_ed25519
    ansible/roles/wireguard/files/hub.wgkey

    # Terraform state holds every attribute of every resource, credentials
    # included, and .tfvars is how run-time-only credentials reach disk.
    terraform/terraform.tfstate
    terraform/terraform.tfstate.backup
    terraform/secrets.auto.tfvars
    terraform/.terraform/providers/lock
    terraform/tfplan
    terraform/plan.json

    # Machine-local state: holds addresses discovered on this host.
    state/bootstrap.log
    state/tracker.conf
    ansible/inventory/generated.yml
    docker/coredns/zones/lab.test.zone
    docker/proxy/conf/default.conf

    # Container runtime state and vendored-installer droppings.
    docker/vault/data/vault.db
    docker/vault/logs/audit.log
    docker/gitea/data/gitea.db
    cloudstack/cloudstack-installer-tracker.conf
    cloudstack/installer.log

    # Build output. A qcow2 is gigabytes and is rebuilt from the template.
    packer/output-ubuntu-2404/ubuntu.qcow2

    # The catch-all bucket.
    secrets/cloudstack-api-key
)

# Paths that must NOT be ignored. These are committed config: clone the repo
# elsewhere and it must stand up the same.
MUST_COMMIT=(
    # Pins provider versions. Ignoring it makes `init` irreproducible, and the
    # failure appears on someone else's machine, weeks later.
    terraform/.terraform.lock.hcl

    # Templates are the source of truth; only their rendered output is ignored.
    docker/coredns/zones/lab.test.zone.tmpl
    docker/proxy/conf/default.conf.tmpl
    terraform/secrets.auto.tfvars.example

    # Code and compose specs.
    bootstrap.sh
    lib/lib.sh
    docker/vault/docker-compose.yml
    docker/vault/config/vault.hcl
    terraform/main.tf
    ansible/site.yml
    policy/egress.rego
    .gitea/workflows/ci.yml
)

fail=0

for path in "${MUST_IGNORE[@]}"; do
    if ! git check-ignore -q -- "${path}"; then
        printf '\033[1;31m[x]\033[0m NOT ignored, but must be: %s\n' "${path}" >&2
        fail=1
    fi
done

for path in "${MUST_COMMIT[@]}"; do
    if git check-ignore -q -- "${path}"; then
        printf '\033[1;31m[x]\033[0m ignored, but must be committable: %s\n' "${path}" >&2
        printf '      a .gitignore rule is too broad - find it with: git check-ignore -v -- %s\n' "${path}" >&2
        fail=1
    fi
done

if ((fail)); then
    printf '\033[1;31m[x]\033[0m .gitignore assertions failed\n' >&2
    exit 1
fi

printf '\033[1;32m[+]\033[0m .gitignore: %d paths ignored, %d committable, as intended\n' \
    "${#MUST_IGNORE[@]}" "${#MUST_COMMIT[@]}"
