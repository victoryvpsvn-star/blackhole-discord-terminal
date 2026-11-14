# =====================================================================
# blackhole-vps-bench · 64-history.sh — run-to-run score history + sparkline
# =====================================================================
# shellcheck shell=bash
#
# One TSV row per scored run is appended to a user-local cache file:
#   ${XDG_CACHE_HOME:-$HOME/.cache}/blackhole-vps-bench/history.tsv
#   epoch<TAB>total<TAB>grade<TAB>cpu1c<TAB>cpumc<TAB>mem<TAB>dseq<TAB>d4k<TAB>ndown<TAB>nup
#
# Strictly guarded (bh_history_append): BH_HISTORY=1 AND stdout is an
# interactive TTY AND BH_SCORE_TOTAL > 0 — CI runs and piped output never
# write into $HOME, and every failure path is silent so the history layer
# can never fail the benchmark run.
#
# This file defines functions only — no top-level side effects.

# bh_history_path — print the history TSV path (used by tests + append).
# Returns 1 (prints nothing) when no usable home/XDG base exists.
bh_history_path() {
  local base
  base="${XDG_CACHE_HOME:-}"
  if [ -z "$base" ]; then
    [ -n "${HOME:-}" ] || return 1
    base="$HOME/.cache"
  fi
  printf '%s/blackhole-vps-bench/history.tsv\n' "$base"
}

# bh_sparkline — pure: map a list of numbers to the 8-level block ramp
# ▁▂▃▄▅▆▇█ by min-max normalization. Fewer than 2 points → "" (empty).
# A constant series renders as the middle block. Input tokens accept digits
# and a dot only; anything else makes the whole call return "".
# mawk-safe: integer indexes stay tiny; LC_ALL=C (exported by 00-core) makes
# the block table byte-addressable (3 bytes per UTF-8 block char).
bh_sparkline() {
  [ $# -ge 2 ] || return 0
  local p
  for p in "$@"; do
    case "$p" in ''|*[!0-9.]*) return 0 ;; esac
  done
  printf '%s\n' "$@" | awk -v blocks="▁▂▃▄▅▆▇█" '{
    v[NR] = $1 + 0
  }
  END {
    if (NR < 2) exit 0
    mn = v[1]; mx = v[1]
    for (i = 2; i <= NR; i++) {
      if (v[i] < mn) mn = v[i]
      if (v[i] > mx) mx = v[i]
    }
    out = ""
    for (i = 1; i <= NR; i++) {
      if (mx > mn) f = (v[i] - mn) / (mx - mn) * 7
      else         f = 3.5
      idx = int(f + 0.5)
      if (idx < 0) idx = 0
      if (idx > 7) idx = 7
      out = out substr(blocks, idx * 3 + 1, 3)   # LC_ALL=C: 3 bytes per block
    }
    printf "%s\n", out
  }'
}

# bh_trend_delta — pure: last vs previous value of a numeric list →
# "+37" / "-12" / "±0" (integer delta via awk). Fewer than 2 points → "".
bh_trend_delta() {
  [ $# -ge 2 ] || return 0
  local a b
  while [ $# -gt 2 ]; do shift; done
  a="$1"; b="$2"
  case "$a$b" in ''|*[!0-9]*) return 0 ;; esac
  awk -v a="$a" -v b="$b" 'BEGIN{
    d = b - a
    if (d > 0)      printf "+%d\n", d
    else if (d < 0) printf "%d\n", d
    else            print "±0"
  }'
}

# bh_history_append — record the just-computed BH_SCORE_* row (call right
# after compute_scores). Appends ONE tab-separated line, keeps the file
# capped at the 512 newest rows, chmod 600, silent on any error.
bh_history_append() {
  [ "${BH_HISTORY:-0}" = "1" ] || return 0
  [ -t 1 ] || return 0                                   # interactive stdout only
  case "${BH_SCORE_TOTAL:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$BH_SCORE_TOTAL" -gt 0 ] || return 0
  local file dir max lines
  file="$(bh_history_path 2>/dev/null)" || return 0
  [ -n "$file" ] || return 0
  dir="${file%/*}"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" \
    "$BH_SCORE_TOTAL" \
    "${BH_GRADE:-}" \
    "${BH_SCORE_CPU1C:-0}" "${BH_SCORE_CPUMC:-0}" "${BH_SCORE_MEM:-0}" \
    "${BH_SCORE_DSEQ:-0}" "${BH_SCORE_D4K:-0}" \
    "${BH_SCORE_NDOWN:-0}" "${BH_SCORE_NUP:-0}" \
    >> "$file" 2>/dev/null || return 0
  chmod 600 "$file" 2>/dev/null || true
  # cap at the N newest lines (truncate oldest); N overridable for tests
  max="${BH_HISTORY_MAX_LINES:-512}"
  case "$max" in ''|*[!0-9]*) max=512 ;; esac
  lines="$(wc -l < "$file" 2>/dev/null)"
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$lines" -gt "$max" ]; then
    if ! { tail -n "$max" "$file" > "$file.tmp" 2>/dev/null \
        && mv -f "$file.tmp" "$file" 2>/dev/null; }; then
      rm -f "$file.tmp" 2>/dev/null || true
    fi
  fi
  return 0
}

# bh_history_render — read the last 10 history rows (same total field the
# append writes: column 2) and set report-facing globals:
#   BH_SPARKLINE  sparkline of the totals (oldest → newest)
#   BH_TREND      "+N" / "-N" / "±0" (last vs previous total)
# Silent no-op (globals stay empty) with fewer than 2 readable records.
bh_history_render() {
  BH_SPARKLINE=""
  BH_TREND=""
  local file totals n ep tot rest
  file="$(bh_history_path 2>/dev/null)" || return 0
  [ -n "$file" ] && [ -r "$file" ] || return 0
  totals=""
  n=0
  while IFS=$'\t' read -r ep tot rest; do
    case "$tot" in ''|*[!0-9]*) continue ;; esac
    totals="$totals${totals:+ }$tot"
    n=$((n + 1))
  done < <(tail -n 10 "$file" 2>/dev/null)
  [ "$n" -ge 2 ] || return 0
  # shellcheck disable=SC2086  # intentional: totals list → one arg per number
  BH_SPARKLINE="$(bh_sparkline $totals)"
  # shellcheck disable=SC2086  # intentional: totals list → one arg per number
  BH_TREND="$(bh_trend_delta $totals)"
  return 0
}
