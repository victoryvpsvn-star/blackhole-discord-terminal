# =====================================================================
# blackhole-vps-bench · 30-cpu.sh — CPU benchmark (sha256 throughput)
# Primary metric: MB/s of sha256 over memory streams — 1 core and N cores.
# Predictable across distros (pure dd/sha256sum), works on busybox too.
# =====================================================================
# shellcheck shell=bash

BH_SHA1C=""; BH_SHANC=""; BH_OPENSSL_K=""

bench_cpu() {
  local n=256
  [ "$BH_FAST" = "1" ] && n=96
  local t0 t1

  log "CPU bench: sha256 single-core (${n} MB)..."
  # warmup (small, unmeasured)
  dd if=/dev/zero bs=1M count=8 2>/dev/null | sha256sum >/dev/null 2>&1

  t0=$(now_ms)
  dd if=/dev/zero bs=1M count="$n" 2>/dev/null | sha256sum >/dev/null 2>&1
  t1=$(now_ms)
  BH_SHA1C="$(awk -v n="$n" -v ms=$((t1 - t0)) 'BEGIN{ if (ms>50) printf "%.1f", n*1048576/(ms/1000)/1048576; else print 0 }')"
  [ "${BH_SHA1C:-0}" = "0" ] && warn "single-core CPU timing too short to be reliable"

  log "CPU bench: sha256 multi-core (${BH_PAR_JOBS} jobs x ${n} MB)..."
  t0=$(now_ms)
  local i=0
  while [ "$i" -lt "$BH_PAR_JOBS" ]; do
    ( dd if=/dev/zero bs=1M count="$n" 2>/dev/null | sha256sum >/dev/null 2>&1 ) &
    i=$((i + 1))
  done
  wait
  t1=$(now_ms)
  BH_SHANC="$(awk -v n="$n" -v j="$BH_PAR_JOBS" -v ms=$((t1 - t0)) 'BEGIN{ if (ms>50) printf "%.1f", n*j*1048576/(ms/1000)/1048576; else print 0 }')"

  # optional cross-check via openssl (info only, format varies by version)
  if command_exists openssl; then
    BH_OPENSSL_K="$(openssl speed -seconds 2 -evp sha256 2>/dev/null | awk 'tolower($1) ~ /sha/ && $2 ~ /k$/ {gsub(/k$/,"",$2); print $2; exit}')"
    if [ -z "$BH_OPENSSL_K" ]; then
      BH_OPENSSL_K="$(openssl speed -seconds 2 -evp sha256 2>/dev/null | awk 'tolower($0) ~ /sha/ && NF>1 {v=$NF; gsub(/k$/,"",v); if (v ~ /^[0-9.]+$/) {print v; exit}}')"
    fi
  fi
}
