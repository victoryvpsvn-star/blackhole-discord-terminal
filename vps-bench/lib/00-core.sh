# =====================================================================
# blackhole-vps-bench · 00-core.sh — constants, env, helpers
# =====================================================================
# shellcheck shell=bash

BH_VERSION="4.0.0"
BH_TOOL="blackhole-vps-bench"
BH_REPO="victoryvpsvn-star/blackhole-discord-terminal"

export LC_ALL=C
umask 077

# ------- configuration (env overridable, CLI wins later) -------
BH_FAST="${BH_FAST:-0}"
BH_NO_NET="${BH_NO_NET:-0}"
BH_NO_SEC="${BH_NO_SEC:-0}"
BH_WEBHOOK="${BH_WEBHOOK:-}"
BH_JSON_OUT="${BH_JSON_OUT:-}"
BH_MD_OUT="${BH_MD_OUT:-}"
BH_TXT_OUT="${BH_TXT_OUT:-}"
BH_DISK_DIR="${BH_DISK_DIR:-/tmp}"
BH_NO_COLOR="${BH_NO_COLOR:-0}"
# v4 additions
BH_REDACT="${BH_REDACT:-0}"          # 1 = mask identity (IPs, usernames, instance ids) in every sink
BH_MIN_SCORE="${BH_MIN_SCORE:-}"     # exit 3 when BH-SCORE total < N
BH_FAIL_ON="${BH_FAIL_ON:-}"         # warn|bad → exit 4 when security posture matches
BH_ONLY="${BH_ONLY:-}"               # comma list: run only these modules
BH_SKIP="${BH_SKIP:-}"               # comma list: skip these modules
BH_PROM_OUT="${BH_PROM_OUT:-}"       # prometheus textfile output path
BH_COMPARE_IN="${BH_COMPARE_IN:-}"   # previous JSON report for run-to-run diff
BH_PORT_PROBE="${BH_PORT_PROBE:-1}"  # 1 = outbound port viability checks (auto-off in fast/sec)

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
# now_ms: milliseconds since epoch, pure bash (no awk!) because mawk's
# printf "%d" saturates at INT32_MAX and would return a constant 2147483647
# on Debian/Ubuntu containers — that bug made every benchmark report 0 ms.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local secs frac
    secs=${EPOCHREALTIME%%.*}
    frac=${EPOCHREALTIME#*.}
    case "$frac" in ''|*[!0-9]*) frac=0 ;; esac
    printf '%s%03d' "$secs" $(( 10#$frac / 1000 ))
  elif [ -r /proc/uptime ]; then
    local up
    IFS=. read -r up _ < /proc/uptime 2>/dev/null || up=""
    case "$up" in ''|*[!0-9]*) printf '0'; return ;; esac
    printf '%s000' "$up"
  else
    date +%s000
  fi
}

# now_us: microsecond-resolution elapsed helper via $EPOCHREALTIME with the
# dot stripped (pure bash, zero forks) — used by the 4K random latency sampler.
now_us() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t=${EPOCHREALTIME%%.*}${EPOCHREALTIME#*.}
    case "$t" in ''|*[!0-9]*) printf '0'; return ;; esac
    printf '%s' "$t"
  else
    printf '%s000' "$(date +%s)"
  fi
}

# ------- formatting -------
fmt_mb()    { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else if (v>=1000) printf "%.2f GB/s", v/1024; else printf "%.1f MB/s", v }'; }
fmt_gbs()   { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else printf "%.2f GB/s", v }'; }
fmt_mbps()  { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else if (v>=1000) printf "%.2f Gbps", v/1000; else printf "%.1f Mbps", v }'; }
fmt_ms()    { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else printf "%.1f ms", v }'; }
fmt_mbint() { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print "n/a"; else printf "%d MB", v }'; }

# ------- gauge bar (v4) — bh_gauge VALUE MAX [WIDTH] -------
# Renders a 10-char (default) horizontal bar. Unicode ▰▱ by default,
# ASCII #--- when BH_GAUGE_ASCII=1 or the env looks non-UTF-8.
bh_gauge() {
  local v="${1:-0}" m="${2:-100}" w="${3:-10}"
  case "$w" in ''|*[!0-9]*|0) w=10 ;; esac
  local on='▰' off='▱'
  if [ "${BH_GAUGE_ASCII:-0}" = "1" ]; then on='#'; off='-'; fi
  local fill empty i s=""
  fill=$(awk -v v="$v" -v m="$m" -v w="$w" 'BEGIN{
    if (m+0<=0) m=1
    f = (v+0) / m * w
    if (f < 0) f = 0
    if (f > w) f = w
    printf "%.0f", f
  }')
  empty=$(( w - fill ))
  i=0; while [ "$i" -lt "$fill" ];  do s="$s$on";  i=$((i+1)); done
  i=0; while [ "$i" -lt "$empty" ]; do s="$s$off"; i=$((i+1)); done
  printf '%s' "$s"
}

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

# bh_cpuset count → number of cores in the cpuset mask ("0-7,12" → 9; "" → 0).
# v4 (bug G7): this now participates in the parallel-job count below.
bh_cpuset_count() {
  [ -n "$CPUSET" ] || { echo 0; return; }
  awk -v s="$CPUSET" 'BEGIN{
    n = 0; m = split(s, a, ",")
    for (i = 1; i <= m; i++) {
      p = split(a[i], r, "-")
      if (p == 2)          n += r[2] - r[1] + 1
      else if (a[i] != "") n++
    }
    print n
  }'
}
CPUSET_N_CORES="$(bh_cpuset_count)"

NCPU="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
if [ -z "$NCPU" ] || [ "$NCPU" -lt 1 ] 2>/dev/null; then NCPU=1; fi

# parallel jobs (v4, bug G7): min(cgroup CPU quota, NCPU, cpuset core count),
# capped at 64. Previously the cpuset was display-only, oversubscribing pinned
# containers and skewing the multi-core score + efficiency %.
BH_PAR_JOBS=$NCPU
BH_EFF_CORES=$NCPU
if awk -v q="$QUOTA_CORES" 'BEGIN{exit !(q+0>0)}'; then
  j=$(awk -v q="$QUOTA_CORES" 'BEGIN{ j=int(q); if (j<1) j=1; print j }')
  if [ "$j" -lt "$BH_PAR_JOBS" ]; then BH_PAR_JOBS=$j; fi
fi
if [ "${CPUSET_N_CORES:-0}" -gt 0 ] 2>/dev/null && [ "$CPUSET_N_CORES" -lt "$BH_PAR_JOBS" ]; then
  BH_PAR_JOBS=$CPUSET_N_CORES
fi
BH_EFF_CORES=$BH_PAR_JOBS
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
