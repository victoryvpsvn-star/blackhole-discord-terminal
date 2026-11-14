# =====================================================================
# blackhole-vps-bench · 00-core.sh — constants, env, helpers
# =====================================================================
# shellcheck shell=bash

BH_VERSION="1.0.0"
BH_TOOL="blackhole-vps-bench"
BH_REPO="victoryvpsvn-star/blackhole-discord-terminal"

export LC_ALL=C
umask 077

# ------- configuration (env overridable, CLI wins later) -------
BH_FAST="${BH_FAST:-0}"
BH_NO_NET="${BH_NO_NET:-0}"
BH_WEBHOOK="${BH_WEBHOOK:-}"
BH_JSON_OUT="${BH_JSON_OUT:-}"
BH_MD_OUT="${BH_MD_OUT:-}"
BH_TXT_OUT="${BH_TXT_OUT:-}"
BH_DISK_DIR="${BH_DISK_DIR:-/tmp}"
BH_NO_COLOR="${BH_NO_COLOR:-0}"

# ------- colors (report bodies stay ANSI-free; only the banner gets color on a TTY) -------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "$BH_NO_COLOR" != "1" ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_CYN=$'\033[36m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_RED=$'\033[31m'; C_MAG=$'\033[35m'
else
  C_RST=''; C_B=''; C_DIM=''; C_CYN=''; C_GRN=''; C_YLW=''; C_RED=''; C_MAG=''
fi

# ------- logging -------
log()  { printf '[%s] %s\n' "$BH_TOOL" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$BH_TOOL" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$BH_TOOL" "$*" >&2; exit "${2:-2}"; }

# ------- temp workspace -------
BH_RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/bhvps.XXXXXX")" || die "cannot create temp dir"
bh_cleanup() { rm -rf "$BH_RUNDIR"; }
trap bh_cleanup EXIT

# ------- time helpers -------
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    awk -v t="$EPOCHREALTIME" 'BEGIN{n=split(t,a,"."); printf "%d", a[1]*1000 + int(substr((a[2] "000"),1,3))}'
  elif [ -r /proc/uptime ]; then
    awk '{printf "%d", $1*1000}' /proc/uptime
  else
    date +%s000
  fi
}

# ------- formatting -------
fmt_mb()    { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else if (v>=1000) printf "%.2f GB/s", v/1024; else printf "%.1f MB/s", v }'; }
fmt_gbs()   { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else printf "%.2f GB/s", v }'; }
fmt_mbps()  { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else if (v>=1000) printf "%.2f Gbps", v/1000; else printf "%.1f Mbps", v }'; }
fmt_ms()    { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else printf "%.1f ms", v }'; }
fmt_mbint() { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else printf "%d MB", v }'; }

# ------- cgroup environment -------
bh_cg_version() {
  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then echo 2
  elif [ -d /sys/fs/cgroup/cpu ]; then echo 1
  else echo 0
  fi
}
CG_VER="$(bh_cg_version)"

bh_cpu_quota_cores() {
  case "$CG_VER" in
    2)
      if [ -r /sys/fs/cgroup/cpu.max ]; then
        local q p
        read -r q p < /sys/fs/cgroup/cpu.max 2>/dev/null || { echo 0; return; }
        [ "${q:-max}" = "max" ] && { echo 0; return; }
        awk -v q="$q" -v p="$p" 'BEGIN{ if (p+0>0) printf "%.2f", q/p; else print 0 }'
      else echo 0; fi
      ;;
    1)
      local q p
      q="$(head -n 1 /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)"
      p="$(head -n 1 /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 100000)"
      [ -z "$q" ] && q=-1
      awk -v q="$q" -v p="$p" 'BEGIN{ if (q+0>0 && p+0>0) printf "%.2f", q/p; else print 0 }'
      ;;
    *) echo 0 ;;
  esac
}
QUOTA_CORES="$(bh_cpu_quota_cores)"

bh_mem_limit_kb() {
  case "$CG_VER" in
    2)
      local v
      v="$(head -n 1 /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
      if [ -z "$v" ] || [ "$v" = "max" ]; then echo 0
      else awk -v b="$v" 'BEGIN{printf "%d", b/1024}'; fi
      ;;
    1)
      local v
      v="$(head -n 1 /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)"
      awk -v b="$v" 'BEGIN{ if (b+0>=9000000000000000 || b+0<=0) print 0; else printf "%d", b/1024 }'
      ;;
    *) echo 0 ;;
  esac
}
MEM_LIMIT_KB="$(bh_mem_limit_kb)"

bh_cpuset() {
  case "$CG_VER" in
    2) head -n 1 /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null ;;
    1) head -n 1 /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null ;;
    *) : ;;
  esac | tr -d '\n'
}
CPUSET="$(bh_cpuset)"

NCPU="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
if [ -z "$NCPU" ] || [ "$NCPU" -lt 1 ] 2>/dev/null; then NCPU=1; fi

# parallel jobs: respect cgroup CPU quota when present, cap at 64
if awk -v q="$QUOTA_CORES" 'BEGIN{exit !(q+0>0)}'; then
  BH_PAR_JOBS=$(awk -v q="$QUOTA_CORES" 'BEGIN{ j=int(q); if (j<1) j=1; print j }')
  BH_EFF_CORES="$BH_PAR_JOBS"
  if [ "$BH_PAR_JOBS" -gt "$NCPU" ]; then BH_PAR_JOBS=$NCPU; BH_EFF_CORES=$NCPU; fi
else
  BH_PAR_JOBS=$NCPU
  BH_EFF_CORES=$NCPU
fi
if [ "$BH_PAR_JOBS" -gt 64 ]; then BH_PAR_JOBS=64; fi

# ------- JSON helpers -------
json_esc() {
  local s=$1
  s=${s//[[:cntrl:]]/}   # raw control bytes (e.g. from DMI strings) would break JSON
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/ }
  printf '%s' "$s"
}
json_val() { # quote unless it matches a strict JSON number: ^-?[0-9]+(\.[0-9]+)?$
  if [[ ${1:-} =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$1"
  else
    printf '"%s"' "$(json_esc "${1:-}")"
  fi
}

# ------- misc -------
command_exists() { command -v "$1" >/dev/null 2>&1; }
awk_min2() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0<a+0) print b; else print a }'; }
