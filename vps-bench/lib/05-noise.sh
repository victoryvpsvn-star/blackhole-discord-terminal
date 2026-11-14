# =====================================================================
# blackhole-vps-bench · 05-noise.sh — run-to-run noise discipline (v5)
# =====================================================================
# Purpose: run-to-run noise discipline for v5 micro-benches: median of 3
# plus spread%. A sub-second micro-bench is run several times back to
# back; the median pass is reported as the value and the pass-to-pass
# spread decides whether the report must label the metric "noise: high"
# instead of silently publishing a lucky (or unlucky) single run.
#
# Do NOT wrap long benches (disk seq, net) — only sub-second micro-benches.
# Wrapping a long bench would run it end-to-end BH_MEDIAN3_PASSES times.
#
# Public API:
#   bh_median3 CMD...       Run CMD BH_MEDIAN3_PASSES times (default 3, cap
#                           5); print ONLY the median pass's stdout. Passes
#                           are ranked by per-pass wall time, the middle one
#                           wins (upper middle on an even count).
#   bh_noise_spread CMD...  Same passes; print ONE integer:
#                           spread% = (max-min)/median*100 of the per-pass
#                           wall time (ms), rounded via awk printf "%.0f".
#   Both: rc 1 + empty output when fewer than 2 passes exit 0, and (spread)
#   also when the median wall time is below 1 ms (timer resolution, n/a).
#
# Usage:
#   out=$(bh_median3 my_micro_bench arg)         # reported value: median pass
#   sp=$(bh_noise_spread my_micro_bench arg)     # noise indicator, integer %
#   [ "${sp:-0}" -gt "$BH_NOISE_SPREAD_HIGH_PCT" ] && note="noise: high"
#
# Discipline rules:
#   - The noise key is per-pass wall time (now_ms from 00-core.sh), so both
#     helpers accept ANY command, multi-line stdout included. For a
#     fixed-work micro-bench, wall-time spread tracks the metric spread.
#   - Each pass inherits the caller's own timeout. No sleeps, no background
#     jobs, no temp files, no retries — failed passes simply drop out.
#   - Pass stdout is captured to memory (multi-line ok, trailing newlines
#     trimmed like $()); pass stderr is discarded and stdin is /dev/null so
#     a stray read can never hang a pass.
#   - Passes run in a subshell: a bench must return its result on stdout,
#     not through BH_* globals (those would be lost — see the note on
#     bh_hash_reps in 30-cpu.sh).
#   - Test hook: BH_MEDIAN3_PASSES (default 3, cap 5; 0 or non-numeric
#     falls back to 3; 1-2 honored — 1 always fails the ">=2 passes" rule).
#   - Rule: spread > 25% => report "noise: high" (70-report.sh renders it;
#     threshold constant: BH_NOISE_SPREAD_HIGH_PCT below).
# =====================================================================
# shellcheck shell=bash

# spread% above this renders "noise: high" in 70-report.sh (guarded default,
# overridable for tests)
BH_NOISE_SPREAD_HIGH_PCT="${BH_NOISE_SPREAD_HIGH_PCT:-25}"

# ------- internals (shared pass store, filled only at runtime) -------

# _bh_noise_passes — resolve the pass count from BH_MEDIAN3_PASSES.
_bh_noise_passes() {
  local p="${BH_MEDIAN3_PASSES:-3}"
  case "$p" in ''|*[!0-9]*) p=3 ;; esac
  [ "$p" -eq 0 ] && p=3
  [ "$p" -gt 5 ] && p=5
  printf '%s' "$p"
}

# _bh_noise_collect PASSES CMD... — run CMD up to PASSES times back to back
# and fill the shared pass store: _bh_noise_n (successful pass count),
# _bh_noise_ms[i] (elapsed ms, clamped at 0) and _bh_noise_out[i] (stdout).
# A pass counts only when CMD exits 0; failed passes drop out, no retries.
# Returns 1 when fewer than 2 passes succeeded.
_bh_noise_collect() {
  local passes="$1"; shift
  _bh_noise_ms=(); _bh_noise_out=(); _bh_noise_n=0
  local i t0 t1 ms out rc
  i=0
  while [ "$i" -lt "$passes" ]; do
    i=$(( i + 1 ))
    t0=$(now_ms)
    out="$("$@" 2>/dev/null </dev/null)"
    rc=$?
    t1=$(now_ms)
    [ "$rc" -eq 0 ] || continue
    ms=$(( t1 - t0 ))
    [ "$ms" -lt 0 ] && ms=0
    _bh_noise_ms[_bh_noise_n]=$ms
    _bh_noise_out[_bh_noise_n]="$out"
    _bh_noise_n=$(( _bh_noise_n + 1 ))
  done
  [ "$_bh_noise_n" -ge 2 ]
}

# _bh_noise_sort — stable insertion sort of the collected passes ascending
# by elapsed ms (N <= 5, in place). Afterwards _bh_noise_ms[k] is the k-th
# smallest elapsed and _bh_noise_ord[k] the original pass index, so
# _bh_noise_out[_bh_noise_ord[k]] is that pass's stdout.
_bh_noise_sort() {
  local i j tm ti
  for (( i = 0; i < _bh_noise_n; i++ )); do
    _bh_noise_ord[i]=$i
  done
  for (( i = 1; i < _bh_noise_n; i++ )); do
    tm=${_bh_noise_ms[i]}
    ti=${_bh_noise_ord[i]}
    for (( j = i - 1; j >= 0 && _bh_noise_ms[j] > tm; j-- )); do
      _bh_noise_ms[j + 1]=${_bh_noise_ms[j]}
      _bh_noise_ord[j + 1]=${_bh_noise_ord[j]}
    done
    _bh_noise_ms[j + 1]=$tm
    _bh_noise_ord[j + 1]=$ti
  done
}

# ------- public API -------

# bh_median3 CMD... — median-of-N stdout for a sub-second micro-bench.
# Runs CMD BH_MEDIAN3_PASSES times (default 3, cap 5) and prints ONLY the
# median pass's stdout: passes are ranked by per-pass wall time (now_ms)
# and the middle one wins; on an even count the upper middle is used.
# rc 1, no output when fewer than 2 passes exit 0.
bh_median3() {
  [ $# -ge 1 ] || return 1
  local passes
  passes="$(_bh_noise_passes)"
  _bh_noise_collect "$passes" "$@" || return 1
  _bh_noise_sort
  local mid=$(( _bh_noise_n / 2 ))
  printf '%s\n' "${_bh_noise_out[_bh_noise_ord[mid]]}"
}

# bh_noise_spread CMD... — integer run-to-run spread% for a micro-bench.
# Same passes as bh_median3; prints ONE number:
#   spread% = (max - min) / median * 100   (per-pass wall time in ms)
# rounded via awk printf "%.0f" (float math, mawk-safe: only small doubles).
# rc 1, no output when fewer than 2 passes exit 0 or the median wall time
# is below 1 ms — callers then render "n/a".
bh_noise_spread() {
  [ $# -ge 1 ] || return 1
  command_exists awk || return 1
  local passes
  passes="$(_bh_noise_passes)"
  _bh_noise_collect "$passes" "$@" || return 1
  _bh_noise_sort
  local lo med hi
  lo=${_bh_noise_ms[0]}
  med=${_bh_noise_ms[_bh_noise_n / 2]}
  hi=${_bh_noise_ms[_bh_noise_n - 1]}
  [ "$med" -gt 0 ] || return 1
  awk -v lo="$lo" -v hi="$hi" -v med="$med" 'BEGIN{ printf "%.0f\n", (hi - lo) / med * 100 }'
}
