# =====================================================================
# blackhole-vps-bench · 40-mem.sh — memory bandwidth benchmark
# Preferred: real C stream-copy kernel (dst[i]=src[i]) compiled at runtime
#            (cc/gcc/clang, -O2); 16 bytes/element counted (8 read + 8 write).
# Fallback:  dd write-to-null CPU proxy with adaptive payload sizing
#            (NOT memory bandwidth — kept only for compiler-less systems).
# =====================================================================
# shellcheck shell=bash

BH_MEM_GBS=""; BH_MEM_METHOD=""
# context notes for the report layer (filled in by bench_mem)
BH_MEM_THP_NOTE=""; BH_MEM_SWAP_NOTE=""

# Stream-copy kernel. argv: [1]=per-buffer MB [2]=min seconds [3]=output file.
# Copies src->dst repeatedly until >=min seconds elapsed or >=3 full passes.
# A rotating checksum sampled from dst every pass (plus a compiler memory
# barrier) defeats dead-store elimination; elapsed ns, total bytes and the
# checksum are written to the output file for bash to turn into GB/s.
BH_MEMBENCH_C='
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef unsigned long long u64;
static long long now_ns(void){
  struct timespec ts;
  ts.tv_sec = 0; ts.tv_nsec = 0;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return (long long)time(NULL) * 1000000000LL;
  return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}
int main(int argc, char **argv){
  size_t mb, n, i;
  double mins;
  const char *outpath;
  long long min_ns, t0, t1, elapsed, total_bytes;
  u64 *src, *dst, checksum;
  int pass, passes_done;
  FILE *f;

  mb      = argc > 1 ? (size_t)strtoul(argv[1], NULL, 10) : 256;
  mins    = argc > 2 ? atof(argv[2]) : 2.0;
  outpath = argc > 3 ? argv[3] : NULL;
  if (mb < 1) mb = 1;
  min_ns  = (long long)(mins * 1e9);
  if (min_ns < 1) min_ns = 1;

  n = mb * 1024UL * 1024UL / sizeof(u64);   /* elements per buffer */
  if (n < 1024) n = 1024;

  src = (u64 *)malloc(n * sizeof(u64));
  dst = (u64 *)malloc(n * sizeof(u64));
  if (!src || !dst) { free(src); free(dst); return 1; }

  /* touch + init both buffers outside the timed region (page faults etc.) */
  for (i = 0; i < n; i++) src[i] = ((u64)i + 1) * 2654435761ULL ^ 0x9E3779B97F4A7C15ULL;
  for (i = 0; i < n; i++) dst[i] = 0;
  checksum = 0;

  t0 = now_ns();
  passes_done = 0;
  for (pass = 0; pass < 1000000; pass++) {
    for (i = 0; i < n; i++) dst[i] = src[i];
#if defined(__GNUC__) || defined(__clang__)
    __asm__ __volatile__("" ::: "memory");  /* the copy stores must land */
#endif
    /* observe dst so the copy cannot be optimized away */
    checksum ^= dst[0] ^ dst[n / 2] ^ dst[n - 1] ^ dst[(size_t)pass * 65599ULL % n];
    passes_done++;
    t1 = now_ns();
    if (t1 - t0 >= min_ns || passes_done >= 3) break;
  }
  elapsed = now_ns() - t0;
  if (elapsed <= 0) elapsed = 1;            /* division guard */
  total_bytes = (long long)passes_done * (long long)n * 16LL; /* 8 read + 8 write */

  free(src); free(dst);
  if (!outpath) {
    printf("%lld %lld %llu\n", elapsed, total_bytes, checksum);
    return 0;
  }
  f = fopen(outpath, "w");
  if (!f) return 2;
  fprintf(f, "%lld %lld %llu\n", elapsed, total_bytes, checksum);
  fclose(f);
  return 0;
}
'

bench_mem() {
  # reset outputs so a re-invocation never reuses stale numbers
  BH_MEM_GBS=""; BH_MEM_METHOD=""

  local passes=3
  [ "$BH_FAST" = "1" ] && passes=1

  # context notes for the report layer (informational only)
  [ -n "$BH_THP" ] && BH_MEM_THP_NOTE="thp=$BH_THP"
  [ -n "$BH_SWAP_DETAIL" ] && BH_MEM_SWAP_NOTE="$BH_SWAP_DETAIL"

  # ---- buffer sizing: per-buffer MB (two buffers: src + dst) ----
  # want 256 MB full / 64 MB fast per buffer, but never more than ~1/8 of
  # usable RAM (MemAvailable clamped by the cgroup limit); floor 16 MB.
  local want=256 mb=256 avail_kb=0 avail_mb=0
  [ "$BH_FAST" = "1" ] && want=64

  avail_kb="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  case "$avail_kb" in ''|*[!0-9]*)
    avail_kb="$(awk '/^MemFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
    case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac
  ;; esac
  if [ "${MEM_LIMIT_KB:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$avail_kb" -le 0 ] 2>/dev/null || [ "$MEM_LIMIT_KB" -lt "$avail_kb" ]; then
      avail_kb="$MEM_LIMIT_KB"
    fi
  fi
  if [ "$avail_kb" -gt 0 ] 2>/dev/null; then
    avail_mb=$((avail_kb / 1024))
  elif [ "${BH_MEM_AVAIL_MB:-0}" -gt 0 ] 2>/dev/null; then
    avail_mb="$BH_MEM_AVAIL_MB"
  fi
  if [ "$avail_mb" -gt 0 ] 2>/dev/null; then
    mb=$((avail_mb / 8))
    [ "$mb" -gt "$want" ] && mb=$want
  else
    mb=$want
  fi
  [ "$mb" -lt 16 ] 2>/dev/null && mb=16    # guard rail: scale down, min 16 MB

  # informational: cgroup RAM limit is smaller than the bench buffer request
  if [ "${BH_MEM_LIMIT_MB:-0}" -gt 0 ] 2>/dev/null && [ "$BH_MEM_LIMIT_MB" -lt "$mb" ] 2>/dev/null; then
    log "container RAM limit ${BH_MEM_LIMIT_MB} MB — bench buffer already clamped"
  fi

  # ---- C stream-copy benchmark ----
  local ccbin=""
  command_exists cc    && ccbin=cc
  [ -z "$ccbin" ] && command_exists gcc   && ccbin=gcc
  [ -z "$ccbin" ] && command_exists clang && ccbin=clang

  if [ -n "$ccbin" ]; then
    printf '%s\n' "$BH_MEMBENCH_C" > "$BH_RUNDIR/mem.c" 2>/dev/null
    # -lrt only needed for clock_gettime on pre-2.17 glibc
    if "$ccbin" -O2 -o "$BH_RUNDIR/membench" "$BH_RUNDIR/mem.c" 2>/dev/null \
       || "$ccbin" -O2 -o "$BH_RUNDIR/membench" "$BH_RUNDIR/mem.c" -lrt 2>/dev/null; then
      log "MEM bench: C stream-copy (2 x ${mb} MB buffers, best of ${passes})..."
      local best="" run=0 out ns bytes cksum gbs
      while [ "$run" -lt "$passes" ]; do
        run=$((run + 1))
        out="$BH_RUNDIR/mem.out.$run"
        : > "$out" 2>/dev/null
        "$BH_RUNDIR/membench" "$mb" 2 "$out" >/dev/null 2>&1 || continue
        [ -s "$out" ] || continue
        read -r ns bytes cksum < "$out" 2>/dev/null || continue
        case "$ns"    in ''|*[!0-9]*) continue ;; esac
        case "$bytes" in ''|*[!0-9]*) continue ;; esac
        [ "$ns" -gt 0 ] 2>/dev/null || continue
        # GB/s = bytes / ns (1 GB = 1e9 bytes, 1 s = 1e9 ns)
        gbs="$(awk -v b="$bytes" -v ns="$ns" 'BEGIN{ printf "%.2f", b/ns }')"
        if [ -z "$best" ]; then best="$gbs"
        else best="$(awk -v a="$best" -v b="$gbs" 'BEGIN{ if (b+0>a+0) printf "%.2f", b; else printf "%.2f", a }')"
        fi
      done
      case "$best" in ''|0|0.00) best="" ;; esac
      if [ -n "$best" ]; then
        BH_MEM_GBS="$best"
        BH_MEM_METHOD="c-copy (r+w)"
      fi
    fi
    # never leave temp source/binary/results behind (BH_RUNDIR is trap-cleaned,
    # but be tidy even when callers skip the trap)
    rm -f "$BH_RUNDIR/mem.c" "$BH_RUNDIR/membench" "$BH_RUNDIR"/mem.out.* 2>/dev/null
  fi

  # ---- dd fallback: CPU proxy, NOT memory bandwidth ----
  if [ -z "$BH_MEM_GBS" ] || [ "$BH_MEM_GBS" = "0" ] || [ "$BH_MEM_GBS" = "0.00" ]; then
    log "MEM bench: no C compiler (or compile/run failed) — dd CPU proxy..."
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
    # NOTE: this measures raw CPU/zero-page throughput, NOT memory bandwidth.
    BH_MEM_GBS="$(awk -v b="$blocks" -v ms="$ms" 'BEGIN{ if (ms>=50) printf "%.2f", b*1048576/1e9/(ms/1000); else print 0 }')"
    BH_MEM_METHOD="cpu-proxy (dd)"
  fi
}
