#!/usr/bin/env bash
#
# securitygroup-all.sh - run the site playbook (tier routes + security groups)
# against the terraform_state inventory. Dependencies are installed by bootstrap.sh.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_DIR}/.." && pwd)"
# shellcheck source=../lib/lib.sh
source "${REPO_ROOT}/lib/lib.sh"

# Build the inventory from the ansible_host/ansible_group resources via the
# terraform_provider plugin (reads the project's state). Written into gitignored
# state/ with an absolute project_path at run time.
write_inventory() {
    cat >"${STATE_DIR}/inventory.yml" <<EOF
plugin: cloud.terraform.terraform_provider
project_path: ${REPO_ROOT}/terraform/tf_files
EOF
}

run_playbook() {
    log "Running the site playbook (tier routes + security groups)"
    ansible-playbook site.yml
}

main() {
    cd "${SOURCE_DIR}"
    write_inventory
    run_playbook
}

main "$@"
