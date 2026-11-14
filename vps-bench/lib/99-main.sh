# =====================================================================
# blackhole-vps-bench · 99-main.sh — CLI parsing and run modes
# =====================================================================
# shellcheck shell=bash

usage() {
  cat <<USAGE
$BH_TOOL v$BH_VERSION — VPS virtualization detector + hardware benchmark
Detects KVM / QEMU / Docker / Podman / LXC / OpenVZ / Xen / Hyper-V / VMware /
VirtualBox / bhyve / WSL / bare metal, then benchmarks the REAL (cgroup-limited)
configuration: CPU, memory, disk, network. Reports to terminal, JSON, Markdown
and optionally a Discord webhook.

Usage: blackhole-vps-bench [MODE] [OPTIONS]

Modes:
  all        detect + info + full benchmark (default)
  detect     virtualization detection only (fast, works offline)
  info       system info only, no benchmark
  bench      benchmark only (detection still shown for context)
  help       show this help

Options:
  --fast           quick profile (smaller test payloads)
  --no-net         skip network tests (no outbound traffic)
  --webhook URL    send report to a Discord webhook (env: BH_WEBHOOK)
  --json PATH      write JSON report to PATH ('-' = stdout)
  --markdown PATH  write Markdown report to PATH ('-' = stdout)
  --output PATH    write plain-text report to PATH
  --disk-dir DIR   directory for disk tests (default: /tmp)
  --no-color       disable ANSI colors
  --version        print version
  -h, help         show help

Environment: BH_WEBHOOK, BH_FAST=1, BH_NO_NET=1, BH_DISK_DIR, BH_NO_COLOR=1

Exit codes: 0 ok | 1 benchmark produced no data | 2 usage error

Examples:
  blackhole-vps-bench
  blackhole-vps-bench detect
  blackhole-vps-bench all --fast --webhook https://discord.com/api/webhooks/xxx/yyy
  blackhole-vps-bench all --json report.json --markdown report.md
USAGE
}

BH_MODE="all"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      all|detect|info|bench) BH_MODE="$1" ;;
      help|-h|--help)        BH_MODE="help" ;;
      --version|-V)          BH_MODE="version" ;;
      --fast)                BH_FAST=1 ;;
      --no-net)              BH_NO_NET=1 ;;
      --no-color)            BH_NO_COLOR=1; C_RST=''; C_B=''; C_DIM=''; C_CYN=''; C_GRN=''; C_YLW=''; C_RED=''; C_MAG='' ;;
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
      *)
        die "unknown argument: $1 (see: $BH_TOOL help)" ;;
    esac
    shift
  done
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
}

main() {
  parse_args "$@"

  case "$BH_MODE" in
    help)    usage; exit 0 ;;
    version) printf '%s v%s\n' "$BH_TOOL" "$BH_VERSION"; exit 0 ;;
  esac

  log "mode=$BH_MODE fast=$BH_FAST no_net=$BH_NO_NET"
  detect_virt

  if [ "$BH_MODE" = "detect" ]; then
    # detection must work fully offline
    local saved_net="$BH_NO_NET"
    BH_NO_NET=1
    gather_info
    BH_NO_NET="$saved_net"
    BH_BENCH_SKIPPED=1
  else
    gather_info
    if [ "$BH_MODE" = "info" ]; then
      BH_BENCH_SKIPPED=1
    else
      bench_cpu
      bench_mem
      bench_disk
      bench_net
      compute_scores
    fi
  fi

  build_report
  print_report
  write_outputs
  discord_send

  if [ "${BH_BENCH_SKIPPED:-0}" != "1" ] && [ "$BH_SCORE_TOTAL" -eq 0 ]; then
    warn "benchmark produced no usable data"
    exit 1
  fi
  exit 0
}
