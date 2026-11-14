# =====================================================================
# blackhole-vps-bench · 12-cloud.sh — cloud metadata probes (IMDS etc.)
# Pure functions only: sourcing this file has NO side effects.
# cloud_metadata_probe() is called from gather_info (20-info.sh) when the
# network is allowed; every request is capped at 2 seconds.
# Rule: metadata NEVER overrides a different DMI-derived cloud verdict —
# it only fills an empty BH_CLOUD or refreshes the same family.
# =====================================================================
# shellcheck shell=bash

# Internal: curl with a hard 2s budget, silent on any error.
bh_meta_curl() { # bh_meta_curl <curl args incl. URL>
  curl -fsS --max-time 2 "$@" 2>/dev/null
}

# Internal: fill BH_CLOUD from a metadata result without ever overriding a
# different DMI-derived verdict. Same-family fills just refresh the detail.
bh_meta_fill() { # bh_meta_fill <cloud-name> <detail>
  local cloud="$1" detail="${2:-}"
  case "$BH_CLOUD" in
    "")       BH_CLOUD="$cloud"
              if [ -n "$detail" ]; then BH_CLOUD_DETAIL="$detail"; fi
              BH_CLOUD_METHOD="metadata"
              ;;
    "$cloud") if [ -n "$detail" ]; then BH_CLOUD_DETAIL="$detail"; fi
              BH_CLOUD_METHOD="metadata"
              ;;
    *)        : ;;   # DMI already identified another cloud — leave it alone
  esac
}

# AWS IMDSv2: PUT a session token, then read instance-id / instance-type.
bh_probe_aws() {
  local token iid itype detail=""
  token="$(bh_meta_curl -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
  [ -n "$token" ] || return 0
  iid="$(bh_meta_curl -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)"
  itype="$(bh_meta_curl -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-type)"
  if [ -n "$itype" ]; then detail="$itype"; fi
  if [ -n "$iid" ]; then detail="${detail:+$detail }($iid)"; fi
  bh_meta_fill "AWS EC2" "$detail"
  # IMDSv2 answers on Nitro in practice; DMI keeps authority over Xen evidence
  if [ -z "$BH_AWS_GEN" ]; then BH_AWS_GEN="nitro"; fi
}

# Azure IMDS: instance/compute JSON (requires the Metadata:true header).
bh_probe_azure() {
  local json vmsize zone detail
  json="$(bh_meta_curl -H 'Metadata:true' 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01')"
  [ -n "$json" ] || return 0
  vmsize="$(printf '%s' "$json" | sed -n 's/.*"vmSize"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  zone="$(printf '%s' "$json" | sed -n 's/.*"zone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$vmsize" ] || return 0
  detail="$vmsize"
  if [ -n "$zone" ]; then detail="$detail (zone $zone)"; fi
  bh_meta_fill "Microsoft Azure" "$detail"
}

# GCP metadata server (its DNS name only resolves inside GCP).
bh_probe_gcp() {
  local mt
  mt="$(bh_meta_curl -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/machine-type' | awk -F/ '{print $NF}')"
  [ -n "$mt" ] || return 0
  bh_meta_fill "Google Cloud" "$mt"
}

# OCI requires the well-known 'Authorization: Bearer Oracle' header.
bh_probe_oci() {
  local raw region
  raw="$(bh_meta_curl -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/)"
  [ -n "$raw" ] || return 0
  region="$(printf '%s' "$raw" | grep -o '"region"[^,]*' | head -n 1 | sed -n 's/.*"\([^"]*\)"$/\1/p')"
  bh_meta_fill "Oracle Cloud (OCI)" "$region"
}

# Alibaba uses its own metadata IP instead of the link-local address.
bh_probe_ali() {
  local it
  it="$(bh_meta_curl http://100.100.100.200/latest/meta-data/instance/instance-type)"
  [ -n "$it" ] || return 0
  bh_meta_fill "Alibaba Cloud" "$it"
}

# DigitalOcean legacy v1 metadata (plain HTTP, no auth).
bh_probe_do() {
  local host region detail
  host="$(bh_meta_curl http://169.254.169.254/metadata/v1/hostname)"
  region="$(bh_meta_curl http://169.254.169.254/metadata/v1/region)"
  if [ -z "$host" ] && [ -z "$region" ]; then return 0; fi
  if [ -n "$host" ] && [ -n "$region" ]; then
    detail="$host ($region)"
  elif [ -n "$region" ]; then
    detail="$region"
  else
    detail="$host"
  fi
  bh_meta_fill "DigitalOcean" "$detail"
}

# Tencent serves metadata via a DNS name that only resolves inside their VPC.
bh_probe_tencent() {
  local it
  it="$(bh_meta_curl http://metadata.tencentyun.com/latest/meta-data/instance-type)"
  [ -n "$it" ] || return 0
  bh_meta_fill "Tencent Cloud" "$it"
}

# Best-effort cloud metadata probes. Guarded:
#   - skipped entirely when BH_NO_NET=1 or curl is missing
#   - vendor-hinted probes only: DMI tells us which endpoint is worth trying
#   - last-resort generic: when DMI found nothing at all, try the two most
#     common unambiguous endpoints (AWS IMDSv2 token, Tencent) before giving up
cloud_metadata_probe() {
  [ "$BH_NO_NET" = "1" ] && return 0
  command_exists curl || return 0

  local hinted=0
  case "$BH_DMI_VENDOR" in
    "Amazon EC2")            bh_probe_aws;     hinted=1 ;;
    "Microsoft Corporation") bh_probe_azure;   hinted=1 ;;
    Google)                  bh_probe_gcp;     hinted=1 ;;
    "Oracle Corporation")    bh_probe_oci;     hinted=1 ;;
    Alibaba*)                bh_probe_ali;     hinted=1 ;;
    DigitalOcean)            bh_probe_do;      hinted=1 ;;
    Tencent*)                bh_probe_tencent; hinted=1 ;;
  esac

  if [ "$hinted" = "0" ] && [ -z "$BH_CLOUD" ]; then
    bh_probe_aws
    if [ -z "$BH_CLOUD" ]; then bh_probe_tencent; fi
  fi
}

# Deprecated alias kept for compatibility with the old 20-info call site.
probe_cloud_meta() { cloud_metadata_probe; }
