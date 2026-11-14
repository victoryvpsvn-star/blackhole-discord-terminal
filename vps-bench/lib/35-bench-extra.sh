# =====================================================================
# blackhole-vps-bench · 35-bench-extra.sh — extra INFO-ONLY benchmarks
# B1 crypto throughput (openssl aes-256-gcm / chacha20-poly1305,
#    cbc-fallback for openssl < 1.1.1)
# B2 compression throughput (gzip, xz -0 fallback, zstd -1)
# B3 fork/exec rate · B4 pipe IPC throughput · B5 small-file create rate
#
# ALL metrics in this module are informational: the score engine
# (70-report.sh) reads ONLY BH_SHA1C / BH_SHANC / BH_MEM_GBS / BH_SEQW /
# BH_4KW / BH_4KR / BH_DOWN_MBPS / BH_UP_MBPS — nothing here may write
# to those variables or influence the score.
# =====================================================================
# shellcheck shell=bash

# ------- globals ("" = not measured / failed / unavailable) -------
BH_AES_GCM_MBPS=""; BH_CHACHA_MBPS=""; BH_AES_CBC_MBPS=""
BH_AES_METHOD=""                    # gcm+chacha | cbc-fallback | "" (no openssl)
BH_GZIP_MBPS=""
BH_GZIP_METHOD=""                   # gzip | xz-0 | ""
BH_ZSTD_MBPS=""
BH_FORK_RATE=""                     # exec/s
BH_PIPE_GBS=""; BH_PIPE4K_GBS=""    # GB/s through a pipe
BH_SMALLFILE_RATE=""                # file creates/s
BH_SMALLFILE_FS=""                  # stat -f -c %T of the bench dir (context)

# bhx_speed_mbps SPEED_OUTPUT ROWKEY — parse the last numeric token on
# ROWKEY's row of an `openssl speed` table. openssl prints 1000s of
# bytes/s ('k'-suffixed); convert to MB/s. Prints nothing (caller keeps
# "") when the row is missing or the value is not a clean number.
# Case-insensitive on purpose: openssl 3.x prints AES-256-GCM in caps.
bhx_speed_mbps() {
  local raw k
  raw="$(printf '%s\n' "$1" | awk -v key="$2" '
    {
      line = tolower($0)
      if (index(line, key) > 0) {
        for (i = NF; i >= 1; i--)
          if ($i ~ /^[0-9]+(\.[0-9]+)?k?$/) { print $i; exit }
      }
    }' 2>/dev/null)"
  case "$raw" in ''|*[!0-9.k]*) return 0 ;; esac
  k="${raw%k}"
  case "$k" in ''|*[!0-9.]*) return 0 ;; esac
  # 1000s of bytes/s -> bytes/s -> MB/s (BEGIN-only math, mawk-safe)
  awk -v k="$k" 'BEGIN{ printf "%.1f", k * 1000 / 1048576 }' 2>/dev/null
  return 0
}

bench_extra() {
  local t0 t1 ms rc n i j true_bin comp_file comp_n comp_r comp_bytes
  local p_cnt p_bytes p4_cnt p4_bytes sf_dir gcm_out chch_out

  # ---------------- B1: crypto throughput (INFO-ONLY) ----------------
  if command_exists openssl; then
    log "EXTRA: openssl crypto (aes-256-gcm / chacha20-poly1305, ~1s each)..."
    # probe -bytes support ONCE (openssl < 1.1.1 rejects the option)
    if timeout 10 openssl speed -seconds 1 -bytes 16384 -evp aes-256-gcm >/dev/null 2>&1; then
      gcm_out="$(timeout 10 openssl speed -seconds 1 -bytes 16384 -evp aes-256-gcm 2>/dev/null)"
      BH_AES_GCM_MBPS="$(bhx_speed_mbps "$gcm_out" "aes-256-gcm")"
      # chacha may be absent from the build — skip silently (stays "")
      chch_out="$(timeout 10 openssl speed -seconds 1 -bytes 16384 -evp chacha20-poly1305 2>/dev/null)"
      if [ -n "$chch_out" ]; then
        BH_CHACHA_MBPS="$(bhx_speed_mbps "$chch_out" "chacha20-poly1305")"
      fi
      BH_AES_METHOD="gcm+chacha"
    else
      # legacy fallback: one CBC pass over 48 MB of urandom
      log "EXTRA: openssl too old for -bytes, using aes-256-cbc fallback..."
      t0=$(now_ms)
      dd if=/dev/urandom bs=1M count=48 2>/dev/null |
        timeout 15 openssl enc -aes-256-cbc \
          -K "$(printf '%064d' 0)" -iv "$(printf '%032d' 0)" \
          >/dev/null 2>/dev/null
      rc=$?
      t1=$(now_ms)
      ms=$((t1 - t0))
      if [ "$rc" -eq 0 ]; then
        BH_AES_CBC_MBPS="$(awk -v ms="$ms" 'BEGIN{ if (ms >= 50) printf "%.1f", 48 / (ms / 1000); else print "" }' 2>/dev/null)"
      fi
      BH_AES_METHOD="cbc-fallback"
    fi
  fi

  # ---------------- B2: compression throughput (INFO-ONLY) ----------------
  # input: 48 MB of 'A' + 8 MB random (fast: 24+4). NEVER `yes | head` — hangs.
  comp_n=48; comp_r=8
  [ "$BH_FAST" = "1" ] && { comp_n=24; comp_r=4; }
  comp_file="$BH_RUNDIR/bx_comp.bin"
  comp_bytes=$(( (comp_n + comp_r) * 1048576 ))
  { dd if=/dev/zero bs=1M count="$comp_n" 2>/dev/null | tr '\0' 'A'
    dd if=/dev/urandom bs=1M count="$comp_r" 2>/dev/null
  } > "$comp_file" 2>/dev/null
  if [ -s "$comp_file" ]; then
    log "EXTRA: compression throughput ($((comp_n + comp_r)) MB input)..."
    if command_exists gzip; then
      BH_GZIP_METHOD="gzip"
      t0=$(now_ms); timeout 20 gzip -c "$comp_file" >/dev/null 2>/dev/null; rc=$?; t1=$(now_ms)
      ms=$((t1 - t0))
      if [ "$rc" -eq 0 ]; then
        BH_GZIP_MBPS="$(awk -v b="$comp_bytes" -v ms="$ms" 'BEGIN{ if (ms >= 50) printf "%.1f", b / (ms / 1000) / 1048576; else print "" }' 2>/dev/null)"
      fi
    elif command_exists xz; then
      BH_GZIP_METHOD="xz-0"
      t0=$(now_ms); timeout 25 xz -0 -c "$comp_file" >/dev/null 2>/dev/null; rc=$?; t1=$(now_ms)
      ms=$((t1 - t0))
      if [ "$rc" -eq 0 ]; then
        BH_GZIP_MBPS="$(awk -v b="$comp_bytes" -v ms="$ms" 'BEGIN{ if (ms >= 50) printf "%.1f", b / (ms / 1000) / 1048576; else print "" }' 2>/dev/null)"
      fi
    fi
    if command_exists zstd; then
      t0=$(now_ms); timeout 10 zstd -1 -c "$comp_file" >/dev/null 2>/dev/null; rc=$?; t1=$(now_ms)
      ms=$((t1 - t0))
      if [ "$rc" -eq 0 ]; then
        BH_ZSTD_MBPS="$(awk -v b="$comp_bytes" -v ms="$ms" 'BEGIN{ if (ms >= 50) printf "%.1f", b / (ms / 1000) / 1048576; else print "" }' 2>/dev/null)"
      fi
    fi
  fi
  rm -f "$comp_file" 2>/dev/null || :

  # ---------------- B3: fork/exec rate (INFO-ONLY) ----------------
  true_bin="/bin/true"
  [ -x "$true_bin" ] || true_bin="/usr/bin/true"
  if [ -x "$true_bin" ]; then
    n=1000
    [ "$BH_FAST" = "1" ] && n=300
    log "EXTRA: fork/exec rate ($n x true)..."
    t0=$(now_ms)
    i=0
    while [ "$i" -lt "$n" ]; do
      "$true_bin"
      i=$((i + 1))
    done
    t1=$(now_ms)
    ms=$((t1 - t0))
    BH_FORK_RATE="$(awk -v n="$n" -v ms="$ms" 'BEGIN{ if (ms >= 20) printf "%d", n * 1000 / ms; else print "" }' 2>/dev/null)"
  fi

  # ---------------- B4: pipe IPC throughput (INFO-ONLY) ----------------
  # CRITICAL: dd's stderr is silenced INSIDE the pipeline (2>/dev/null on dd).
  # Never `2>&1 |` — that would push dd's progress report into cat, skewing
  # both the byte count and the timing.
  p_cnt=2048
  [ "$BH_FAST" = "1" ] && p_cnt=1024
  log "EXTRA: pipe IPC (dd 256k x $p_cnt | cat)..."
  t0=$(now_ms)
  timeout 20 dd if=/dev/zero bs=256k count="$p_cnt" 2>/dev/null | cat >/dev/null
  t1=$(now_ms)
  ms=$((t1 - t0))
  p_bytes=$(( 262144 * p_cnt ))
  BH_PIPE_GBS="$(awk -v b="$p_bytes" -v ms="$ms" 'BEGIN{ if (ms >= 50) printf "%.1f", b / (ms / 1000) / 1073741824; else print "" }' 2>/dev/null)"

  # optional 4k second pass (skipped in fast mode); widen the window
  # house-style when a single 16 MB pass is too short to time reliably
  if [ "$BH_FAST" != "1" ]; then
    p4_cnt=4096   # 16 MB
    i=0
    while :; do
      t0=$(now_ms)
      timeout 20 dd if=/dev/zero bs=4k count="$p4_cnt" 2>/dev/null | cat >/dev/null
      t1=$(now_ms)
      ms=$((t1 - t0))
      { [ "$ms" -ge 60 ] || [ "$i" -ge 2 ]; } && break
      p4_cnt=$((p4_cnt * 4))   # 16 -> 64 -> 256 MB, max 3 passes
      i=$((i + 1))
    done
    p4_bytes=$(( 4096 * p4_cnt ))
    BH_PIPE4K_GBS="$(awk -v b="$p4_bytes" -v ms="$ms" 'BEGIN{ if (ms >= 60) printf "%.1f", b / (ms / 1000) / 1073741824; else print "" }' 2>/dev/null)"
  fi

  # ---------------- B5: small-file metadata rate (INFO-ONLY) ----------------
  sf_dir=""
  mkdir -p "$BH_DISK_DIR" 2>/dev/null || :
  sf_dir="$(mktemp -d "${BH_DISK_DIR%/}/.bhvps_sf.XXXXXX" 2>/dev/null)" || sf_dir=""
  if [ -z "$sf_dir" ]; then
    sf_dir="$(mktemp -d "${TMPDIR:-/tmp}/.bhvps_sf.XXXXXX" 2>/dev/null)" || sf_dir=""
  fi
  if [ -n "$sf_dir" ]; then
    BH_SMALLFILE_FS="$(stat -f -c %T "$sf_dir" 2>/dev/null)"
    n=500
    [ "$BH_FAST" = "1" ] && n=200
    log "EXTRA: small-file create rate (fs=${BH_SMALLFILE_FS:-unknown})..."
    # adaptive window (house style): a fast fs crunches 200 files in <20 ms,
    # so widen with 4x more files (fresh names) until the pass is measurable
    i=0
    while :; do
      t0=$(now_ms)
      j=0
      while [ "$j" -lt "$n" ]; do
        : > "$sf_dir/f${i}_$j"
        j=$((j + 1))
      done
      t1=$(now_ms)
      ms=$((t1 - t0))
      { [ "$ms" -ge 60 ] || [ "$i" -ge 2 ]; } && break
      n=$((n * 4))   # 500 -> 2000 -> 8000 files, max 3 passes
      i=$((i + 1))
    done
    BH_SMALLFILE_RATE="$(awk -v n="$n" -v ms="$ms" 'BEGIN{ if (ms >= 60) printf "%d", n * 1000 / ms; else print "" }' 2>/dev/null)"
    rm -rf "$sf_dir" 2>/dev/null || :
  fi

  return 0
}
