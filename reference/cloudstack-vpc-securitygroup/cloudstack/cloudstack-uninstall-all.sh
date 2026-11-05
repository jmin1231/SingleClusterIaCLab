#!/usr/bin/env bash
#
# cloudstack-uninstall-all.sh - remove CloudStack and the host tweaks the install made.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_DIR}/.." && pwd)"
# shellcheck source=../lib/lib.sh
source "${REPO_ROOT}/lib/lib.sh"

# Stop and disable the CloudStack services.
stop_services() {
    log "Stopping CloudStack services"
    local svc
    for svc in cloudstack-usage cloudstack-management cloudstack-agent; do
        systemctl disable --now "${svc}" 2>/dev/null || true
    done
}

# Destroy and undefine every libvirt domain (system VMs + guests) and its disks.
destroy_vms() {
    log "Destroying libvirt VMs"
    local vm
    for vm in $(virsh list --all --name 2>/dev/null | grep -v '^$'); do
        virsh destroy "${vm}" 2>/dev/null || true
        virsh undefine "${vm}" --nvram --remove-all-storage 2>/dev/null || true
    done
}

# Drop the CloudStack databases and user.
drop_databases() {
    log "Dropping CloudStack databases"
    mysql -e "DROP DATABASE IF EXISTS cloud;
              DROP DATABASE IF EXISTS cloud_usage;
              DROP USER IF EXISTS 'cloud'@'%', 'cloud'@'localhost';
              FLUSH PRIVILEGES;" 2>/dev/null || true
}

# Purge the CloudStack packages.
purge_packages() {
    log "Purging CloudStack packages"
    apt-get purge -y 'cloudstack-*' 2>/dev/null || true
    apt-get autoremove --purge -y 2>/dev/null || true
}

# Remove the NFS primary/secondary storage exports.
teardown_nfs() {
    log "Removing NFS storage"
    if [[ -f /etc/exports ]]; then
        sed -i '\#^/export #d' /etc/exports
        exportfs -ra 2>/dev/null || true
    fi
    rm -rf /export/primary /export/secondary
}

# Remove config, logs, drop-ins, repo, cmk, and the lab's state secrets.
remove_files() {
    log "Removing config, drop-ins, repo, cmk, and state secrets"
    rm -rf /etc/cloudstack /var/log/cloudstack /var/lib/cloudstack

    if [[ -e /etc/ssh/sshd_config.d/01-cloudstack.conf ]]; then
        rm -f /etc/ssh/sshd_config.d/01-cloudstack.conf
        systemctl restart ssh 2>/dev/null || true
    fi

    rm -f /etc/sysctl.d/99-disable-bridge-netfilter.conf
    rm -f /etc/apt/sources.list.d/cloudstack.list
    rm -f /usr/local/bin/cmk
    rm -rf "${HOME}/.cmk"

    # the vendored installer's own tracker + its agent-wait drop-in, so a later
    # 'up' redeploys the schema cleanly instead of skipping on a stale marker
    rm -f /etc/systemd/system/cloudstack-agent.service.d/10-wait-for-management.conf
    rm -f /usr/local/sbin/cloudstack-agent-wait-mgmt.sh
    systemctl daemon-reload 2>/dev/null || true

    rm -f "${STATE_DIR}/root_password" \
          "${STATE_DIR}/cloudstack_admin_password" \
          "${STATE_DIR}/image_password" \
          "${STATE_DIR}/lab_ssh_key" \
          "${STATE_DIR}/lab_ssh_key.pub" \
          "${STATE_DIR}/tracker.conf" \
          "${STATE_DIR}/cloudstack-installer-tracker.conf"

    rm -rf "${REPO_ROOT}/terraform/tf_files/.terraform" \
           "${REPO_ROOT}/terraform/tf_files/terraform.tfstate" \
           "${REPO_ROOT}/terraform/tf_files/terraform.tfstate.backup"
}

main() {
    verify_root
    stop_services
    destroy_vms
    drop_databases
    purge_packages
    teardown_nfs
    remove_files
    log "CloudStack removed"
}

main "$@"
