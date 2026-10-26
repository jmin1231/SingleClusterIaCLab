#!/usr/bin/env bash
#
# bootstrap.sh - single entry point; dispatches the lab commands.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lib.sh
source "${SOURCE_DIR}/lib/lib.sh"

# Fail fast on a broken apt source. The vendored CloudStack installer runs under
# 'set -euo pipefail' and dies silently if 'apt-get update' returns non-zero, so we
# surface the offending source here with a clear message instead. Non-destructive.
apt_preflight() {
    log "Checking apt sources"
    local out
    if out="$(apt-get update 2>&1)"; then
        return 0
    fi
    warn "'apt-get update' failed — a broken apt source will abort the install:"
    printf '%s\n' "${out}" | grep -E '^(E|W):' >&2 || printf '%s\n' "${out}" >&2
    die "fix or remove the apt source above (see /etc/apt/sources.list.d/), then re-run"
}

# Install every host tool the phases need, so the phase scripts never check deps.
# (CloudStack/MySQL/qemu-kvm are installed by the provision script; wg/nft by Ansible.)
install_dependencies() {
    verify_root
    log "Installing host dependencies"
    apt-get update -qq || true
    ensure_apt_pkg jq jq
    ensure_apt_pkg curl curl
    ensure_apt_pkg openssl openssl
    ensure_apt_pkg gpg gnupg
    ensure_apt_pkg ssh-keygen openssh-client
    ensure_apt_pkg ansible-playbook ansible
    ensure_apt_pkg docker docker.io
    if ! docker compose version >/dev/null 2>&1; then
        log "Installing the docker compose plugin"
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
    fi
    ensure_apt_pkg qemu-img qemu-utils
    ensure_apt_pkg qemu-system-x86_64 qemu-system-x86
    ensure_hashicorp_repo
    ensure_apt_pkg terraform terraform
    ensure_apt_pkg packer packer
    "${SOURCE_DIR}/cloudstack/scripts/cloudmonkey-install.sh" # cmk (non-apt binary)
    (cd "${SOURCE_DIR}/ansible" && ansible-galaxy collection install -r requirements.yml)
    apt_preflight
    log "Dependencies installed"
}

# --- phase commands ---

cmd_provision() {
    verify_root
    "${SOURCE_DIR}/cloudstack/cloudstack-install-all.sh"
}

cmd_image() {
    "${SOURCE_DIR}/packer/image-build-all.sh"
}

cmd_setup() {
    verify_root
    "${SOURCE_DIR}/terraform/terraform-apply-all.sh" apply
}

cmd_secgroups() {
    verify_root
    "${SOURCE_DIR}/ansible/securitygroup-all.sh"
}

cmd_verify() {
    verify_root
    "${SOURCE_DIR}/verify/verify-all.sh" verify
}

cmd_demo() {
    verify_root
    "${SOURCE_DIR}/verify/verify-all.sh" demo
}

cmd_down() {
    verify_root
    read -rp "This DESTROYS the lab CloudStack on this host. Type YES to continue: " confirm
    [[ "${confirm}" == "YES" ]] || die "aborted"
    "${SOURCE_DIR}/terraform/terraform-apply-all.sh" destroy || warn "terraform destroy failed; continuing teardown"
    docker compose -f "${SOURCE_DIR}/minio/compose.yml" down -v 2>/dev/null || true
    "${SOURCE_DIR}/cloudstack/cloudstack-uninstall-all.sh"
    restore_netplan
    log "Teardown complete. Rebooting to finish the revert."
    reboot
}

cmd_up() {
    install_dependencies
    cmd_provision
    cmd_image
    cmd_setup
    cmd_secgroups
    cmd_verify
}

usage() {
    cat <<EOF
Usage: ${0} <command>

    up          build the whole lab (deps, CloudStack, image, VPC, security groups)
    demo        human-readable proof the security groups work
    down        tear down and restore the host
EOF
}

main() {
    CMD="${1:-}"
    case "${CMD}" in
        up)   cmd_up ;;
        demo) cmd_demo ;;
        down) cmd_down ;;
        *)    usage; exit 1 ;;
    esac
}

main "$@"
