#!/usr/bin/env bash
#
# terraform-apply-all.sh - apply (or destroy) the VPC/VM Terraform and, on apply,
# render the Ansible inventory. Credentials and the lab SSH key come from state/.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_DIR}/.." && pwd)"
# shellcheck source=../lib/lib.sh
source "${REPO_ROOT}/lib/lib.sh"
# shellcheck source=../cloudstack/scripts/cloudmonkey-install.sh
source "${REPO_ROOT}/cloudstack/scripts/cloudmonkey-install.sh"

TF_DIR="${SOURCE_DIR}/tf_files"
SSH_KEY_FILE="${STATE_DIR}/lab_ssh_key"

# Generate the lab SSH key once (gitignored, 0600) and read its public half.
resolve_ssh_key() {
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
        mkdir -p "${STATE_DIR}"
        ssh-keygen -t ed25519 -N '' -C 'iac-lab' -f "${SSH_KEY_FILE}" >/dev/null
        log "Generated lab SSH key -> ${SSH_KEY_FILE}"
    fi
    SSH_PUBLIC_KEY="$(cat "${SSH_KEY_FILE}.pub")"
}

# Always address the mgmt shared network from cloudbr0 (the host uplink bridge).
detect_mgmt_network() {
    local net3 gw
    net3="$(bridge_ip)"
    net3="${net3%.*}"
    gw="$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    [[ -n "${gw}" ]] || gw="${net3}.1"

    export TF_VAR_mgmt_cidr="${net3}.0/24"
    export TF_VAR_mgmt_gateway="${gw}"
    export TF_VAR_mgmt_startip="${net3}.200"
    export TF_VAR_mgmt_endip="${net3}.220"
    log "mgmt network: ${TF_VAR_mgmt_cidr} gw ${gw} range ${net3}.200-${net3}.220"
}

# Mint/read the API keys and hand the provider its inputs via TF_VAR_*.
export_tf_vars() {
    ensure_cloudstack_api_keys
    export TF_VAR_cloudstack_api_url="${CLOUDSTACK_URL}"
    export TF_VAR_cloudstack_api_key="${CLOUDSTACK_API_KEY}"
    export TF_VAR_cloudstack_secret_key="${CLOUDSTACK_SECRET_KEY}"
    export TF_VAR_ssh_public_key="${SSH_PUBLIC_KEY}"
}

MGMT_OFFERING="iac-mgmt-offering"

# Ensure a shared-network offering that serves UserData via ConfigDrive (so the
# ConfigDrive-pinned image gets its SSH key on the default NIC). Enabled, idempotent.
ensure_mgmt_offering() {
    MGMT_OFFERING_ID="$(cmk -o json list networkofferings name="${MGMT_OFFERING}" \
        | jq -r '.networkoffering[]? | select(.name=="'"${MGMT_OFFERING}"'") | .id' | head -n1)"
    if [[ -z "${MGMT_OFFERING_ID}" || "${MGMT_OFFERING_ID}" == "null" ]]; then
        log "Creating shared network offering ${MGMT_OFFERING} (UserData via ConfigDrive)"
        cmk create networkoffering \
            name="${MGMT_OFFERING}" displaytext="${MGMT_OFFERING}" \
            guestiptype=Shared traffictype=GUEST specifyvlan=true specifyipranges=true \
            supportedservices=Dhcp,Dns,UserData \
            'serviceproviderlist[0].service=Dhcp' 'serviceproviderlist[0].provider=VirtualRouter' \
            'serviceproviderlist[1].service=Dns' 'serviceproviderlist[1].provider=VirtualRouter' \
            'serviceproviderlist[2].service=UserData' 'serviceproviderlist[2].provider=ConfigDrive' >/dev/null
        MGMT_OFFERING_ID="$(cmk -o json list networkofferings name="${MGMT_OFFERING}" | jq -r '.networkoffering[0].id // empty')"
    fi
    [[ -n "${MGMT_OFFERING_ID}" && "${MGMT_OFFERING_ID}" != "null" ]] || die "failed to ensure ${MGMT_OFFERING}"
    cmk update networkoffering id="${MGMT_OFFERING_ID}" state=Enabled >/dev/null 2>&1 || true
}

# Create the untagged mgmt shared network via cmk (the provider's vlan field is numeric
# and can't express "untagged"), idempotently, and hand its id to Terraform.
create_mgmt_network() {
    ensure_mgmt_offering
    local zone="${CLOUDSTACK_ZONE:-Zone1}" existing zone_id net
    existing="$(cmk -o json list networks 2>/dev/null \
        | jq -r '.network[]? | select(.name=="iac-mgmt") | .id' | head -n1)"
    if [[ -n "${existing}" && "${existing}" != "null" ]]; then
        export TF_VAR_mgmt_network_id="${existing}"
        log "mgmt shared network exists (${existing})"
        return 0
    fi
    zone_id="$(cmk -o json list zones name="${zone}" | jq -r '.zone[0].id // empty')"
    [[ -n "${zone_id}" ]] || die "zone ${zone} not found"
    log "Creating untagged mgmt shared network iac-mgmt"
    net="$(cmk -o json create network name=iac-mgmt displaytext=iac-mgmt \
        networkofferingid="${MGMT_OFFERING_ID}" zoneid="${zone_id}" \
        gateway="${TF_VAR_mgmt_gateway}" netmask=255.255.255.0 \
        startip="${TF_VAR_mgmt_startip}" endip="${TF_VAR_mgmt_endip}" \
        vlan=untagged acltype=Domain)"
    TF_VAR_mgmt_network_id="$(jq -r '.network.id // empty' <<<"${net}")"
    [[ -n "${TF_VAR_mgmt_network_id}" ]] || die "failed to create mgmt shared network"
    export TF_VAR_mgmt_network_id
    log "Created mgmt shared network (${TF_VAR_mgmt_network_id})"
}

tf_init() {
    terraform -chdir="${TF_DIR}" init -input=false
}

tf_apply() {
    terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -parallelism=1
}

tf_destroy() {
    terraform -chdir="${TF_DIR}" destroy -input=false -auto-approve -parallelism=1
}

run_action() {
    case "$1" in
        apply)
            tf_apply
            ;;
        destroy)
            tf_destroy
            ;;
        *)
            die "usage: $(basename "$0") [apply|destroy]"
            ;;
    esac
}

main() {
    local action="${1:-apply}"
    resolve_ssh_key
    detect_mgmt_network
    export_tf_vars
    create_mgmt_network
    tf_init
    run_action "${action}"
}

main "$@"
