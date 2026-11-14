# =====================================================================
# blackhole-vps-bench · 35-bench-extra.sh — extra INFO-ONLY benchmarks
# B1 crypto throughput (openssl aes-256-gcm / chacha20-poly1305,
#    cbc-fallback for openssl < 1.1.1)
# B2 compression throughput (gzip, xz -0 fallback, zstd -1)
# B3 fork/exec rate · B4 pipe IPC throughput · B5 small-file create rate
# v5 (C12): BH_PIPE_US (1-byte pipe RTT via coproc) · BH_SQLITE_RPS /
#   BH_SQLITE_BATCH (commit path on the real disk) · BH_STAT_KPS (stat syscall
#   path) · BH_URANDOM_MBPS (urandom read throughput)
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
# v5 (C12) additions
BH_PIPE_US=""                       # pipe round-trip latency, us (1-byte ping-pong)
BH_SQLITE_RPS=""                    # sqlite3 autocommit INSERT rows/s (on BH_DISK_DIR)
BH_SQLITE_BATCH=""                  # wrapped-TRANSACTION speedup factor (batch / autocommit)
BH_STAT_KPS=""                      # stat(1) syscall-path rate, stats/s (float)
BH_URANDOM_MBPS=""                  # /dev/urandom read throughput, MB/s (float)

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

  # ---------------- v5 (C12) additions ----------------
  bhv5c12_pipe_pingpong
  bhv5c12_sqlite
  bhv5c12_stat_kps
  bhv5c12_urandom

  return 0
}

# =====================================================================
# v5 additions (C12) — pipe RTT, sqlite commit path, stat path, urandom
# =====================================================================

# bhv5c12_pipe_pingpong — 1-byte pipe round-trip latency through a `cat`
# coproc: write 1 byte, read 1 byte back, per round-trip. Stops at the
# iteration cap (fast 500 / full 2000) or the deadline (fast 1s / full 3s).
# BH_PIPE_US = elapsed_us / completed round-trips (awk float). Teardown is
# explicit and unconditional — close both coproc fds, kill, wait — so no fd
# or process leaks out of this function.
bhv5c12_pipe_pingpong() {
  BH_PIPE_US=""
  [ -n "${BASH_VERSION:-}" ] || return 0
  local n=500 deadline_us=1000000
  [ "${BH_FAST:-0}" != "1" ] && { n=2000; deadline_us=3000000; }
  coproc PINGPONG { cat; } 2>/dev/null || return 0
  [ -n "${PINGPONG_PID:-}" ] || return 0
  local i=0 ok=0 t0 t1 us c
  t0=$(now_us)
  while [ "$i" -lt "$n" ]; do
    { printf 'x' >&"${PINGPONG[1]}"; } 2>/dev/null || break
    { IFS= read -r -N 1 c <&"${PINGPONG[0]}"; } 2>/dev/null || break
    i=$((i + 1))
    ok=$((ok + 1))
    if [ $((i % 25)) -eq 0 ]; then
      us=$(( $(now_us) - t0 ))
      [ "$us" -ge "$deadline_us" ] && break
    fi
  done
  us=$(( $(now_us) - t0 ))
  # ---- explicit teardown (no fd / process leak) ----
  # shellcheck disable=SC2093,SC1083  # mandated coproc fd-close idiom: exec {NAME[n]}>&- closes fd N
  exec {PINGPONG[1]}>&-
  # shellcheck disable=SC2093,SC1083
  exec {PINGPONG[0]}<&-
  kill "$PINGPONG_PID" 2>/dev/null
  wait "$PINGPONG_PID" 2>/dev/null
  # ---- rate ----
  if [ "$ok" -ge 10 ] && [ "$us" -gt 0 ]; then
    BH_PIPE_US="$(awk -v us="$us" -v n="$ok" 'BEGIN{ printf "%.2f", us / n }' 2>/dev/null)"
    case "$BH_PIPE_US" in ''|.*|*[!0-9.]*) BH_PIPE_US="" ;; esac
  fi
  return 0
}

# bhv5c12_sqlite — sqlite3 commit path on the REAL disk (BH_DISK_DIR, NOT
# BH_RUNDIR, which may be tmpfs): autocommit INSERT rate until a wall deadline
# (fast 1s / full 2s) or the row cap (fast 1000 / full 2000), then one
# wrapped-TRANSACTION run sized to ~1s (fast 0.5s) from the measured rate.
# BH_SQLITE_RPS  = autocommit rows/s (float)
# BH_SQLITE_BATCH = wrapped-transaction rows/s divided by autocommit rows/s
# Skipped when sqlite3 is missing, the target dir is unusable, or free space
# cannot be confirmed (>= 16 MB, mirroring the disk bench's space guard).
# The db (plus any journal/wal sidecars) is always removed afterwards.
bhv5c12_sqlite() {
  BH_SQLITE_RPS=""
  BH_SQLITE_BATCH=""
  command_exists sqlite3 || return 0
  local dir="${BH_DISK_DIR:-/tmp}" db avail_kb
  mkdir -p "$dir" 2>/dev/null || return 0
  avail_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
  case "$avail_kb" in ''|*[!0-9]*) return 0 ;; esac
  [ "$avail_kb" -ge 16384 ] || return 0   # free-space guard: >= 16 MB
  db="$dir/bhv5c12_$$.db"
  if ! timeout 10 sqlite3 "$db" 'CREATE TABLE IF NOT EXISTS t (a INTEGER, b TEXT);' >/dev/null 2>&1; then
    rm -f "$db" "$db-journal" "$db-wal" "$db-shm" 2>/dev/null
    return 0
  fi
  local rows_cap=2000 chunk=25 deadline_ms=2000 wrapped_s=1
  [ "${BH_FAST:-0}" = "1" ] && { rows_cap=1000; deadline_ms=1000; wrapped_s=0.5; }
  local rows=0 t0 t1 ms k rc
  # ---- autocommit phase: one sqlite3 process per chunk, each INSERT its own
  # transaction (no BEGIN wrapper) — that is the fsync-per-statement path ----
  t0=$(now_ms)
  while [ "$rows" -lt "$rows_cap" ]; do
    ms=$(( $(now_ms) - t0 ))
    [ "$ms" -ge "$deadline_ms" ] && break
    k="$chunk"
    [ $(( rows + k )) -gt "$rows_cap" ] && k=$(( rows_cap - rows ))
    if awk -v k="$k" -v o="$rows" 'BEGIN{ for (i = 0; i < k; i++) printf "INSERT INTO t VALUES(%d,0123456789abcdef);\n", o + i }' \
       | timeout 10 sqlite3 "$db" >/dev/null 2>&1; then
      rows=$((rows + k))
    else
      break
    fi
  done
  ms=$(( $(now_ms) - t0 ))
  if [ "$rows" -ge 50 ] && [ "$ms" -ge 1 ]; then
    BH_SQLITE_RPS="$(awk -v r="$rows" -v ms="$ms" 'BEGIN{ printf "%.1f", r * 1000 / ms }' 2>/dev/null)"
    case "$BH_SQLITE_RPS" in ''|.*|*[!0-9.]*) BH_SQLITE_RPS="" ;; esac
  fi
  # ---- wrapped-TRANSACTION phase: BEGIN ... N INSERTs ... COMMIT in one
  # stream, N sized from the autocommit rate to spend ~1s (fast 0.5s) ----
  if [ -n "$BH_SQLITE_RPS" ]; then
    local w_rows
    w_rows="$(awk -v r="$BH_SQLITE_RPS" -v s="$wrapped_s" 'BEGIN{ w = int(r * s); if (w < 200) w = 200; if (w > 20000) w = 20000; print w }')"
    t0=$(now_ms)
    { printf 'BEGIN;\n'
      awk -v k="$w_rows" 'BEGIN{ for (i = 0; i < k; i++) printf "INSERT INTO t VALUES(%d,0123456789abcdef);\n", i }'
      printf 'COMMIT;\n'
    } | timeout 5 sqlite3 "$db" >/dev/null 2>&1
    rc=$?
    t1=$(now_ms)
    ms=$((t1 - t0))
    if [ "$rc" -eq 0 ] && [ "$ms" -ge 1 ]; then
      BH_SQLITE_BATCH="$(awk -v w="$w_rows" -v ms="$ms" -v r="$BH_SQLITE_RPS" 'BEGIN{
        if (ms > 0 && r + 0 > 0) printf "%.2f", (w * 1000 / ms) / r
      }' 2>/dev/null)"
      case "$BH_SQLITE_BATCH" in ''|.*|*[!0-9.]*) BH_SQLITE_BATCH="" ;; esac
    fi
  fi
  rm -f "$db" "$db-journal" "$db-wal" "$db-shm" 2>/dev/null
  return 0
}

# bhv5c12_stat_kps — stat(1) syscall-path rate on one fixed file in BH_RUNDIR
# (fork + exec + stat per iteration; gVisor/FUSE overhead shows up here).
# Iterations: fast 1500 / full 5000, hard deadline 3s (checked every 100).
# BH_STAT_KPS = completed stats/s (float; i * 1000000 can exceed 2^31, so the
# division happens in awk with a %.1f float — never printf %d).
bhv5c12_stat_kps() {
  BH_STAT_KPS=""
  local f="${BH_RUNDIR:-/tmp}/.bhv5c12_stat_target"
  : > "$f" 2>/dev/null || return 0
  stat -c %i "$f" >/dev/null 2>&1 || { rm -f "$f" 2>/dev/null; return 0; }
  local n=1500
  [ "${BH_FAST:-0}" != "1" ] && n=5000
  local i=0 t0 t1 us
  t0=$(now_us)
  while [ "$i" -lt "$n" ]; do
    stat -c %i "$f" >/dev/null 2>&1
    i=$((i + 1))
    if [ $((i % 100)) -eq 0 ]; then
      us=$(( $(now_us) - t0 ))
      [ "$us" -ge 3000000 ] && break
    fi
  done
  t1=$(now_us)
  us=$((t1 - t0))
  rm -f "$f" 2>/dev/null
  [ "$us" -gt 0 ] || return 0
  BH_STAT_KPS="$(awk -v i="$i" -v us="$us" 'BEGIN{ printf "%.1f", i * 1000000 / us }' 2>/dev/null)"
  case "$BH_STAT_KPS" in ''|.*|*[!0-9.]*) BH_STAT_KPS="" ;; esac
  return 0
}

# bhv5c12_urandom — /dev/urandom read throughput: dd bs=64k with the block
# count doubled until one run takes >= 300 ms (cap 8192 blocks, timeout 20).
# BH_URANDOM_MBPS = last run's MB/s (float). Adaptive sizing keeps slow hosts
# short (they stop early) and fast hosts accurate.
bhv5c12_urandom() {
  BH_URANDOM_MBPS=""
  [ -r /dev/urandom ] || return 0
  local count=64 ms t0 t1 rc
  while :; do
    t0=$(now_ms)
    if command_exists timeout; then
      timeout 20 dd if=/dev/urandom of=/dev/null bs=64k count="$count" 2>/dev/null
    else
      dd if=/dev/urandom of=/dev/null bs=64k count="$count" 2>/dev/null
    fi
    rc=$?
    t1=$(now_ms)
    ms=$((t1 - t0))
    { [ "$ms" -ge 300 ] || [ "$count" -ge 8192 ] || [ "$rc" -ne 0 ]; } && break
    count=$((count * 2))
  done
  [ "$ms" -ge 1 ] || ms=1
  BH_URANDOM_MBPS="$(awk -v c="$count" -v ms="$ms" 'BEGIN{ printf "%.1f", c * 65536 / 1048576 / (ms / 1000) }' 2>/dev/null)"
  case "$BH_URANDOM_MBPS" in ''|.*|*[!0-9.]*) BH_URANDOM_MBPS="" ;; esac
  return 0
}
