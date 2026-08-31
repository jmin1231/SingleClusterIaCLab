# syntax=docker/dockerfile:1
#
# toolbox — the image every CI job runs in (4.3). Nothing is installed at job
# time: a pipeline that apt-gets its own tools is slower on every run, is not
# reproducible, and trusts whatever the network served that minute.
#
# Rules: 1. pin every version in an ARG. 2. checksum every downloaded binary.
# 3. every tool names the pipeline that needs it — if you cannot name one, do
#    not add the tool.

# Base chosen on measurement, not taste:
#   ubuntu 119 MB · bookworm-slim 116 · trixie-slim 119 · wolfi 25 · alpine 12
# debian-slim saves 3 MB and diverges from the guests; alpine saves 107 MB and
# costs musl, which most tools here do not ship for; Chainguard returns FORBIDDEN
# on the free tier; Wolfi's apk has terraform at 1.5.7 and kubectl 1.24.
FROM ubuntu:24.04

# Populated by buildx — setting it by hand is what makes a build arch-assuming.
ARG TARGETARCH

# Versions checked upstream 2026-08-27; kubectl 2026-08-31.
#
# terraform: 1.16.0 is newer but shipped 2026-08-26, one day before this pin. A
# .0 minor that young is where the provider surprises are; 1.15.9 is the settled
# line. Take 1.16.x once it has a patch release.
ARG TERRAFORM_VERSION=1.15.9
#ARG TERRAFORM_VERSION=1.16.0
ARG PACKER_VERSION=1.16.0
ARG TRIVY_VERSION=0.74.0
ARG CMK_VERSION=6.5.0

# kubectl cannot be picked freely: a client is supported at most one minor from
# the API server. kubectl stable is 1.37.0, but k3s's newest line is 1.36
# (v1.36.4+k3s1), so 1.37 has no server yet. Re-check when Phase 9 fixes k3s.
ARG KUBECTL_VERSION=1.36.4

# helm 4, decided. Both lines are maintained (4.2.4 and 3.21.4, a day apart), so
# this was not a "move off the old one" choice. Lower-stakes than it looks:
# Flux's helm-controller embeds its own Helm, so this CLI governs CI and local
# use, not what GitOps applies. Helm 4 reads Helm 3 charts but changes behaviour.
ARG HELM_VERSION=4.2.4
# mc is date-stamped, not semver — hence MC_RELEASE. See its layer.
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
# Match the Vault SERVER version; the client is not the thing to keep current.
ARG VAULT_VERSION=2.0.4
# ansible-core, not the bundle — measurements in the ansible layer.
ARG ANSIBLE_CORE_VERSION=2.21.3
# NOT named ANSIBLE_COLLECTIONS_PATH: an ARG is exported into every RUN, so that
# name would silently configure ansible during the build.
ARG ANSIBLE_VENV=/opt/ansible
ARG ANSIBLE_COLLECTIONS_DIR=/usr/share/ansible/collections
# 24 is the current LTS. v26.8.1 is newer but odd-numbered, so not LTS.
ARG NODE_MAJOR=24

ENV DEBIAN_FRONTEND=noninteractive

# One apt layer: a second pays another `apt-get update` and another cache
# invalidation point. NodeSource and Docker are the exceptions below — both need
# a keyring before their repo resolves.
#
# Unversioned, against rule 1: pinning an apt package breaks the build the moment
# Ubuntu rotates it out on a security update. The real answer is a frozen archive
# (snapshot mirror, Pulp, Artifactory); this lab skips it. Rule 1 still holds for
# every downloaded binary below, where a pin costs nothing.
#
# The last six are ansible's and qemu's, not general tools: python3-venv rather
# than python3-pip (see the ansible layer), and qemu because 4.4 passes /dev/kvm
# into the job container. The `/*` in the rm is load-bearing — removing the
# directory makes the next `apt-get update` fail on a missing partial/.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq unzip openssh-client gnupg \
        python3 python3-venv sshpass rsync \
        qemu-system-x86 qemu-utils; \
    rm -rf /var/lib/apt/lists/*

# terraform — needed by 7.x, and 7.5 drift detection.
#
# The unzip names the binary as a member deliberately: every HashiCorp zip
# carries a LICENSE.txt, and extracting the lot leaves one in /tmp for the next
# tool to collide with — unzip then prompts, reads EOF, and fails the layer.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSL -O "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep " terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}\.zip$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q -o "terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" terraform; \
    install -m 0755 terraform /usr/local/bin/terraform; \
    rm -f terraform*

# packer — needed by 6.2.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSL -O "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_SHA256SUMS"; \
    grep " packer_${PACKER_VERSION}_linux_${TARGETARCH}\.zip$" "packer_${PACKER_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q -o "packer_${PACKER_VERSION}_linux_${TARGETARCH}.zip" packer; \
    install -m 0755 packer /usr/local/bin/packer; \
    rm -f packer*

# ansible — needed by Phase 8 configuration management.
#
# ansible-core, not the bundle. On PyPI: ansible 14.3.1 is a 47.9 MB wheel,
# ansible-core 2.21.3 is 2.3 MB. The engine is identical; the 45 MB is ~100
# collections, of which Phase 8 uses two — and one, cloud.terraform, is not in
# the bundle anyway.
#
# The venv is the size lever, not just PEP 668 compliance: python3-pip measured
# +420 MB, while `python3 -m venv` bootstraps pip via ensurepip.
#
# Three symlinks, not seven — rule 3 covers console scripts. The other four stay
# in the venv, off PATH until a pipeline needs them.
RUN set -eux; \
    python3 -m venv "${ANSIBLE_VENV}"; \
    "${ANSIBLE_VENV}/bin/pip" install --no-cache-dir \
        "ansible-core==${ANSIBLE_CORE_VERSION}"; \
    for binary in ansible ansible-playbook ansible-galaxy; do \
        ln -s "${ANSIBLE_VENV}/bin/$binary" "/usr/local/bin/$binary"; \
    done

# Collections baked in rather than installed per job.
#
# -p targets a system path deliberately: it is the last entry in ansible-core's
# default search order, so a plain `ansible-playbook` finds them unconfigured.
# The reference lab's ansible.cfg points collections_path at a project-local
# ./collections — a setting that REPLACES the default list, so an ansible.cfg
# copied from there would hide everything installed here.
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install \
        -r /tmp/requirements.yml \
        -p "${ANSIBLE_COLLECTIONS_DIR}"; \
    rm -f /tmp/requirements.yml; \
    rm -rf /root/.ansible

# Arch strings: dpkg says amd64, cmk's assets say x86-64, trivy's say 64bit.
# terraform, packer, helm, kubectl and mc take $TARGETARCH straight through;
# trivy and cmk each carry a `case` that fails loudly on anything unsupported,
# rather than 404-ing halfway through a build.

# kubectl — needed by 9.x onward. Its .sha256 is a bare hash with no filename,
# so it needs the printf pairing rather than a plain `sha256sum -c`.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSL -O "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256"; \
    printf '%s  %s\n' "$(cat kubectl.sha256)" kubectl | sha256sum -c -; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    rm -f kubectl kubectl.sha256

# helm — needed by 11.x chart deploys.
#
# One artifact, so nothing to grep, and checksum-file layout (bare hash vs. hash
# plus filename) varies by project. Taking field 1 and pairing it with the name
# we downloaded handles both and can never verify a file we did not fetch.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSL -O "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum"; \
    printf '%s  %s\n' \
        "$(awk 'NR == 1 { print $1 }' "helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum")" \
        "helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
        | sha256sum -c -; \
    tar -xzf "helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" "linux-${TARGETARCH}/helm"; \
    install -m 0755 "linux-${TARGETARCH}/helm" /usr/local/bin/helm; \
    rm -rf helm-v* "linux-${TARGETARCH}"

# trivy — needed by 4.6 image and filesystem scanning, 6.3 template scanning.
#
# DECIDED: the vulnerability DB is NOT baked in. Baking makes the first job fast
# and stale by the second day, and a scan passing on last week's data reports
# success — worse than no scan. 4.4 caches it in a volume instead.
RUN set -eux; \
    cd /tmp; \
    case "${TARGETARCH}" in \
        amd64) TRIVY_ARCH="64bit" ;; \
        arm64) TRIVY_ARCH="ARM64" ;; \
        *) echo "unsupported arch ${TARGETARCH} for trivy" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -O "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz"; \
    curl -fsSL -O "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt"; \
    grep " trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}\.tar\.gz$" \
        "trivy_${TRIVY_VERSION}_checksums.txt" | sha256sum -c -; \
    tar -xzf "trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" trivy; \
    install -m 0755 trivy /usr/local/bin/trivy; \
    rm -f trivy*

# cmk — needed by CloudStack API calls from pipelines.
#
# The one tool that does not meet rule 2, and not for lack of looking: the 6.5.0
# release ships eight binaries and no .sha256/.sha512/.asc, so it is pinned by
# version and trusted no further than TLS.
#
# With no synced API cache, every cmk run prints "Failed to read API cache" to
# stderr. Harmless; it goes once a pipeline runs `cmk sync`.
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) CMK_ARCH="x86-64" ;; \
        arm64) CMK_ARCH="arm64" ;; \
        *) echo "unsupported arch ${TARGETARCH} for cmk" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/cmk \
        "https://github.com/apache/cloudstack-cloudmonkey/releases/download/${CMK_VERSION}/cmk.linux.${CMK_ARCH}"; \
    chmod 0755 /usr/local/bin/cmk

# mc — needed by 5.1 bucket/policy management and 6.2's packer-ci image pushes.
#
# The obvious URL is a trap: .../linux-${ARCH}/mc is always latest, which is what
# the reference lab uses. The pinned .../archive/mc.${MC_RELEASE} has a
# .sha256sum beside it — .sha256 returns 404.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive/mc.${MC_RELEASE}"; \
    curl -fsSL -O "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive/mc.${MC_RELEASE}.sha256sum"; \
    printf '%s  %s\n' \
        "$(awk 'NR == 1 { print $1 }' "mc.${MC_RELEASE}.sha256sum")" \
        "mc.${MC_RELEASE}" \
        | sha256sum -c -; \
    install -m 0755 "mc.${MC_RELEASE}" /usr/local/bin/mc; \
    rm -f mc.*

# vault — needed by Phase 3: jobs log in by AppRole and read secrets, and without
# a client every job hand-rolls curl against the API.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSL -O "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS"; \
    grep " vault_${VAULT_VERSION}_linux_${TARGETARCH}\.zip$" "vault_${VAULT_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q -o "vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" vault; \
    install -m 0755 vault /usr/local/bin/vault; \
    rm -f vault*

# node — needed by the first step of the first workflow: Gitea Actions runs JS
# actions in-container and actions/checkout is one.
#
# NodeSource documents `curl .../setup_24.x | bash -`. Installing the keyring and
# repo directly does the same job without piping a remote script into a root
# shell, and lets apt verify the packages against a key on disk.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    chmod a+r /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

# docker CLI — needed by 6.1 image builds. Client only: no engine, no daemon.
# buildx because `docker build` is an alias for it on modern engines.
#
# DELIBERATELY UNPINNED, against rule 1: this client talks to a daemon on a host
# the image does not control, and pinning it against an engine that upgrades
# underneath is the worse failure. How it reaches a daemon is 4.4's threat model.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin; \
    rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]
