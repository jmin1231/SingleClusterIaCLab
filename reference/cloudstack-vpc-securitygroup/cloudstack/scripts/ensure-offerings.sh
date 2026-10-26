#!/usr/bin/env sh
set -eu

# ensure-offerings.sh - ensure the CloudStack VPC, network, and service offerings
# exist and are enabled (VPC/tier offerings serve UserData via ConfigDrive).

CLOUDSTACK_API_URL="${CLOUDSTACK_API_URL:-http://127.0.0.1:8080/client/api}"
CLOUDSTACK_API_KEY="${CLOUDSTACK_API_KEY:-}"
CLOUDSTACK_SECRET_KEY="${CLOUDSTACK_SECRET_KEY:-}"
CS_USERNAME="${CS_USERNAME:-admin}"
CS_PASSWORD="${CS_PASSWORD:-password}"
CLOUDSTACK_ZONE="${CLOUDSTACK_ZONE:-Zone1}"
CMK_TIMEOUT_SECONDS="${CMK_TIMEOUT_SECONDS:-120}"
JOB_WAIT_SECONDS="${JOB_WAIT_SECONDS:-600}"

# Service-offering shape, overridable via env for single-host all-in-one CloudStack.
SERVICE_OFFERING_CPU_NUMBER="${SERVICE_OFFERING_CPU_NUMBER:-4}"
SERVICE_OFFERING_CPU_SPEED="${SERVICE_OFFERING_CPU_SPEED:-2000}"
SERVICE_OFFERING_MEMORY_MB="${SERVICE_OFFERING_MEMORY_MB:-8192}"
SERVICE_OFFERING_ROOT_DISK_GB="${SERVICE_OFFERING_ROOT_DISK_GB:-80}"
SERVICE_OFFERING_STORAGE_TYPE="${SERVICE_OFFERING_STORAGE_TYPE:-shared}"
SERVICE_OFFERING_OFFER_HA="${SERVICE_OFFERING_OFFER_HA:-true}"

log() {
  printf '[offerings] %s\n' "$*"
}

die() {
  printf '[offerings] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Run a cmk command, returning its JSON on stdout (stderr kept separate so a stray warning never corrupts the JSON).
cmk_json() {
  err="$(mktemp)"
  output="$(timeout "$CMK_TIMEOUT_SECONDS" cmk -o json "$@" 2>"$err")" || {
    rc=$?
    cat "$err" >&2
    rm -f "$err"
    [ "$rc" -eq 124 ] && die "cmk $* timed out after ${CMK_TIMEOUT_SECONDS}s"
    return 1
  }
  rm -f "$err"

  if [ -z "$output" ]; then
    printf '{}\n'
    return 0
  fi

  printf '%s\n' "$output" | jq -e . >/dev/null || {
    printf 'cmk %s returned non-JSON output:\n%s\n' "$*" "$output" >&2
    return 1
  }

  printf '%s\n' "$output"
}

# Poll an async CloudStack job until it completes, failing on job error or timeout.
wait_for_job() {
  job_id="$1"
  label="$2"
  start=$(date +%s)

  while :; do
    response=$(cmk_json query asyncjobresult jobid="$job_id")
    status=$(printf '%s\n' "$response" | jq -r '.jobstatus // empty')

    case "$status" in
    1)
      printf '%s\n' "$response"
      return 0
      ;;
    2)
      message=$(printf '%s\n' "$response" | jq -r '.jobresult.errortext // .jobresult.errorText // .jobresult | tostring')
      die "$label failed: $message"
      ;;
    esac

    if [ "$(($(date +%s) - start))" -ge "$JOB_WAIT_SECONDS" ]; then
      die "$label did not finish within ${JOB_WAIT_SECONDS}s"
    fi

    sleep 5
  done
}

# Block on an async cmk response when it carries a jobid; synchronous responses return immediately.
wait_for_async_response() {
  response="$1"
  label="$2"
  job_id=$(printf '%s\n' "$response" | jq -r '.jobid // empty')
  if [ -n "$job_id" ]; then
    wait_for_job "$job_id" "$label" >/dev/null
  fi
}

configure_cmk() {
  cmk set url "$CLOUDSTACK_API_URL" >/dev/null
  if [ -n "$CLOUDSTACK_API_KEY" ] && [ -n "$CLOUDSTACK_SECRET_KEY" ]; then
    log "Authenticating cmk with API key/secret."
    cmk set apikey "$CLOUDSTACK_API_KEY" >/dev/null
    cmk set secretkey "$CLOUDSTACK_SECRET_KEY" >/dev/null
  else
    log "No API keys provided; falling back to username/password auth."
    cmk set username "$CS_USERNAME" >/dev/null
    cmk set password "$CS_PASSWORD" >/dev/null
  fi
  cmk set output json >/dev/null
  timeout "$CMK_TIMEOUT_SECONDS" cmk sync >/dev/null
}

resolve_zone_id() {
  cmk_json list zones |
    jq -r --arg ref "$CLOUDSTACK_ZONE" '.zone[]? | select(.id == $ref or .name == $ref) | .id' |
    head -n 1
}

# Enable the VpcVirtualRouter service provider and its element in the zone.
enable_vpc_virtual_router() {
  physical_network_id=$(cmk_json list physicalnetworks zoneid="$ZONE_ID" |
    jq -r '.physicalnetwork[0].id // empty')
  [ -n "$physical_network_id" ] || die "could not resolve physical network in zone $CLOUDSTACK_ZONE"

  provider_id=$(cmk_json list networkserviceproviders physicalnetworkid="$physical_network_id" name=VpcVirtualRouter |
    jq -r '.networkserviceprovider[0].id // empty')
  [ -n "$provider_id" ] || die "could not resolve VpcVirtualRouter provider"

  element_id=$(cmk_json list virtualrouterelements nspid="$provider_id" |
    jq -r '.virtualrouterelement[0].id // empty')
  if [ -n "$element_id" ]; then
    response=$(cmk_json configure virtualrouterelement id="$element_id" enabled=true)
    wait_for_async_response "$response" "enable VpcVirtualRouter element"
  fi

  response=$(cmk_json update networkserviceprovider id="$provider_id" state=Enabled)
  wait_for_async_response "$response" "enable VpcVirtualRouter provider"
}

find_vpc_offering_id() {
  cmk_json list vpcofferings name="$VPC_OFFERING_NAME" |
    jq -r --arg name "$VPC_OFFERING_NAME" '.vpcoffering[]? | select(.name == $name) | .id' |
    head -n 1
}

find_network_offering_id() {
  cmk_json list networkofferings name="$NETWORK_OFFERING_NAME" |
    jq -r --arg name "$NETWORK_OFFERING_NAME" '.networkoffering[]? | select(.name == $name) | .id' |
    head -n 1
}

find_service_offering_id() {
  cmk_json list serviceofferings name="$SERVICE_OFFERING_NAME" |
    jq -r --arg name "$SERVICE_OFFERING_NAME" '.serviceoffering[]? | select(.name == $name) | .id' |
    head -n 1
}

ensure_vpc_offering() {
  [ -n "${VPC_OFFERING_NAME:-}" ] || return 0

  vpc_offering_id=$(find_vpc_offering_id)
  if [ -z "$vpc_offering_id" ]; then
    log "Creating VPC offering $VPC_OFFERING_NAME"
    response=$(cmk_json create vpcoffering \
      name="$VPC_OFFERING_NAME" \
      displaytext="$VPC_OFFERING_NAME" \
      supportedservices=SourceNat,StaticNat,PortForwarding,NetworkACL,Dns,Dhcp,UserData \
      'serviceproviderlist[0].service=SourceNat' \
      'serviceproviderlist[0].provider=VpcVirtualRouter' \
      'serviceproviderlist[1].service=StaticNat' \
      'serviceproviderlist[1].provider=VpcVirtualRouter' \
      'serviceproviderlist[2].service=PortForwarding' \
      'serviceproviderlist[2].provider=VpcVirtualRouter' \
      'serviceproviderlist[3].service=NetworkACL' \
      'serviceproviderlist[3].provider=VpcVirtualRouter' \
      'serviceproviderlist[4].service=Dns' \
      'serviceproviderlist[4].provider=VpcVirtualRouter' \
      'serviceproviderlist[5].service=Dhcp' \
      'serviceproviderlist[5].provider=VpcVirtualRouter' \
      'serviceproviderlist[6].service=UserData' \
      'serviceproviderlist[6].provider=ConfigDrive')
    wait_for_async_response "$response" "create VPC offering $VPC_OFFERING_NAME"
    vpc_offering_id=$(find_vpc_offering_id)
  else
    log "Using existing VPC offering $VPC_OFFERING_NAME"
  fi

  [ -n "$vpc_offering_id" ] || die "VPC offering $VPC_OFFERING_NAME not found after ensure"
  # Re-assert Enabled on both paths (create leaves offerings Disabled by default).
  response=$(cmk_json update vpcoffering id="$vpc_offering_id" state=Enabled)
  wait_for_async_response "$response" "enable VPC offering $VPC_OFFERING_NAME"
}

# Ensure the VPC network offering exists and is enabled, serving UserData via ConfigDrive (not the VR).
# why UserData must be ConfigDrive and not VirtualRouter (cloud-init pre-network race).
ensure_network_offering() {
  [ -n "${NETWORK_OFFERING_NAME:-}" ] || return 0

  network_offering_id=$(find_network_offering_id)
  if [ -z "$network_offering_id" ]; then
    log "Creating network offering $NETWORK_OFFERING_NAME"
    response=$(cmk_json create networkoffering \
      name="$NETWORK_OFFERING_NAME" \
      displaytext="$NETWORK_OFFERING_NAME" \
      traffictype=GUEST \
      guestiptype=Isolated \
      forvpc=true \
      egressdefaultpolicy=false \
      supportedservices=SourceNat,StaticNat,PortForwarding,Dhcp,Dns,UserData,NetworkACL \
      'serviceproviderlist[0].service=SourceNat' \
      'serviceproviderlist[0].provider=VpcVirtualRouter' \
      'serviceproviderlist[1].service=StaticNat' \
      'serviceproviderlist[1].provider=VpcVirtualRouter' \
      'serviceproviderlist[2].service=PortForwarding' \
      'serviceproviderlist[2].provider=VpcVirtualRouter' \
      'serviceproviderlist[3].service=Dhcp' \
      'serviceproviderlist[3].provider=VpcVirtualRouter' \
      'serviceproviderlist[4].service=Dns' \
      'serviceproviderlist[4].provider=VpcVirtualRouter' \
      'serviceproviderlist[5].service=UserData' \
      'serviceproviderlist[5].provider=ConfigDrive' \
      'serviceproviderlist[6].service=NetworkACL' \
      'serviceproviderlist[6].provider=VpcVirtualRouter')
    wait_for_async_response "$response" "create network offering $NETWORK_OFFERING_NAME"
    network_offering_id=$(find_network_offering_id)
  else
    log "Using existing network offering $NETWORK_OFFERING_NAME"
  fi

  [ -n "$network_offering_id" ] || die "network offering $NETWORK_OFFERING_NAME not found after ensure"
  # Network offerings are created Disabled; enable on both paths.
  response=$(cmk_json update networkoffering id="$network_offering_id" state=Enabled)
  wait_for_async_response "$response" "enable network offering $NETWORK_OFFERING_NAME"
}

ensure_service_offering() {
  [ -n "${SERVICE_OFFERING_NAME:-}" ] || return 0

  service_offering_id=$(find_service_offering_id)
  if [ -n "$service_offering_id" ]; then
    log "Using existing service offering $SERVICE_OFFERING_NAME"
    return 0
  fi

  log "Creating service offering $SERVICE_OFFERING_NAME"
  response=$(cmk_json create serviceoffering \
    name="$SERVICE_OFFERING_NAME" \
    displaytext="${SERVICE_OFFERING_CPU_NUMBER} vCPU, $((SERVICE_OFFERING_MEMORY_MB / 1024))GB RAM, ${SERVICE_OFFERING_ROOT_DISK_GB}GB root disk" \
    cpunumber="$SERVICE_OFFERING_CPU_NUMBER" \
    cpuspeed="$SERVICE_OFFERING_CPU_SPEED" \
    memory="$SERVICE_OFFERING_MEMORY_MB" \
    rootdisksize="$SERVICE_OFFERING_ROOT_DISK_GB" \
    storagetype="$SERVICE_OFFERING_STORAGE_TYPE" \
    offerha="$SERVICE_OFFERING_OFFER_HA")
  wait_for_async_response "$response" "create service offering $SERVICE_OFFERING_NAME"
}

main() {
  need_cmd cmk
  need_cmd jq
  need_cmd timeout
  need_cmd mktemp

  if [ -z "${VPC_OFFERING_NAME:-}" ] && [ -z "${NETWORK_OFFERING_NAME:-}" ] && [ -z "${SERVICE_OFFERING_NAME:-}" ]; then
    exit 0
  fi

  configure_cmk
  ZONE_ID=$(resolve_zone_id)
  [ -n "$ZONE_ID" ] || die "could not resolve zone $CLOUDSTACK_ZONE"

  enable_vpc_virtual_router
  ensure_vpc_offering
  ensure_network_offering
  ensure_service_offering
}

main "$@"
