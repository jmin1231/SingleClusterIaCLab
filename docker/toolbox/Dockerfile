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

# TODO 4.3-1: pick the base and say why in a comment.
#   Candidates: ubuntu:24.04, debian:bookworm-slim, alpine:3.20.
#   Two things decide it. (a) Alpine is musl; most of these tools ship glibc
#   builds, and the ones that do not still drag a different libc into your
#   ansible runs than the guests have. (b) Phase 8 runs ansible against Ubuntu
#   24.04 guests — a control node on the same base removes a whole class of
#   "works locally, fails in CI".
#   Pin by digest, not just tag, once you have chosen.
FROM ubuntu:24.04

# Populated by buildx. Do not set it by hand — that is what makes the build
# arch-aware rather than arch-assuming.
ARG TARGETARCH

# TODO 4.3-2: pin every version, then record where you got it.
#   Check each project's releases page and write the real number here. An
#   unpinned tool makes the image unreproducible, which defeats the point of
#   building one.
ARG TERRAFORM_VERSION=
ARG PACKER_VERSION=
ARG KUBECTL_VERSION=
ARG HELM_VERSION=
ARG TRIVY_VERSION=
ARG CMK_VERSION=
ARG MC_VERSION=

ENV DEBIAN_FRONTEND=noninteractive

# TODO 4.3-3: the apt layer. Only what the downloads below need, plus what the
#   pipelines genuinely use: ca-certificates, curl, git, jq, unzip, openssh-client,
#   gnupg. Name the pipeline for anything beyond that list.
#   Clean /var/lib/apt/lists in the SAME RUN, or the deleted files stay in the
#   layer and the image carries them forever.
RUN echo "TODO 4.3-3" && false

# TODO 4.3-4: ansible. apt or pip? apt is older and simpler; pip pins exactly and
#   needs python3-pip + a venv on 24.04 (PEP 668 marks the system python
#   externally-managed, so a bare `pip install` refuses). Decide, and say why.
#   Needed by: Phase 8 configuration management.

# TODO 4.3-5: the HashiCorp tools — terraform and packer.
#   Both ship as a zip plus a SHA256SUMS file at releases.hashicorp.com.
#   Download, verify the checksum, unzip, install, delete the archive — all in
#   one RUN, or the archive survives in a lower layer.
#   The arch string is not $TARGETARCH verbatim for every project; check.
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
#   policy management in 5.1. Both are single static binaries.

# TODO 4.3-9: the Docker CLI — the client only, never the daemon.
#   Needed by: 6.1 image builds. How it reaches a daemon is 4.4's problem and
#   is the whole content of that phase's threat model. Installing the client
#   here does not decide it.

# TODO 4.3-10: create an unprivileged user and USER it.
#   A job that runs as root inside the container is one container escape from
#   root on your hypervisor. Check what act_runner requires before choosing the
#   uid — 4.4 may constrain this.

# TODO 4.3-11: a verification layer. Run --version for every tool as the last
#   step, so a broken download fails the BUILD rather than the first pipeline
#   that needs it. This is the image's own test and it costs one layer.
