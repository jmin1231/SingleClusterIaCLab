# syntax=docker/dockerfile:1
#
# toolbox — the image every CI job runs in (4.3).
#
# Nothing here is installed at job time. A pipeline that apt-gets its own tools
# is slower on every run, is not reproducible across runs, and widens the
# supply-chain surface to "whatever the network served that minute".
#
# Rules this file follows:
#   1. every version is pinned in an ARG — never `latest`, never unversioned apt
#   2. every downloaded binary is checksum-verified before it is trusted
#   3. every tool carries a comment naming the pipeline that needs it
#
# Rule 3 is the one that keeps this image from accumulating things nobody can
# justify. If you cannot name the pipeline, do not add the tool.

# Base: ubuntu:24.04. Measured alternatives, so this is not taste:
#
#   ubuntu:24.04  119 MB   debian:bookworm-slim  116 MB   alpine:3.21  12 MB
#   wolfi-base     25 MB   debian:trixie-slim    119 MB
#
# Debian-slim saves 3 MB and is not worth diverging from the guests for. Alpine
# saves 107 MB and costs musl — most tools here ship glibc builds. Chainguard's
# terraform/trivy/ansible images return FORBIDDEN on the free tier, and Wolfi's
# apk has terraform frozen at 1.5.7 (pre-BUSL) with no packer and kubectl 1.24.
#
# The base is ~10% of the finished image, so it is the wrong thing to optimise.
# The ansible layer is the ~40% — see the note there.
FROM ubuntu:24.04

# Populated by buildx. Do not set it by hand — that is what makes the build
# arch-aware rather than arch-assuming.
ARG TARGETARCH

# Every version below was checked against its upstream releases page on
# 2026-08-27. Re-check before the first build. The one still open is kubectl
# (4.3-14, waits on Phase 9).
#
# TERRAFORM: 1.16.0 is the newest stable — and was released 2026-08-26, ONE DAY
# before this pin was written. A .0 minor that young is where the regressions
# and the provider-compatibility surprises are, and this lab wants a toolbox
# that is boring. 1.15.9 (2026-08-19) is the settled line; take 1.16.x once it
# has a patch release. Swap the comment when you decide otherwise.
ARG TERRAFORM_VERSION=1.15.9
#ARG TERRAFORM_VERSION=1.16.0
ARG PACKER_VERSION=1.16.0
ARG TRIVY_VERSION=0.74.0
ARG CMK_VERSION=6.5.0

# TODO 4.3-14: kubectl is the ONE version here you cannot pick freely.
#   Kubernetes supports a client at most one minor from the API server. k3s
#   arrives in Phase 9 and decides that number, so pinning latest (1.37.0) now
#   risks being several minors ahead of whatever k3s ships. Leave this until
#   Phase 9 fixes the server version, then pin to it.
ARG KUBECTL_VERSION=

# helm 4, decided. Both lines are actively maintained — 4.2.4 (2026-08-13) and
# 3.21.4 (2026-08-14, one day LATER) — so this was not a "move off the old one"
# choice. It is lower-stakes than it looks either way: Flux's helm-controller
# embeds its own Helm, so this CLI governs local and CI use, not what GitOps
# actually applies. Helm 4 reads Helm 3 charts but changes behaviour; Phase 11
# is where that gets tested.
ARG HELM_VERSION=4.2.4
# mc is date-stamped, NOT semver: RELEASE.2025-08-13T08-35-41Z. See 4.3-8.
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
# Not in build-order 4.3's list, and all three are load-bearing — see 4.3-13.
# Match the Vault SERVER version — the client is not the thing to keep current.
ARG VAULT_VERSION=2.0.4
# ansible-core, decided — the bundle buys nothing this lab uses. See the ansible
# layer below for the measurements behind that.
ARG ANSIBLE_CORE_VERSION=2.21.3
# Where the venv and the baked collections live. ANSIBLE_COLLECTIONS_DIR is
# deliberately NOT named ANSIBLE_COLLECTIONS_PATH: an ARG is exported into every
# RUN's environment, so that name would silently configure ansible itself during
# the build, and a setting that arrives invisibly is the kind nobody can find.
ARG ANSIBLE_VENV=/opt/ansible
ARG ANSIBLE_COLLECTIONS_DIR=/usr/share/ansible/collections
# 24 is the current LTS ("Krypton", v24.20.0). v26.8.1 exists and is NEWER but
# is NOT LTS — CI is the last place to run an odd-numbered Node line.
ARG NODE_MAJOR=24

ENV DEBIAN_FRONTEND=noninteractive

# The apt layer. Everything from the Ubuntu archive belongs in THIS one RUN —
# a second apt layer pays a second `apt-get update` and adds a second point
# where the cache invalidates. NodeSource and Docker are the exceptions (4.3-13,
# 4.3-9): both need a keyring installed before their repo resolves.
#
# curl, unzip and gnupg are builder-only — they exist to fetch and unpack static
# binaries and do not follow into the final stage when 4.3-12 splits the build.
#
# These are deliberately unversioned, against rule 1. Pinning an apt package to
# an exact version breaks the build the moment Ubuntu rotates that version out
# of the pocket on a security update. The enterprise answer is a frozen archive
# — a snapshot mirror or an apt proxy (Pulp, Artifactory, snapshot.ubuntu.com) —
# so the same `apt-get install curl` resolves to the same bytes forever. This
# lab skips that. Rule 1 holds for every downloaded binary below, where a pin
# costs nothing.
#
# The last six are not general tools: python3/python3-venv, sshpass and rsync
# for ansible (python3-venv NOT python3-pip — see that layer for why), and qemu
# because 4.4 passes /dev/kvm into the job container for packer-ci in 6.2.
#
# The `/*` in the rm is load-bearing: removing the directory itself makes the
# next `apt-get update` fail with "List directory .../partial is missing".
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq unzip openssh-client gnupg \
        python3 python3-venv sshpass rsync \
        qemu-system-x86 qemu-utils; \
    rm -rf /var/lib/apt/lists/*

# terraform — needed by 7.x, and 7.5 drift detection.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSL -O "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep " terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}\.zip$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"; \
    install -m 0755 terraform /usr/local/bin/terraform; \
    rm -f terraform*

# packer — needed by 6.2.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSL -O "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_SHA256SUMS"; \
    grep " packer_${PACKER_VERSION}_linux_${TARGETARCH}\.zip$" "packer_${PACKER_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "packer_${PACKER_VERSION}_linux_${TARGETARCH}.zip"; \
    install -m 0755 packer /usr/local/bin/packer; \
    rm -f packer*

# ansible — needed by Phase 8 configuration management. The heaviest thing in
# this image, and the ~40% the base-image note points at.
#
# ansible-core, not the ansible bundle. On PyPI, 2026-08-27:
#     ansible       14.3.1   wheel 47.9 MB   engine + ~100 bundled collections
#     ansible-core   2.21.3  wheel  2.3 MB   engine only
# The engine is identical either way — the 45 MB is collections, and Phase 8
# uses two of them (requirements.yml). One, cloud.terraform, is not in the
# bundle at all: the reference lab ships the bundle AND still runs
# ansible-galaxy on every job to get it.
#
# The venv is not merely PEP 668 compliance, it is the size lever. python3-pip
# measured +420 MB; python3-venv is a fraction of that and `python3 -m venv`
# bootstraps pip via ensurepip. The 420 MB never happens rather than being
# trimmed back afterwards.
#
# Three symlinks, not seven — rule 3 covers console scripts too. ansible and
# ansible-playbook are what ansible-ci calls; ansible-galaxy is used by the
# build below. The other four stay in the venv at /opt/ansible/bin, off PATH
# until a pipeline needs them.
RUN set -eux; \
    python3 -m venv "${ANSIBLE_VENV}"; \
    "${ANSIBLE_VENV}/bin/pip" install --no-cache-dir \
        "ansible-core==${ANSIBLE_CORE_VERSION}"; \
    for binary in ansible ansible-playbook ansible-galaxy; do \
        ln -s "${ANSIBLE_VENV}/bin/$binary" "/usr/local/bin/$binary"; \
    done

# The collections, baked in rather than installed per job.
#
# -p targets a system path deliberately: it is the last entry in ansible-core's
# default search order, so a plain `ansible-playbook` finds these unconfigured.
# ~/.ansible/collections would break the moment 4.3-10 changes the job user, and
# the reference lab's ansible.cfg points `collections_path` at a project-local
# ./collections — a setting that REPLACES the default list rather than extending
# it, so an ansible.cfg copied from there hides everything installed here.
#
# The COPY invalidates every layer below it. 4.3-12's multi-stage rewrite
# reorders all of this anyway, so it stays beside the install it belongs with.
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install \
        -r /tmp/requirements.yml \
        -p "${ANSIBLE_COLLECTIONS_DIR}"; \
    rm -f /tmp/requirements.yml; \
    rm -rf /root/.ansible

# Arch strings. $TARGETARCH is not the string every project uses, and the
# mismatches are real: dpkg says amd64, cmk's release assets say x86-64, trivy's
# say 64bit. terraform, packer, helm and mc take it straight through; trivy and
# cmk each carry a `case` below. Every case fails loudly on an unsupported arch,
# because the alternative is a 404 halfway through a build that reads like a
# network problem rather than an unhandled platform.

# TODO 4.3-6 (part): kubectl. helm is done below; kubectl waits on 4.3-14, which
#   waits on Phase 9 to fix the k3s server version. When it lands:
#     https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl
#     ...same URL with .sha256 appended — a BARE hash, no filename, so it needs
#     the printf pairing the helm block below uses, not a plain `sha256sum -c`.
#   Needed by: 9.x onward.

# helm — needed by 11.x chart deploys.
#
# One artifact, so nothing to grep — and the checksum file's layout (bare hash
# vs. hash + filename) varies by project. Taking field 1 and pairing it with the
# name we downloaded handles both, and can never verify a file we did not fetch.
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

# trivy — needed by 4.6 image and filesystem scanning, and 6.3 template scanning.
#
# DECIDED, on 4.3-7: the vulnerability DB is NOT baked in. Baking makes the
# first job fast and offline-capable, and stale by the second day — a scan that
# passes against last week's data reports success, which is worse than no scan.
# 4.4 caches it in a volume; that is where the cost gets paid down.
#
# The tarball carries LICENSE and README beside the binary, so name `trivy`
# explicitly rather than extracting the whole thing into /usr/local/bin.
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
# The one tool here that does not meet rule 2, and not for lack of looking.
# VERIFIED against the GitHub release API on 2026-08-31: 6.5.0 ships eight
# binaries and nothing else — no .sha256, no .sha512, no .asc. There is no
# upstream artifact to verify against, so this is pinned by version and trusted
# no further than TLS. Asset naming confirmed in the same call: cmk.linux.x86-64
# and cmk.linux.arm64, which is what the case below produces.
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) CMK_ARCH="x86-64" ;; \
        arm64) CMK_ARCH="arm64" ;; \
        *) echo "unsupported arch ${TARGETARCH} for cmk" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/cmk \
        "https://github.com/apache/cloudstack-cloudmonkey/releases/download/${CMK_VERSION}/cmk.linux.${CMK_ARCH}"; \
    chmod 0755 /usr/local/bin/cmk

# mc — needed by 5.1 MinIO bucket and policy management, and 6.2's packer-ci
# pushing built images.
#
# mc is date-stamped, not semver — hence MC_RELEASE, since a field named VERSION
# holding a timestamp is the kind of small lie that costs someone an afternoon.
#
# The obvious URL is a trap. VERIFIED against dl.min.io: the reference lab's
# .../linux-${ARCH}/mc is always latest, while .../archive/mc.${MC_RELEASE} is
# pinned and has a .sha256sum beside it (.sha256 returns 404). One artifact, so
# the same printf pairing as helm.
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

# vault — needed by Phase 3's credential model: jobs log in by AppRole and read
# secrets, and without a client every job hand-rolls curl against the API.
# Matches the SERVER version, not the newest release.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -O "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSL -O "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS"; \
    grep " vault_${VAULT_VERSION}_linux_${TARGETARCH}\.zip$" "vault_${VAULT_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip"; \
    install -m 0755 vault /usr/local/bin/vault; \
    rm -f vault*

# node — needed by the first step of the first workflow. Gitea Actions runs
# JavaScript actions in-container and `actions/checkout` is one, so an image
# without node fails before any pipeline logic runs.
#
# NodeSource documents `curl .../setup_24.x | bash -`, which the reference lab
# uses. Installing the keyring and repo directly does the same job without
# piping a remote script into a root shell, and it means apt verifies the
# packages against a key on disk — the same guarantee the rest of the apt layer
# already gets.
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

# docker CLI — needed by 6.1 image builds. The CLIENT only: no engine, no
# daemon. buildx because `docker build` is an alias for it on modern engines,
# and without the plugin every CI log carries a deprecation warning.
#
# DELIBERATELY UNPINNED, against rule 1: this client talks to a daemon on a host
# the image does not control, and pinning it against an engine that upgrades
# underneath is the worse failure. Said out loud because an unpinned version in
# a file whose first rule is "pin everything" otherwise reads as an oversight.
# How it reaches a daemon is 4.4's threat model, not this layer's.
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

# TODO 4.3-10: create an unprivileged user and USER it.
#   A job that runs as root inside the container is one container escape from
#   root on your hypervisor. Check what act_runner requires before choosing the
#   uid — 4.4 may constrain this.

# TODO 4.3-12: make this a MULTI-STAGE build once the tools install correctly.
#   curl, unzip, gnupg and every downloaded archive exist only to produce a
#   handful of static binaries. A builder stage that downloads and verifies,
#   followed by a final stage that COPYs just the binaries, drops all of it.
#   Do this AFTER the tools work — debugging a download inside a discarded stage
#   is harder, and the size win is worthless if the image is broken.

# The image's own test, and the last thing the build does: a broken download
# fails HERE rather than in the first pipeline that needs the tool.
#
# It asserts the VERSION, not just that the binary runs. A tool that executes is
# not the same as the tool that was pinned — a stale layer or a redirected
# download both produce a working binary of the wrong version, and a bare
# `--version` call passes for both.
#
# `set -eu`, not the file's usual `-eux`: with -x every printf below echoes
# twice and the summary is unreadable. And it tallies rather than exiting on the
# first failure, because these grep patterns are assumptions about each tool's
# output format — on a first build you want all of them at once, not one per
# rebuild. Each mismatch prints what it actually got, so a wrong guess here is
# a one-line fix rather than an investigation.
#
# TODO 4.3-17: add kubectl once 4.3-14 unblocks it.
RUN set -eu; \
    fail=0; \
    check() { \
        name="$1"; want="$2"; shift 2; \
        if ! out="$("$@" 2>&1)"; then \
            printf 'FAIL     %-10s command failed: %s\n' \
                "$name" "$(printf '%s' "$out" | head -n1)" >&2; \
            fail=1; return 0; \
        fi; \
        got="$(printf '%s\n' "$out" | head -n1)"; \
        case "$got" in \
            *"$want"*) printf 'ok       %-10s %s\n' "$name" "$got" ;; \
            *) printf 'MISMATCH %-10s want %s -- got %s\n' "$name" "$want" "$got" >&2; \
               fail=1 ;; \
        esac; \
    }; \
    check terraform "v${TERRAFORM_VERSION}"        terraform version; \
    check packer    "${PACKER_VERSION}"            packer version; \
    check vault     "v${VAULT_VERSION}"            vault version; \
    check helm      "v${HELM_VERSION}"             helm version --short; \
    check trivy     "${TRIVY_VERSION}"             trivy --version; \
    check cmk       "${CMK_VERSION}"               cmk version; \
    check mc        "${MC_RELEASE}"                mc --version; \
    check ansible   "core ${ANSIBLE_CORE_VERSION}" ansible --version; \
    check node      "v${NODE_MAJOR}."              node --version; \
    check qemu      "QEMU emulator version"        qemu-system-x86_64 --version; \
    check docker    "Docker version"               docker --version; \
    for c in cloud.terraform ansible.posix; do \
        if ansible-galaxy collection list 2>/dev/null | grep -q "^$c"; then \
            printf 'ok       %-10s on the default collections path\n' "$c"; \
        else \
            printf 'FAIL     %-10s NOT on the default collections path\n' "$c" >&2; \
            fail=1; \
        fi; \
    done; \
    [ "$fail" -eq 0 ]
