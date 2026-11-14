# =====================================================================
# blackhole-vps-bench · 12-cloud.sh — cloud metadata probes (IMDS etc.)
# Pure functions only: sourcing this file has NO side effects.
# cloud_metadata_probe() is called from gather_info (20-info.sh) when the
# network is allowed. Request budgets: DMI-hinted probes use 2s per
# request; the generic fallback sweep (hidden/unknown DMI) fires all
# provider probes in PARALLEL at 1s per request — worst-case wall time is
# ~3s (AWS token + instance-id + instance-type), inside the 4s total
# metadata budget.
# v5.0.0 (C02) additions: five more providers join the SAME parallel
# sweep wave (zero added wall time), a family-gated corroboration/AZ
# wave adds <=2s worst case, and bh_offline_hints() (pure local reads,
# BH_NO_NET-safe) populates evidence-only provider hints — see the v5
# section below.
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
# State & flags — introduces no BH_* globals of its own; it
# only SETS detection globals owned by 10-detect.sh (BH_CLOUD,
# BH_CLOUD_DETAIL, BH_CLOUD_METHOD, BH_AWS_GEN) and READS the run-mode
# flags BH_NO_NET (00-core.sh) and BH_REDACT (privacy switch: unset or 0
# = off, 1 = keep only provider/region/size evidence).
# v5.0.0 (C02) additionally SETs: BH_CLOUD_META2, the offline hint
# globals BH_RESOLV_HINT / BH_NTP_HINT / BH_MAC_HINT / BH_V6_PREFIX_HINT
# and the internal BHV5_AWS_TOKEN cache (all default "", every read
# guarded with ${VAR:-}; see the v5 section below).
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
  # v5 (C02): stash the session token so the AZ refresh (bhv5c2_az_fetch)
  # can reuse it instead of minting a second session (60s TTL, one run;
  # never printed, never leaves the process).
  BHV5_AWS_TOKEN="$token"
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

# =====================================================================
# v5.0.0 (module C02) — extra provider metadata + passive offline hints
# =====================================================================
# New BH_* globals SET by this module from here on (all default "",
# every read guarded with ${VAR:-}):
#   BH_CLOUD_META2     second, evidence-only metadata verdict from the
#                      v5 provider probes: "vultr <region>" |
#                      "scaleway <type> <zone>" | "upcloud <zone>" |
#                      "openstack <az>" | "hetzner".
#                      Set by bh_meta2_apply (priority: Vultr, Scaleway,
#                      UpCloud, OpenStack, Hetzner). The BH_CLOUD fill
#                      itself still goes through bh_meta_fill, so this
#                      never overrides a different DMI-derived verdict.
#   BHV5_AWS_TOKEN     in-process IMDSv2 session token cache (stashed by
#                      bh_probe_aws, reused by bhv5c2_az_fetch). Never
#                      printed, never leaves the process.
#   BH_RESOLV_HINT     offline hint: /etc/resolv.conf search classes
#   BH_NTP_HINT        offline hint: chrony/ntp/timesyncd server classes
#   BH_MAC_HINT        offline hint: gateway MAC OUI class (first 3
#                      octets only — never a full MAC)
#   BH_V6_PREFIX_HINT  offline hint: global IPv6 prefix classes
# The four hint globals are provider-class evidence, e.g.
# "aws (search ec2.internal)". With BH_REDACT=1 they collapse to class
# names only ("aws-like") — no domains, no OUI strings. They NEVER write
# BH_CLOUD / BH_CLOUD_DETAIL.
# Budget: every v5 network probe runs at a 1s cap and all probes of a
# wave run in PARALLEL — worst-case added wall time is 2s (the Vultr
# regioncode+hostname chain, or the AWS AZ chain when no cached token
# exists; typical is sub-100ms because link-local endpoints answer or
# fail immediately).
# ---------------------------------------------------------------------

# Internal: harden a metadata string for detail/tag fields — first line
# only, pipes neutralized (mirrors bh_probe_record's stripping).
bhv5c2_clean() { # bhv5c2_clean <string>
  local s="$1"
  s="${s%%$'\n'*}"
  s="${s//|/ }"
  printf '%s' "$s"
}

# Vultr v1 metadata (plain-text answers on the link-local address).
# The region code must match ^[a-z]{3}[0-9]?$. The record's tag column
# carries "vultr <region>" for bh_meta2_apply.
# PRIVACY: with BH_REDACT=1 the hostname is never fetched — the valid
# region code alone then carries the identification.
bh_probe_vultr() { # bh_probe_vultr [record-file]
  local out="${1:-}" region="" host="" detail tag
  region="$(bh_meta_curl1 http://169.254.169.254/v1/regioncode)"
  case "$region" in
    [a-z][a-z][a-z]|[a-z][a-z][a-z][0-9]) : ;;
    *) return 0 ;;
  esac
  if ! bh_redact_on; then
    host="$(bh_meta_curl1 http://169.254.169.254/v1/hostname)"
    host="$(bhv5c2_clean "$host")"
  fi
  if [ -z "$host" ] && ! bh_redact_on; then return 0; fi
  detail="$region"
  [ -n "$host" ] && detail="$host ($region)"
  tag="vultr $region"
  if [ -n "$out" ]; then
    bh_probe_record "$out" "Vultr" "$detail" "$tag"
    return 0
  fi
  bh_meta_fill "Vultr" "$detail"
  if [ -z "${BH_CLOUD_META2:-}" ]; then BH_CLOUD_META2="$tag"; fi
  return 0
}

# Scaleway metadata (dedicated 169.254.42.42). Only commercial_type and
# zone are extracted; the zone must match ^[a-z]{2}-[a-z0-9]{2,6}-[0-9]$.
bh_probe_scaleway() { # bh_probe_scaleway [record-file]
  local out="${1:-}" json="" ctype="" zone="" detail tag
  json="$(bh_meta_curl1 'http://169.254.42.42/conf?format=json')"
  [ -n "$json" ] || return 0
  ctype="$(printf '%s' "$json" | sed -n 's/.*"commercial_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  ctype="$(bhv5c2_clean "$ctype")"
  # grep -o takes the FIRST "zone" occurrence in document order, so a
  # hostile user_data blob cannot shadow the top-level key.
  zone="$(printf '%s' "$json" | grep -oE '"zone"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -n 's/.*"[^"]*"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$ctype" ] || return 0
  if [[ ! "$zone" =~ ^[a-z]{2}-[a-z0-9]{2,6}-[0-9]$ ]]; then return 0; fi
  detail="$ctype ($zone)"
  tag="scaleway $ctype $zone"
  if [ -n "$out" ]; then
    bh_probe_record "$out" "Scaleway" "$detail" "$tag"
    return 0
  fi
  bh_meta_fill "Scaleway" "$detail"
  if [ -z "${BH_CLOUD_META2:-}" ]; then BH_CLOUD_META2="$tag"; fi
  return 0
}

# UpCloud metadata v1 (link-local JSON). Only the "zone" key is read;
# the zone must match ^[a-z]{2}-[a-z0-9]+[0-9]$.
bh_probe_upcloud() { # bh_probe_upcloud [record-file]
  local out="${1:-}" json="" zone="" tag
  json="$(bh_meta_curl1 http://169.254.169.254/metadata/v1.json)"
  [ -n "$json" ] || return 0
  zone="$(printf '%s' "$json" | grep -oE '"zone"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -n 's/.*"[^"]*"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [[ ! "$zone" =~ ^[a-z]{2}-[a-z0-9]+[0-9]$ ]]; then return 0; fi
  tag="upcloud $zone"
  if [ -n "$out" ]; then
    bh_probe_record "$out" "UpCloud" "$zone" "$tag"
    return 0
  fi
  bh_meta_fill "UpCloud" "$zone"
  if [ -z "${BH_CLOUD_META2:-}" ]; then BH_CLOUD_META2="$tag"; fi
  return 0
}

# OpenStack nova metadata (covers OVH / Rackspace and other OpenStack
# clouds). The answer must START with '{' before it is parsed; only the
# availability_zone is extracted (never hostname / project / uuid).
bh_probe_openstack() { # bh_probe_openstack [record-file]
  local out="${1:-}" json="" az="" tag=""
  json="$(bh_meta_curl1 http://169.254.169.254/openstack/latest/meta_data.json)"
  [ -n "$json" ] || return 0
  local trimmed="${json#"${json%%[![:space:]]*}"}"
  case "$trimmed" in
    '{'*) : ;;
    *) return 0 ;;
  esac
  az="$(printf '%s' "$json" | sed -n 's/.*"availability_zone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  az="$(bhv5c2_clean "$az")"
  if [ -n "$az" ]; then tag="openstack $az"; fi
  if [ -n "$out" ]; then
    bh_probe_record "$out" "OpenStack cloud" "$az" "$tag"
    return 0
  fi
  bh_meta_fill "OpenStack cloud" "$az"
  if [ -n "$tag" ] && [ -z "${BH_CLOUD_META2:-}" ]; then BH_CLOUD_META2="$tag"; fi
  return 0
}

# Hetzner Cloud metadata (link-local under /hetzner/v1/). Existence
# check only — the hostname and instance-id are NEVER stored, printed or
# recorded. The region is left to the offline sources (cloud-init
# instance-data / resolv + IPv6 prefix hints in bh_offline_hints).
bh_probe_hetzner() { # bh_probe_hetzner [record-file]
  local out="${1:-}" h="" iid=""
  h="$(bh_meta_curl1 http://169.254.169.254/hetzner/v1/metadata/hostname)"
  [ -n "$h" ] || return 0
  iid="$(bh_meta_curl1 http://169.254.169.254/hetzner/v1/metadata/instance-id)"
  [ -n "$iid" ] || return 0
  if [ -n "$out" ]; then
    bh_probe_record "$out" "Hetzner Cloud" "" "hetzner"
    return 0
  fi
  bh_meta_fill "Hetzner Cloud" ""
  if [ -z "${BH_CLOUD_META2:-}" ]; then BH_CLOUD_META2="hetzner"; fi
  return 0
}

# Internal: apply the v5 provider records in priority order (Vultr,
# Scaleway, UpCloud, OpenStack, Hetzner). Mirrors bh_sweep_apply: the
# first provider with a record wins. The record's third column carries
# the BH_CLOUD_META2 tag (bh_probe_record's gen slot, unused for these
# providers); bh_meta_fill still refuses to override a different DMI
# verdict.
bh_meta2_apply() { # bh_meta2_apply <record-file>...   (priority order)
  local f cloud detail tag
  for f in "$@"; do
    [ -s "$f" ] || continue
    while IFS='|' read -r cloud detail tag; do
      [ -n "$cloud" ] || continue
      bh_meta_fill "$cloud" "$detail"
      if [ -n "$tag" ] && [ -z "${BH_CLOUD_META2:-}" ]; then
        BH_CLOUD_META2="$tag"
      fi
      break 2
    done < "$f"
  done
  return 0
}

# Internal (background job): fetch the availability zone for a big-3
# family already established by DMI or metadata. AWS reuses the stashed
# IMDSv2 token when bh_probe_aws minted one this run (60s TTL), else
# requests a fresh one; Alibaba serves zone-id from its own metadata IP;
# Tencent a placement/region. Writes "<family>|<zone>" to <outfile> on
# success — nothing else is kept or printed.
bhv5c2_az_fetch() { # bhv5c2_az_fetch <family> <outfile>
  local fam="$1" out="$2" az="" token=""
  case "$fam" in
    "AWS EC2")
      token="${BHV5_AWS_TOKEN:-}"
      [ -n "$token" ] || token="$(bh_meta_curl1 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
      [ -n "$token" ] || return 0
      az="$(bh_meta_curl1 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
      ;;
    "Alibaba Cloud")
      az="$(bh_meta_curl1 http://100.100.100.200/latest/meta-data/zone-id)"
      ;;
    "Tencent Cloud")
      az="$(bh_meta_curl1 http://metadata.tencentyun.com/latest/meta-data/placement/region)"
      ;;
    *) return 0 ;;
  esac
  [ -n "$az" ] || return 0
  az="$(bhv5c2_clean "$az")"
  printf '%s|%s\n' "$fam" "$az" > "$out" 2>/dev/null || true
  return 0
}

# Internal: append a region/zone token to BH_CLOUD_DETAIL without
# duplicating one already present (used by the AZ refresh only).
bhv5c2_detail_append() { # bhv5c2_detail_append <token>
  local d="${BH_CLOUD_DETAIL:-}" t="$1"
  [ -n "$t" ] || { printf '%s' "$d"; return 0; }
  case " $d " in *" $t "*) printf '%s' "$d"; return 0 ;; esac
  printf '%s' "${d:+$d }$t"
}

# Internal: refresh BH_CLOUD_DETAIL with the fetched zone (foreground —
# bh_meta_fill must run in the parent shell, never a background job).
bhv5c2_az_apply() { # bhv5c2_az_apply <outfile>
  [ -s "$1" ] || return 0
  local fam az
  IFS='|' read -r fam az < "$1"
  case "$fam" in
    "AWS EC2"|"Alibaba Cloud"|"Tencent Cloud") ;;
    *) return 0 ;;
  esac
  [ -n "$az" ] || return 0
  bh_meta_fill "$fam" "$(bhv5c2_detail_append "$az")"
  return 0
}

# v5 wave: family-gated provider corroboration + big-3 AZ refresh. Runs
# after the hinted probes and the generic sweep:
#   - provider corroboration probes fire when DMI (not metadata) picked
#     Scaleway / Hetzner Cloud / OpenStack cloud — DMI names the family
#     but only metadata carries the zone. (Families discovered by the
#     generic sweep were already probed inside its wave.)
#   - the AZ refresh fires when BH_CLOUD is AWS EC2 / Alibaba Cloud /
#     Tencent Cloud; bh_meta_fill applies the same-family refresh rule,
#     so the verdict is never flipped, only the detail gains a zone.
# The family gates are disjoint, so worst-case added wall time is 2s
# (the AWS AZ chain without a cached token); everything runs at 1s caps.
bh_cloud_meta_v5_wave() {
  local probe2=0 azfam=""
  if [ "${BH_CLOUD_METHOD:-}" != "metadata" ]; then
    case "${BH_CLOUD:-}" in
      Scaleway|"Hetzner Cloud"|"OpenStack cloud") probe2=1 ;;
    esac
  fi
  case "${BH_CLOUD:-}" in
    "AWS EC2"|"Alibaba Cloud"|"Tencent Cloud") azfam="${BH_CLOUD}" ;;
  esac
  [ "$probe2" = "1" ] || [ -n "$azfam" ] || return 0
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/bhmeta2.XXXXXX")" || return 0
  if [ "$probe2" = "1" ]; then
    bh_probe_vultr     "$dir/vultr"     &
    bh_probe_scaleway  "$dir/scaleway"  &
    bh_probe_upcloud   "$dir/upcloud"   &
    bh_probe_openstack "$dir/openstack" &
    bh_probe_hetzner   "$dir/hetzner"   &
  fi
  if [ -n "$azfam" ]; then
    bhv5c2_az_fetch "$azfam" "$dir/az" &
  fi
  wait
  bh_meta2_apply "$dir/vultr" "$dir/scaleway" "$dir/upcloud" "$dir/openstack" "$dir/hetzner"
  bhv5c2_az_apply "$dir/az"
  rm -rf "$dir"
  return 0
}

# ---------------------------------------------------------------------
# v5 passive OFFLINE provider hints — pure parsers + one aggregator.
# Every parser takes a FILE PATH (testable in isolation; no system files
# are modified) and prints "name|evidence" ("class|vendor|oui" for the
# MAC parser); empty output = no hint. Evidence strings never contain
# tokens, ids or full MACs; with BH_REDACT=1 the aggregator keeps class
# names only. Evidence-only: these hints never write BH_CLOUD.
# ---------------------------------------------------------------------

# redact-aware formatter: "name|evidence" -> "name (evidence)" | "name-like"
bhv5c2_hint_fmt() { # bhv5c2_hint_fmt <name|evidence>
  local name="${1%%|*}" ev=""
  [ "$name" != "$1" ] && ev="${1#*|}"
  if bh_redact_on; then printf '%s-like' "$name"; return 0; fi
  if [ -n "$ev" ]; then printf '%s (%s)' "$name" "$ev"; else printf '%s' "$name"; fi
  return 0
}

# /etc/resolv.conf search/domain classes. Kubernetes "*.svc.*" entries
# are skipped on purpose (the container module owns that signal) while
# the remaining search entries keep scanning — an EKS-style
# "search default.svc.cluster.local ... ec2.internal" still yields aws.
bhv5c2_parse_resolv() { # bhv5c2_parse_resolv <resolv.conf> -> "name|evidence"
  [ -r "$1" ] || return 0
  local dom hint=""
  while IFS= read -r dom; do
    case "$dom" in
      *.svc|*.svc.*)                    continue ;;
      *ec2.internal|*compute.internal)  hint="aws|search $dom" ;;
      *internal.cloudapp.net)           hint="azure|search $dom" ;;
      *google.internal|c.*.internal)    hint="gcp|search $dom" ;;
    esac
    [ -n "$hint" ] && break
  done < <(awk '$1=="search"||$1=="domain"{for(i=2;i<=NF;i++)print $i}' "$1" 2>/dev/null)
  [ -n "$hint" ] && printf '%s\n' "$hint"
  return 0
}

# chrony/ntp/timesyncd server classes (spec table: time.aws.com,
# metadata.google.internal, ntp1.aliyun.com, time1.cloud.tencent.com).
bhv5c2_parse_ntp() { # bhv5c2_parse_ntp <config-or-sources file> -> "name|evidence"
  [ -r "$1" ] || return 0
  awk '
    /time\.aws\.com/             { print "aws|time.aws.com";             exit }
    /metadata\.google\.internal/ { print "gcp|metadata.google.internal"; exit }
    /ntp1\.aliyun\.com/          { print "alibaba|ntp1.aliyun.com";      exit }
    /time1\.cloud\.tencent\.com/ { print "tencent|time1.cloud.tencent.com"; exit }
  ' "$1" 2>/dev/null
  return 0
}

# Gateway-MAC class from an /proc/net/arp-style table (first complete
# entry: flags 0x2, valid unicast MAC). Only the first 3 octets (OUI)
# are ever reported — never the full MAC. Mini-table = a few well-known
# vendor OUIs; anything with the locally-administered bit set (second
# nibble 2/6/a/e) and no table hit classifies as locally-administered.
bhv5c2_parse_arp() { # bhv5c2_parse_arp <arp table> -> "class|vendor|oui"
  [ -r "$1" ] || return 0
  local ip hw fl mac mask dev oui vendor class
  while read -r ip hw fl mac mask dev; do
    [ "$fl" = "0x2" ] || continue
    case "$mac" in
      ??:??:??:??:??:??) : ;;
      *) continue ;;
    esac
    mac="$(printf '%s' "$mac" | tr 'A-F' 'a-f')"
    oui="${mac:0:8}"
    vendor=""
    case "$oui" in
      00:0d:3a|00:15:5d)                   vendor="microsoft" ;;
      00:50:56|00:0c:29|00:05:69|00:1c:14) vendor="vmware" ;;
      52:54:00)                            vendor="qemu" ;;
      00:16:3e)                            vendor="xen" ;;
      b8:cb:2f)                            vendor="digitalocean" ;;
    esac
    if [ -n "$vendor" ]; then
      class="vendor-known"
    else
      class="vendor-unknown"
      case "${mac:1:1}" in
        2|6|a|e) class="locally-administered" ;;
      esac
    fi
    printf '%s|%s|%s\n' "$class" "$vendor" "$oui"
    return 0
  done < "$1"
  return 0
}

# Global-scope IPv6 prefixes from /proc/net/if_inet6 (the kernel prints
# lowercase hex; scope column "00000000" = global). Provider allocation
# mini-table per spec.
bhv5c2_parse_if_inet6() { # bhv5c2_parse_if_inet6 <if_inet6> -> "name|evidence"
  [ -r "$1" ] || return 0
  local addr idx plen scope flg dev
  while read -r addr idx plen scope flg dev; do
    [ "$scope" = "00000000" ] || continue
    case "$addr" in
      2a01:4f8*)  printf 'hetzner|2a01:4f8\n';       return 0 ;;
      2604:a880*) printf 'digitalocean|2604:a880\n'; return 0 ;;
      2a03:b0c0*) printf 'digitalocean|2a03:b0c0\n'; return 0 ;;
      2001:19f0*) printf 'vultr|2001:19f0\n';        return 0 ;;
      2400:8900*) printf 'vultr|2400:8900\n';        return 0 ;;
      2001:bc8*)  printf 'scaleway|2001:bc8\n';      return 0 ;;
    esac
  done < "$1"
  return 0
}

# Aggregator — sets BH_RESOLV_HINT / BH_NTP_HINT / BH_MAC_HINT /
# BH_V6_PREFIX_HINT (guarded defaults; existing values survive when a
# parser finds nothing). Pure local reads: safe under BH_NO_NET=1 and in
# detect/sec modes. Called at the top of cloud_metadata_probe and by
# 13-region.sh's gather_region (via a command -v guard) so the hints
# populate in EVERY mode.
bh_offline_hints() {
  BH_RESOLV_HINT="${BH_RESOLV_HINT:-}"
  BH_NTP_HINT="${BH_NTP_HINT:-}"
  BH_MAC_HINT="${BH_MAC_HINT:-}"
  BH_V6_PREFIX_HINT="${BH_V6_PREFIX_HINT:-}"
  local r f cls ven oui
  r="$(bhv5c2_parse_resolv /etc/resolv.conf)"
  if [ -n "$r" ]; then BH_RESOLV_HINT="$(bhv5c2_hint_fmt "$r")"; fi
  for f in /etc/chrony/sources /etc/chrony/chrony.conf /etc/ntp.conf /etc/systemd/timesyncd.conf; do
    [ -r "$f" ] || continue
    r="$(bhv5c2_parse_ntp "$f")"
    if [ -n "$r" ]; then BH_NTP_HINT="$(bhv5c2_hint_fmt "$r")"; break; fi
  done
  r="$(bhv5c2_parse_arp /proc/net/arp)"
  if [ -n "$r" ]; then
    cls="${r%%|*}"; r="${r#*|}"; ven="${r%%|*}"; oui="${r#*|}"
    if bh_redact_on; then
      BH_MAC_HINT="$cls"
    else
      BH_MAC_HINT="$cls"
      [ -n "$ven" ] && BH_MAC_HINT="$BH_MAC_HINT $ven"
      [ -n "$oui" ] && BH_MAC_HINT="$BH_MAC_HINT ($oui)"
    fi
  fi
  r="$(bhv5c2_parse_if_inet6 /proc/net/if_inet6)"
  if [ -n "$r" ]; then BH_V6_PREFIX_HINT="$(bhv5c2_hint_fmt "$r")"; fi
  return 0
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
  # v5 (C02): five more providers join the SAME parallel wave — zero
  # added wall time (the AWS 3-request chain stays the longest at ~3s).
  bh_probe_vultr     "$dir/vultr"     &
  bh_probe_scaleway  "$dir/scaleway"  &
  bh_probe_upcloud   "$dir/upcloud"   &
  bh_probe_openstack "$dir/openstack" &
  bh_probe_hetzner   "$dir/hetzner"   &
  wait
  bh_sweep_apply "$dir/aws" "$dir/gcp" "$dir/azure" "$dir/oci" "$dir/linode" "$dir/tencent"
  bh_meta2_apply "$dir/vultr" "$dir/scaleway" "$dir/upcloud" "$dir/openstack" "$dir/hetzner"
  rm -rf "$dir"
}

# Best-effort cloud metadata probes. Guarded:
#   - skipped entirely when BH_NO_NET=1 or curl is missing
#   - vendor-hinted probes only: DMI tells us which endpoint is worth trying
#   - last-resort generic sweep: when DMI found nothing at all, probe every
#     provider endpoint in parallel (1s caps) so DMI-hidden images still
#     identify; first success in priority order wins
cloud_metadata_probe() {
  # v5 (C02): passive offline hints first — pure local reads, so they
  # also populate when BH_NO_NET=1 (detect/sec modes force it) before
  # the network probes are skipped below.
  bh_offline_hints
  [ "$BH_NO_NET" = "1" ] && return 0
  command_exists curl || return 0
  BH_CLOUD_META2="${BH_CLOUD_META2:-}"   # v5 global ("" default, guarded)

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

  # v5 (C02): DMI-known Scaleway/Hetzner/OpenStack corroboration + big-3
  # AZ refresh (family-gated, parallel, 1s caps, <=2s worst case).
  bh_cloud_meta_v5_wave
}

# Deprecated alias kept for compatibility with the old 20-info call site.
probe_cloud_meta() { cloud_metadata_probe; }
