# =====================================================================
# blackhole-vps-bench · 50-disk.sh — disk benchmark (dd, direct-first)
# =====================================================================
# v4.0 changes:
#   * G1 FIX: the old "4K read" was actually a sequential dd stream. It
#     is now a TRUE random-offset read test: N single-4K reads at
#     pseudo-random 4K-aligned offsets (pure-bash RNG), each timed with
#     the $EPOCHREALTIME µs-integer trick (dot stripped), ONE sort pass
#     -> p50/p90/p99 latency (ms) + a genuine random-read MB/s figure.
#   * The 4K write pass runs on its OWN file; the seq write/read test
#     keeps the v3 logic (adaptive payload, direct-first negotiation).
#   * S7: live /proc/diskstats proof — counters are sampled around the
#     whole bench, filtered to the real backing device's major:minor
#     (stat -c %d decoded, verified against /sys/dev/block). No match
#     (tmpfs/overlay anonymous dev, missing line) -> skipped entirely,
#     never a whole-container guess.
#   * X1: free-space guard — every payload is capped at 20% of the free
#     space; the bench is refused entirely when free < 3x the payload.
#     tmpfs/ramfs bench dirs are flagged (RAM-backed, not disk).
#   * S6: passive TRIM/discard matrix from sysfs + /proc/mounts — this
#     module NEVER runs fstrim or any destructive discard.
# Timeout policy: probes, staging writes and fio run under `timeout`.
# The per-IO dd inside the latency loop is intentionally NOT wrapped —
# a `timeout` fork per sample would skew every latency number; that loop
# is instead bounded by a wall-clock deadline and the free-space guard.
# =====================================================================
# shellcheck shell=bash

# ---- globals consumed by 70-report.sh (all names must keep working) ----
BH_SEQW=""; BH_SEQR=""; BH_4KW=""; BH_4KR=""
BH_4K_IOPS_W=""; BH_4K_IOPS_R=""   # dd-derived baseline IOPS (fio stays premium)
BH_DISK_MODE=""; BH_FIO_RIOPS=""; BH_FIO_WIOPS=""

# ---- v4 additions ----
BH_4K_LAT_P50_MS=""; BH_4K_LAT_P90_MS=""; BH_4K_LAT_P99_MS=""
BH_4K_LAT_LABEL=""                     # "direct" | "cached" | "n/a"
BH_LIVE_IOPS=""; BH_LIVE_MBPS=""; BH_LIVE_BUSY_PCT=""; BH_LIVE_DEV=""
BH_DISK_BENCH_FS=""; BH_DISK_WARN=""
BH_TRIM_SUPPORT=""                     # "yes" | "no" | "unknown"
BH_DISCARD_MOUNT=""                    # "yes" | "no" | "" (unknown)

# internal state (not part of the report contract)
BH_RFLAGS4K=""
BH_LIVE_MAJMIN=""; BH_LIVE_T0=""; BH_LIVE_S0=""

# bh_dsk_to SECS CMD... — run CMD under `timeout` when available
bh_dsk_to() {
  local s="$1"; shift
  if command_exists timeout; then
    timeout "$s" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

bh_dd_supports() { # $1=file, rest=dd flags — probe with a 1 MB write
  local file="$1"; shift
  bh_dsk_to 10 dd if=/dev/zero of="$file" bs=1M count=1 "$@"
}

# join two warn strings with "; ", skipping empty parts
bh_dsk_join() {
  if [ -n "$1" ] && [ -n "$2" ]; then printf '%s; %s' "$1" "$2"
  else printf '%s%s' "$1" "$2"
  fi
}

# bh_dsk_majmin DIR -> "maj:min" of the real block device holding DIR ("" if none).
# st_dev (stat -c %d) decoded per new_encode_dev and verified against
# /sys/dev/block — anonymous devices (tmpfs, overlayfs, btrfs subvols)
# never match there, so the live proof skips instead of guessing.
bh_dsk_majmin() {
  local d="$1" dv maj min
  [ -d "$d" ] || return 0
  dv="$(stat -c %d "$d" 2>/dev/null)" || return 0
  case "$dv" in ''|*[!0-9]*) return 0 ;; esac
  maj=$(( (dv & 0xfff00) >> 8 ))
  min=$(( (dv & 0xff) | ((dv >> 12) & 0xfff00) ))
  [ -e "/sys/dev/block/$maj:$min" ] || return 0
  printf '%s:%s' "$maj" "$min"
}

# bh_dsk_stats_line MAJ:MIN -> "reads writes rsectors wsectors io_ticks_ms" | ""
# /proc/diskstats named fields: read_count=$4, write_count=$8,
# sectors_read=$6, sectors_written=$10, io_ticks=$13 (ms, from the end:
# 4th-from-last on modern kernels). The sector delta for MB/s uses BOTH
# transfer counters ($6 + $10) — $10 alone would only count writes and
# under-report the read phases of this bench.
bh_dsk_stats_line() {
  local maj="${1%%:*}" min="${1##*:}"
  [ -r /proc/diskstats ] || return 0
  awk -v M="$maj" -v N="$min" '$1 == M && $2 == N { print $4, $8, $6, $10, $13; exit }' /proc/diskstats 2>/dev/null
}

# bh_dsk_lat_stats "us us us ..." — ONE sort pass -> P50/P90/P99 in ms
bh_dsk_lat_stats() {
  BH_4K_LAT_P50_MS=""; BH_4K_LAT_P90_MS=""; BH_4K_LAT_P99_MS=""
  [ -n "${1:-}" ] || return 0
  local out
  # shellcheck disable=SC2086  # deliberate word split: one latency per line
  out="$(printf '%s\n' $1 | sort -n | awk '
    { v[NR] = $1 }
    END {
      n = NR
      if (n < 1) exit 0
      i50 = int((n * 50 + 99) / 100); if (i50 < 1) i50 = 1; if (i50 > n) i50 = n
      i90 = int((n * 90 + 99) / 100); if (i90 < 1) i90 = 1; if (i90 > n) i90 = n
      i99 = int((n * 99 + 99) / 100); if (i99 < 1) i99 = 1; if (i99 > n) i99 = n
      printf "%.2f %.2f %.2f\n", v[i50] / 1000, v[i90] / 1000, v[i99] / 1000
    }' 2>/dev/null)"
  case "$out" in *' '*) : ;; *) return 0 ;; esac
  BH_4K_LAT_P50_MS="${out%% *}"
  BH_4K_LAT_P99_MS="${out##* }"
  BH_4K_LAT_P90_MS="${out#* }"; BH_4K_LAT_P90_MS="${BH_4K_LAT_P90_MS% *}"
}

# bh_dsk_live_start DIR — open the live-diskstats sampling window
bh_dsk_live_start() {
  BH_LIVE_IOPS=""; BH_LIVE_MBPS=""; BH_LIVE_BUSY_PCT=""; BH_LIVE_DEV=""
  BH_LIVE_MAJMIN="$(bh_dsk_majmin "$1")"
  [ -n "$BH_LIVE_MAJMIN" ] || return 0
  BH_LIVE_S0="$(bh_dsk_stats_line "$BH_LIVE_MAJMIN")"
  [ -n "$BH_LIVE_S0" ] || { BH_LIVE_MAJMIN=""; return 0; }   # no line -> skip
  BH_LIVE_T0="$(now_ms)"
}

# bh_dsk_live_finish — close the window, derive IOPS / MB/s / busy%
bh_dsk_live_finish() {
  [ -n "$BH_LIVE_MAJMIN" ] && [ -n "$BH_LIVE_S0" ] && [ -n "$BH_LIVE_T0" ] || return 0
  local s2 t1 dt nm
  s2="$(bh_dsk_stats_line "$BH_LIVE_MAJMIN")"
  [ -n "$s2" ] || return 0
  t1="$(now_ms)"
  dt=$(( t1 - BH_LIVE_T0 ))
  [ "$dt" -ge 500 ] || return 0
  local r0 w0 sr0 sw0 b0 r1 w1 sr1 sw1 b1
  # shellcheck disable=SC2086  # intentional word-split of "reads writes rsect wsect ioticks"
  set -- $BH_LIVE_S0; r0=$1; w0=$2; sr0=$3; sw0=$4; b0=$5
  # shellcheck disable=SC2086
  set -- $s2;         r1=$1; w1=$2; sr1=$3; sw1=$4; b1=$5
  local dr=$(( r1 - r0 )) dw=$(( w1 - w0 )) dsr=$(( sr1 - sr0 )) dsw=$(( sw1 - sw0 )) db=$(( b1 - b0 ))
  [ "$dr" -ge 0 ] && [ "$dw" -ge 0 ] && [ "$dsr" -ge 0 ] && [ "$dsw" -ge 0 ] && [ "$db" -ge 0 ] || return 0
  nm="$(readlink -f "/sys/dev/block/$BH_LIVE_MAJMIN" 2>/dev/null)"
  BH_LIVE_DEV="${nm##*/}"
  [ -n "$BH_LIVE_DEV" ] || BH_LIVE_DEV="$BH_LIVE_MAJMIN"
  # IOPS = delta(reads+writes)/s; MB/s = delta(read+write sectors)*512/s/1e6;
  # busy% = delta(io_ticks ms) / wall-ms * 100 (may exceed 100 on multi-queue NVMe)
  BH_LIVE_IOPS="$(awk -v ops=$(( dr + dw )) -v ms="$dt" 'BEGIN{ ts = ms / 1000; if (ts > 0) printf "%.0f", ops / ts }')"
  BH_LIVE_MBPS="$(awk -v s=$(( dsr + dsw )) -v ms="$dt" 'BEGIN{ ts = ms / 1000; if (ts > 0) printf "%.1f", s * 512 / ts / 1000000 }')"
  BH_LIVE_BUSY_PCT="$(awk -v b="$db" -v ms="$dt" 'BEGIN{ if (ms > 0) printf "%.1f", b * 100 / ms }')"
}

# bh_dsk_trim_scan MAJ:MIN — passive TRIM matrix (never runs fstrim)
bh_dsk_trim_scan() {
  BH_TRIM_SUPPORT="unknown"
  if [ -n "${1:-}" ]; then
    local rp whole dg dm
    rp="$(readlink -f "/sys/dev/block/$1" 2>/dev/null)"
    # /sys/devices/.../block/vda/vda1 -> backing whole disk = first component after /block/
    whole="$(printf '%s' "$rp" | awk -F '/block/' '{ print $2 }' | awk -F '/' '{ print $1 }')"
    if [ -n "$whole" ] && [ -d "/sys/block/$whole/queue" ]; then
      dg="$(tr -d ' \t\n\r' < "/sys/block/$whole/queue/discard_granularity" 2>/dev/null)"
      dm="$(tr -d ' \t\n\r' < "/sys/block/$whole/queue/discard_max_hw_bytes" 2>/dev/null)"
      [ -n "$dm" ] || dm="$(tr -d ' \t\n\r' < "/sys/block/$whole/queue/discard_max_bytes" 2>/dev/null)"
      case "$dg" in ''|*[!0-9]*) dg="" ;; esac
      case "$dm" in ''|*[!0-9]*) dm="" ;; esac
      if [ -n "$dg" ] && [ -n "$dm" ]; then
        if [ "$dg" -gt 0 ] && [ "$dm" -gt 0 ]; then BH_TRIM_SUPPORT="yes"; else BH_TRIM_SUPPORT="no"; fi
      fi
    fi
  fi
  BH_DISCARD_MOUNT=""
  if [ -r /proc/mounts ]; then
    # real fs mount carrying the kernel auto-discard option ("discard",
    # "discard=sync/async/once"); "nodiscard" does NOT match the pattern
    if awk '$3 ~ /^(ext[234]|xfs|btrfs|f2fs|vfat|exfat|ntfs3?|jfs|reiserfs|ubifs|zfs)$/ && $4 ~ /(^|,)discard(=|,|$)/ { f = 1; exit } END { exit !f }' /proc/mounts 2>/dev/null; then
      BH_DISCARD_MOUNT="yes"
    else
      BH_DISCARD_MOUNT="no"
    fi
  fi
}

bench_disk() {
  local dir="$BH_DISK_DIR"
  mkdir -p "$dir" 2>/dev/null || dir=/tmp
  if [ ! -w "$dir" ]; then dir=/tmp; mkdir -p "$dir" 2>/dev/null; fi
  local file="$dir/.bhvps_disk_$$"      # seq payload (v3 file, logic untouched)
  local wfile="$dir/.bhvps_4kw_$$"      # v4: 4K write gets its own file
  local rfile="$dir/.bhvps_rand_$$"     # v4: random-read payload (urandom)
  local t_bench0 t0 t1 ms rc next
  t_bench0="$(now_ms)"

  # ---------------- X1: fs type + free-space guard ----------------
  local dfout avail_kb cap_mb cap4k seqmb seq4k randmb seqmb_cap seq4k_cap seq_to
  BH_DISK_BENCH_FS="$(stat -f -c %T "$dir" 2>/dev/null)"
  BH_DISK_WARN=""
  case "$BH_DISK_BENCH_FS" in
    tmpfs|ramfs)
      BH_DISK_WARN="bench-dir is RAM-backed (tmpfs) — numbers not disk"
      ;;
  esac
  dfout="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  case "$dfout" in ''|*[!0-9]*) dfout="" ;; esac
  if [ -z "$dfout" ] && [ "${BH_DISK_AVAIL_MB:-0}" -gt 0 ] 2>/dev/null; then
    dfout=$(( BH_DISK_AVAIL_MB * 1024 ))
  fi
  case "$dfout" in
    ''|*[!0-9]*|0)
      BH_DISK_WARN="$(bh_dsk_join "$BH_DISK_WARN" "cannot determine free space of $dir — disk bench skipped")"
      BH_4K_LAT_LABEL="n/a"
      return 0
      ;;
  esac
  avail_kb=$dfout

  # S6 TRIM matrix — read-only sysfs/mounts info, collected even if the
  # space guard refuses the payload afterwards
  bh_dsk_trim_scan "$(bh_dsk_majmin "$dir")"

  cap_mb=$(( avail_kb / 5120 ))   # 20% of free space, whole MB
  cap4k=$(( avail_kb / 20 ))      # 20% of free space, 4K blocks
  case "$BH_DISK_BENCH_FS" in
    tmpfs|ramfs)
      # RAM-backed bench dir: also respect the cgroup RAM limit
      if [ "${MEM_LIMIT_KB:-0}" -gt 0 ] 2>/dev/null; then
        [ "$cap_mb" -gt $(( MEM_LIMIT_KB / 5120 )) ] && cap_mb=$(( MEM_LIMIT_KB / 5120 ))
        [ "$cap4k" -gt $(( MEM_LIMIT_KB / 20 )) ]    && cap4k=$(( MEM_LIMIT_KB / 20 ))
      fi
      ;;
  esac
  seqmb=256; seq4k=8192; randmb=256
  if [ "$BH_FAST" = "1" ]; then seqmb=96; seq4k=4096; randmb=64; fi
  [ "$seqmb" -gt "$cap_mb" ] && seqmb=$cap_mb
  [ "$seqmb" -lt 16 ] && seqmb=16
  [ "$randmb" -gt "$cap_mb" ] && randmb=$cap_mb
  [ "$randmb" -lt 16 ] && randmb=16
  [ "$seq4k" -gt "$cap4k" ] && seq4k=$cap4k
  [ "$seq4k" -lt 2048 ] && seq4k=2048
  # refuse when free < 3x the payload — never wedge a nearly-full disk
  if [ $(( seqmb * 3072 )) -gt "$avail_kb" ] || \
     [ $(( randmb * 3072 )) -gt "$avail_kb" ] || \
     [ $(( seq4k * 12 )) -gt "$avail_kb" ]; then
    BH_DISK_WARN="$(bh_dsk_join "$BH_DISK_WARN" "free space < 3x test payload ($(( avail_kb / 1024 )) MB free) — disk bench skipped")"
    BH_4K_LAT_LABEL="n/a"
    return 0
  fi
  seqmb_cap=$cap_mb; [ "$seqmb_cap" -lt 16 ]  && seqmb_cap=16
  seq4k_cap=$cap4k;  [ "$seq4k_cap" -lt 2048 ] && seq4k_cap=2048
  seq_to=20; [ "$BH_FAST" = "1" ] && seq_to=10

  # ------------- S7: open the live-diskstats proof window -------------
  bh_dsk_live_start "$dir"

  # pick the strongest write mode this filesystem accepts
  BH_DISK_MODE="plain"
  if bh_dd_supports "$file" oflag=direct conv=fdatasync; then
    BH_WFLAGS="oflag=direct conv=fdatasync"; BH_DISK_MODE="direct+fsync"
  elif bh_dd_supports "$file" conv=fdatasync; then
    BH_WFLAGS="conv=fdatasync"; BH_DISK_MODE="fsync (buffered)"
  elif bh_dd_supports "$file" conv=fsync; then
    BH_WFLAGS="conv=fsync"; BH_DISK_MODE="fsync (buffered)"
  else
    BH_WFLAGS=""; BH_DISK_MODE="plain (cache-inflated!)"
  fi
  BH_RFLAGS=""
  if dd if="$file" of=/dev/null bs=1M count=1 iflag=direct 2>/dev/null; then
    BH_RFLAGS="iflag=direct"; BH_DISK_MODE="${BH_DISK_MODE} +direct-read"
  fi

  local seqw_ok=0 seq4k_ok=0
  log "DISK bench on $dir (mode: $BH_DISK_MODE): seq write (adaptive from ${seqmb} MB)..."

  # ---- seq write (v3 logic: adaptive payload, double until >= 300 ms) ----
  while :; do
    t0=$(now_ms)
    # shellcheck disable=SC2086  # flags are intentionally word-split
    if bh_dsk_to "$seq_to" dd if=/dev/zero of="$file" bs=1M count="$seqmb" $BH_WFLAGS 2>/dev/null; then rc=0; else rc=1; fi
    sync 2>/dev/null
    t1=$(now_ms)
    ms=$((t1 - t0))
    { [ "$rc" -ne 0 ] || [ "$ms" -ge 300 ] || [ "$seqmb" -ge 1024 ] || [ "$seqmb" -ge "$seqmb_cap" ]; } && break
    next=$((seqmb * 2)); [ "$next" -gt "$seqmb_cap" ] && next=$seqmb_cap
    [ "$next" -le "$seqmb" ] && break
    seqmb=$next
  done
  if [ "$rc" -eq 0 ]; then
    seqw_ok=1
    BH_SEQW="$(awk -v n="$seqmb" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*1048576/(ms/1000)/1048576; else print 0 }')"
  fi

  # ---- seq read over the same file (direct when negotiated; the buffered
  #      case keeps the v3 "cache-inflated" semantics via BH_DISK_MODE) ----
  if [ "$seqw_ok" = 1 ]; then
    t0=$(now_ms)
    # shellcheck disable=SC2086
    if bh_dsk_to "$seq_to" dd if="$file" of=/dev/null bs=1M $BH_RFLAGS 2>/dev/null; then rc=0; else rc=1; fi
    t1=$(now_ms)
    ms=$((t1 - t0))
    [ "$rc" -ne 0 ] || BH_SEQR="$(awk -v n="$seqmb" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*1048576/(ms/1000)/1048576; else print 0 }')"
  fi
  rm -f "$file" 2>/dev/null    # seq payload no longer needed — free the space

  # ---- 4K write pass on its OWN file (v3 adaptive logic, x4 growth) ----
  log "DISK bench: 4K blocks (adaptive from ${seq4k})..."
  while :; do
    t0=$(now_ms)
    # shellcheck disable=SC2086
    if bh_dsk_to "$seq_to" dd if=/dev/zero of="$wfile" bs=4k count="$seq4k" $BH_WFLAGS 2>/dev/null; then rc=0; else rc=1; fi
    sync 2>/dev/null
    t1=$(now_ms)
    ms=$((t1 - t0))
    { [ "$rc" -ne 0 ] || [ "$ms" -ge 300 ] || [ "$seq4k" -ge 131072 ] || [ "$seq4k" -ge "$seq4k_cap" ]; } && break
    next=$((seq4k * 4)); [ "$next" -gt "$seq4k_cap" ] && next=$seq4k_cap
    [ "$next" -le "$seq4k" ] && break
    seq4k=$next
  done
  if [ "$rc" -eq 0 ]; then
    seq4k_ok=1
    BH_4KW="$(awk -v n="$seq4k" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*4096/(ms/1000)/1048576; else print 0 }')"
    BH_4K_IOPS_W="$(awk -v n="$seq4k" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n/(ms/1000); else print "" }')"
  fi
  rm -f "$wfile" 2>/dev/null

  # ---- G1 FIX: TRUE 4K random-offset read test (latency + MB/s) ----
  local do_rand=1 rand_gate rl has_us dl
  local nblocks niter it off lat t_l0 t_l1 okcnt tbytes latlist
  rand_gate=16000; [ "$BH_FAST" = "1" ] && rand_gate=6000
  [ $(( $(now_ms) - t_bench0 )) -gt "$rand_gate" ] && do_rand=0
  if [ "$do_rand" = 1 ]; then
    log "DISK bench: 4K random-offset reads (${randmb} MB payload, latency percentiles)..."
    if bh_dsk_to 10 dd if=/dev/urandom of="$rfile" bs=1M count="$randmb" conv=fdatasync 2>/dev/null; then
      # read-path ladder: direct -> nocache (buffered, drop-cache) -> plain
      if dd if="$rfile" of=/dev/null bs=4096 count=1 skip=0 iflag=direct status=none 2>/dev/null; then
        rl="iflag=direct status=none"; BH_4K_LAT_LABEL="direct"
      elif dd if="$rfile" of=/dev/null bs=4096 count=1 skip=0 iflag=direct 2>/dev/null; then
        rl="iflag=direct"; BH_4K_LAT_LABEL="direct"
      elif dd if="$rfile" of=/dev/null bs=4096 count=1 skip=0 iflag=nocache status=none 2>/dev/null; then
        rl="iflag=nocache status=none"; BH_4K_LAT_LABEL="cached"
      elif dd if="$rfile" of=/dev/null bs=4096 count=1 skip=0 iflag=nocache 2>/dev/null; then
        rl="iflag=nocache"; BH_4K_LAT_LABEL="cached"
      elif dd if="$rfile" of=/dev/null bs=4096 count=1 skip=0 2>/dev/null; then
        rl=""; BH_4K_LAT_LABEL="cached"
      else
        rl="X"; BH_4K_LAT_LABEL="n/a"
      fi
      if [ "$rl" != "X" ]; then
        BH_RFLAGS4K="$rl"
        nblocks=$(( randmb * 256 ))
        niter=400; [ "$BH_FAST" = "1" ] && niter=150
        has_us=0; case "${EPOCHREALTIME:-}" in *.*) has_us=1 ;; esac
        if [ "$has_us" = 1 ]; then
          t_l0=${EPOCHREALTIME//./}
          dl=$(( 8 * 1000000 )); [ "$BH_FAST" = "1" ] && dl=$(( 4 * 1000000 ))
        else
          # no µs clock (old bash): keep the throughput number, no latencies
          t_l0="$(now_ms)"
          dl=8000; [ "$BH_FAST" = "1" ] && dl=4000
          BH_4K_LAT_LABEL="n/a"
        fi
        it=0; okcnt=0; tbytes=0; latlist=""
        while [ "$it" -lt "$niter" ]; do
          it=$(( it + 1 ))
          # pure-bash uniform 30-bit pick folded into the 4K-block range
          off=$(( (RANDOM << 15 | RANDOM) % nblocks ))
          if [ "$has_us" = 1 ]; then t0=${EPOCHREALTIME//./}; else t0="$(now_ms)"; fi
          # shellcheck disable=SC2086  # rl is intentionally word-split
          dd if="$rfile" of=/dev/null bs=4096 count=1 skip=$off $rl 2>/dev/null
          rc=$?
          if [ "$has_us" = 1 ]; then t1=${EPOCHREALTIME//./}; else t1="$(now_ms)"; fi
          if [ "$rc" -eq 0 ]; then
            okcnt=$(( okcnt + 1 )); tbytes=$(( tbytes + 4096 ))
            if [ "$has_us" = 1 ]; then
              lat=$(( t1 - t0 ))
              [ "$lat" -ge 0 ] && [ "$lat" -le 60000000 ] && latlist="$latlist $lat"
            fi
          fi
          # bounded loop: no per-IO timeout fork (it would skew latencies)
          if [ "$has_us" = 1 ]; then
            [ $(( ${EPOCHREALTIME//./} - t_l0 )) -gt "$dl" ] && break
          else
            [ $(( $(now_ms) - t_l0 )) -gt "$dl" ] && break
          fi
        done
        if [ "$has_us" = 1 ]; then t1=${EPOCHREALTIME//./}; else t1="$(now_ms)"; fi
        if [ "$okcnt" -ge 10 ] && [ "$t1" -gt "$t_l0" ]; then
          if [ "$has_us" = 1 ]; then
            BH_4KR="$(awk -v b="$tbytes" -v us=$(( t1 - t_l0 )) 'BEGIN{ if (us > 0) printf "%.2f", b / (us / 1000000) / 1048576 }')"
          else
            BH_4KR="$(awk -v b="$tbytes" -v ms=$(( t1 - t_l0 )) 'BEGIN{ if (ms > 0) printf "%.2f", b / (ms / 1000) / 1048576 }')"
          fi
        fi
        if [ "$has_us" = 1 ]; then
          bh_dsk_lat_stats "$latlist"
          [ -n "$BH_4K_LAT_P50_MS" ] || BH_4K_LAT_LABEL="n/a"
          # report guard: derived IOPS only for the honest direct path
          if [ "$BH_4K_LAT_LABEL" = "direct" ] && [ -n "$BH_4K_LAT_P50_MS" ]; then
            BH_4K_IOPS_R="$(awk -v p="$BH_4K_LAT_P50_MS" 'BEGIN{ if (p + 0 > 0) printf "%.0f", 1000 / p }')"
          fi
        fi
      fi
    else
      BH_4K_LAT_LABEL="n/a"
    fi
  else
    BH_4K_LAT_LABEL="n/a"
  fi
  rm -f "$rfile" 2>/dev/null

  # ---- S7: close the window and derive the live device numbers ----
  bh_dsk_live_finish

  # optional: fio cross-check of 4K random IOPS (gated by time + 20% space rule)
  if command_exists fio && [ "$BH_FAST" != "1" ] && [ "$seq4k_ok" = 1 ] && \
     [ $(( $(now_ms) - t_bench0 )) -lt 12000 ] && [ "$avail_kb" -ge 163840 ]; then
    log "DISK bench: fio 4k randrw (8s, direct)..."
    local fj="$BH_RUNDIR/fio.json" r w
    if bh_dsk_to 14 fio --name=bh --filename="$dir/.bhvps_fio_$$" --size=32M --bs=4k --rw=randrw \
        --rwmixread=50 --ioengine=sync --direct=1 --numjobs=1 --runtime=8 \
        --time_based --group_reporting --output-format=json \
        --output="$fj" >/dev/null 2>&1 && [ -s "$fj" ]; then
      r="$(grep -oE '"iops"[[:space:]]*:[[:space:]]*[0-9.]+' "$fj" | head -n 1 | grep -oE '[0-9.]+$')"
      w="$(grep -oE '"iops"[[:space:]]*:[[:space:]]*[0-9.]+' "$fj" | tail -n 1 | grep -oE '[0-9.]+$')"
      [ -n "$r" ] && BH_FIO_RIOPS="$(awk -v r="$r" 'BEGIN{printf "%.0f", r}')"
      [ -n "$w" ] && BH_FIO_WIOPS="$(awk -v w="$w" 'BEGIN{printf "%.0f", w}')"
    fi
    rm -f "$dir/.bhvps_fio_$$" 2>/dev/null
  fi
}
