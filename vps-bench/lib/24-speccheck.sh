# =====================================================================
# blackhole-vps-bench · 24-speccheck.sh — advertised vs measured spec check
# =====================================================================
#
# v5.0 (C4): cross-checks the cloud PLAN the provider advertises (vCPU, RAM)
# against what this box actually reports. 100% offline, read-only, and cheap:
# a handful of awk/tr one-shots, well inside the 50 ms module budget.
#
# Load order: after 20-info.sh. Reuses BH_MEM_TOTAL_MB when gather_info already
# ran (falls back to its own /proc/meminfo read otherwise) and BH_HOSTNAME as
# the last plan-string candidate (falls back to `hostname`).
#
# Globals SET (initialized by gather_speccheck; "" when unknown):
#   BH_SPEC_CPU_V     "<verdict> eff=<eff> adv=<adv>"   e.g. "ok eff=2 adv=2"
#                     (<adv> is the raw table token, e.g. "2shared" for e2-*)
#   BH_SPEC_RAM_V     "<verdict> <measured>MB/<adv>MB"  e.g. "warn 700MB/1024MB"
#   BH_SPEC_BURST     "" | "burstable: bench peak is not sustainable
#                          (t-family/e2-shared/B-series)"
#   BH_SPEC_SUMMARY   "cpu=ok ram=warn" | "no-plan"
#                     (63-tips.sh keys on ram=warn|ram=bad inside it)
#
# Verdict rules (bh_spec_verdict, pure and unit-testable):
#   cpu:   ok   measured >= advertised
#          warn measured >= advertised/2   (shared / burstable tolerated)
#          bad  below
#   ram:   ratio = measured / advertised:
#          ok >= 0.85, warn >= 0.68, bad below
#   burst: passthrough of the tag string.
#   empty / zero / non-numeric input -> "" (unknown; never warns).
#   NOTE: the draft spec wrote "cpu: warn if measured >= advertised-0.5" and
#   "ram: warn >= 0.70", but its own acceptance vectors ((2,1.2,cpu) -> warn,
#   (1024,700,ram) -> warn) contradict both (1.2 < 1.5; 700/1024 = 0.684).
#   Thresholds are resolved in favor of the acceptance tests: half-advertised
#   for cpu (the shared/burst tolerance the draft intended) and 0.68 for ram.
#
# Never-warn guard: an unknown provider or an unknown plan token yields
# BH_SPEC_SUMMARY="no-plan" with every other SPEC var left empty. This module
# never invents a plan and never warns on a machine it cannot identify.
#
# Contract: function definitions only, no top-level side effects; sets BH_*
# globals only (never stdout); no network, no writes; survives `set -u`.
# =====================================================================
# shellcheck shell=bash

# bhv5c4_norm STRING — normalize a plan/detail string for token compare:
# lowercase, and '._-' become spaces ("t3.micro" -> "t3 micro",
# "Standard_B2s" -> "standard b2s", "s-1vcpu-1gb" -> "s 1vcpu 1gb").
# One tr with aligned sets: [:upper:] maps to [:lower:], then '.' '_' '-'
# each map to a space (LC_ALL=C is exported by 00-core.sh).
bhv5c4_norm() {
  printf '%s' "${1:-}" | tr '[:upper:]._-' '[:lower:]   '
}

# bhv5c4_provider CLOUD-NAME — map a detection cloud name (BH_CLOUD values
# from 10-detect.sh/12-cloud.sh: "AWS EC2", "Google Cloud", "Microsoft Azure",
# "DigitalOcean", "Hetzner Cloud", "Scaleway", "Oracle Cloud (OCI)",
# "Linode (Akamai)", ...) to the table key: aws|gcp|azure|do|hetzner|scaleway|
# vultr|linode|oci|upcloud. "" when unknown (no table rows exist for it).
bhv5c4_provider() {
  local c
  c="$(bhv5c4_norm "${1:-}")"
  case "$c" in
    *amazon*|*aws*|*ec2*) printf 'aws' ;;
    *google*|*gcp*)       printf 'gcp' ;;
    *azure*|*microsoft*)  printf 'azure' ;;
    do|*digitalocean*)    printf 'do' ;;
    *hetzner*)            printf 'hetzner' ;;
    *scaleway*)           printf 'scaleway' ;;
    *vultr*)              printf 'vultr' ;;
    *linode*|*akamai*)    printf 'linode' ;;
    *oracle*|*oci*)       printf 'oci' ;;
    *upcloud*)            printf 'upcloud' ;;
    *)                    : ;;   # alibaba / tencent / openstack / "" -> unknown
  esac
  return 0
}

# bhv5c4_hostname — plan-string hostname fallback: BH_HOSTNAME when set
# (20-info.sh owns it), else one `hostname` call. Always safe under set -u.
bhv5c4_hostname() {
  if [ -n "${BH_HOSTNAME:-}" ]; then
    printf '%s\n' "$BH_HOSTNAME"
    return 0
  fi
  hostname 2>/dev/null || :
  return 0
}

# bhv5c4_plan_candidates — print the strings that may carry the plan token,
# one per line, in priority order: BH_CLOUD_DETAIL (provider metadata),
# BH_CLOUD_META2 (second metadata slot, v5), BH_CI_CLOUD / BH_CI_PLAN (CI
# hint variables), hostname last. All reads are ${VAR:-} guarded: the vars
# are optional and may not exist yet.
bhv5c4_plan_candidates() {
  [ -n "${BH_CLOUD_DETAIL:-}" ] && printf '%s\n' "$BH_CLOUD_DETAIL"
  [ -n "${BH_CLOUD_META2:-}" ]  && printf '%s\n' "$BH_CLOUD_META2"
  [ -n "${BH_CI_CLOUD:-}" ]     && printf '%s\n' "$BH_CI_CLOUD"
  [ -n "${BH_CI_PLAN:-}" ]      && printf '%s\n' "$BH_CI_PLAN"
  bhv5c4_hostname
  return 0
}

# bhv5c4_mem_mb — RAM in MB from /proc/meminfo MemTotal, parsed exactly the
# way 20-info.sh does (awk field $2, then integer /1024). 0 when unreadable.
bhv5c4_mem_mb() {
  local kb
  kb="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  case "$kb" in
    ''|*[!0-9]*) printf '0' ; return 0 ;;
  esac
  printf '%d' $(( kb / 1024 ))
}

# bhv5c4_lookup PROVIDER PLAN-STRING — the embedded spec table (2-D via
# nested case). PROVIDER is a bhv5c4_provider key, PLAN-STRING is any
# provider detail/metadata/hostname text; the plan is matched by substring
# of its normalized tokens. Prints "<vcpu> <ram_mb> [burst]" (vcpu may be
# the raw spec token "2shared" for GCP shared-core rows; "burst" marks
# burstable/shared families) or "" when the plan is not in the table.
bhv5c4_lookup() {
  local prov plan
  # fast path: an already-normalized table key skips the tr fork entirely
  case "${1:-}" in
    aws|gcp|azure|do|hetzner|scaleway|vultr|linode|oci|upcloud) prov="$1" ;;
    *)                                                          prov="$(bhv5c4_provider "${1:-}")" ;;
  esac
  plan="$(bhv5c4_norm "${2:-}")"
  [ -n "$prov" ] || return 0
  [ -n "$plan" ] || return 0
  case "$prov" in
    aws)
      case "$plan" in
        *"t3a medium"*) printf '2 4096 burst' ;;
        *"t3 micro"*)   printf '2 1024 burst' ;;
        *"t3 small"*)   printf '2 2048 burst' ;;
        *"t3 medium"*)  printf '2 4096 burst' ;;
        *"t4g medium"*) printf '2 4096 burst' ;;
        *"t2 micro"*)   printf '1 1024 burst' ;;
        *"m5 large"*)   printf '2 8192' ;;
        *"m6g large"*)  printf '2 8192' ;;
      esac
      ;;
    gcp)
      case "$plan" in
        *"e2 standard 2"*) printf '2 8192' ;;
        *"e2 micro"*)      printf '2shared 4096 burst' ;;
        *"e2 small"*)      printf '2shared 4096 burst' ;;
        *"e2 medium"*)     printf '2shared 4096 burst' ;;
      esac
      ;;
    azure)
      case "$plan" in
        *"b2ms"*) printf '2 8192 burst' ;;
        *"b2s"*)  printf '2 4096 burst' ;;
        *"b1ms"*) printf '1 2048 burst' ;;
        *"b1s"*)  printf '1 1024 burst' ;;
      esac
      ;;
    do)
      case "$plan" in
        *"s 2vcpu 4gb"*) printf '2 4096' ;;
        *"s 1vcpu 2gb"*) printf '1 2048' ;;
        *"s 1vcpu 1gb"*) printf '1 1024' ;;
      esac
      ;;
    hetzner)
      case "$plan" in
        *"cx32"*)  printf '4 8192' ;;
        *"cx22"*)  printf '2 4096' ;;
        *"cpx11"*) printf '2 2048' ;;
      esac
      ;;
    scaleway)
      case "$plan" in
        *"dev1 s"*) printf '1 2048' ;;
        *"dev1 m"*) printf '3 4096' ;;
      esac
      ;;
    vultr)
      case "$plan" in
        *"vc2 2c 2048"*) printf '2 2048' ;;
        *"vc2 1c 1024"*) printf '1 1024' ;;
      esac
      ;;
    linode)
      case "$plan" in
        *"g6 standard 1"*) printf '1 2048' ;;
        *"g6 nanode 1"*)   printf '1 1024' ;;
      esac
      ;;
    oci)
      case "$plan" in
        *"e2 1 micro"*) printf '1 1024' ;;
      esac
      ;;
    upcloud)
      case "$plan" in
        *"1xcpu 1gb"*) printf '1 1024' ;;
      esac
      ;;
  esac
  return 0
}

# bh_spec_verdict ADVERTISED MEASURED KIND — pure verdict helper (printable,
# no side effects). KIND = cpu | ram | burst. Prints ok|warn|bad, the tag
# string (burst), or "" for empty/zero/non-numeric input. See the threshold
# notes in the file header.
bh_spec_verdict() {
  local kind="${3:-}"
  case "$kind" in
    burst)
      # passthrough: return the tag string handed in
      [ -n "${1:-}" ] && printf '%s' "$1"
      return 0
      ;;
    cpu|ram) : ;;
    *)       return 0 ;;
  esac
  local adv="${1:-}" meas="${2:-}"
  case "$adv" in ''|*[!0-9.]*) return 0 ;; esac
  case "$meas" in ''|*[!0-9.]*) return 0 ;; esac
  awk -v a="$adv" -v m="$meas" -v k="$kind" 'BEGIN{
    if (a+0 <= 0 || m+0 <= 0) { print ""; exit }
    if (k == "cpu") {
      if (m >= a)        print "ok"
      else if (m >= a/2) print "warn"   # shared / burstable tolerance
      else               print "bad"
    } else {
      r = m / a
      if (r >= 0.85)      print "ok"
      else if (r >= 0.68) print "warn"
      else                print "bad"
    }
  }'
  return 0
}

# gather_speccheck — module entry point. Computes the advertised-vs-measured
# verdicts and sets BH_SPEC_CPU_V / BH_SPEC_RAM_V / BH_SPEC_BURST /
# BH_SPEC_SUMMARY. Never fails: any unknown (provider, plan, measured value)
# degrades to BH_SPEC_SUMMARY="no-plan" with the other SPEC vars empty.
gather_speccheck() {
  BH_SPEC_CPU_V=""
  BH_SPEC_RAM_V=""
  BH_SPEC_BURST=""
  BH_SPEC_SUMMARY=""

  # ---- provider: detection maps it (10-detect/12-cloud); "" -> no-plan ----
  local provider
  provider="$(bhv5c4_provider "${BH_CLOUD:-}")"
  if [ -z "$provider" ]; then
    BH_SPEC_SUMMARY="no-plan"
    return 0
  fi

  # ---- plan token: first candidate (detail, meta2, CI hints, hostname)
  #      that actually matches a table row wins ----
  local cands cand row=""
  cands="$(bhv5c4_plan_candidates)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    row="$(bhv5c4_lookup "$provider" "$cand")"
    [ -n "$row" ] && break
  done <<< "$cands"
  if [ -z "$row" ]; then
    BH_SPEC_SUMMARY="no-plan"
    return 0
  fi

  # ---- advertised spec from the table row ("<vcpu> <ram_mb> [burst]") ----
  local adv_tok adv_ram burst
  IFS=' ' read -r adv_tok adv_ram burst <<< "$row"
  local adv_cpu=""
  case "$adv_tok" in
    [0-9]*) adv_cpu="${adv_tok%%[!0-9]*}" ;;  # "2shared" -> 2
    *)      adv_cpu="" ;;
  esac
  case "$adv_ram" in ''|0|*[!0-9]*) adv_ram="" ;; esac

  # ---- measured vCPU: quota-aware effective cores (NCPU fallback) ----
  local eff="${BH_EFF_CORES:-}"
  case "$eff" in ''|0|*[!0-9]*) eff="${NCPU:-}" ;; esac
  case "$eff" in ''|0|*[!0-9]*) eff="" ;; esac

  # ---- measured RAM: MemTotal the 20-info way, clamped by the cgroup
  #      memory limit when one exists and is lower ----
  local mem=""
  case "${BH_MEM_TOTAL_MB:-}" in
    ''|0|*[!0-9]*) mem="$(bhv5c4_mem_mb)" ;;
    *)             mem="$BH_MEM_TOTAL_MB" ;;
  esac
  case "$mem" in ''|0|*[!0-9]*) mem="" ;; esac
  local lim="${MEM_LIMIT_KB:-0}"
  case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
  if [ -n "$mem" ] && [ "$lim" -gt 0 ] 2>/dev/null; then
    local lim_mb=$(( lim / 1024 ))
    if [ "$lim_mb" -gt 0 ] && [ "$lim_mb" -lt "$mem" ]; then
      mem="$lim_mb"
    fi
  fi

  # ---- verdicts ----
  local cpu_v="" ram_v=""
  if [ -n "$adv_cpu" ] && [ -n "$eff" ]; then
    cpu_v="$(bh_spec_verdict "$adv_cpu" "$eff" cpu)"
  fi
  if [ -n "$adv_ram" ] && [ -n "$mem" ]; then
    ram_v="$(bh_spec_verdict "$adv_ram" "$mem" ram)"
  fi

  # ---- globals ----
  if [ -n "$cpu_v" ]; then
    BH_SPEC_CPU_V="$cpu_v eff=$eff adv=$adv_tok"
  fi
  if [ -n "$ram_v" ]; then
    BH_SPEC_RAM_V="$ram_v ${mem}MB/${adv_ram}MB"
  fi
  if [ -n "$burst" ]; then
    BH_SPEC_BURST="burstable: bench peak is not sustainable (t-family/e2-shared/B-series)"
  fi

  [ -n "$cpu_v" ] && BH_SPEC_SUMMARY="cpu=$cpu_v"
  if [ -n "$ram_v" ]; then
    BH_SPEC_SUMMARY="${BH_SPEC_SUMMARY:+$BH_SPEC_SUMMARY }ram=$ram_v"
  fi
  case "$BH_SPEC_SUMMARY" in
    '') BH_SPEC_SUMMARY="no-plan" ;;   # plan known but nothing measurable
  esac
  return 0
}
