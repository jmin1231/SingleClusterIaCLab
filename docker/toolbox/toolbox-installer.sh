#!/usr/bin/env bash
#
# toolbox-installer.sh — build the CI image every pipeline job runs in (4.3).
#
# Usage: sudo ./toolbox-installer.sh
#
# Belongs to Phase 4 but depends on nothing else in it: the image is never
# pulled, so it can be built before Gitea exists. 4.4 is what consumes it, by
# registering a runner whose label names the tag below.
#
# It does depend on Vault. The last Dockerfile layer bakes in the lab CA, which
# reaches the build through a second named context rooted at the Vault service's
# certs/ directory - that is where the CA lands when Vault issues itself a
# certificate. So vault-installer.sh has to have run on this machine first.
# preflight() checks that: .gitignore keeps certificates out of git, so a fresh
# clone never has one.
#
# Safe to re-run. An unchanged Dockerfile is all cache hits; a changed ARG
# rebuilds from that layer down.

set -euo pipefail

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Two levels up, and resolved rather than left as a literal `../..`:
# --build-context takes its path relative to the CLI's working directory, not to
# this script, so only an absolute path keeps the script runnable from anywhere.
LAB_CA_DIR="$(cd -- "${SOURCE_SCRIPT}/.." && pwd)/vault/certs"
DOCKERFILE="${SOURCE_SCRIPT}/Dockerfile"
REQUIREMENTS="${SOURCE_SCRIPT}/requirements.yml"

# The tag 4.4's runner label has to match. `latest` rather than a version, which
# looks wrong in a repo that pins everything: this image is built here and never
# pulled, so there is no registry for a version tag to disambiguate against, and
# act_runner's label names a tag rather than a digest. The pinning that matters
# is inside the Dockerfile, on the tools.
IMAGE="${TOOLBOX_IMAGE:-toolbox:latest}"

# Fail on a missing input here rather than inside BuildKit, which reports a
# missing COPY source as a solve error with no filename in it.
preflight() {
  command -v docker >/dev/null 2>&1 ||
    {
      die "docker is not installed. bootstrap.sh installs it; see its docker step."
    }
  docker info >/dev/null 2>&1 ||
    {
      die "Cannot reach the Docker daemon. Is it running, and are you root?"
    }
  [[ -f "${DOCKERFILE}" ]] || die "No Dockerfile at ${DOCKERFILE}"
  [[ -f "${REQUIREMENTS}" ]] ||
    {
      die "No requirements.yml at ${REQUIREMENTS}; the ansible layer COPYs it."
    }
  [[ -f "${LAB_CA_DIR}/ca.crt" ]] ||
    {
      die "No CA at ${LAB_CA_DIR}/ca.crt. Run: sudo ./docker/vault/vault-installer.sh"
    }
}

build_image() {
  log "Building ${IMAGE} — the first run downloads roughly a gigabyte of tools."
  docker build --build-context "labca=${LAB_CA_DIR}" \
    -t "${IMAGE}" "${SOURCE_SCRIPT}" ||
    {
      die "Build failed; the failing step's output is above."
    }
  log "Built ${IMAGE}"
}

# 4.3's acceptance test, run once here rather than as a layer inside the image:
# terraform and trivy execute from the image with nothing downloaded at run time.
#
# Each command is captured before it is trimmed. Piping into `head` first would
# hand the pipeline head's exit status and swallow the failure entirely, which
# is the whole reason a broken tool would slip through this check.
verify_image() {
  local out

  if ! out="$(docker run --rm "${IMAGE}" terraform version 2>&1)"; then
    {
      die "terraform does not run in ${IMAGE}: $(printf '%s' "${out}" | head -n1)"
    }
  fi
  log "  $(printf '%s' "${out}" | head -n1)"

  if ! out="$(docker run --rm "${IMAGE}" trivy --version 2>&1)"; then
    {
      die "trivy does not run in ${IMAGE}: $(printf '%s' "${out}" | head -n1)"
    }
  fi
  log "  $(printf '%s' "${out}" | head -n1)"

  log "${IMAGE} passes 4.3: both tools run with no downloads at job time."
}

main() {
  [[ ${EUID} -eq 0 ]] || die "toolbox-installer.sh must be run as root:  sudo $0"
  preflight
  build_image
  verify_image
}

main "$@"
