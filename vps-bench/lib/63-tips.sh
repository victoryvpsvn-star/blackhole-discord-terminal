# =====================================================================
# blackhole-vps-bench · 63-tips.sh — data-driven "top tips" engine (v5)
# =====================================================================
# Reads the module globals and produces actionable fix hints. Pure logic:
# no forks besides awk float compares, no side effects at source time —
# 70-report.sh calls bh_tips_engine() right before rendering section [T].
#
# Output contract:
#   BH_TIPS — newline-separated records "sev|title|fix"
#             sev  in bad|warn|info, at most 8 records, severity-sorted
#             (bad first, then warn, then info; rule order within a tier).
# 70-report.sh renders the top 3 into the human report and pushes the full
# list into the "tips" JSON array.
# Every module global is ${BH_X:-} guarded: the engine must never crash the
# tool under `set -u` when an optional module did not run.
# shellcheck shell=bash

bh_tips_engine() {
  BH_TIPS=""
  local _NL=$'\n'
  local _bad="" _warn="" _info=""

  _tip_add() { # TIER RECORD — append one "sev|title|fix" record to its tier
    case "$1" in
      bad)  _bad="${_bad}${_bad:+$_NL}$2" ;;
      warn) _warn="${_warn}${_warn:+$_NL}$2" ;;
      *)    _info="${_info}${_info:+$_NL}$2" ;;
    esac
  }

  # ---- [bad] SSH password auth enabled (80-ssh) ----
  if [ "${BH_SSH_PWDAUTH:-}" = "yes" ]; then
    _tip_add bad "bad|SSH password auth enabled|PasswordAuthentication no in /etc/ssh/sshd_config then systemctl reload sshd"
  fi

  # ---- [bad] sshd config fails syntax check (80-ssh; marker set by C10) ----
  case "${BH_SSHD_CFG_VALID:-}" in
    *INVALID*)
      _tip_add bad "bad|sshd config fails syntax check|run sshd -t and fix before restarting SSH" ;;
  esac

  # ---- [bad] advertised RAM below live spec (12-cloud spec-check) ----
  case "${BH_SPEC_SUMMARY:-}" in
    *ram=warn*|*ram=bad*)
      _tip_add bad "bad|RAM below advertised spec (provider oversell)|verify with free -m; escalate to provider with this report" ;;
  esac

  # ---- [warn] TRIM never runs on SSD (55-storage-map) ----
  case "${BH_FSTRIM_TXT:-}" in
    *"never runs"*)
      _tip_add warn "warn|TRIM never runs on SSD|systemctl enable --now fstrim.timer" ;;
  esac

  # ---- [warn] cgroup CPU throttling above 5% (30-cpu / 35-bench-extra) ----
  case "${BH_THROTTLE_PCT:-}" in
    ''|*[!0-9.]*) : ;;
    *)
      if awk -v t="${BH_THROTTLE_PCT:-}" 'BEGIN{exit !(t+0>5)}' 2>/dev/null; then
        _tip_add warn "warn|cgroup CPU throttling active (${BH_THROTTLE_PCT:-}%)|upgrade plan or reduce load"
      fi ;;
  esac

  # ---- [warn] memory pressure events (PSI avg10 > 10) ----
  case "${BH_PSI_TXT:-}" in
    *"memory s="*)
      local _psiv
      _psiv="$(awk -v t="${BH_PSI_TXT:-}" 'BEGIN{
        if (match(t, /memory s=[0-9.]+/)) print substr(t, RSTART + 9, RLENGTH - 9)
      }' 2>/dev/null)"
      case "$_psiv" in
        ''|*[!0-9.]*) : ;;
        *)
          if awk -v v="$_psiv" 'BEGIN{exit !(v+0>10)}' 2>/dev/null; then
            _tip_add warn "warn|memory pressure events|check for leaks/add swap"
          fi ;;
      esac ;;
  esac

  # ---- [warn] clock drift > 5s (60-net) ----
  if [ "${BH_CLOCK_SKEW_BAD:-}" = "1" ]; then
    _tip_add warn "warn|clock drift >5s|timedatectl set-ntp true (breaks TLS/cron)"
  fi

  # ---- [warn] DNS resolver hijack / suspect (60-net) ----
  case "${BH_DNS_HIJACK:-}" in
    *hijack*|*spoof*)
      _tip_add warn "warn|DNS resolver hijack/suspect|set known-good resolvers in /etc/resolv.conf" ;;
  esac

  # ---- [warn] sshd effective config differs from the on-disk file (80-ssh) ----
  case "${BH_SSH_EFF_DECL:-}" in
    *override*)
      _tip_add warn "warn|sshd effective config differs from file|check Match blocks + sshd_config.d drop-ins" ;;
  esac

  # ---- [info] no swap on a small-RAM box (20-info v4 globals) ----
  case "${BH_MEM_SWAP_MB:-}" in
    0)
      case "${BH_MEM_TOTAL_MB:-}" in
        ''|*[!0-9]*) : ;;
        *)
          if [ "${BH_MEM_TOTAL_MB:-0}" -lt 2048 ] 2>/dev/null; then
            _tip_add info "info|no swap on small-RAM box|fallocate -l 1G /swapfile && mkswap /swapfile && swapon /swapfile"
          fi ;;
      esac ;;
  esac

  # ---- [info] traffic exits via a proxy/tunnel (60-net) ----
  if [ -n "${BH_EGRESS_PROXY:-}" ]; then
    _tip_add info "info|traffic exits via proxy/tunnel|bench numbers reflect the proxy path"
  fi

  # ---- [info] running inside a Kubernetes pod (25-env) ----
  if [ -n "${BH_K8S_CTX:-}" ]; then
    _tip_add info "info|running in k8s pod ${BH_K8S_CTX:-}|VPS-grade benchmarks need dedicated VM"
  fi

  # ---- [info] rootless container (25-env uid map) ----
  case "${BH_UIDMAP_MODE:-}" in
    *rootless*)
      _tip_add info "info|container root is mapped (no real host root)|understand capability limits" ;;
  esac

  # ---- assemble severity-sorted, capped at 8 records ----
  local _all="${_bad}"
  [ -n "$_warn" ] && _all="${_all:+$_all$_NL}$_warn"
  [ -n "$_info" ] && _all="${_all:+$_all$_NL}$_info"
  BH_TIPS="$(printf '%s\n' "$_all" | awk 'NF { if (++_n <= 8) print }' 2>/dev/null)"
  return 0
}
