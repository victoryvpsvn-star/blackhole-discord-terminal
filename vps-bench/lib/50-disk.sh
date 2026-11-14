# =====================================================================
# blackhole-vps-bench · 50-disk.sh — disk benchmark (dd with auto flag pick)
# Tries direct I/O first for honest numbers; falls back cleanly on
# filesystems that reject O_DIRECT (common inside containers/overlayfs).
# Optional fio pass when available for true 4K random numbers.
# =====================================================================
# shellcheck shell=bash

BH_SEQW=""; BH_SEQR=""; BH_4KW=""; BH_4KR=""
BH_4K_IOPS_W=""; BH_4K_IOPS_R=""   # dd-derived baseline IOPS (fio stays premium)
BH_DISK_MODE=""; BH_FIO_RIOPS=""; BH_FIO_WIOPS=""

bh_dd_supports() { # $1=flags — probe with a 1 MB write
  local file="$1"; shift
  dd if=/dev/zero of="$file" bs=1M count=1 "$@" 2>/dev/null
}

bench_disk() {
  local dir="$BH_DISK_DIR"
  mkdir -p "$dir" 2>/dev/null || dir=/tmp
  if [ ! -w "$dir" ]; then dir=/tmp; mkdir -p "$dir" 2>/dev/null; fi
  local file="$dir/.bhvps_disk_$$"

  # keep payloads small on tiny disks: at most ~20% of available space
  local seqmb=256 seq4k=8192
  [ "$BH_FAST" = "1" ] && { seqmb=96; seq4k=4096; }
  if [ "${BH_DISK_AVAIL_MB:-0}" -gt 64 ] 2>/dev/null; then
    seqmb="$(awk_min2 "$seqmb" "$(awk -v a="$BH_DISK_AVAIL_MB" 'BEGIN{printf "%d", a/5}')")"
    # keep the 4k payload (seq4k * 4096 bytes) inside the same ~20% budget
    seq4k="$(awk_min2 "$seq4k" "$(awk -v a="$BH_DISK_AVAIL_MB" 'BEGIN{printf "%d", a*51.2}')")"
  fi

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

  local t0 t1 ms
  log "DISK bench on $dir (mode: $BH_DISK_MODE): seq write (adaptive from ${seqmb} MB)..."

  # adaptive payload: double until the measurement window is >= 300 ms
  while :; do
    t0=$(now_ms)
    # shellcheck disable=SC2086  # flags are intentionally word-split
    dd if=/dev/zero of="$file" bs=1M count="$seqmb" $BH_WFLAGS 2>/dev/null
    sync 2>/dev/null
    t1=$(now_ms)
    ms=$((t1 - t0))
    { [ "$ms" -ge 300 ] || [ "$seqmb" -ge 1024 ] || [ "$seqmb" -ge $((BH_DISK_AVAIL_MB / 2)) ]; } && break
    seqmb=$((seqmb * 2))
  done
  BH_SEQW="$(awk -v n="$seqmb" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*1048576/(ms/1000)/1048576; else print 0 }')"

  t0=$(now_ms)
  # shellcheck disable=SC2086
  dd if="$file" of=/dev/null bs=1M $BH_RFLAGS 2>/dev/null
  t1=$(now_ms)
  ms=$((t1 - t0))
  BH_SEQR="$(awk -v n="$seqmb" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*1048576/(ms/1000)/1048576; else print 0 }')"

  log "DISK bench: 4K blocks (adaptive from ${seq4k})..."
  while :; do
    t0=$(now_ms)
    # shellcheck disable=SC2086
    dd if=/dev/zero of="$file" bs=4k count="$seq4k" $BH_WFLAGS 2>/dev/null
    sync 2>/dev/null
    t1=$(now_ms)
    ms=$((t1 - t0))
    { [ "$ms" -ge 300 ] || [ "$seq4k" -ge 131072 ]; } && break
    seq4k=$((seq4k * 4))
  done
  BH_4KW="$(awk -v n="$seq4k" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*4096/(ms/1000)/1048576; else print 0 }')"
  # baseline 4K write IOPS = ops / seconds (ops = final 4K block count)
  BH_4K_IOPS_W="$(awk -v n="$seq4k" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n/(ms/1000); else print "" }')"

  t0=$(now_ms)
  # shellcheck disable=SC2086
  dd if="$file" of=/dev/null bs=4k $BH_RFLAGS 2>/dev/null
  t1=$(now_ms)
  ms=$((t1 - t0))
  BH_4KR="$(awk -v n="$seq4k" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*4096/(ms/1000)/1048576; else print 0 }')"
  # baseline 4K read IOPS over the same payload
  BH_4K_IOPS_R="$(awk -v n="$seq4k" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n/(ms/1000); else print "" }')"

  rm -f "$file" 2>/dev/null

  # optional: fio for true 4K random IOPS
  if command_exists fio && [ "$BH_FAST" != "1" ]; then
    log "DISK bench: fio 4k randrw (8s, direct)..."
    local fj="$BH_RUNDIR/fio.json"
    if fio --name=bh --filename="$dir/.bhvps_fio_$$" --size=32M --bs=4k --rw=randrw \
        --rwmixread=50 --ioengine=sync --direct=1 --numjobs=1 --runtime=8 \
        --time_based --group_reporting --output-format=json \
        --output="$fj" >/dev/null 2>&1 && [ -s "$fj" ]; then
      local r w
      r="$(grep -oE '"iops"[[:space:]]*:[[:space:]]*[0-9.]+' "$fj" | head -n 1 | grep -oE '[0-9.]+$')"
      w="$(grep -oE '"iops"[[:space:]]*:[[:space:]]*[0-9.]+' "$fj" | tail -n 1 | grep -oE '[0-9.]+$')"
      [ -n "$r" ] && BH_FIO_RIOPS="$(awk -v r="$r" 'BEGIN{printf "%.0f", r}')"
      [ -n "$w" ] && BH_FIO_WIOPS="$(awk -v w="$w" 'BEGIN{printf "%.0f", w}')"
    fi
    rm -f "$dir/.bhvps_fio_$$" 2>/dev/null
  fi
}
