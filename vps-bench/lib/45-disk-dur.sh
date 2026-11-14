# =====================================================================
# blackhole-vps-bench · 45-disk-dur.sh — fsync durability probe (v5)
# =====================================================================
# The DB-decision number: how long ONE 4K data-sync write actually takes
# (p50/p99) and how many fsyncs/sec that implies. Network-backed cloud
# disks, over-cached containers and tmpfs all expose themselves here.
# Design notes:
#   * The bench file is "$BH_DISK_DIR/bhv5c13_fsync_$$.img" — NEVER
#     $BH_RUNDIR (that lives under /tmp, frequently tmpfs, which would
#     fake a stellar result). A RAM-backed BH_DISK_DIR is still flagged
#     via BH_FSYNC_NOTE.
#   * Requires dd oflag=dsync AND a sanity write measurably >= 0.3 ms:
#     a dd that silently ignores oflag=dsync would report cache speed.
#   * Per-IO latencies are timed with now_us ($EPOCHREALTIME) exactly
#     like 50-disk's random-read sampler. NO per-IO `timeout` fork — it
#     would skew every sample; the loop is bounded by a wall-clock
#     deadline (6 s full / 3 s fast) plus an early-stop when the p99 of
#     the last 20 samples exceeds 100 ms (worst-case disks).
#   * Latency is reported AS-IS — no baseline subtraction. A mean of 50
#     plain (non-synced) 4K writes is kept in BH_FSYNC_BASE_MS so the
#     report layer can annotate "includes ~1-2ms process overhead" on
#     fast disks (p50 < 3 ms).
# shellcheck shell=bash

# ---- globals consumed by 70-report.sh ("" = not measured) ----
BH_FSYNC_P50_MS=""     # median of N dsync 4k writes, ms float ("0.9")
BH_FSYNC_P99_MS=""     # 99th percentile, ms float ("12.4")
BH_FSYNC_RPS=""        # 1000 / p50 -> sustainable fsyncs/sec
BH_FSYNC_BASE_MS=""    # mean of 50 PLAIN (non-synced) 4k writes, ms
BH_FSYNC_N=""          # samples actually collected
BH_FSYNC_NOTE=""       # caveat string (tmpfs dir, skipped reason, overhead)

# bhv5c13_note_join A B — join two note strings with "; " (private helper)
bhv5c13_note_join() {
  if [ -n "$1" ] && [ -n "$2" ]; then printf '%s; %s' "$1" "$2"
  else printf '%s%s' "$1" "$2"
  fi
}

bench_disk_dur() {
  BH_FSYNC_P50_MS=""; BH_FSYNC_P99_MS=""; BH_FSYNC_RPS=""
  BH_FSYNC_BASE_MS=""; BH_FSYNC_N=""; BH_FSYNC_NOTE=""

  local dir="$BH_DISK_DIR"
  mkdir -p "$dir" 2>/dev/null || dir=/tmp
  if [ ! -w "$dir" ]; then dir=/tmp; mkdir -p "$dir" 2>/dev/null; fi
  local file="$dir/bhv5c13_fsync_$$.img"
  local t0 rc lat

  # ---- free-space guard (same style as 50-disk X1; we need only ~1 MB) ----
  local dfout avail_kb
  dfout="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  case "$dfout" in ''|*[!0-9]*) dfout="" ;; esac
  if [ -z "$dfout" ] && [ "${BH_DISK_AVAIL_MB:-0}" -gt 0 ] 2>/dev/null; then
    dfout=$(( BH_DISK_AVAIL_MB * 1024 ))
  fi
  case "$dfout" in
    ''|*[!0-9]*)
      BH_FSYNC_NOTE="cannot determine free space of $dir — fsync bench skipped"
      return 0
      ;;
  esac
  avail_kb=$dfout
  if [ "$avail_kb" -lt 2048 ]; then
    BH_FSYNC_NOTE="free space < 2 MB ($(( avail_kb / 1024 )) MB free) — fsync bench skipped"
    return 0
  fi
  case "$(stat -f -c %T "$dir" 2>/dev/null)" in
    tmpfs|ramfs) BH_FSYNC_NOTE="bench-dir is RAM-backed (tmpfs) — numbers not disk" ;;
  esac

  t0="$(now_ms)"
  local t_dl=6000 n_max=200
  if [ "$BH_FAST" = "1" ]; then t_dl=3000; n_max=60; fi

  # ---- oflag=dsync support probe (50-disk's bh_dd_supports when loaded;
  #      lib glob order makes that guard mandatory, not cosmetic) ----
  local dsync_ok=0
  if declare -F bh_dd_supports >/dev/null 2>&1; then
    if bh_dd_supports "$file" oflag=dsync; then dsync_ok=1; fi
  else
    if dd if=/dev/zero of="$file" bs=1M count=1 oflag=dsync 2>/dev/null; then dsync_ok=1; fi
  fi
  rm -f "$file" 2>/dev/null
  if [ "$dsync_ok" -ne 1 ]; then
    BH_FSYNC_NOTE="$(bhv5c13_note_join "$BH_FSYNC_NOTE" "dd oflag=dsync unsupported — fsync bench skipped")"
    return 0
  fi

  # ---- sanity: one 4k dsync write must take measurably >= 0.3 ms ----
  local has_us=0 sane_us=300 sa sb
  case "${EPOCHREALTIME:-}" in *.*) has_us=1 ;; esac
  [ "$has_us" = "1" ] || sane_us=1000   # ms-resolution clock: demand 1 ms
  if [ "$has_us" = "1" ]; then sa=${EPOCHREALTIME//./}; else sa="$(now_us)"; fi
  dd if=/dev/zero of="$file" bs=4096 count=1 oflag=dsync 2>/dev/null
  rc=$?
  if [ "$has_us" = "1" ]; then sb=${EPOCHREALTIME//./}; else sb="$(now_us)"; fi
  if [ "$rc" -ne 0 ]; then
    BH_FSYNC_NOTE="$(bhv5c13_note_join "$BH_FSYNC_NOTE" "dsync 4k write failed — fsync bench skipped")"
    rm -f "$file" 2>/dev/null
    return 0
  fi
  lat=$(( sb - sa ))
  if [ "$lat" -lt 0 ] || [ "$lat" -lt "$sane_us" ]; then
    BH_FSYNC_NOTE="$(bhv5c13_note_join "$BH_FSYNC_NOTE" "oflag=dsync not honored (4k write not measurably synced) — fsync bench skipped")"
    rm -f "$file" 2>/dev/null
    return 0
  fi

  log "DISK bench: fsync durability (${n_max} dsync 4k writes)..."
  local bsum=0 bn=0 i=0 ok=0 latlist=""

  # ---- baseline: 50 PLAIN (no-sync) 4k writes, mean = process-overhead floor
  #      (capped at 1 s of wall time so the dsync loop keeps its budget) ----
  i=0
  while [ "$i" -lt 50 ]; do
    i=$(( i + 1 ))
    if [ "$has_us" = "1" ]; then sa=${EPOCHREALTIME//./}; else sa="$(now_us)"; fi
    dd if=/dev/zero of="$file" bs=4096 count=1 conv=notrunc 2>/dev/null
    rc=$?
    if [ "$has_us" = "1" ]; then sb=${EPOCHREALTIME//./}; else sb="$(now_us)"; fi
    if [ "$rc" -eq 0 ]; then
      lat=$(( sb - sa ))
      if [ "$lat" -ge 0 ] && [ "$lat" -le 60000000 ]; then
        bsum=$(( bsum + lat )); bn=$(( bn + 1 ))
      fi
    fi
    [ $(( $(now_ms) - t0 )) -gt 1000 ] && break
  done

  # ---- per-IO dsync loop (no per-IO fork beyond dd itself) ----
  local -a W
  local wi=0 wn=0 wmax wlat
  i=0
  while [ "$i" -lt "$n_max" ]; do
    i=$(( i + 1 ))
    if [ "$has_us" = "1" ]; then sa=${EPOCHREALTIME//./}; else sa="$(now_us)"; fi
    dd if=/dev/zero of="$file" bs=4096 count=1 oflag=dsync conv=notrunc 2>/dev/null
    rc=$?
    if [ "$has_us" = "1" ]; then sb=${EPOCHREALTIME//./}; else sb="$(now_us)"; fi
    if [ "$rc" -eq 0 ]; then
      lat=$(( sb - sa ))
      if [ "$lat" -ge 0 ] && [ "$lat" -le 60000000 ]; then
        ok=$(( ok + 1 ))
        latlist="$latlist $lat"
        W[wi]=$lat
        wi=$(( (wi + 1) % 20 ))
        [ "$wn" -lt 20 ] && wn=$(( wn + 1 ))
      fi
    fi
    # bounded loop: wall-clock deadline first...
    [ $(( $(now_ms) - t0 )) -gt "$t_dl" ] && break
    # ...then early stop when p99 of the last 20 samples > 100 ms
    # (p99 of 20 sorted values = the max — checked without a single fork)
    if [ "$wn" -eq 20 ] && [ $(( ok % 20 )) -eq 0 ]; then
      wmax=0
      for wlat in "${W[@]}"; do
        [ "$wlat" -gt "$wmax" ] && wmax=$wlat
      done
      [ "$wmax" -gt 100000 ] && break
    fi
  done

  # ---- stats: ONE sort -n + awk pass -> p50/p99 in ms (float, 1 decimal) ----
  if [ "$ok" -ge 10 ]; then
    local out
    # shellcheck disable=SC2086  # deliberate word split: one latency (us) per line
    out="$(printf '%s\n' $latlist | sort -n | awk '
      { v[NR] = $1 }
      END {
        n = NR
        if (n < 1) exit 1
        i50 = int((n * 50 + 99) / 100); if (i50 < 1) i50 = 1; if (i50 > n) i50 = n
        i99 = int((n * 99 + 99) / 100); if (i99 < 1) i99 = 1; if (i99 > n) i99 = n
        printf "%.1f %.1f\n", v[i50] / 1000, v[i99] / 1000
      }' 2>/dev/null)"
    case "$out" in
      *' '*)
        BH_FSYNC_P50_MS="${out%% *}"
        BH_FSYNC_P99_MS="${out##* }"
        BH_FSYNC_N="$ok"
        BH_FSYNC_RPS="$(awk -v p="$BH_FSYNC_P50_MS" 'BEGIN{ if (p + 0 > 0) printf "%.1f", 1000 / p }')"
        ;;
    esac
  fi
  if [ -n "$BH_FSYNC_P50_MS" ]; then
    [ "$bn" -gt 0 ] && \
      BH_FSYNC_BASE_MS="$(awk -v s="$bsum" -v n="$bn" 'BEGIN{ printf "%.2f", s / n / 1000 }')"
    if awk -v p="$BH_FSYNC_P50_MS" 'BEGIN{ exit !(p + 0 > 0 && p + 0 < 3) }'; then
      BH_FSYNC_NOTE="$(bhv5c13_note_join "$BH_FSYNC_NOTE" "includes ~1-2ms process overhead")"
    fi
  else
    BH_FSYNC_NOTE="$(bhv5c13_note_join "$BH_FSYNC_NOTE" "fewer than 10 usable dsync samples — fsync bench skipped")"
  fi

  rm -f "$file" 2>/dev/null
  return 0
}
