# =====================================================================
# blackhole-vps-bench · 40-mem.sh — memory bandwidth benchmark
# Preferred: tiny C memcpy-style loop compiled at runtime (cc/gcc/clang).
# Fallback: dd write-to-null proxy with adaptive payload sizing.
# =====================================================================
# shellcheck shell=bash

BH_MEM_GBS=""; BH_MEM_METHOD=""
# context notes for the report layer (filled in by bench_mem)
BH_MEM_THP_NOTE=""; BH_MEM_SWAP_NOTE=""

BH_MEMBENCH_C='
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double now(void){
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}
int main(int argc, char **argv){
  size_t mb = argc > 1 ? (size_t)atoi(argv[1]) : 256;
  int passes = argc > 2 ? atoi(argv[2]) : 3;
  size_t sz = mb * 1024UL * 1024UL;
  char *buf = malloc(sz);
  double best = 0;
  int p, i;
  if (!buf) { perror("malloc"); return 1; }
  memset(buf, 0xAB, sz);
  for (p = 0; p < passes; p++) {
    double t0 = now();
    memset(buf, 0x5A + (unsigned char)p, sz);
    volatile unsigned long acc = 0;
    for (i = 0; i < (int)(sz / 4096); i++) acc += (unsigned long)buf[(size_t)i * 4096];
    (void)acc;
    double dt = now() - t0;
    double gbps = ((double)sz * 2.0) / dt / 1e9;
    if (gbps > best) best = gbps;
  }
  printf("%.2f\n", best);
  free(buf);
  return 0;
}
'

bench_mem() {
  local passes=3
  [ "$BH_FAST" = "1" ] && passes=1

  # pick a safe buffer size: fast=128 / normal=256, clamped to 25% of available RAM
  local mb=256
  [ "$BH_FAST" = "1" ] && mb=128
  if [ "${BH_MEM_AVAIL_MB:-0}" -gt 8 ] 2>/dev/null; then
    mb="$(awk_min2 "$mb" "$(awk -v a="$BH_MEM_AVAIL_MB" 'BEGIN{printf "%d", a/4}')")"
  fi
  [ "$mb" -lt 16 ] 2>/dev/null && mb=16

  # context notes for the report layer (informational only)
  [ -n "$BH_THP" ] && BH_MEM_THP_NOTE="thp=$BH_THP"
  [ -n "$BH_SWAP_DETAIL" ] && BH_MEM_SWAP_NOTE="$BH_SWAP_DETAIL"

  # informational: cgroup RAM limit is smaller than the bench buffer request
  if [ "${BH_MEM_LIMIT_MB:-0}" -gt 0 ] 2>/dev/null && [ "$BH_MEM_LIMIT_MB" -lt "$mb" ] 2>/dev/null; then
    log "container RAM limit ${BH_MEM_LIMIT_MB} MB — bench buffer already clamped"
  fi

  local ccbin=""
  command_exists cc    && ccbin=cc
  [ -z "$ccbin" ] && command_exists gcc   && ccbin=gcc
  [ -z "$ccbin" ] && command_exists clang && ccbin=clang

  if [ -n "$ccbin" ]; then
    printf '%s\n' "$BH_MEMBENCH_C" > "$BH_RUNDIR/mem.c" 2>/dev/null
    if "$ccbin" -O2 -o "$BH_RUNDIR/membench" "$BH_RUNDIR/mem.c" 2>/dev/null; then
      log "MEM bench: memcpy-style C loop (${mb} MB x ${passes})..."
      BH_MEM_GBS="$("$BH_RUNDIR/membench" "$mb" "$passes" 2>/dev/null | tr -d '\n')"
      BH_MEM_METHOD="memcpy (C, write+read counted)"
    fi
  fi

  if [ -z "$BH_MEM_GBS" ] || [ "$BH_MEM_GBS" = "0" ] || [ "$BH_MEM_GBS" = "0.00" ]; then
    log "MEM bench: no C compiler — dd proxy with adaptive payload..."
    local blocks=1024 t0 t1 ms
    [ "$BH_FAST" != "1" ] && blocks=2048
    while :; do
      t0=$(now_ms)
      dd if=/dev/zero of=/dev/null bs=1M count="$blocks" 2>/dev/null
      t1=$(now_ms)
      ms=$((t1 - t0))
      { [ "$ms" -ge 300 ] || [ "$blocks" -ge 8192 ]; } && break
      blocks=$((blocks * 2))
    done
    BH_MEM_GBS="$(awk -v b="$blocks" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.2f", b*1048576/1e9/(ms/1000); else print 0 }')"
    BH_MEM_METHOD="dd /dev/zero->null proxy"
  fi
}
