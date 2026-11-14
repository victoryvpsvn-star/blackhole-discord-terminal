# =====================================================================
# blackhole-vps-bench · 13-region.sh — offline region / datasource facts
# =====================================================================
# v5.0.0 (module C02). 100% OFFLINE: reads only cloud-init's local state
# files — no network, no metadata services, no curl. Expected to run in
# EVERY mode, including detect and sec (which force BH_NO_NET=1 before
# any gather call).
#
# Sources (first match wins per key):
#   1. /run/cloud-init/instance-data.json — whitelisted keys only:
#        cloud-name, region, availability-zone (plus "datasource" for the
#      class name). Parsed with grep/sed only — no jq dependency. Values
#      may be JSON null -> treated as empty. The file is only trusted
#      after a guard confirms it carries cloud-init markers ("ds-mode" /
#      "datasource" / "cloud-name").
#   2. /var/lib/cloud/instance/datasource — fallback for the datasource
#      class name only (e.g. DataSourceEc2Local).
#
# Globals SET by gather_region() (each defaults ""):
#   BH_CI_CLOUD   cloud-init cloud-name (aws / azure / gce / openstack /
#                 digitalocean / hetzner / scaleway / vultr / nocloud);
#                 derived from the datasource class when cloud-init had
#                 no cloud-name
#   BH_CI_REGION  region; derived from the AZ prefix when cloud-init has
#                 none (fsn1-dc14 -> fsn1, us-east-1a -> us-east-1)
#   BH_CI_AZ      availability-zone ("" when cloud-init had none)
#   BH_DS_CLASS   raw datasource class (DataSourceEc2Local, ...)
# BH_CLOUD / BH_CLOUD_DETAIL are NEVER touched here — detection
# (10-detect.sh) owns the verdict; these are corroborating region facts
# only.
#
# PRIVACY: no instance ids, hostnames or tokens are read from either
# file — only the whitelisted region/zone/cloud-class keys are kept.
#
# 99-main wiring: bhv5c15_v5_gathers() calls gather_region() in every
# mode. gather_region also pulls in 12-cloud.sh's bh_offline_hints()
# (via a command -v guard) so the passive provider hints populate even
# in detect/sec mode, where cloud_metadata_probe() is never called.
# =====================================================================
# shellcheck shell=bash

# ---------------------------------------------------------------------
# Pure helpers (bhv5c2_ prefix) — every one takes a path/value argument,
# prints its result ("" = nothing found) and has no side effects.
# ---------------------------------------------------------------------

# Guard: only trust a JSON file that actually carries cloud-init markers.
bhv5c2_ci_guard() { # bhv5c2_ci_guard <instance-data.json> -> 0 = trustworthy
  [ -r "$1" ] || return 1
  grep -qE '"(ds-mode|datasource|cloud-name)"' "$1" 2>/dev/null
}

# Extract a whitelisted key's string value from cloud-init's
# pretty-printed instance-data.json (grep to find the key line, sed to
# cut the value). Unquoted JSON null simply never matches the sed value
# pattern -> empty. Keys are caller-supplied literals from the whitelist
# (cloud-name / region / availability-zone / datasource).
bhv5c2_ci_json_value() { # bhv5c2_ci_json_value <file> <key> -> value|""
  [ -r "$1" ] || return 0
  grep -E "^[[:space:]]*\"$2\"[[:space:]]*:" "$1" 2>/dev/null \
    | head -n 1 \
    | sed -n 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  return 0
}

# Derive the region from an availability-zone per spec:
#   fsn1-dc14    -> fsn1         (Hetzner "-dcNN" suffix)
#   us-east-1a   -> us-east-1    (trailing zone letter after a digit)
#   us-east1-b   -> us-east1     (GCP-style "-<letter>" suffix)
#   cn-hangzhou-g -> cn-hangzhou (Alibaba-style "-<letter>" suffix)
# Prints "" when no known suffix shape matches — the AZ is then not a
# reliable region prefix (e.g. OpenStack's generic "nova", Scaleway's
# "fr-par-1"), so the region stays empty instead of being guessed.
bhv5c2_region_from_az() { # bhv5c2_region_from_az <az> -> region|""
  local az="$1" r=""
  case "$az" in
    *-dc[0-9]*)  r="${az%-dc*}" ;;   # fsn1-dc14     -> fsn1
    *[0-9][a-z]) r="${az%?}" ;;      # us-east-1a    -> us-east-1
    *-[a-z])     r="${az%-?}" ;;     # us-east1-b    -> us-east1
  esac
  case "$r" in
    ""|*[!0-9]*) : ;;                # keep (non-empty, not a bare number)
    *) r="" ;;                       # "1a" would yield "1" — not a region
  esac
  printf '%s' "$r"
}

# Whitelisted cloud-init datasource classes (spec list; DataSourceEc2 is
# accepted as a superset for older cloud-init releases that wrote the
# bare class name). Leftmost-longest ERE matching, longer names first.
bhv5c2_ds_class_from_file() { # <file> -> first whitelisted class|""
  [ -r "$1" ] || return 0
  local re='DataSource(Ec2Local|HetznerCloud|DigitalOcean|OpenStack|Scaleway|Vultr|Azure|NoCloud|GCE|Ec2)'
  grep -oE "$re" "$1" 2>/dev/null | head -n 1
  return 0
}

# Same extraction for an already-read string (e.g. the "datasource"
# value inside instance-data.json, which may carry extra text).
bhv5c2_ds_class_from_string() { # <string> -> first whitelisted class|""
  [ -n "$1" ] || return 0
  local re='DataSource(Ec2Local|HetznerCloud|DigitalOcean|OpenStack|Scaleway|Vultr|Azure|NoCloud|GCE|Ec2)'
  printf '%s\n' "$1" | grep -oE "$re" 2>/dev/null | head -n 1
  return 0
}

# Map a datasource class to cloud-init's lowercase cloud-name vocabulary.
# Only used to fill an EMPTY BH_CI_CLOUD — it never overrides anything.
bhv5c2_ds_to_cloud() { # <class> -> cloud-name|""
  case "$1" in
    DataSourceEc2*)         printf 'aws' ;;
    DataSourceAzure)        printf 'azure' ;;
    DataSourceGCE)          printf 'gce' ;;
    DataSourceOpenStack)    printf 'openstack' ;;
    DataSourceDigitalOcean) printf 'digitalocean' ;;
    DataSourceHetznerCloud) printf 'hetzner' ;;
    DataSourceScaleway)     printf 'scaleway' ;;
    DataSourceVultr)        printf 'vultr' ;;
    DataSourceNoCloud)      printf 'nocloud' ;;
  esac
  return 0
}

# ---------------------------------------------------------------------
# Entry point — 99-main.sh calls gather_region() in every mode.
# Idempotent, offline, silent. Pure function definitions above; this
# file has NO top-level side effects.
# ---------------------------------------------------------------------
gather_region() {
  BH_CI_CLOUD=""
  BH_CI_REGION=""
  BH_CI_AZ=""
  BH_DS_CLASS=""
  local ci="/run/cloud-init/instance-data.json"
  local dsv="/var/lib/cloud/instance/datasource"
  local v
  if bhv5c2_ci_guard "$ci"; then
    v="$(bhv5c2_ci_json_value "$ci" cloud-name)"
    [ -n "$v" ] && BH_CI_CLOUD="$v"
    v="$(bhv5c2_ci_json_value "$ci" region)"
    [ -n "$v" ] && BH_CI_REGION="$v"
    v="$(bhv5c2_ci_json_value "$ci" availability-zone)"
    [ -n "$v" ] && BH_CI_AZ="$v"
    # the datasource class rides along in instance-data as well
    v="$(bhv5c2_ci_json_value "$ci" datasource)"
    [ -n "$v" ] && BH_DS_CLASS="$(bhv5c2_ds_class_from_string "$v")"
  fi
  # region fallback: derive from the AZ prefix when cloud-init had none
  if [ -z "$BH_CI_REGION" ] && [ -n "$BH_CI_AZ" ]; then
    v="$(bhv5c2_region_from_az "$BH_CI_AZ")"
    [ -n "$v" ] && BH_CI_REGION="$v"
  fi
  # datasource fallback when instance-data was absent or untrusted
  if [ -z "$BH_DS_CLASS" ]; then
    BH_DS_CLASS="$(bhv5c2_ds_class_from_file "$dsv")"
  fi
  # coarse cloud-name from the datasource class when cloud-init had none
  if [ -z "$BH_CI_CLOUD" ] && [ -n "$BH_DS_CLASS" ]; then
    v="$(bhv5c2_ds_to_cloud "$BH_DS_CLASS")"
    [ -n "$v" ] && BH_CI_CLOUD="$v"
  fi
  # passive offline provider hints (12-cloud.sh) — pulled in here too so
  # they populate in every mode even when cloud_metadata_probe() is not
  # called (detect/sec). Idempotent; guarded because this module must
  # also work when sourced standalone.
  if command -v bh_offline_hints >/dev/null 2>&1; then
    bh_offline_hints
  fi
  return 0
}
