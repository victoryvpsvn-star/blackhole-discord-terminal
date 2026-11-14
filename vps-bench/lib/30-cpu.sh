# =====================================================================
# blackhole-vps-bench · 30-cpu.sh — CPU benchmark (sha256 throughput)
# Primary metric: MB/s of sha256 over memory streams — 1 core and N cores.
#
# G3 fix: the hashed payload is a RANDOM buffer generated once per run into
# $BH_RUNDIR/cpu-input.bin (/dev/urandom). Hashing /dev/zero hit the zero
# fast-path in sha-ni/pipeline implementations and was unrepresentative of
# real workloads. Every job (single- and multi-core) hashes the SAME file, so
# the multi-core efficiency ratio compares identical payloads per job.
# The stream length stays adaptive: each timed run repeats the payload until
# the batch takes >= 300 ms, keeping the number accurate on a Raspberry Pi
# and on GH-runner-class machines alike.
#
# Extras:
#   - BH_STEAL_UNDER_LOAD: /proc/stat steal % sampled across the multi-core
#     window (noisy-neighbor detection under load, unlike 20-info's idle steal).
#   - BH_BASH_OPS / BH_AWK_OPS: pure-bash vs awk integer loop cross-check (B6).
#   - BH_OSSL_SHA256_KS: openssl sha256 cross-check, tolerant of both the
#     OpenSSL 3.x ("SHA2-256") and 1.x ("sha256") summary-row formats.
# =====================================================================
# shellcheck shell=bash

# ---- globals (empty defaults; this file SETS them, never prints) ----
BH_SHA1C=""; BH_SHANC=""
BH_OPENSSL_K=""          # legacy openssl alias consumed by 70-report.sh (kB/s)
BH_OSSL_SHA256_KS=""     # robust openssl sha256 cross-check, kB/s ("" on failure)
BH_CPU_EFFICIENCY=""     # BH_SHANC / (BH_SHA1C * jobs) * 100
BH_LAST_N=0; BH_LAST_MS=0
BH_CPU_INPUT_MB=""       # payload per job per repetition, MB
BH_CPU_INPUT_SRC=""      # "urandom" | "zeros-fallback"
BH_CPU_INPUT_FILE=""     # shared payload path; "" => stream /dev/zero directly
BH_CPU_THREADS=""        # jobs used by the multi-core bench
BH_STEAL_UNDER_LOAD=""   # steal % across the multi-core window ("" if unknown)
BH_BASH_OPS=""           # pure-bash integer loop rate, ops/s
BH_AWK_OPS=""            # awk BEGIN-loop rate, ops/s

BH_RUNDIR="${BH_RUNDIR:-/tmp}"

# _bh_stat_steal — "<steal> <total_jiffies>" from the aggregate "cpu " line of
# /proc/stat; steal is the 8th value after "cpu" (awk $9). "" when unreadable.
_bh_stat_steal() {
  awk '$1 == "cpu" { print $9 + 0, $2+$3+$4+$5+$6+$7+$8+$9+$10+$11; exit }' /proc/stat 2>/dev/null
}

# _bh_file_bytes FILE — size in bytes ("" when unknown/unreadable)
_bh_file_bytes() { wc -c < "$1" 2>/dev/null | tr -d ' \t'; }

# bh_make_cpu_input N_MB — generate the shared random payload once per run into
# $BH_RUNDIR/cpu-input.bin. Sets BH_CPU_INPUT_MB / BH_CPU_INPUT_SRC /
# BH_CPU_INPUT_FILE. Preference order:
#   1. urandom at N_MB (GNU dd status=none, then a retry for dd without it)
#   2. zeros at N_MB written to the same file ("zeros-fallback": still a fixed,
#      repeatable on-disk buffer — better than streaming /dev/zero)
#   3. urandom at N_MB/4 (tiny tmpfs / low cgroup memory limit)
#   4. give up on the file; the bench then streams /dev/zero directly
bh_make_cpu_input() {
  local n="$1" f="$BH_RUNDIR/cpu-input.bin" want halved
  want=$(( n * 1048576 ))
  BH_CPU_INPUT_MB="$n"
  BH_CPU_INPUT_FILE="$f"
  BH_CPU_INPUT_SRC=""
  rm -f "$f" 2>/dev/null
  if dd if=/dev/urandom of="$f" bs=1M count="$n" status=none 2>/dev/null \
     && [ "$(_bh_file_bytes "$f")" -ge "$want" ] 2>/dev/null; then
    BH_CPU_INPUT_SRC="urandom"; return 0
  fi
  rm -f "$f" 2>/dev/null
  if dd if=/dev/urandom of="$f" bs=1M count="$n" 2>/dev/null \
     && [ "$(_bh_file_bytes "$f")" -ge "$want" ] 2>/dev/null; then
    BH_CPU_INPUT_SRC="urandom"; return 0
  fi
  rm -f "$f" 2>/dev/null
  if { dd if=/dev/zero of="$f" bs=1M count="$n" status=none 2>/dev/null || \
       dd if=/dev/zero of="$f" bs=1M count="$n" 2>/dev/null; } \
     && [ "$(_bh_file_bytes "$f")" -ge "$want" ] 2>/dev/null; then
    BH_CPU_INPUT_SRC="zeros-fallback"; return 0
  fi
  halved=$(( n / 4 )); [ "$halved" -ge 8 ] || halved=8
  want=$(( halved * 1048576 ))
  rm -f "$f" 2>/dev/null
  if dd if=/dev/urandom of="$f" bs=1M count="$halved" 2>/dev/null \
     && [ "$(_bh_file_bytes "$f")" -ge "$want" ] 2>/dev/null; then
    BH_CPU_INPUT_MB="$halved"; BH_CPU_INPUT_SRC="urandom"; return 0
  fi
  rm -f "$f" 2>/dev/null
  BH_CPU_INPUT_FILE=""
  BH_CPU_INPUT_SRC="zeros-fallback"
  return 0
}

# bh_hash_reps N_MB JOBS REPS — hash the shared payload: JOBS parallel
# pipelines, each streaming REPS x N_MB read from the SAME input file, so every
# job digests identical bytes (fixes the per-job payload mismatch that used to
# confound the efficiency %). Sets BH_LAST_N (MB per job hashed) and
# BH_LAST_MS (wall ms). Do NOT call this in a command substitution — the
# globals would be lost.
bh_hash_reps() {
  local n="$1" jobs="$2" reps="$3" src t0 t1 i r
  src="$BH_CPU_INPUT_FILE"
  { [ -n "$src" ] && [ -f "$src" ]; } || src=/dev/zero
  t0=$(now_ms)
  i=0
  while [ "$i" -lt "$jobs" ]; do
    (
      r=0
      while [ "$r" -lt "$reps" ]; do
        dd if="$src" bs=1M count="$n" 2>/dev/null
        r=$((r + 1))
      done
    ) | sha256sum >/dev/null 2>&1 &
    i=$((i + 1))
  done
  wait
  t1=$(now_ms)
  BH_LAST_N=$(( n * reps ))
  BH_LAST_MS=$((t1 - t0))
}

# bh_cpu_arith — B6 cross-check: pure-bash integer loop vs awk BEGIN-only loop.
# Both report iterations/second as integers. The awk program is BEGIN-only and
# its stdin is /dev/null so it can never block reading input.
bh_cpu_arith() {
  local iters=200000 t0 t1 ms x=0 i
  [ "$BH_FAST" = "1" ] && iters=50000

  # ---- pure bash: x=$((x+i)) style loop, timed in-process via now_ms ----
  t0=$(now_ms)
  for (( i = 0; i < iters; i++ )); do
    x=$(( x + i ))
  done
  t1=$(now_ms)
  ms=$(( t1 - t0 ))
  [ "$ms" -ge 1 ] || ms=1
  BH_BASH_OPS="$(awk -v n="$iters" -v ms="$ms" 'BEGIN{ printf "%d", n * 1000 / ms }' 2>/dev/null)"
  case "$BH_BASH_OPS" in ''|.*|*[!0-9]*) BH_BASH_OPS="" ;; esac
  [ "$x" -lt 0 ] && x=0 # keep the accumulator live; no optimizing shell exists, but be explicit

  # ---- awk: BEGIN-only loop, </dev/null so stdin can never hang it ----
  iters=2000000
  [ "$BH_FAST" = "1" ] && iters=500000
  BH_AWK_OPS=""
  if command_exists awk; then
    t0=$(now_ms)
    if command_exists timeout; then
      timeout 30 awk -v n="$iters" 'BEGIN{ x = 0; for (i = 0; i < n; i++) x += i; print x }' </dev/null >/dev/null 2>&1
    else
      awk -v n="$iters" 'BEGIN{ x = 0; for (i = 0; i < n; i++) x += i; print x }' </dev/null >/dev/null 2>&1
    fi
    t1=$(now_ms)
    ms=$(( t1 - t0 ))
    [ "$ms" -ge 1 ] || ms=1
    BH_AWK_OPS="$(awk -v n="$iters" -v ms="$ms" 'BEGIN{ printf "%d", n * 1000 / ms }' 2>/dev/null)"
    case "$BH_AWK_OPS" in ''|.*|*[!0-9]*) BH_AWK_OPS="" ;; esac
  fi
}

# bh_cpu_openssl — robust openssl sha256 cross-check, kB/s ("" on any failure).
# Runs `openssl speed -seconds 2 -evp sha256` ONCE and parses the summary row
# (the row holding the per-block-size columns, first of which is the 16-byte
# block column). Handles OpenSSL 3.x ("SHA2-256") and 1.x ("sha256") name
# formats by taking the LAST numeric field of that row. Guarded by timeout when
# available; BH_OPENSSL_K is kept in sync as the legacy alias for 70-report.sh.
bh_cpu_openssl() {
  BH_OSSL_SHA256_KS=""
  BH_OPENSSL_K=""
  command_exists openssl || return 0
  local out
  if command_exists timeout; then
    out="$(timeout 30 openssl speed -seconds 2 -evp sha256 2>/dev/null)"
  else
    out="$(openssl speed -seconds 2 -evp sha256 2>/dev/null)"
  fi
  [ -n "$out" ] || return 0
  BH_OSSL_SHA256_KS="$(printf '%s\n' "$out" | awk '
    tolower($1) ~ /^sha/ {
      v = $NF
      gsub(/k$/, "", v)
      if (v ~ /^[0-9]+(\.[0-9]+)?$/) { print v; exit }
    }' 2>/dev/null)"
  case "$BH_OSSL_SHA256_KS" in
    ''|.*|*[!0-9.]*) BH_OSSL_SHA256_KS="" ;;
  esac
  BH_OPENSSL_K="$BH_OSSL_SHA256_KS"
  return 0
}

bench_cpu() {
  local n=256
  [ "$BH_FAST" = "1" ] && n=96
  local ms reps j sa sb src

  # ---- shared random payload (G3: never benchmark /dev/zero's zero fast-path) ----
  bh_make_cpu_input "$n"
  n="$BH_CPU_INPUT_MB"
  src="$BH_CPU_INPUT_FILE"
  { [ -n "$src" ] && [ -f "$src" ]; } || src=/dev/zero
  log "CPU bench: sha256 payload ${n} MB/job (source: ${BH_CPU_INPUT_SRC:-unknown})..."

  # warm-up: prime the hash path AND pull the payload into page cache so the
  # timed runs measure CPU throughput, not first-touch disk reads
  dd if="$src" bs=1M count=8 2>/dev/null | sha256sum >/dev/null 2>&1
  if [ -n "$BH_CPU_INPUT_FILE" ]; then
    dd if="$BH_CPU_INPUT_FILE" of=/dev/null bs=1M 2>/dev/null
  fi

  # ---- single core ----
  log "CPU bench: sha256 single-core (adaptive, ${n} MB per rep)..."
  reps=1
  while :; do
    bh_hash_reps "$n" 1 "$reps"
    ms="$BH_LAST_MS"
    { [ "$ms" -ge 300 ] || [ "$reps" -ge 8 ]; } && break
    reps=$((reps * 2))
  done
  BH_SHA1C="$(awk -v n="$BH_LAST_N" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*1048576/(ms/1000)/1048576; else print 0 }')"
  [ "${BH_SHA1C:-0}" = "0" ] && warn "single-core CPU timing too short to be reliable"

  # ---- multi core (identical payload per job) + steal-under-load window ----
  j="$BH_PAR_JOBS"
  { [ "$j" -ge 1 ] 2>/dev/null; } || j=1
  BH_CPU_THREADS="$j"
  log "CPU bench: sha256 multi-core (${j} jobs, ${n} MB per rep, same payload each)..."
  sa="$(_bh_stat_steal)"                 # steal sample immediately before the window
  reps=1
  while :; do
    bh_hash_reps "$n" "$j" "$reps"
    ms="$BH_LAST_MS"
    { [ "$ms" -ge 300 ] || [ "$reps" -ge 8 ]; } && break
    reps=$((reps * 2))
  done
  sb="$(_bh_stat_steal)"                 # ... and immediately after
  BH_SHANC="$(awk -v n="$BH_LAST_N" -v j="$j" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*j*1048576/(ms/1000)/1048576; else print 0 }')"

  # steal % over the multi-core wall window — same math as 20-info's
  # bh_cpu_steal_pct but with our own before/after samples; "" when /proc/stat
  # is unreadable or the window is bad
  BH_STEAL_UNDER_LOAD=""
  if [ -n "$sa" ] && [ -n "$sb" ]; then
    BH_STEAL_UNDER_LOAD="$(awk -v a="$sa" -v b="$sb" 'BEGIN{
      split(a, A, " "); split(b, B, " ");
      ds = B[1] - A[1]; dt = B[2] - A[2];
      if (ds < 0) ds = 0
      if (dt > 0) printf "%.1f", ds / dt * 100
    }' 2>/dev/null)"
    case "$BH_STEAL_UNDER_LOAD" in ''|.*|*[!0-9.]*) BH_STEAL_UNDER_LOAD="" ;; esac
  fi

  # scaling efficiency: ~100% = linear speedup across BH_CPU_THREADS threads
  # (fair comparison now that every job hashed the identical payload)
  BH_CPU_EFFICIENCY="$(awk -v s1="$BH_SHA1C" -v sn="$BH_SHANC" -v j="$j" 'BEGIN{
    if (s1+0 > 0 && sn+0 > 0 && j+0 > 0) printf "%.1f", sn / (s1 * j) * 100
  }' 2>/dev/null)"

  # ---- B6: pure-bash vs awk integer arithmetic cross-check ----
  bh_cpu_arith

  # ---- openssl sha256 cross-check (info only) ----
  bh_cpu_openssl
}
