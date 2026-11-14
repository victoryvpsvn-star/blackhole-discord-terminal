# =====================================================================
# blackhole-vps-bench · 12-cloud.sh — cloud metadata probes (IMDS etc.)
# Pure functions only: sourcing this file has NO side effects.
# cloud_metadata_probe() is called from gather_info (20-info.sh) when the
# network is allowed. Request budgets: DMI-hinted probes use 2s per
# request; the generic fallback sweep (hidden/unknown DMI) fires all
# provider probes in PARALLEL at 1s per request — worst-case wall time is
# ~3s (AWS token + instance-id + instance-type), inside the 4s total
# metadata budget.
# Rules:
#   - metadata NEVER overrides a different DMI-derived cloud verdict —
#     it only fills an empty BH_CLOUD or refreshes the same family;
#   - BH_AWS_GEN is derived ONLY from DMI product / instance-type evidence
#     (see bh_probe_aws) — never from "an IMDSv2 token succeeded": Xen-
#     generation EC2 instances serve IMDSv2 just like Nitro ones;
#   - PRIVACY: with BH_REDACT=1, BH_CLOUD_DETAIL keeps provider/region/size
#     evidence only — instance ids, hostnames and tenancy OCID strings are
#     never fetched into the detail (stripped at composition time).
# =====================================================================
# shellcheck shell=bash

# ---------------------------------------------------------------------
# State & flags — no new BH_* globals are introduced by this module. It
# only SETS detection globals owned by 10-detect.sh (BH_CLOUD,
# BH_CLOUD_DETAIL, BH_CLOUD_METHOD, BH_AWS_GEN) and READS the run-mode
# flags BH_NO_NET (00-core.sh) and BH_REDACT (privacy switch: unset or 0
# = off, 1 = keep only provider/region/size in BH_CLOUD_DETAIL).
# ---------------------------------------------------------------------

# Internal: curl with a caller-chosen per-request budget, silent on any
# error, and a hard silent skip when BH_NO_NET=1. EVERY network-capable
# helper in this module funnels through here.
bh_meta_curl_cap() { # bh_meta_curl_cap <seconds> <curl args incl. URL>
  [ "${BH_NO_NET:-0}" = "1" ] && return 0
  local cap="$1"; shift
  curl -fsS --max-time "$cap" "$@" 2>/dev/null
}

# Internal budgets: 2s for DMI-hinted probes, 1s for the generic sweep.
bh_meta_curl()  { bh_meta_curl_cap 2 "$@"; }
bh_meta_curl1() { bh_meta_curl_cap 1 "$@"; }

# PRIVACY switch: returns 0 (true) when BH_REDACT=1 was requested.
bh_redact_on() { [ "${BH_REDACT:-0}" = "1" ]; }

# Internal: append one generic-sweep result record "cloud|detail|gen".
# Pipes are stripped so a hostile metadata answer cannot forge extra fields.
bh_probe_record() { # bh_probe_record <file> <cloud> <detail> [aws_gen]
  [ -n "$1" ] || return 0
  local d="${3:-}" g="${4:-}"
  d=${d//|/ }
  g=${g//|/ }
  printf '%s|%s|%s\n' "$2" "$d" "$g" >> "$1"
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
# bh_probe_aws [record-file]
#   no record-file — hinted mode (2s caps): fills BH_CLOUD/BH_CLOUD_DETAIL
#                    and derives BH_AWS_GEN from DMI/instance-type evidence.
#   record-file    — generic-sweep mode (1s caps): appends one result record.
#
# BUG G6 fix — BH_AWS_GEN derivation. A successful IMDSv2 token does NOT
# identify the hypervisor generation: Xen-generation EC2 instances serve
# IMDSv2 too. The generation is therefore derived ONLY from DMI product /
# instance-type evidence, never from "IMDSv2 answered", and it never
# overrides a verdict already made by 10-detect.sh (classify_aws, which
# owns the DMI vendor='Amazon EC2' case and runs before any metadata probe):
#   DMI product contains "HVM domU"   -> xen
#   instance type matches *.metal     -> metal (bare metal; classify_aws
#                                        reports the same DMI evidence as
#                                        'nitro' when it sees the product)
#   DMI vendor QEMU + EC2-style type  -> nitro (Nitro guests are KVM/QEMU;
#                                        EC2-style = lowercase family.type,
#                                        e.g. m5.large / t3.micro)
#   otherwise                         -> "" (unknown, left empty on purpose)
bh_probe_aws() { # bh_probe_aws [record-file]
  local out="${1:-}" cap=2
  [ -n "$out" ] && cap=1
  local token iid="" itype detail="" gen=""
  token="$(bh_meta_curl_cap "$cap" -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
  [ -n "$token" ] || return 0
  # PRIVACY: with BH_REDACT=1 the instance-id is not even fetched — it can
  # never leak into BH_CLOUD_DETAIL.
  if ! bh_redact_on; then
    iid="$(bh_meta_curl_cap "$cap" -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)"
  fi
  itype="$(bh_meta_curl_cap "$cap" -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-type)"
  if [ -n "$itype" ]; then detail="$itype"; fi
  if [ -n "$iid" ]; then detail="${detail:+$detail }($iid)"; fi
  if [ -z "${BH_AWS_GEN:-}" ]; then
    case "${BH_DMI_PRODUCT:-}" in
      *"HVM domU"*) gen="xen" ;;
      *)
        case "$itype" in
          *.metal) gen="metal" ;;
          *)
            if [ "${BH_DMI_VENDOR:-}" = "QEMU" ]; then
              case "$itype" in
                [a-z]*.[a-z]*) gen="nitro" ;;
              esac
            fi
            ;;
        esac
        ;;
    esac
  fi
  if [ -n "$out" ]; then
    bh_probe_record "$out" "AWS EC2" "$detail" "$gen"
    return 0
  fi
  bh_meta_fill "AWS EC2" "$detail"
  if [ -n "$gen" ]; then BH_AWS_GEN="$gen"; fi
}

# Azure IMDS.
#   hinted mode (no record file, 2s cap): instance/compute JSON; only
#     vmSize + zone are extracted — no subscription/tenant fields.
#   sweep mode (record file, 1s caps): the dedicated location / vmSize text
#     endpoints — stores region + size only.
bh_probe_azure() { # bh_probe_azure [record-file]
  local out="${1:-}" cap=2
  [ -n "$out" ] && cap=1
  local detail=""
  if [ -n "$out" ]; then
    local loc vmsize
    loc="$(bh_meta_curl_cap "$cap" -H 'Metadata: true' 'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text')"
    vmsize="$(bh_meta_curl_cap "$cap" -H 'Metadata: true' 'http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text')"
    [ -n "$loc" ] || [ -n "$vmsize" ] || return 0
    if [ -n "$vmsize" ] && [ -n "$loc" ]; then detail="$vmsize ($loc)"
    elif [ -n "$vmsize" ]; then detail="$vmsize"
    else detail="$loc"
    fi
    bh_probe_record "$out" "Microsoft Azure" "$detail"
    return 0
  fi
  local json vmsize zone
  json="$(bh_meta_curl_cap "$cap" -H 'Metadata:true' 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01')"
  [ -n "$json" ] || return 0
  vmsize="$(printf '%s' "$json" | sed -n 's/.*"vmSize"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  zone="$(printf '%s' "$json" | sed -n 's/.*"zone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$vmsize" ] || return 0
  detail="$vmsize"
  if [ -n "$zone" ]; then detail="$detail (zone $zone)"; fi
  bh_meta_fill "Microsoft Azure" "$detail"
}

# GCP metadata server (its DNS name only resolves inside GCP).
# Detail = machine-type + zone (the "projects/<n>/zones/" prefix is
# stripped away); both are provider/region/size facts only.
bh_probe_gcp() { # bh_probe_gcp [record-file]
  local out="${1:-}" cap=2
  [ -n "$out" ] && cap=1
  local mt zone detail=""
  mt="$(bh_meta_curl_cap "$cap" -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/machine-type' | awk -F/ '{print $NF}')"
  zone="$(bh_meta_curl_cap "$cap" -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/zone' | awk -F/ '{print $NF}')"
  [ -n "$mt" ] || [ -n "$zone" ] || return 0
  if [ -n "$mt" ] && [ -n "$zone" ]; then detail="$mt ($zone)"
  elif [ -n "$mt" ]; then detail="$mt"
  else detail="$zone"
  fi
  if [ -n "$out" ]; then
    bh_probe_record "$out" "Google Cloud" "$detail"
    return 0
  fi
  bh_meta_fill "Google Cloud" "$detail"
}

# OCI requires the well-known 'Authorization: Bearer Oracle' header.
# Hinted mode uses opc/v2; the generic sweep uses opc/v1 (same shape).
# Only the region is extracted — no tenancy/compartment OCIDs are kept.
# (The DMI chassis asset-tag 'OracleCloud.com' path in 10-detect.sh stays
# the primary OCI identifier; this is the metadata corroboration.)
bh_probe_oci() { # bh_probe_oci [record-file]
  local out="${1:-}" cap=2 url="http://169.254.169.254/opc/v2/instance/"
  if [ -n "$out" ]; then cap=1; url="http://169.254.169.254/opc/v1/instance/"; fi
  local raw region
  raw="$(bh_meta_curl_cap "$cap" -H 'Authorization: Bearer Oracle' "$url")"
  [ -n "$raw" ] || return 0
  region="$(printf '%s' "$raw" | grep -o '"region"[^,]*' | head -n 1 | sed -n 's/.*"\([^"]*\)"$/\1/p')"
  if [ -n "$out" ]; then
    bh_probe_record "$out" "Oracle Cloud (OCI)" "$region"
    return 0
  fi
  bh_meta_fill "Oracle Cloud (OCI)" "$region"
}

# Linode has no distinctive sys_vendor (only bios_vendor="Linode"), so the
# generic sweep also tries the Linode metadata service. v1.json may require
# a metadata token on hardened images — guarded: any failure is a silent
# skip, and only a trivially parseable region/size label is kept.
bh_probe_linode() { # bh_probe_linode <record-file>  (generic sweep only)
  local out="${1:-}"
  [ -n "$out" ] || return 0
  local json label region detail
  json="$(bh_meta_curl1 http://169.254.169.254/v1.json)"
  [ -n "$json" ] || return 0
  label="$(printf '%s' "$json" | sed -n 's/.*"label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  region="$(printf '%s' "$json" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$label" ] || [ -n "$region" ] || return 0
  if [ -n "$label" ] && [ -n "$region" ]; then detail="$label ($region)"
  elif [ -n "$label" ]; then detail="$label"
  else detail="$region"
  fi
  bh_probe_record "$out" "Linode (Akamai)" "$detail"
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
  if bh_redact_on; then
    host=""   # PRIVACY: the hostname is never fetched nor stored
    region="$(bh_meta_curl http://169.254.169.254/metadata/v1/region)"
  else
    host="$(bh_meta_curl http://169.254.169.254/metadata/v1/hostname)"
    region="$(bh_meta_curl http://169.254.169.254/metadata/v1/region)"
  fi
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
bh_probe_tencent() { # bh_probe_tencent [record-file]
  local out="${1:-}" cap=2
  [ -n "$out" ] && cap=1
  local it
  it="$(bh_meta_curl_cap "$cap" http://metadata.tencentyun.com/latest/meta-data/instance-type)"
  [ -n "$it" ] || return 0
  if [ -n "$out" ]; then
    bh_probe_record "$out" "Tencent Cloud" "$it"
    return 0
  fi
  bh_meta_fill "Tencent Cloud" "$it"
}

# Internal: apply generic-sweep records in priority order — the first
# provider with a result wins; bh_meta_fill still refuses to override a
# different DMI verdict, and the AWS generation from a record never
# overrides an already-established BH_AWS_GEN.
bh_sweep_apply() { # bh_sweep_apply <record-file>...   (priority order)
  local f cloud detail gen
  for f in "$@"; do
    [ -s "$f" ] || continue
    while IFS='|' read -r cloud detail gen; do
      [ -n "$cloud" ] || continue
      bh_meta_fill "$cloud" "$detail"
      if [ "$cloud" = "AWS EC2" ] && [ -n "$gen" ] && [ -z "${BH_AWS_GEN:-}" ]; then
        BH_AWS_GEN="$gen"
      fi
      break 2
    done < "$f"
  done
}

# Generic metadata sweep for DMI-hidden images (no vendor hint and no DMI
# cloud verdict): every unambiguous provider endpoint is probed in PARALLEL,
# each request capped at 1s, so the worst-case wall time is ~3s (AWS token +
# instance-id + instance-type) — within the 4s total metadata budget. First
# success in priority order wins: AWS, GCP, Azure, OCI, Linode, Tencent.
bh_generic_metadata_sweep() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/bhmeta.XXXXXX")" || return 0
  bh_probe_aws     "$dir/aws"     &
  bh_probe_gcp     "$dir/gcp"     &
  bh_probe_azure   "$dir/azure"   &
  bh_probe_oci     "$dir/oci"     &
  bh_probe_linode  "$dir/linode"  &
  bh_probe_tencent "$dir/tencent" &
  wait
  bh_sweep_apply "$dir/aws" "$dir/gcp" "$dir/azure" "$dir/oci" "$dir/linode" "$dir/tencent"
  rm -rf "$dir"
}

# Best-effort cloud metadata probes. Guarded:
#   - skipped entirely when BH_NO_NET=1 or curl is missing
#   - vendor-hinted probes only: DMI tells us which endpoint is worth trying
#   - last-resort generic sweep: when DMI found nothing at all, probe every
#     provider endpoint in parallel (1s caps) so DMI-hidden images still
#     identify; first success in priority order wins
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
    bh_generic_metadata_sweep
  fi
}

# Deprecated alias kept for compatibility with the old 20-info call site.
probe_cloud_meta() { cloud_metadata_probe; }
