#!/usr/bin/env bash
#
# cloudstack-install-all.sh - CloudStack all-in-one on Ubuntu 24.04.
#
# Usage: sudo ./cloudstack-install-all.sh
#
# Lays a bootstrap resolver floor, seeds the apt repository, prepares the KVM
# host, installs cmk, runs the vendored installer unattended, then disables
# bridge netfilter and verifies it.
#
# scripts/cloudstack-install.sh stays a separate file on purpose: it is upstream
# code we have modified but do not maintain line by line, and the Makefile
# excludes it from lint and fmt so the diff against upstream stays readable.
#
# Safe to re-run - each step is a no-op once its work is done.
#
# LAB ONLY. This rewrites host networking and opens root + password SSH.

set -euo pipefail

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CS_INSTALLER="${SOURCE_SCRIPT}/scripts/cloudstack-install.sh"

export ROOT_PASSWORD="${ROOT_PASSWORD:-password}"
export CLOUDSTACK_UNATTENDED=1

# Matches the vendored installer's own DNS default.
BOOTSTRAP_DNS="${BOOTSTRAP_DNS:-8.8.8.8}"
# Sorts below CoreDNS's 10-lab.conf, which retires it.
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/05-cloudstack-bootstrap.conf"

# The installer's own default, 4.22, is broken upstream.
CS_REPO_VERSION="${CS_REPO_VERSION:-4.21}"
CS_REPO_URL="${CS_REPO_URL:-https://download.cloudstack.org/ubuntu}"
CS_KEYRING="/etc/apt/keyrings/cloudstack.gpg"
CS_LIST="/etc/apt/sources.list.d/cloudstack.list"

SSHD_DROPIN="/etc/ssh/sshd_config.d/01-cloudstack.conf"
CMK_VERSION="${CMK_VERSION:-6.5.0}"

# Set to false for runs that do not use local KVM bridges. Any other value is an
# error, not a silent skip.
CHECK_BRIDGE_NETFILTER="${CHECK_BRIDGE_NETFILTER:-true}"

# apt-get waits for the dpkg lock rather than dying on it. Common on a host's
# first boots, when unattended-upgrades is still running.
APT="apt-get -o DPkg::Lock::Timeout=300"

[[ ${EUID} -eq 0 ]] || {
  echo "cloudstack-install-all.sh must be run as root:  sudo $0" >&2
  exit 1
}

# Resolved before anything runs. Step 3 sets the root password and opens SSH, so
# a wrong path has to stop us here, while the host is still untouched.
[[ -x "${CS_INSTALLER}" ]] || {
  echo "Missing or not executable: ${CS_INSTALLER}" >&2
  exit 1
}

# --- Step 1/6 · the bootstrap resolver floor --------------------------------
#
# systemd-resolved needs a global resolver for the window in which the installer
# rebuilds host networking and no link yet supplies DNS. Removed by
# coredns-installer.sh.

echo "[+] Step 1/6: installing the bootstrap resolver floor..."
if systemctl is-active --quiet systemd-resolved; then
  mkdir -p "$(dirname "${RESOLVED_DROPIN}")"
  cat >"${RESOLVED_DROPIN}" <<EOF
# Written by cloudstack-install-all.sh; removed by coredns-installer.sh.
[Resolve]
DNS=${BOOTSTRAP_DNS}
EOF
  chmod 644 "${RESOLVED_DROPIN}"
  systemctl restart systemd-resolved || {
    echo "Failed to restart systemd-resolved after writing ${RESOLVED_DROPIN}." >&2
    exit 1
  }
  # Assert on resolution, not on the file: ask for the name the installer fetches.
  resolvectl query download.cloudstack.org >/dev/null 2>&1 || {
    echo "Wrote ${RESOLVED_DROPIN} but download.cloudstack.org still does not resolve. The host has no working DNS or no route out. Check 'resolvectl status' and that ${BOOTSTRAP_DNS} is reachable." >&2
    exit 1
  }
  echo "[+] Resolver floor in place: global DNS=${BOOTSTRAP_DNS}"
else
  echo "[!] systemd-resolved is not active; skipping the resolver floor. If the installer fails to resolve download.cloudstack.org right after configuring cloudbr0, this is why." >&2
fi

# --- Step 2/6 · the apt repository ------------------------------------------
#
# Seeding the list file is how the installer's silent-mode path lets us pin the
# version without patching the vendored file.

echo "[+] Step 2/6: seeding the CloudStack apt repository..."
codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
keytmp="$(mktemp)"
trap 'rm -f "${keytmp}"' EXIT

curl -fsS "${CS_REPO_URL%/ubuntu}/release.asc" | gpg --dearmor >"${keytmp}" || {
  echo "Could not fetch or dearmour the CloudStack signing key. Check DNS and outbound HTTPS." >&2
  exit 1
}
[[ -s "${keytmp}" ]] || {
  echo "The CloudStack signing key dearmoured to an empty file; refusing to install it." >&2
  exit 1
}
install -D -m 0644 "${keytmp}" "${CS_KEYRING}"
printf 'deb [signed-by=%s] %s %s %s\n' \
  "${CS_KEYRING}" "${CS_REPO_URL}" "${codename}" "${CS_REPO_VERSION}" >"${CS_LIST}"
echo "[+] Seeded ${CS_LIST} -> ${codename} ${CS_REPO_VERSION}"

# Prove the repo yields an installable package before the installer runs on it.
${APT} update >/dev/null || {
  echo "apt-get update failed against ${CS_LIST}. A size or hash mismatch means component ${CS_REPO_VERSION} is broken upstream - try CS_REPO_VERSION=4.xx." >&2
  exit 1
}
# Captured, not piped: `| grep -q` under pipefail reports 141 on a match. Match a
# digit, because an unavailable package prints `Candidate: (none)`.
policy="$(apt-cache policy cloudstack-management 2>/dev/null || true)"
grep -qE 'Candidate: [0-9]' <<<"${policy}" || {
  echo "The repository updated but cloudstack-management has no installation candidate; ${CS_REPO_VERSION} may not publish for ${codename}." >&2
  exit 1
}
echo "[+] CloudStack repo ready: $(awk '/Candidate:/{print $2}' <<<"${policy}")"

# --- Step 3/6 · prepare the KVM host ----------------------------------------
#
# CloudStack adds hosts over SSH even when the host is itself, which is why an
# all-in-one install needs root + password SSH.
#
# LAB ONLY. Root login with a password is a real hole, opened deliberately.
# Close it with:
#   sudo rm /etc/ssh/sshd_config.d/01-cloudstack.conf && sudo systemctl restart ssh

echo "[+] Step 3/6: preparing the KVM host..."
if ! dpkg -s openssh-server >/dev/null 2>&1; then
  echo "[+] Installing openssh-server..."
  ${APT} update || {
    echo "apt-get update failed." >&2
    exit 1
  }
  # --force-confnew: take the package's canonical sshd_config.
  ${APT} install -y -o Dpkg::Options::=--force-confnew openssh-server || {
    echo "Failed to install openssh-server." >&2
    exit 1
  }
fi

printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd || {
  echo "Failed to set root password." >&2
  exit 1
}

grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config || {
  echo "sshd_config has no Include for sshd_config.d/ - the drop-in would be ignored." >&2
  exit 1
}
cat >"${SSHD_DROPIN}" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
chmod 644 "${SSHD_DROPIN}"
systemctl restart ssh || {
  echo "Failed to restart ssh." >&2
  exit 1
}

# Assert on what sshd concluded, not on the file we wrote. `sshd -T` prints the
# effective config after every drop-in is merged, and it uses the FIRST value it
# obtains for each keyword - so a lower-numbered drop-in silently outranks ours.
effective="$(sshd -T 2>/dev/null)" || {
  echo "sshd -T failed; the config is invalid." >&2
  exit 1
}
for directive in "permitrootlogin yes" "passwordauthentication yes"; do
  grep -qi "^${directive}$" <<<"${effective}" || {
    echo "sshd reports '${directive%% *}' is not '${directive##* }'. Check that sshd_config Includes sshd_config.d/, and that no drop-in sorting before ${SSHD_DROPIN##*/} overrides it." >&2
    exit 1
  }
done
echo "[+] Host prepared: root + password SSH enabled"

# --- Step 4/6 · cloudmonkey --------------------------------------------------
#
# Only the install. Minting API keys with cmk lives in
# docker/vault/scripts/vault-ensure-cloudstack.sh, beside the code that stores
# them - this script runs before Vault exists.

echo "[+] Step 4/6: installing cloudmonkey..."
if command -v cmk >/dev/null 2>&1; then
  echo "[+] Cloudmonkey already installed"
else
  case "$(uname -m)" in
  x86_64 | amd64) arch="x86-64" ;;
  aarch64 | arm64) arch="arm64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
  esac
  cmktmp="$(mktemp)"
  curl -fSL "https://github.com/apache/cloudstack-cloudmonkey/releases/download/${CMK_VERSION}/cmk.linux.${arch}" \
    -o "${cmktmp}" || {
    echo "Failed to download CloudMonkey ${CMK_VERSION}." >&2
    rm -f "${cmktmp}"
    exit 1
  }
  install -m 0755 "${cmktmp}" /usr/local/bin/cmk
  rm -f "${cmktmp}"
  echo "[+] CloudMonkey ${CMK_VERSION} installed"
fi

# --- Step 5/6 · the vendored installer ---------------------------------------

echo "[+] Step 5/6: running the vendored CloudStack installer..."
"${CS_INSTALLER}"

# --- Step 6/6 · bridge netfilter ---------------------------------------------
#
# With bridge netfilter on, iptables sees bridged frames and CloudStack's VPC
# port forwards drop them SILENTLY - no error, no log entry, packets simply
# vanish. That invisibility is why this is checked rather than assumed, and why
# it is worth re-checking before anything that depends on VPC networking.

echo "[+] Step 6/6: disabling KVM bridge netfilter..."
cat >/etc/sysctl.d/99-cloudstack-bridge.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF
sysctl -p /etc/sysctl.d/99-cloudstack-bridge.conf >/dev/null 2>&1 || true

case "${CHECK_BRIDGE_NETFILTER}" in
true)
  # No br_netfilter module means no bridge netfilter, which is the state we
  # want. An absent directory is therefore a pass, not a failure.
  if [[ -d /proc/sys/net/bridge ]]; then
    enabled=""
    for path in \
      /proc/sys/net/bridge/bridge-nf-call-iptables \
      /proc/sys/net/bridge/bridge-nf-call-ip6tables \
      /proc/sys/net/bridge/bridge-nf-call-arptables; do
      [[ -f "${path}" ]] || continue
      if [[ "$(cat "${path}")" == "1" ]]; then
        enabled="${enabled:+${enabled} }${path#/proc/sys/}"
      fi
    done
    [[ -z "${enabled}" ]] || {
      echo "KVM bridge netfilter is still enabled (${enabled}). Disable these host sysctls before relying on VPC networking, or set CHECK_BRIDGE_NETFILTER=false." >&2
      exit 1
    }
  fi
  echo "[+] Bridge netfilter is disabled."
  ;;
false) echo "[+] CHECK_BRIDGE_NETFILTER=false - skipping the bridge netfilter check." ;;
*)
  echo "CHECK_BRIDGE_NETFILTER must be 'true' or 'false', got '${CHECK_BRIDGE_NETFILTER}'." >&2
  exit 1
  ;;
esac

echo "[+] CloudStack all-in-one setup complete."
