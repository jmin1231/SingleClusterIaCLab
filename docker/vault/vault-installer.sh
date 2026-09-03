#!/usr/bin/env bash
#
# vault-installer.sh - Vault from nothing to configured: TLS, initialised,
# unsealed, with its audit device, KV store and PKI engine.
#
# Usage: sudo ./vault-installer.sh
#
# This used to be two scripts. They were split because the PKI engine emitted a
# CSR that an offline openssl root had to sign, so configuration could not happen
# until Vault was already up. That root is gone - Vault's CA is self-signed now -
# and with it the reason for the split.
#
# The chicken-and-egg that replaces it: Vault needs a certificate to start, and
# Vault is what issues certificates. Resolved in two passes. A self-signed
# certificate gets it listening; once its own PKI exists, it issues itself a real
# one and restarts. TLS is on from the first start either way.
#
# Two things to hold on to: `operator init` mints the storage key once and never
# again, and it cannot live in Vault. And seal is not stop - a restarted Vault is
# running, listening, and answers everything 503.

set -euo pipefail

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

SOURCE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${SOURCE_SCRIPT}/docker-compose.yml"
CERT_DIR="${SOURCE_SCRIPT}/certs"
DATA_DIR="${SOURCE_SCRIPT}/data"
LOGS_DIR="${SOURCE_SCRIPT}/logs"
# Plural: .gitignore and .yamllint both match this name and nothing else.
SECRETS_DIR="${SOURCE_SCRIPT}/secrets"
# Write-once material, kept apart from anything rotatable.
INIT_FILE="${SECRETS_DIR}/vault-init.json"

TLS_CRT="${CERT_DIR}/tls.crt"
TLS_KEY="${CERT_DIR}/tls.key"
BUNDLE="${CERT_DIR}/bundle.crt" # what Vault serves: leaf + chain
CA_CRT="${CERT_DIR}/ca.crt"     # what clients verify against

# NOT the image's 100:1000 - Ubuntu allocates uid 100-999 per package install, so
# on the host it means a different daemon on every machine. 65100 belongs to
# nobody. Must match user: in docker-compose.yml.
VAULT_UID=65100
VAULT_GID=65100

CA_CN="lab.test CA"

[[ ${EUID} -eq 0 ]] || die "vault-installer.sh must be run as root:  sudo $0"

# The host address, discovered rather than written down: it differs per host.
BRIDGE="$(ip -4 addr show cloudbr0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
[[ -n "${BRIDGE}" ]] || die "cloudbr0 has no IPv4 address; is it up?"

# Discovered values only; everything fixed lives in docker-compose.yml and the
# committed vault.hcl. Overwrites, so a re-run corrects a stale address.
printf 'CLOUDBR0_IP=%s\n' "${BRIDGE}" >"${SOURCE_SCRIPT}/.env"
log "Vault will publish on ${BRIDGE}:8200; wrote .env"

# --- a certificate to start with --------------------------------------------
#
# Only when there is none. A self-signed certificate is enough to bring the
# listener up; the real one is issued at the end of this script, once Vault's own
# PKI exists. Guarded because regenerating it on every run would replace a
# Vault-issued certificate with a self-signed one.

install -d -m 0755 "${CERT_DIR}"
if [[ -s "${TLS_CRT}" && -s "${TLS_KEY}" ]]; then
  log "Certificate already present: $(openssl x509 -in "${TLS_CRT}" -noout -issuer | sed 's/^issuer=//')"
else
  log "No certificate yet - generating a self-signed one to get Vault listening"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${TLS_KEY}" -out "${TLS_CRT}" \
    -subj "/O=SingleClusterIaCLab/CN=vault.lab.test" \
    -addext "subjectAltName=DNS:vault.lab.test" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" 2>/dev/null
  # Self-signed, so the leaf is also the chain and also the trust anchor.
  cp "${TLS_CRT}" "${BUNDLE}"
  cp "${TLS_CRT}" "${CA_CRT}"
fi

# --- ownership, before the container ----------------------------------------
#
# Docker creates a missing bind-mount source as root, so a compose up first is a
# failure to repair rather than to prevent.

# 0400: nothing but the container can be 65100, so the narrowest mode is free.
# Certificates stay world-readable - they are public.
chown "${VAULT_UID}:${VAULT_GID}" "${TLS_KEY}"
chmod 0400 "${TLS_KEY}"
chmod 0444 "${TLS_CRT}" "${BUNDLE}" "${CA_CRT}"

# Vault's own state, so Vault owns it.
install -d -o "${VAULT_UID}" -g "${VAULT_GID}" -m 0700 "${DATA_DIR}"

# The audit device's destination, load-bearing in a way data/ is not: Vault STOPS
# SERVING REQUESTS if it cannot write its audit log. The image ships /vault/logs
# owned by its own uid 100, and the `user:` pin skips the entrypoint's chown - so
# without this the mount is unwritable and enabling the device takes Vault down.
install -d -o "${VAULT_UID}" -g "${VAULT_GID}" -m 0700 "${LOGS_DIR}"

# Root only, and created before the one unrepeatable credential is written here.
install -d -o root -g root -m 0700 "${SECRETS_DIR}"

# --remove-orphans: a renamed service otherwise holds 8200, and the bind error
# reads like something else is installed.
log "Starting Vault..."
docker compose -f "${COMPOSE}" up -d --remove-orphans

# --- wait for it to listen ---------------------------------------------------
#
# `compose up -d` returns when the process starts, not when it listens. Any
# status counts - 501 uninitialised and 503 sealed are what init and unseal need
# to find. --resolve because the certificate's only SAN is a name.

log "Waiting for Vault to answer on ${BRIDGE}:8200..."
for ((i = 0; i < 60; i++)); do
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    --cacert "${CA_CRT}" \
    --resolve "vault.lab.test:8200:${BRIDGE}" \
    "https://vault.lab.test:8200/v1/sys/health")" || true
  [[ "${code}" != "000" ]] && break
  sleep 1
done
if [[ "${code}" == "000" ]]; then
  # The answer is almost always in the container's own log, and the likeliest
  # cause is Vault unable to read tls.key - it dies loading its listener.
  echo "Last lines from the container:" >&2
  docker logs vault --tail 20 2>&1 | sed 's/^/    /' >&2 || true
  die "Vault did not answer on ${BRIDGE}:8200 within 60s. See the log above."
fi
log "Vault is answering (HTTP ${code})."

# --- initialise, which happens exactly once ----------------------------------
#
# Four states, from cross-checking Vault against disk: an emptied storage
# directory makes Vault report "uninitialised" exactly as a fresh one does.

# Storage was destroyed under a Vault that existed. Re-minting is made a thing
# you choose rather than one that happens.
if [[ "${code}" == "501" && -e "${INIT_FILE}" ]]; then
  die "${DATA_DIR} was emptied but ${INIT_FILE} remains - that Vault's data is gone. To mint a new one:  sudo rm -f ${INIT_FILE}"
fi

# Works now; comes back sealed with nothing to open it. No repair exists.
if [[ "${code}" != "501" && ! -e "${INIT_FILE}" ]]; then
  die "Vault is initialised but ${INIT_FILE} is gone - it cannot survive a restart. To start over:  docker compose -f ${COMPOSE} down && sudo rm -rf ${DATA_DIR}"
fi

if [[ "${code}" == "501" ]]; then
  log "Initialising Vault. This happens once and cannot be repeated."

  # -T or Compose allocates a TTY and the JSON arrives with control bytes jq
  # rejects and cat hides. 1/1 is the degenerate case of Shamir, not threshold
  # cryptography. umask because `>` creates the file before the command writes.
  (
    umask 077
    docker compose -f "${COMPOSE}" exec -T vault \
      vault operator init -key-shares=1 -key-threshold=1 -format=json \
      >"${INIT_FILE}"
  ) || die "operator init failed."
  chmod 0400 "${INIT_FILE}"

  # Cannot be repeated: once init returned Vault was initialised, and a truncated
  # redirect means the unseal key exists nowhere.
  jq -e '.unseal_keys_b64[0] and .root_token' "${INIT_FILE}" >/dev/null 2>&1 || die "${INIT_FILE} lacks the unseal key or root token, and Vault is initialised - the only path is a fresh init."
  # The path, never the contents: this stdout is read by a person.
  log "Vault initialised. Unseal key and root token: ${INIT_FILE} (the only copy)."
else
  log "Vault is already initialised; leaving it alone."
fi

# Delegated, because the same command has to work after a reboot and in a drill,
# not only during an install.
"${SOURCE_SCRIPT}/scripts/vault-unseal.sh"

# --- configure ---------------------------------------------------------------
#
# Every vault command below is written out in full. -e VAULT_TOKEN with no value
# passes it through from the environment; writing -e VAULT_TOKEN=$TOKEN would put
# the token in argv, where ps shows it to every user on the host.

VAULT_TOKEN="$(jq -r '.root_token // empty' "${INIT_FILE}")"
[[ -n "${VAULT_TOKEN}" ]] || die "${INIT_FILE} holds no root_token."
export VAULT_TOKEN

# --- audit device -----------------------------------------------------------
#
# Enabled first, so everything below is recorded. Vault refuses to serve if its
# only audit device cannot be written, which is the intended behaviour: an
# unauditable Vault should not answer.

if docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault audit list -format=json | jq -e 'has("file/")' >/dev/null; then
  log "Audit device already enabled"
else
  docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
    vault audit enable -path=file file file_path=/vault/logs/audit.log
  log "Audit device enabled at file/"
fi

# --- KV v2 ------------------------------------------------------------------

if docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null; then
  log "KV v2 already mounted at secret/"
else
  docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
    vault secrets enable -path=secret kv-v2
  log "KV v2 mounted at secret/"
fi

# --- PKI --------------------------------------------------------------------
#
# One self-signed CA, issuing leaves directly. There is no tier above it, so
# rotating this CA makes every trust store wrong until it is updated - the
# Ansible base role owns the trust store on every VM, which is what makes that a
# play to re-run rather than a crawl.

if docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault secrets list -format=json | jq -e 'has("pki/")' >/dev/null; then
  log "PKI already mounted at pki/"
else
  docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
    vault secrets enable -path=pki -max-lease-ttl=87600h pki
  log "PKI mounted at pki/"
fi

# `read pki/cert/ca` succeeds only when the mount has an issuer. Without this,
# a second run generates a second CA and the mount starts issuing from whichever
# one is default - which is how you end up with two roots and no idea which
# certificate trusts which.
if docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault read -field=certificate pki/cert/ca >/dev/null 2>&1; then
  log "PKI already has a CA"
else
  docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
    vault write -field=certificate pki/root/generate/internal \
    common_name="lab.test CA" \
    organization="SingleClusterIaCLab" \
    issuer_name="lab-ca" \
    key_type=rsa key_bits=4096 \
    ttl=87600h >/dev/null
  log "Generated the lab's CA inside Vault"
fi

# Where a client fetches the issuer and the CRL. Written every run; overwriting
# with the same values costs nothing.
docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault write pki/config/urls \
  issuing_certificates="https://vault.lab.test:8200/v1/pki/ca" \
  crl_distribution_points="https://vault.lab.test:8200/v1/pki/crl" >/dev/null
log "PKI AIA URLs set"

# What this CA will and will not issue, enforced server-side: a caller cannot ask
# for a name outside lab.test or a lifetime beyond the ceiling, whatever it sends.
docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault write pki/roles/lab-server \
  allowed_domains="lab.test" \
  allow_subdomains=true \
  allow_bare_domains=false \
  allow_localhost=false \
  allow_ip_sans=false \
  organization="SingleClusterIaCLab" \
  key_type=rsa key_bits=2048 \
  server_flag=true client_flag=false \
  key_usage="DigitalSignature,KeyEncipherment" \
  ext_key_usage="ServerAuth" \
  ttl=720h max_ttl=720h >/dev/null
log "PKI role lab-server: *.lab.test, ttl 720h"

# Vault's own serving certificate, which cannot use lab-server: 720h with no
# renewal automation would expire the thing every other service authenticates to.
docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
  vault write pki/roles/lab-vault \
  allowed_domains="lab.test" \
  allow_subdomains=true \
  allow_localhost=false \
  allow_ip_sans=false \
  organization="SingleClusterIaCLab" \
  key_type=rsa key_bits=2048 \
  server_flag=true client_flag=false \
  ttl=8760h max_ttl=8760h >/dev/null
log "PKI role lab-vault: *.lab.test, ttl 8760h"

# --- issue Vault its real certificate ----------------------------------------
#
# The second half of the chicken-and-egg. If Vault is still serving the
# self-signed certificate it started with, replace it with one from its own PKI
# and restart. Guarded on the issuer, so a re-run does not reissue every time.

current_issuer="$(openssl x509 -in "${TLS_CRT}" -noout -issuer | sed 's/.*CN *= *//')"
if [[ "${current_issuer}" == "${CA_CN}" ]]; then
  log "Vault's certificate is already issued by ${CA_CN}"
else
  log "Replacing the self-signed certificate with one from Vault's own PKI"
  issued="$(docker compose -f "${COMPOSE}" exec -T -e VAULT_TOKEN vault \
    vault write -format=json pki/issue/lab-vault common_name=vault.lab.test ttl=8760h)"

  jq -e '.data.certificate and .data.private_key' <<<"${issued}" >/dev/null || die "Vault did not return a usable certificate for itself."

  jq -r '.data.certificate' <<<"${issued}" >"${TLS_CRT}"
  jq -r '.data.certificate, .data.ca_chain[]' <<<"${issued}" >"${BUNDLE}"
  jq -r '.data.issuing_ca' <<<"${issued}" >"${CA_CRT}"
  jq -r '.data.private_key' <<<"${issued}" >"${TLS_KEY}"

  chown "${VAULT_UID}:${VAULT_GID}" "${TLS_KEY}"
  chmod 0400 "${TLS_KEY}"
  chmod 0444 "${TLS_CRT}" "${BUNDLE}" "${CA_CRT}"

  # A restart re-reads the listener config, and comes back sealed.
  docker compose -f "${COMPOSE}" up -d --force-recreate
  "${SOURCE_SCRIPT}/scripts/vault-unseal.sh"
  log "Vault is serving a certificate issued by its own PKI"
fi

log "Vault is up, unsealed and configured. Verify with no -k and no --cacert:"
echo "      curl https://vault.lab.test:8200/v1/sys/seal-status"
echo "    Exit 60 means the CA is not in the host trust store yet."
