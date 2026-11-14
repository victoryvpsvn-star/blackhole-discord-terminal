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
  --only LIST      run only these modules: cpu,mem,disk,extra,net,sec,env,gpu,storage,info
  --skip LIST      skip these modules (same names)
  --min-score N    exit 3 when the BH-SCORE total is below N (CI gate)
  --fail-on LEVEL  exit 4 when security posture has warn|bad findings (CI gate)
  --prom PATH      write a Prometheus textfile (.prom) report — atomic rename
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
BH_PORT_PROBE=0, BH_GAUGE_ASCII=1, BH_DISK_DIR, BH_NO_COLOR=1

Exit codes: 0 ok | 1 benchmark produced no data | 2 usage error
            3 score below --min-score | 4 security posture hit --fail-on

Examples:
  blackhole-vps-bench
  blackhole-vps-bench detect
  blackhole-vps-bench sec                        # only the SSH/security audit
  blackhole-vps-bench all --fast
  blackhole-vps-bench all --json r.json --prom metrics.prom
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

  log "mode=$BH_MODE fast=$BH_FAST no_net=$BH_NO_NET redact=$BH_REDACT only=${BH_ONLY:-} skip=${BH_SKIP:-}"
  detect_virt

  if [ "$BH_MODE" = "detect" ]; then
    # detection must work fully offline and instantly
    BH_BENCH_SKIPPED=1
    BH_SEC_SKIPPED=1
    bh_mod_enabled info    && gather_info
    bh_mod_enabled env     && gather_env
    bh_mod_enabled gpu     && gather_gpu
    bh_mod_enabled storage && gather_storage_map
  else
    bh_mod_enabled info    && gather_info
    bh_mod_enabled env     && gather_env
    bh_mod_enabled gpu     && gather_gpu
    if [ "$BH_NO_NET" != "1" ]; then
      bh_mod_enabled cloud && cloud_metadata_probe
    fi
    if [ "$BH_MODE" = "info" ] || [ "$BH_MODE" = "sec" ]; then
      BH_BENCH_SKIPPED=1
      bh_mod_enabled sec && run_sec_audit
    elif [ "$BH_MODE" = "bench" ]; then
      BH_SEC_SKIPPED=1
      bh_mod_enabled cpu     && bench_cpu
      bh_mod_enabled mem     && bench_mem
      bh_mod_enabled disk    && bench_disk
      bh_mod_enabled storage && gather_storage_map
      bh_mod_enabled extra   && bench_extra
      bh_mod_enabled net     && bench_net
      compute_scores
    else
      bh_mod_enabled cpu     && bench_cpu
      bh_mod_enabled mem     && bench_mem
      bh_mod_enabled disk    && bench_disk
      bh_mod_enabled storage && gather_storage_map
      bh_mod_enabled extra   && bench_extra
      bh_mod_enabled net     && bench_net
      compute_scores
      bh_mod_enabled sec && run_sec_audit
    fi
  fi

  build_report
  print_report
  write_outputs
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
