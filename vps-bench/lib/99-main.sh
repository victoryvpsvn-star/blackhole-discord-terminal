# =====================================================================
# blackhole-vps-bench · 99-main.sh — CLI parsing, run modes, selftest, exit gates
# =====================================================================
# shellcheck shell=bash

usage() {
  cat <<USAGE
$BH_TOOL v$BH_VERSION — VPS virtualization detector + hardware benchmark + SSH/security audit
Detects KVM / QEMU / Docker / Podman / Kubernetes / LXC / OpenVZ / Xen / Hyper-V /
VMware / VirtualBox / bhyve / WSL / bare metal (+ confidential computing SEV-SNP/TDX,
GPU / accelerators, nesting stack), fingerprints the cloud provider, benchmarks the
REAL (cgroup-limited) configuration — CPU (with steal-under-load / noisy-neighbor
proof), memory, disk (true random 4K latency + live device proof), network speed —
and audits the local SSH & security posture (password vs key auth, root login,
weak crypto, fail2ban, firewall, hardening). Everything prints right here in the
terminal; JSON / Markdown / Prometheus / Discord outputs are optional extras.

Usage: blackhole-vps-bench [MODE] [OPTIONS]

Modes:
  all        detect + info + full benchmark + security audit (default)
  detect     virtualization detection only (fast, works offline)
  info       system info + security audit, no benchmark
  bench      benchmark only (detection still shown for context)
  sec        security/SSH audit only — NO benchmark, ZERO network traffic
  selftest   internal assertions (pure helpers, no stress, no network)
  help       show this help

Options:
  --fast           quick profile (smaller payloads, no region matrix / port probes)
  --no-net         skip all network tests (no outbound traffic at all)
  --no-sec         skip the SSH/security audit
  --no-port-probe  skip the outbound port viability checks (25/465/587/1194/51820)
  --redact         mask IPs, usernames and cloud instance ids in every output
  --only LIST      run only these modules: cpu,mem,disk,extra,net,sec,env,gpu,storage,info,region,spec,hw,container,mounts,health,diskdur,netextra
  --skip LIST      skip these modules (same names)
  --min-score N    exit 3 when the BH-SCORE total is below N (CI gate)
  --fail-on LEVEL  exit 4 when security posture has warn|bad findings (CI gate)
  --prom PATH      write a Prometheus textfile (.prom) report — atomic rename
  --timing PATH    write a per-module wall-time table (TSV) to PATH — atomic rename
  --badge PATH     write a shields.io endpoint badge JSON to PATH — atomic rename
  --svg PATH       write a static SVG score-gauge chart to PATH — atomic rename
  --compare PATH   diff this run against a previous JSON report (trend arrows)
  --webhook URL    send report to a Discord webhook (env: BH_WEBHOOK)
  --json PATH      write JSON report to PATH ('-' = stdout)
  --markdown PATH  write Markdown report to PATH ('-' = stdout)
  --output PATH    write plain-text report to PATH
  --disk-dir DIR   directory for disk tests (default: /tmp)
  --no-color       disable ANSI colors
  --version        print version
  -h, help         show help

Environment: BH_WEBHOOK, BH_FAST=1, BH_NO_NET=1, BH_NO_SEC=1, BH_REDACT=1,
BH_PORT_PROBE=0, BH_GAUGE_ASCII=1, BH_DISK_DIR, BH_NO_COLOR=1, BH_QUIET=1,
BH_HISTORY=0 (disable run-history TSV append)

Exit codes: 0 ok | 1 benchmark produced no data | 2 usage error
            3 score below --min-score | 4 security posture hit --fail-on

Examples:
  blackhole-vps-bench
  blackhole-vps-bench detect
  blackhole-vps-bench sec                        # only the SSH/security audit
  blackhole-vps-bench all --fast
  blackhole-vps-bench all --json r.json --prom metrics.prom
  blackhole-vps-bench all --timing t.tsv --badge b.json --svg score.svg
  blackhole-vps-bench bench --compare last.json --min-score 400
USAGE
}

BH_MODE="all"

# bh_mod_enabled NAME — module filter via --only/--skip (comma lists).
bh_mod_enabled() {
  local n="$1"
  if [ -n "$BH_SKIP" ]; then
    case ",$(printf '%s' "$BH_SKIP" | tr -d ' ')," in *",$n,"*) return 1 ;; esac
  fi
  if [ -n "$BH_ONLY" ]; then
    case ",$(printf '%s' "$BH_ONLY" | tr -d ' ')," in *",$n,"*) return 0 ;; esac
    return 1
  fi
  return 0
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      all|detect|info|bench|sec|selftest) BH_MODE="$1" ;;
      help|-h|--help)        BH_MODE="help" ;;
      --version|-V)          BH_MODE="version" ;;
      --fast)                BH_FAST=1 ;;
      --no-net)              BH_NO_NET=1 ;;
      --no-sec)              BH_NO_SEC=1 ;;
      --no-port-probe)       BH_PORT_PROBE=0 ;;
      --redact)              BH_REDACT=1 ;;
      --only)
        [ -n "${2:-}" ] || die "--only requires a module list"
        BH_ONLY="$2"; shift ;;
      --skip)
        [ -n "${2:-}" ] || die "--skip requires a module list"
        BH_SKIP="$2"; shift ;;
      --min-score)
        [ -n "${2:-}" ] || die "--min-score requires a number"
        BH_MIN_SCORE="$2"; shift ;;
      --fail-on)
        [ -n "${2:-}" ] || die "--fail-on requires warn|bad"
        BH_FAIL_ON="$2"; shift ;;
      --prom)
        [ -n "${2:-}" ] || die "--prom requires a path"
        BH_PROM_OUT="$2"; shift ;;
      --timing)
        [ -n "${2:-}" ] || die "--timing requires a path"
        BH_TIMING_OUT="$2"; shift ;;
      --badge)
        [ -n "${2:-}" ] || die "--badge requires a path"
        BH_BADGE_OUT="$2"; shift ;;
      --svg)
        [ -n "${2:-}" ] || die "--svg requires a path"
        BH_SVG_OUT="$2"; shift ;;
      --compare)
        [ -n "${2:-}" ] || die "--compare requires a previous JSON report path"
        BH_COMPARE_IN="$2"; shift ;;
      --webhook)
        [ -n "${2:-}" ] || die "--webhook requires a URL"
        BH_WEBHOOK="$2"; shift ;;
      --json)
        [ -n "${2:-}" ] || die "--json requires a path"
        BH_JSON_OUT="$2"; shift ;;
      --markdown)
        [ -n "${2:-}" ] || die "--markdown requires a path"
        BH_MD_OUT="$2"; shift ;;
      --output)
        [ -n "${2:-}" ] || die "--output requires a path"
        BH_TXT_OUT="$2"; shift ;;
      --disk-dir)
        [ -n "${2:-}" ] || die "--disk-dir requires a directory"
        BH_DISK_DIR="$2"; shift ;;
      --no-color) BH_NO_COLOR=1; C_RST=''; C_B=''; C_DIM=''; C_CYN=''; C_GRN=''; C_YLW=''; C_RED=''; C_MAG='' ;;
      *)
        die "unknown argument: $1 (see: $BH_TOOL help)" ;;
    esac
    shift
  done
}

# =====================================================================
# v5 wiring helpers (C15) — private, bhv5c15_* prefixed
# =====================================================================

# bhv5c15_progress MSG — one in-place progress hint on stderr. TTY-only and
# silenced by BH_QUIET=1; step counter auto-increments up to the per-mode
# BHV5C15_TOTAL so the numbering follows each mode's actual sequence.
bhv5c15_progress() {
  [ -t 2 ] || return 0
  [ "${BH_QUIET:-0}" != "1" ] || return 0
  BHV5C15_STEP=$(( ${BHV5C15_STEP:-0} + 1 ))
  if [ "${BHV5C15_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    printf '\r\033[K[bh] [%d/%d] %s' "$BHV5C15_STEP" "$BHV5C15_TOTAL" "$*" >&2
  else
    printf '\r\033[K[bh] %s' "$*" >&2
  fi
  return 0
}

# bhv5c15_v5_gathers [--health] — v5 info-side modules. Every module is
# double-guarded (bh_mod_enabled + declare -F) so a partial upgrade tree
# (lib file not merged yet) never breaks main. Timing names:
# region spec hw container mounts [health].
bhv5c15_v5_gathers() {
  bh_mod_enabled region    && declare -F gather_region      >/dev/null 2>&1 && bh_timed region    gather_region      || true
  bh_mod_enabled spec      && declare -F gather_speccheck   >/dev/null 2>&1 && bh_timed spec      gather_speccheck   || true
  bh_mod_enabled hw        && declare -F gather_hwdeep      >/dev/null 2>&1 && bh_timed hw        gather_hwdeep      || true
  bh_mod_enabled container && declare -F gather_container   >/dev/null 2>&1 && bh_timed container gather_container   || true
  bh_mod_enabled mounts    && declare -F gather_mount_audit >/dev/null 2>&1 && bh_timed mounts    gather_mount_audit || true
  if [ "${1:-}" = "--health" ]; then
    bh_mod_enabled health && declare -F gather_storage_health >/dev/null 2>&1 && bh_timed health gather_storage_health || true
  fi
  return 0
}

# bhv5c15_quiet_summary — BH_QUIET=1 one-glance CI summary on stdout. Uses
# the same score/posture globals the 70-report sink renders. Sinks (files)
# are unaffected.
bhv5c15_quiet_summary() {
  [ "${BH_QUIET:-0}" = "1" ] || return 0
  local total max grade w b
  total="${BH_SCORE_TOTAL:-0}"
  max="${BH_SCORE_MAX:-700}"
  grade="${BH_GRADE:-}"
  if [ -z "$grade" ] && declare -F grade_letter >/dev/null 2>&1; then
    grade="$(grade_letter "$total" "$max" 2>/dev/null)" || grade=""
  fi
  if [ -n "$grade" ]; then
    printf 'BH-SCORE: %s/%s (%s)\n' "$total" "$max" "$grade"
  else
    printf 'BH-SCORE: %s/%s\n' "$total" "$max"
  fi
  case "${BH_SEC_WARN:-}" in ''|*[!0-9]*) w=0 ;; *) w="$BH_SEC_WARN" ;; esac
  case "${BH_SEC_BAD:-}"  in ''|*[!0-9]*) b=0 ;; *) b="$BH_SEC_BAD" ;; esac
  if [ "$w" -gt 0 ] || [ "$b" -gt 0 ]; then
    printf 'posture: warn:%s bad:%s\n' "$w" "$b"
  else
    printf 'posture: good\n'
  fi
  local fp
  fp="${BH_FINGERPRINT:-${BH_FP:-}}"
  [ -n "$fp" ] && printf 'fingerprint: %s\n' "$fp"
  return 0
}

# bhv5c15_timing_out — write the module wall-time table atomically
# (tmp + mv); also echo one row per log line to stderr unless quiet.
bhv5c15_timing_out() {
  [ -n "${BH_TIMING_OUT:-}" ] || return 0
  if bh_timing_table > "${BH_TIMING_OUT}.tmp" 2>/dev/null; then
    if mv -f "${BH_TIMING_OUT}.tmp" "$BH_TIMING_OUT" 2>/dev/null; then
      log "timing table written to $BH_TIMING_OUT"
    else
      rm -f "${BH_TIMING_OUT}.tmp" 2>/dev/null || true
      log "timing table could not be moved to $BH_TIMING_OUT"
    fi
  else
    rm -f "${BH_TIMING_OUT}.tmp" 2>/dev/null || true
    log "timing table unavailable"
  fi
  if [ "${BH_QUIET:-0}" != "1" ]; then
    local row
    bh_timing_table 2>/dev/null | while IFS= read -r row; do
      [ -n "$row" ] || continue
      log "timing $row"
    done
  fi
  return 0
}

# bhv5c15_atomic_out PATH BUILDER LABEL — guarded sink runner for badge/svg.
# Tolerates BOTH builder contracts:
#   a) builder prints artifact to stdout  -> committed here via tmp + mv;
#   b) builder writes PATH itself (the 70-report sinks are self-atomic)
#      -> accepted when PATH exists non-empty after the call.
# Absent builder = logged skip (mid-merge safe); failures never abort main.
bhv5c15_atomic_out() {
  local path="$1" fn="$2" label="$3" tmp rc=0
  [ -n "$path" ] || return 0
  declare -F "$fn" >/dev/null 2>&1 || { log "$label skipped (builder $fn not present)"; return 0; }
  tmp="${path}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  "$fn" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    if mv -f "$tmp" "$path" 2>/dev/null; then
      log "$label written to $path"
      return 0
    fi
  elif [ "$rc" -eq 0 ] && [ -s "$path" ]; then
    # self-atomic builder already committed the artifact during the call
    log "$label present at $path"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  log "$label build failed"
  return 0
}

# bhv5c15_sinks_out — badge + svg sinks (builders live in 70-report; guarded).
bhv5c15_sinks_out() {
  [ -n "${BH_BADGE_OUT:-}" ] && bhv5c15_atomic_out "$BH_BADGE_OUT" build_badge "badge"
  [ -n "${BH_SVG_OUT:-}" ]   && bhv5c15_atomic_out "$BH_SVG_OUT"   build_svg   "svg gauge"
  return 0
}

# bhv5c15_footer — wall time + rerun hint reconstructed from actual state.
# --webhook is deliberately never echoed (may be a private URL).
bhv5c15_footer() {
  local wall=0 now flags=""
  if [ -n "${BH_T_MAIN0:-}" ]; then
    now="$(now_ms)"
    case "$now" in ''|*[!0-9]*) now="" ;; esac
    if [ -n "$now" ]; then
      wall=$(( (now - BH_T_MAIN0 + 999) / 1000 ))
      [ "$wall" -lt 0 ] 2>/dev/null && wall=0
    fi
  fi
  [ "${BH_FAST:-0}" = "1" ]   && flags="$flags --fast"
  [ "${BH_NO_NET:-0}" = "1" ] && flags="$flags --no-net"
  [ -n "${BH_SKIP:-}" ]       && flags="$flags --skip ${BH_SKIP}"
  log "wall ${wall}s · v${BH_VERSION} · rerun: ${BH_TOOL} all${flags}"
  return 0
}

# run_selftest — v4 internal assertions. Pure helper math only: no network,
# no disk stress, no forking storms. Exit 0 = all green, 1 = regressions.
run_selftest() {
  local fails=0
  _t() { # _t NAME CONDITION...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf 'PASS: %s\n' "$name"
    else
      printf 'FAIL: %s\n' "$name"
      fails=$((fails + 1))
    fi
  }
  _eq() { [ "$1" = "$2" ]; }
  _ge() { [ "$1" -ge "$2" ]; }
  _len() { [ "${#1}" -eq "$2" ]; }
  # v5 assertion helpers (plain predicates — no eval, no early `return` inside
  # the _t condition: a `return` executed by eval would unwind _t itself and
  # silently skip the PASS/FAIL line + fail counter)
  _num()   { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }        # non-empty digits only
  _match() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }                 # substring
  _slug()  { case "${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; *) return 0 ;; esac; }  # fingerprint slug charset

  local a b
  a=$(now_ms)
  ${SLEEP_CMD:-sleep} 0.05 2>/dev/null || true
  b=$(now_ms)
  _t "now_ms monotonic"            _ge "$b" "$a"
  _t "now_us numeric"              eval 'case "$(now_us)" in *[!0-9]*|"") return 1 ;; esac'

  _t "json_val numeric"            _eq "$(json_val 42)" "42"
  _t "json_val float"              _eq "$(json_val 3.5)" "3.5"
  _t "json_val string"             _eq "$(json_val abc)" '"abc"'
  _t "json_esc escapes quote"      _eq "$(json_esc 'a"b')" 'a\"b'
  _t "json_esc escapes newline"    _eq "$(json_esc "$(printf 'a\nb')")" 'ab'

  _t "grade_letter S"              _eq "$(grade_letter 630 700)" "S"
  _t "grade_letter A"              _eq "$(grade_letter 530 700)" "A"
  _t "grade_letter F"              _eq "$(grade_letter 10 700)" "F"
  _t "grade_letter empty"          _eq "$(grade_letter 0 700)" ""
  _t "tier_cpu1c server"           _eq "$(tier_cpu1c 4000)" "server-grade"
  _t "tier_cpu1c empty"            _eq "$(tier_cpu1c "")" ""
  _t "tier_net gigabit"            _eq "$(tier_net 940)" "gigabit-class"
  _t "cap100 clamps"               _eq "$(cap100 250)" "100"
  _t "cap100 zero"                 _eq "$(cap100 -5)" "0"

  _t "fmt_mbps gigabit"            eval 'case "$(fmt_mbps 940)" in *Mbps*) return 0 ;; *) return 1 ;; esac'
  _t "fmt_mb empty"                _eq "$(fmt_mb "")" "n/a"

  _t "gauge zero vs full"          eval '[ "$(bh_gauge 0 100)" != "$(bh_gauge 100 100)" ]'
  _t "gauge width ascii 10"        eval 'x="$(BH_GAUGE_ASCII=1 bh_gauge 50 100)"; [ ${#x} -eq 10 ]'
  _t "gauge empty on max 0"        eval 'x="$(BH_GAUGE_ASCII=1 bh_gauge 5 0)"; [ ${#x} -eq 10 ]'

  _t "cpuset count range"          eval 'x="$(CPUSET=0-3,8 bh_cpuset_count)"; [ "$x" = "5" ]'
  _t "cpuset count empty"          eval '[ "$(CPUSET= bh_cpuset_count)" = "0" ]'
  _t "par jobs sane"               eval '[ "$BH_PAR_JOBS" -ge 1 ] && [ "$BH_PAR_JOBS" -le "$NCPU" ]'
  _t "cpu quota parses"            eval 'case "$QUOTA_CORES" in *[!0-9.]*) return 1 ;; esac'

  # ---- v5 selftests (guarded: an unmerged optional module prints SKIP) ----

  # bh_median3 (05-noise) — median-of-N command runner
  if declare -F bh_median3 >/dev/null 2>&1; then
    _t "bh_median3 runs cmd"       _eq "$(bh_median3 sh -c 'echo hi' 2>/dev/null)" "hi"
  else
    printf 'SKIP: bh_median3 (feature not present)\n'
  fi

  # bh_noise_spread (05-noise) — spread% of a ~10ms micro-bench is a plain integer
  if declare -F bh_noise_spread >/dev/null 2>&1; then
    _t "bh_noise_spread numeric"   _num "$(bh_noise_spread "${SLEEP_CMD:-sleep}" 0.01 2>/dev/null)"
  else
    printf 'SKIP: bh_noise_spread (feature not present)\n'
  fi

  # bh_psi (00-core) — fixture-driven PSI parse
  local psi_dir psi_out
  psi_dir="$(mktemp -d "${TMPDIR:-/tmp}/bhvps_psi.XXXXXX" 2>/dev/null)" || psi_dir=""
  if [ -n "$psi_dir" ]; then
    printf 'some avg10=1.00 avg60=0.50 avg300=0.10\n' > "$psi_dir/cpu" 2>/dev/null || true
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00\nfull avg10=0.00 avg60=0.00 avg300=0.00\n' > "$psi_dir/memory" 2>/dev/null || true
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00\nfull avg10=0.00 avg60=0.00 avg300=0.00\n' > "$psi_dir/io" 2>/dev/null || true
    psi_out="$(bh_psi "$psi_dir" 2>/dev/null)"
    _t "bh_psi fixture cpu avg10"  _match "$psi_out" "cpu s=1.00"
  else
    printf 'SKIP: bh_psi fixture (mktemp unavailable)\n'
  fi
  [ -z "$psi_dir" ] || rm -rf "$psi_dir" 2>/dev/null || true

  # bh_spec_verdict (55-storage-map) — claimed-vs-actual spec verdicts
  if declare -F bh_spec_verdict >/dev/null 2>&1; then
    _t "bh_spec_verdict cpu ok"    _eq "$(bh_spec_verdict 2 2 cpu 2>/dev/null)" "ok"
    _t "bh_spec_verdict ram warn"  _eq "$(bh_spec_verdict 1024 700 ram 2>/dev/null)" "warn"
  else
    printf 'SKIP: bh_spec_verdict (feature not present)\n'
  fi

  # bh_sparkline (64-history) — min-max block ramp ▁▂▃▄▅▆▇█.
  # NOTE on "length": LC_ALL=C (exported by 00-core) makes ${#s} count BYTES,
  # and each block char is 3 UTF-8 bytes — so a 3-point ramp is 9 "chars".
  # The exact-ramp assertions below are the locale-stable "length 3" check.
  if declare -F bh_sparkline >/dev/null 2>&1; then
    local sl slc
    sl="$(bh_sparkline 1 2 3 2>/dev/null)"
    slc="$(bh_sparkline 4 4 4 2>/dev/null)"
    _t "bh_sparkline 3 blocks"     _eq "$sl" "▁▅█"
    _t "bh_sparkline 3 bytes x3"   _len "$sl" 9
    _t "bh_sparkline const ramp"   _eq "$slc" "▅▅▅"
    _t "bh_sparkline single empty" _eq "$(bh_sparkline 42 2>/dev/null)" ""
    _t "bh_sparkline noargs empty" _eq "$(bh_sparkline 2>/dev/null)" ""
  else
    printf 'SKIP: bh_sparkline (feature not present)\n'
  fi

  # bh_fp_sanitize (70-report) — machine fingerprint slug
  if declare -F bh_fp_sanitize >/dev/null 2>&1; then
    _t "bh_fp_sanitize slug chars" _slug "$(bh_fp_sanitize 'KVM/AWS t3.medium' 2>/dev/null)"
  else
    printf 'SKIP: bh_fp_sanitize (feature not present)\n'
  fi

  # bh_history_render (64-history) — fixture TSV in a throwaway XDG_CACHE_HOME
  local hdir old_xdg sl3 tr3
  hdir="$(mktemp -d "${TMPDIR:-/tmp}/bhvps_hist.XXXXXX" 2>/dev/null)" || hdir=""
  if [ -n "$hdir" ] && declare -F bh_history_render >/dev/null 2>&1 && declare -F bh_sparkline >/dev/null 2>&1; then
    old_xdg="${XDG_CACHE_HOME:-}"
    XDG_CACHE_HOME="$hdir"
    mkdir -p "$hdir/blackhole-vps-bench" 2>/dev/null || true
    printf '1700000000\t500\tA\t50\t50\t50\t50\t50\t100\t100\n1700000010\t537\tA\t50\t50\t60\t50\t50\t120\t107\n1700000020\t563\tA\t50\t50\t70\t50\t50\t140\t103\n' \
      > "$hdir/blackhole-vps-bench/history.tsv" 2>/dev/null || true
    bh_history_render
    sl3="${BH_SPARKLINE:-}"; tr3="${BH_TREND:-}"
    XDG_CACHE_HOME="$old_xdg"
    _t "history render sparkline"  _eq "$sl3" "▁▅█"
    _t "history render trend +26"  _eq "$tr3" "+26"
  elif [ -z "$hdir" ]; then
    printf 'SKIP: bh_history_render fixture (mktemp unavailable)\n'
  fi
  [ -z "$hdir" ] || rm -rf "$hdir" 2>/dev/null || true

  if [ "$fails" -eq 0 ]; then
    printf 'SELFTEST: all checks passed\n'
    return 0
  fi
  printf 'SELFTEST: %d check(s) FAILED\n' "$fails"
  return 1
}

write_outputs() {
  if [ -n "$BH_JSON_OUT" ]; then
    if [ "$BH_JSON_OUT" = "-" ]; then
      build_json; printf '\n'
    else
      build_json > "$BH_JSON_OUT" && log "JSON report written to $BH_JSON_OUT"
    fi
  fi
  if [ -n "$BH_MD_OUT" ]; then
    if [ "$BH_MD_OUT" = "-" ]; then
      build_markdown
    else
      build_markdown > "$BH_MD_OUT" && log "Markdown report written to $BH_MD_OUT"
    fi
  fi
  # NOTE: the plain-text report (--output PATH) is written internally by
  # print_report (70-report.sh renders from its bh_lines array). Do not
  # redirect build_report here — it prints nothing and would truncate the file.
}

# bh_step_summary — when running inside GitHub Actions, silently append the
# Markdown report to the job summary (zero-config, complements artifacts).
bh_step_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  [ -n "${BH_MD_OUT:-}" ] || return 0   # only auto-embed when a markdown output was requested
  { printf '\n'; build_markdown; } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  log "GitHub Job Summary appended ($GITHUB_STEP_SUMMARY)"
}

main() {
  parse_args "$@"
  BH_T_MAIN0="$(now_ms)"   # v5: wall-clock anchor for the rerun footer

  case "$BH_MODE" in
    help)     usage; exit 0 ;;
    version)  printf '%s v%s\n' "$BH_TOOL" "$BH_VERSION"; exit 0 ;;
    selftest) run_selftest; exit $? ;;
  esac

  # Bug G4 (v4): privacy modes clamp ALL network BEFORE any gather call —
  # `sec` and `detect` must never emit a single packet. Fast mode also
  # disables the outbound port probes (keeps --fast quick and quiet).
  if [ "$BH_MODE" = "sec" ] || [ "$BH_MODE" = "detect" ]; then
    BH_NO_NET=1
  fi
  if [ "$BH_FAST" = "1" ]; then
    BH_PORT_PROBE=0
  fi
  if [ "$BH_NO_NET" = "1" ]; then
    BH_PORT_PROBE=0
  fi

  # v5: progress-hint step totals (numbering follows each mode's sequence:
  # all=8 detect info cpu mem disk extra net sec | bench=7 | detect=2 | info/sec=3)
  case "$BH_MODE" in
    all)      BHV5C15_TOTAL=8 ;;
    bench)    BHV5C15_TOTAL=7 ;;
    detect)   BHV5C15_TOTAL=2 ;;
    info|sec) BHV5C15_TOTAL=3 ;;
    *)        BHV5C15_TOTAL=0 ;;
  esac
  BHV5C15_STEP=0

  log "mode=$BH_MODE fast=$BH_FAST no_net=$BH_NO_NET redact=$BH_REDACT only=${BH_ONLY:-} skip=${BH_SKIP:-}"

  bhv5c15_progress "virtualization detect..."
  bh_timed virt detect_virt

  if [ "$BH_MODE" = "detect" ]; then
    # detection must work fully offline and instantly
    BH_BENCH_SKIPPED=1
    BH_SEC_SKIPPED=1
    bhv5c15_progress "system info..."
    bh_mod_enabled info    && bh_timed info gather_info
    bh_mod_enabled env     && bh_timed env gather_env
    bh_mod_enabled gpu     && bh_timed gpu gather_gpu
    bh_mod_enabled storage && bh_timed storage gather_storage_map
    bhv5c15_v5_gathers
  else
    bhv5c15_progress "system info..."
    bh_mod_enabled info    && bh_timed info gather_info
    bh_mod_enabled env     && bh_timed env gather_env
    bh_mod_enabled gpu     && bh_timed gpu gather_gpu
    if [ "$BH_NO_NET" != "1" ]; then
      bh_mod_enabled cloud && bh_timed cloud cloud_metadata_probe
    fi
    # v5 modules (region/spec/hw/container/mounts/health) — info context for
    # every non-detect mode; double-guarded so a mid-merge tree still runs.
    bhv5c15_v5_gathers --health
    if [ "$BH_MODE" = "info" ] || [ "$BH_MODE" = "sec" ]; then
      BH_BENCH_SKIPPED=1
      bhv5c15_progress "security audit..."
      bh_mod_enabled sec && bh_timed sec run_sec_audit
    elif [ "$BH_MODE" = "bench" ]; then
      BH_SEC_SKIPPED=1
      bhv5c15_progress "cpu bench..."
      bh_mod_enabled cpu     && bh_timed cpu bench_cpu
      bhv5c15_progress "memory bench..."
      bh_mod_enabled mem     && bh_timed mem bench_mem
      bhv5c15_progress "disk bench..."
      bh_mod_enabled disk    && bh_timed disk bench_disk
      bh_mod_enabled diskdur && declare -F bench_disk_dur >/dev/null 2>&1 && bh_timed diskdur bench_disk_dur || true
      bh_mod_enabled storage && bh_timed storage gather_storage_map
      bhv5c15_progress "extras bench..."
      bh_mod_enabled extra   && bh_timed extra bench_extra
      bhv5c15_progress "network bench..."
      bh_mod_enabled net     && bh_timed net bench_net
      bh_mod_enabled netextra && declare -F bench_net_extra >/dev/null 2>&1 && bh_timed netextra bench_net_extra || true
      compute_scores
      declare -F bh_history_append >/dev/null 2>&1 && bh_history_append
      declare -F bh_history_render >/dev/null 2>&1 && bh_history_render
    else
      bhv5c15_progress "cpu bench..."
      bh_mod_enabled cpu     && bh_timed cpu bench_cpu
      bhv5c15_progress "memory bench..."
      bh_mod_enabled mem     && bh_timed mem bench_mem
      bhv5c15_progress "disk bench..."
      bh_mod_enabled disk    && bh_timed disk bench_disk
      bh_mod_enabled diskdur && declare -F bench_disk_dur >/dev/null 2>&1 && bh_timed diskdur bench_disk_dur || true
      bh_mod_enabled storage && bh_timed storage gather_storage_map
      bhv5c15_progress "extras bench..."
      bh_mod_enabled extra   && bh_timed extra bench_extra
      bhv5c15_progress "network bench..."
      bh_mod_enabled net     && bh_timed net bench_net
      bh_mod_enabled netextra && declare -F bench_net_extra >/dev/null 2>&1 && bh_timed netextra bench_net_extra || true
      compute_scores
      declare -F bh_history_append >/dev/null 2>&1 && bh_history_append
      declare -F bh_history_render >/dev/null 2>&1 && bh_history_render
      bhv5c15_progress "security audit..."
      bh_mod_enabled sec && bh_timed sec run_sec_audit
    fi
  fi

  build_report
  if [ "${BH_QUIET:-0}" = "1" ]; then
    # quiet mode: suppress the full human body on stdout (the --output file
    # sink inside print_report still runs); only the summary below prints.
    print_report >/dev/null
  else
    print_report
  fi
  bhv5c15_quiet_summary
  write_outputs
  bhv5c15_timing_out
  bhv5c15_sinks_out
  bhv5c15_footer
  if [ "$BH_MODE" = "sec" ]; then
    log "sec mode: Discord webhook skipped (zero-traffic mode)"
  else
    discord_send
  fi
  bh_step_summary

  # ---- exit gates (v4) ----
  if [ "${BH_BENCH_SKIPPED:-0}" != "1" ] && [ "$BH_SCORE_TOTAL" -eq 0 ]; then
    warn "benchmark produced no usable data"
    exit 1
  fi
  if [ -n "$BH_MIN_SCORE" ]; then
    if [ "$BH_SCORE_TOTAL" -lt "$BH_MIN_SCORE" ] 2>/dev/null; then
      warn "BH-SCORE $BH_SCORE_TOTAL is below --min-score $BH_MIN_SCORE"
      exit 3
    fi
  fi
  if [ -n "$BH_FAIL_ON" ] && [ "${BH_SEC_SKIPPED:-0}" != "1" ]; then
    case "$BH_FAIL_ON" in
      warn)
        if [ "${BH_SEC_WARN:-0}" -gt 0 ] || [ "${BH_SEC_BAD:-0}" -gt 0 ]; then
          warn "security posture hit --fail-on warn (warn=${BH_SEC_WARN:-0} bad=${BH_SEC_BAD:-0})"
          exit 4
        fi
        ;;
      bad)
        if [ "${BH_SEC_BAD:-0}" -gt 0 ]; then
          warn "security posture hit --fail-on bad (bad=${BH_SEC_BAD:-0})"
          exit 4
        fi
        ;;
      *) die "--fail-on must be 'warn' or 'bad'" ;;
    esac
  fi
  exit 0
}
