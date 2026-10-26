#!/usr/bin/env bash
#
# image-build-all.sh
#
# builds the golden image, publishs it to MinIO, and
# registarts it as a CloudStack template

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SOURCE_DIR}/.." && pwd)"
# shellcheck source=../lib/lib.sh
source "${REPO_ROOT}/lib/lib.sh"
# shellcheck source=../cloudstack/scripts/cloudmonkey-install.sh
source "${REPO_ROOT}/cloudstack/scripts/cloudmonkey-install.sh"

MINIO_COMPOSE="${REPO_ROOT}/minio/compose.yml"
MINIO_NET="minio_default"
MC_IMAGE="cgr.dev/chainguard/minio-client:latest-dev"
QCOW2_DIR="${REPO_ROOT}/builds/ubuntu-24.04-qemu"
QCOW2_NAME="ubuntu-24.04.qcow2"
IMAGE_OBJECT="images/${QCOW2_NAME}"
TEMPLATE_NAME="ubuntu-24.04"
IMAGE_PASS_FILE="${STATE_DIR}/image_password"

export MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
export MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"

# Generate + persist the image password (override with PKR_VAR_image_password)
resolve_image_password() {
    if [[ -f "${IMAGE_PASS_FILE}" ]]; then
        IMAGE_PASSWORD="$(cat "${IMAGE_PASS_FILE}")"
    else
        mkdir -p "${STATE_DIR}"
        IMAGE_PASSWORD="$(openssl rand -hex 16)"
        (umask 077; printf '%s' "${IMAGE_PASSWORD}" > "${IMAGE_PASS_FILE}")
    fi
}

# Start MinIO bound to the bridge
start_minio() {
    log "Starting minio"
    MINIO_BIND_IP="$(bridge_ip)" docker compose -f "${MINIO_COMPOSE}" up -d
}

# A throwaway mc on the minio network; pass it the mc args. The minio-client image's
# entrypoint is 'mc', so override it to a shell to run the alias-set + command chain.
mc_run() {
    docker run --rm --network "${MINIO_NET}" \
        -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD \
        ${MC_MOUNT:+-v "${MC_MOUNT}"} \
        --entrypoint sh \
        "${MC_IMAGE}" -c "mc alias set local http://minio:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD >/dev/null 2>&1 && $*"
}

# Is the image already in MinIO? (source of truth for skip-on-rerun)
image_published() { 
    mc_run "mc stat local/${IMAGE_OBJECT}" >/dev/null 2>&1; 
}

build_and_publish() {
    if image_published; then
        log "Image already in MinIO; skipping build + upload"
        return 0
    fi
    if [[ -f "${QCOW2_DIR}/${QCOW2_NAME}" ]]; then
        log "qcow2 already built locally; skipping Packer build"
    else
        log "Building the golden image with Packer (this is the slow step)"
        packer init "${SOURCE_DIR}/hcl"
        PKR_VAR_image_password="${IMAGE_PASSWORD}" packer build "${SOURCE_DIR}/hcl"
    fi
    log "Uploading ${QCOW2_NAME} to MinIO"
    MC_MOUNT="${QCOW2_DIR}:/upload:ro" mc_run "mc cp /upload/${QCOW2_NAME} local/${IMAGE_OBJECT}"
}

# Mint API keys, then register the template from the MinIO URL.
register_template() {
    ensure_cloudstack_api_keys
    CLOUDSTACK_API_URL="http://$(bridge_ip):8080/client/api" \
        CLOUDSTACK_API_KEY="${CLOUDSTACK_API_KEY}" \
        CLOUDSTACK_SECRET_KEY="${CLOUDSTACK_SECRET_KEY}" \
        TEMPLATE_NAME="${TEMPLATE_NAME}" \
        TEMPLATE_URL="http://$(bridge_ip):9000/${IMAGE_OBJECT}" \
        "${SOURCE_DIR}/scripts/register-cloudstack-template.sh"
}

main() {
    resolve_image_password
    start_minio
    build_and_publish
    register_template
    log "Image ready and registered as template '${TEMPLATE_NAME}'"
}

main "$@"

