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
# See TODO 4.3-4 for the ~40%.
#
# TODO 4.3-1: pin this by digest, not by tag. A tag moves; a rebuild months from
#   now must resolve to the same bytes or none of the version pinning below
#   means anything.
FROM ubuntu:24.04

# Populated by buildx. Do not set it by hand — that is what makes the build
# arch-aware rather than arch-assuming.
ARG TARGETARCH

# TODO 4.3-2: pin every version, then record where you got it.
#   Check each project's releases page and write the real number here. An
#   unpinned tool makes the image unreproducible, which defeats the point of
#   building one.
# Checked against upstream on 2026-08-27. Re-check before first build.
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

# TODO 4.3-15: helm 3 or helm 4 — and BOTH lines are actively maintained, so
#   this is not a "move off the old one" decision:
#     4.2.4  released 2026-08-13
#     3.21.4 released 2026-08-14   <- ONE DAY LATER
#   Helm 4 reads Helm 3 charts but changes behaviour, and Phase 11 is built on
#   chart deploys. Flux's helm-controller embeds its OWN Helm, so this CLI
#   governs your local and CI use rather than what GitOps actually applies —
#   which makes the choice lower-stakes than it looks, but still a choice.
#   If you pick 3, pin 3.21.4 — NOT the reference lab's 3.17.0, which is stale.
ARG HELM_VERSION=4.2.4
# mc is date-stamped, NOT semver: RELEASE.2025-08-13T08-35-41Z. See 4.3-8.
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
# Not in build-order 4.3's list, and all three are load-bearing — see 4.3-13.
# Match the Vault SERVER version — the client is not the thing to keep current.
ARG VAULT_VERSION=2.0.4
# Pick ONE and delete the other — see 4.3-4. ansible-core is recommended.
ARG ANSIBLE_CORE_VERSION=3.21.4
#ARG ANSIBLE_VERSION=14.3.1
# 24 is the current LTS ("Krypton", v24.20.0). v26.8.1 exists and is NEWER but
# is NOT LTS — CI is the last place to run an odd-numbered Node line.
ARG NODE_MAJOR=24

ENV DEBIAN_FRONTEND=noninteractive

# TODO 4.3-3: the apt layer. Only what the downloads below need, plus what the
#   pipelines genuinely use: ca-certificates, curl, git, jq, unzip, openssh-client,
#   gnupg. Name the pipeline for anything beyond that list.
#   Clean /var/lib/apt/lists in the SAME RUN, or the deleted files stay in the
#   layer and the image carries them forever.
RUN echo "TODO 4.3-3" && false

# TODO 4.3-4: ansible — the single heaviest thing in this image.
#   MEASURED: `apt-get install python3-pip` alone costs **+420 MB**, nearly four
#   times the entire base, before ansible itself is installed. This is the line
#   to fight, not the base image.
#   MEASURED on PyPI, 2026-08-27:
#     ansible       14.3.1   wheel 47.9 MB   engine + ~100 bundled collections
#     ansible-core   2.21.3  wheel  2.3 MB   engine only
#   ansible 14.x is a wrapper around ansible-core~=2.21.3 plus the bundle, so the
#   engine is identical either way. Both need python >= 3.12; 24.04 ships 3.12.
#
#   RECOMMENDED: ansible-core, plus a `requirements.yml` naming exactly the
#   collections Phase 8 uses, installed with `ansible-galaxy collection install
#   -r`. That is not just smaller — it is MORE reproducible, because the bundle
#   picks collection versions for you and changes them with every bundle release,
#   while requirements.yml pins each one and lives in Git like everything else.
#   ansible.builtin ships with core and already covers apt, copy, template,
#   systemd, user, file and lineinfile. Start there and add only what fails.
#
#   Three levers, in order of effect:
#     - ansible-core rather than ansible
#     - `--no-install-recommends` on every apt call in this file
#     - a venv, which PEP 668 forces anyway on 24.04: the system python is marked
#       externally-managed and a bare `pip install` refuses. The reference lab
#       uses --break-system-packages instead, which is defensible in a
#       single-purpose image but leaves pip able to fight apt later.
#   Needed by: Phase 8 configuration management.

# TODO 4.3-5: the HashiCorp tools — terraform and packer.
#   Both ship as a zip plus a SHA256SUMS file at releases.hashicorp.com.
#   Download, verify the checksum, unzip, install, delete the archive — all in
#   one RUN, or the archive survives in a lower layer.
#   The arch string is not $TARGETARCH verbatim for every project, and the
#   mismatches are real: dpkg says amd64, cmk's release assets say x86-64, and
#   trivy's say 64bit. A `case` per tool, with an explicit failure on an
#   unsupported arch rather than a 404 halfway through the build.
#   Needed by: terraform -> 7.x and 7.5 drift detection; packer -> 6.2.

# TODO 4.3-6: kubectl and helm.
#   Needed by: kubectl -> 9.x onward; helm -> 11.x chart deploys.
#   helm publishes a checksum per artifact; kubectl publishes <binary>.sha256.

# TODO 4.3-7: trivy.
#   Needed by: 4.6 image and filesystem scanning, 6.3 template scanning.
#   Decide whether to bake the vulnerability DB into the image. Baking makes
#   jobs fast and offline-capable but stale on day two; not baking means every
#   job downloads it. There is a third option — cache it in a volume — and it
#   belongs to 4.4, not here. Write down which you chose.

# TODO 4.3-8: cmk and mc.
#   Needed by: cmk -> CloudStack API from pipelines; mc -> MinIO bucket and
#   policy management in 5.1, and 6.2's packer-ci pushing built images. Both are
#   single static binaries.
#
#   mc does not use semantic versions. Releases are date-stamped
#   `RELEASE.2025-08-13T08-35-41Z`, which is why the ARG above is MC_RELEASE
#   rather than MC_VERSION — a field named VERSION holding a timestamp is the
#   kind of small lie that costs someone an afternoon.
#
#   VERIFIED against dl.min.io, because the obvious URL is a trap:
#     unpinned (what the reference lab uses — always latest, do NOT copy):
#       https://dl.min.io/client/mc/release/linux-${ARCH}/mc
#     pinned + checksummed (use this):
#       https://dl.min.io/client/mc/release/linux-${ARCH}/archive/mc.${MC_RELEASE}
#       https://dl.min.io/client/mc/release/linux-${ARCH}/archive/mc.${MC_RELEASE}.sha256sum
#   The `.sha256sum` suffix exists; `.sha256` returns 404.

# TODO 4.3-13: the three tools build-order 4.3 does not list, and why each is
#   not optional:
#     - **Node.js.** Gitea Actions runs JavaScript actions in-container, and
#       `actions/checkout` is one. With no node, the FIRST step of the FIRST
#       workflow fails. Install from NodeSource; pin the major.
#     - **qemu-system-x86 + qemu-utils.** 4.4's hard constraint is that packer-ci
#       opens /dev/kvm inside the job container. Passing the device through
#       achieves nothing if there is no qemu here to use it. Needed by: 6.2.
#     - **The Vault CLI.** Jobs authenticate by AppRole and read secrets; the
#       whole credential model in Phase 3 assumes a client. Without it every job
#       hand-rolls curl against the API. Match the SERVER version.
#   Also: sshpass and rsync (ansible), and docker-buildx-plugin (`docker build`
#   is an alias for buildx on modern engines; without it every CI log carries a
#   deprecation warning).

# TODO 4.3-9: the Docker CLI — the client only, never the daemon.
#   DELIBERATELY UNPINNED, unlike everything else here. This client talks to a
#   daemon on a host the image does not control, and pinning it against an
#   engine that upgrades underneath is the worse failure. Write that reasoning
#   in a comment — an unpinned version in a file whose rule 1 is "pin
#   everything" reads as an oversight unless it says why it is not one.
#   Needed by: 6.1 image builds. How it reaches a daemon is 4.4's problem and
#   is the whole content of that phase's threat model. Installing the client
#   here does not decide it.

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

# TODO 4.3-11: a verification layer. Run --version for every tool as the last
#   step, so a broken download fails the BUILD rather than the first pipeline
#   that needs it. This is the image's own test and it costs one layer.
