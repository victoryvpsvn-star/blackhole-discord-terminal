# =====================================================================
# blackhole-vps-bench · 30-cpu.sh — CPU benchmark (sha256 throughput)
# Primary metric: MB/s of sha256 over memory streams — 1 core and N cores.
# Payload is adaptive: doubles until the run takes >= 300 ms so the number
# stays accurate on both Raspberry Pi and GH-runner NVMe-class machines.
# =====================================================================
# shellcheck shell=bash

BH_SHA1C=""; BH_SHANC=""; BH_OPENSSL_K=""
BH_LAST_N=0; BH_LAST_MS=0

# dd_time_ms n_mb [jobs] — runs n MB of dd|sha256sum (jobs parallel copies).
# Sets globals BH_LAST_N (payload used) and BH_LAST_MS (elapsed ms).
# Do NOT call this in a command substitution — the globals would be lost.
dd_time_ms() {
  local n="$1" jobs="${2:-1}" t0 t1 i
  t0=$(now_ms)
  i=0
  while [ "$i" -lt "$jobs" ]; do
    ( dd if=/dev/zero bs=1M count="$n" 2>/dev/null | sha256sum >/dev/null 2>&1 ) &
    i=$((i + 1))
  done
  wait
  t1=$(now_ms)
  BH_LAST_N="$n"
  BH_LAST_MS=$((t1 - t0))
}

bench_cpu() {
  local n=256
  [ "$BH_FAST" = "1" ] && n=96
  local ms jobs_n

  log "CPU bench: sha256 single-core (adaptive, starts at ${n} MB)..."
  dd if=/dev/zero bs=1M count=8 2>/dev/null | sha256sum >/dev/null 2>&1 # warmup
  while :; do
    dd_time_ms "$n" 1
    ms="$BH_LAST_MS"
    { [ "$ms" -ge 300 ] || [ "$n" -ge 1024 ]; } && break
    n=$((n * 2))
  done
  BH_SHA1C="$(awk -v n="$BH_LAST_N" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*1048576/(ms/1000)/1048576; else print 0 }')"
  [ "${BH_SHA1C:-0}" = "0" ] && warn "single-core CPU timing too short to be reliable"

  local j="$BH_PAR_JOBS" mn="$n"
  log "CPU bench: sha256 multi-core (${j} jobs, adaptive from ${mn} MB each)..."
  while :; do
    dd_time_ms "$mn" "$j"
    ms="$BH_LAST_MS"
    { [ "$ms" -ge 300 ] || [ "$mn" -ge 512 ]; } && break
    mn=$((mn * 2))
  done
  BH_SHANC="$(awk -v n="$BH_LAST_N" -v j="$j" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.1f", n*j*1048576/(ms/1000)/1048576; else print 0 }')"

  # optional cross-check via openssl (info only, format varies by version)
  if command_exists openssl; then
    BH_OPENSSL_K="$(openssl speed -seconds 2 -evp sha256 2>/dev/null | awk 'tolower($1) ~ /sha/ && $2 ~ /k$/ {gsub(/k$/,"",$2); print $2; exit}')"
    if [ -z "$BH_OPENSSL_K" ]; then
      BH_OPENSSL_K="$(openssl speed -seconds 2 -evp sha256 2>/dev/null | awk 'tolower($0) ~ /sha/ && NF>1 {v=$NF; gsub(/k$/,"",v); if (v ~ /^[0-9.]+$/) {print v; exit}}')"
    fi
  fi
}
