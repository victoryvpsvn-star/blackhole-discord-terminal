# =====================================================================
# blackhole-vps-bench · 70-report.sh — scoring + human/JSON/Markdown/Discord output
# =====================================================================
# shellcheck shell=bash

BH_SCORE_CPU1C=0; BH_SCORE_CPUMC=0; BH_SCORE_MEM=0; BH_SCORE_DSEQ=0
BH_SCORE_D4K=0; BH_SCORE_NDOWN=0; BH_SCORE_NUP=0; BH_SCORE_TOTAL=0
BH_SCORE_MAX=700

num_or_0() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf '0'; fi; }

cap100() { awk -v v="$1" 'BEGIN{ if (v+0<=0) print 0; else if (v>100) print 100; else printf "%.0f", v }'; }

BH_GRADE=""   # S/A/B/C/D/F letter from the total/max ratio ("" = no usable data)

# ---- tier labels (pure awk, no side effects; "" for empty/zero input) ----
tier_cpu1c()    { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print ""; else if (v<500) print "budget-tier"; else if (v<1500) print "standard"; else if (v<3500) print "high-perf"; else print "server-grade" }'; }
tier_mem_gbs()  { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print ""; else if (v<2) print "low"; else if (v<8) print "standard"; else if (v<20) print "high"; else print "server-grade" }'; }
tier_disk_seq() { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print ""; else if (v<80) print "HDD-class"; else if (v<250) print "SATA-SSD-class"; else if (v<1200) print "entry-NVMe"; else print "premium-NVMe" }'; }
tier_iops()     { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print ""; else if (v<500) print "very-slow"; else if (v<3000) print "cloud-standard"; else if (v<20000) print "fast-SSD"; else print "NVMe-class" }'; }
tier_net()      { awk -v v="$1" 'BEGIN{ if (v=="" || v+0<=0) print ""; else if (v<10) print "slow"; else if (v<100) print "standard"; else if (v<500) print "fast"; else if (v<1000) print "gigabit-class"; else print "10G-class" }'; }

# grade_letter TOTAL MAX — S >=90% | A >=75% | B >=60% | C >=45% | D >=30% | F below.
# Prints "" when there is no measurable result (empty/0 total or max).
grade_letter() {
  awk -v t="$(num_or_0 "$1")" -v m="$(num_or_0 "$2")" 'BEGIN{
    if (t+0 <= 0 || m+0 <= 0) { print ""; exit }
    r = t / m
    if      (r >= 0.9)  print "S"
    else if (r >= 0.75) print "A"
    else if (r >= 0.6)  print "B"
    else if (r >= 0.45) print "C"
    else if (r >= 0.3)  print "D"
    else                print "F"
  }'
}

compute_scores() {
  BH_SCORE_CPU1C="$(cap100 "$(awk -v v="$(num_or_0 "$BH_SHA1C")" 'BEGIN{print v/5}')")"
  BH_SCORE_CPUMC="$(cap100 "$(awk -v v="$(num_or_0 "$BH_SHANC")" 'BEGIN{print v/20}')")"
  BH_SCORE_MEM="$(cap100 "$(awk -v v="$(num_or_0 "$BH_MEM_GBS")" 'BEGIN{print v*8}')")"
  BH_SCORE_DSEQ="$(cap100 "$(awk -v v="$(num_or_0 "$BH_SEQW")" 'BEGIN{print v/10}')")"
  BH_SCORE_D4K="$(cap100 "$(awk -v w="$(num_or_0 "$BH_4KW")" -v r="$(num_or_0 "$BH_4KR")" 'BEGIN{print (w+r)/4}')")"
  BH_SCORE_NDOWN="$(cap100 "$(awk -v v="$(num_or_0 "$BH_DOWN_MBPS")" 'BEGIN{print v/20}')")"
  BH_SCORE_NUP="$(cap100 "$(awk -v v="$(num_or_0 "$BH_UP_MBPS")" 'BEGIN{print v/20}')")"
  BH_SCORE_TOTAL="$(( BH_SCORE_CPU1C + BH_SCORE_CPUMC + BH_SCORE_MEM + BH_SCORE_DSEQ + BH_SCORE_D4K + BH_SCORE_NDOWN + BH_SCORE_NUP ))"
  BH_GRADE="$(grade_letter "$BH_SCORE_TOTAL" "$BH_SCORE_MAX")"
}

verdict_text() {
  case "$BH_KIND" in
    container)
      local v="Container ($BH_PRODUCT)"
      [ -n "$BH_HOST_PRODUCT" ] && v="$v on host: $BH_HOST_PRODUCT"
      printf '%s' "$v"
      ;;
    vm)        printf 'Virtual machine — %s' "$BH_PRODUCT" ;;
    bare-metal) printf 'Dedicated / bare metal server' ;;
    *)         printf 'Unknown environment' ;;
  esac
}

# ---------------------------------------------------------------- human report
bh_lines=()
rpt() { bh_lines+=("$1"); }

# print lines with ANSI colors on a TTY (files always get the plain body):
# section headers bold+cyan, [OK] green, [WARN] yellow, [BAD] red.
print_line_color() {
  local l="$1"
  if [ -z "$C_CYN" ]; then printf '%s\n' "$l"; return; fi
  case "$l" in
    \[[0-9]\]\ *)  printf '%s%s%s\n' "$C_B$C_CYN" "$l" "$C_RST" ;;
    "  [OK]"*)     printf '%s%s%s\n' "$C_GRN" "$l" "$C_RST" ;;
    "  [WARN]"*)   printf '%s%s%s\n' "$C_YLW" "$l" "$C_RST" ;;
    "  [BAD]"*)    printf '%s%s%s\n' "$C_RED" "$l" "$C_RST" ;;
    "  [POST]"*)   printf '%s%s%s\n' "$C_B$C_MAG" "$l" "$C_RST" ;;
    *)             printf '%s\n' "$l" ;;
  esac
}

print_evidence() {
  if [ -n "$BH_EVIDENCE" ]; then
    while IFS= read -r ev; do
      rpt "  $ev"
    done <<< "$BH_EVIDENCE"
  else
    rpt "  (no evidence collected)"
  fi
}

# ---- v3 deep-scan report lines (shared by the text and Markdown reports) ----
# The [5] audit body comes from 80-ssh/85-hardening via BH_SEC_LINES; these
# helpers add lines derived from the deep-scan globals while skipping any topic
# the audit itself already reported (first reporter wins — no duplicates).
BH_SEC_EXTRA_LINES=()

sec_extra() { # STATUS TEXT — record one extra [5] line (same format as sec_line)
  local st="$1" txt="$2" tag
  case "$st" in
    ok)   tag="[OK]" ;;
    warn) tag="[WARN]" ;;
    bad)  tag="[BAD]" ;;
    *)    tag="[INFO]" ;;
  esac
  BH_SEC_EXTRA_LINES+=("  $tag  $txt")
}

sec_extra_unless() { # TOPIC STATUS TEXT — skip when BH_SEC_LINES already covers TOPIC (regex)
  local topic="$1"
  if [ "${#BH_SEC_LINES[@]}" -gt 0 ] 2>/dev/null &&
     printf '%s\n' "${BH_SEC_LINES[@]}" | grep -qiE -- "$topic"; then
    return 0
  fi
  sec_extra "$2" "$3"
}

# sec_report_extras — build BH_SEC_EXTRA_LINES from the v3 deep-scan globals.
# Every access is ${VAR:-} guarded so the report still works when an optional
# module (detect extras, hardening scan) did not run or is mid-upgrade.
sec_report_extras() {
  BH_SEC_EXTRA_LINES=()

  # ---- system hardening scan (85-hardening) ----
  if [ -n "${BH_MAC:-}" ]; then
    case "$BH_MAC" in
      *enforcing*|*Enforcing*|*apparmor*|*AppArmor*|*enabled*|*Enabled*|*active*|*Active*)
        sec_extra_unless "MAC:" ok "MAC: $BH_MAC" ;;
      *) sec_extra_unless "MAC:" info "MAC: $BH_MAC" ;;
    esac
  fi
  if [ -n "${BH_UPDATES:-}" ] && [ "$BH_UPDATES" != "n/a" ]; then
    # 85-hardening phrases this as "N package updates pending" / "all packages
    # up to date" — only fall back to our own line when it did not report
    sec_extra_unless 'package updates pending|all packages up to date|pending updates' \
      info "Pending updates: $BH_UPDATES${BH_UPDATES_N:+ (count $BH_UPDATES_N)}"
  fi
  [ -n "${BH_RISKY_PORTS:-}" ] && sec_extra_unless "exposed" warn "Exposed services: $BH_RISKY_PORTS"
  case "${BH_MINERS:-}" in
    ''|0) : ;;
    *)    sec_extra_unless "Miner" bad "Miner processes: ${BH_MINERS}${BH_MINER_NAMES:+ — ${BH_MINER_NAMES}}" ;;
  esac
  case "${BH_DOCKER_SOCK:-}" in
    ''|absent) : ;;
    *writable*|*accessible*|*"mode 777"*|*"mode 775"*|*"mode 666"*|unknown)
      sec_extra_unless "docker.sock" warn "docker.sock: $BH_DOCKER_SOCK — container-escape surface" ;;
    *)                       sec_extra_unless "docker.sock" info "docker.sock: $BH_DOCKER_SOCK" ;;
  esac
  if [ -n "${BH_SYSCTL_KPTR:-}${BH_SYSCTL_DMESG:-}${BH_SYSCTL_BPF:-}${BH_SYSCTL_YAMA:-}" ]; then
    sec_extra_unless 'kptr_restrict|dmesg_restrict|unprivileged_bpf|ptrace_scope|kernel sysctls' \
      info "Kernel: kptr=${BH_SYSCTL_KPTR:-?} dmesg=${BH_SYSCTL_DMESG:-?} bpf=${BH_SYSCTL_BPF:-?} yama=${BH_SYSCTL_YAMA:-?}"
  fi
  [ -n "${BH_TMP_OPTS:-}" ] && sec_extra_unless "/tmp" info "/tmp mount: $BH_TMP_OPTS"
  [ "${BH_TIMERS_N:-0}" -gt 0 ] 2>/dev/null && sec_extra_unless "systemd timers" info "systemd timers: $BH_TIMERS_N"
  [ "${BH_CRON_N:-0}" -gt 0 ] 2>/dev/null   && sec_extra_unless "cron" info "cron files: $BH_CRON_N"

  # ---- deep SSH audit (80-ssh globals; skipped when already reported) ----
  [ -n "${BH_SSH_VERSION:-}" ] && sec_extra_unless "OpenSSH version" info "OpenSSH version: $BH_SSH_VERSION"
  case "${BH_SSH_RUNNING:-}" in
    1) sec_extra_unless "sshd process" info "sshd process: running${BH_SSH_LISTENING:+, listening on: $BH_SSH_LISTENING}" ;;
    0) : ;;
    *) sec_extra_unless "sshd process" info "sshd process: ${BH_SSH_RUNNING}${BH_SSH_LISTENING:+ (listening: $BH_SSH_LISTENING)}" ;;
  esac
  case "${BH_SSH_PERMPTY:-}" in
    yes) sec_extra_unless "PermitEmptyPasswords" bad "PermitEmptyPasswords: yes — accounts with empty passwords could log in" ;;
    no)  sec_extra_unless "PermitEmptyPasswords" ok  "PermitEmptyPasswords: no" ;;
  esac
  case "${BH_SSH_LOGINGRACE:-}" in
    ''|*[!0-9]*) : ;;
    *) [ "$BH_SSH_LOGINGRACE" -gt 120 ] 2>/dev/null &&
       sec_extra_unless "LoginGraceTime" warn "LoginGraceTime: ${BH_SSH_LOGINGRACE}s — long pre-auth window (default 120s)" ;;
  esac
  [ "${BH_SSH_X11:-}" = "yes" ] && sec_extra_unless "X11Forwarding" warn "X11Forwarding: yes — extra attack surface; disable unless needed"
  [ -n "${BH_SSH_ALLOWUSERS:-}" ] && sec_extra_unless "AllowUsers" ok "SSH access restricted to: $BH_SSH_ALLOWUSERS"
  case "${BH_AK_PERM_BAD:-0}" in
    ''|0) : ;;
    *)    sec_extra_unless "StrictModes" warn "authorized_keys permissions: $BH_AK_PERM_BAD path(s) too open — sshd StrictModes would refuse auth" ;;
  esac
  [ "${BH_F2B_ACTIVE:-0}" = "1" ] && sec_extra_unless "fail2ban" ok "fail2ban: active with sshd jail"
  [ "${BH_SSHGUARD:-0}" = "1" ]  && sec_extra_unless "sshguard"  ok "sshguard: present (brute-force protection)"
  [ "${BH_CROWDSEC:-0}" = "1" ]  && sec_extra_unless "crowdsec"  ok "crowdsec: present (collaborative brute-force protection)"
  return 0
}

# =========================================================== v4.0 (W3-O) ====
# render helpers — PURE RENDER LOGIC: they read the module globals and compose
# output; they never recompute or mutate benchmark data (except bh_redact_sink,
# which masks identity globals in place when BH_REDACT=1).

# bh_redact_sink — privacy pass: mask identity-bearing globals BEFORE any sink
# (text / markdown / json / discord / prom) renders them. Called at the top of
# every emitter; idempotent, so chained emitters cannot double-mask.
#   BH_IPV4 -> "<redacted-ip>"   BH_IPV6 -> "<redacted-ip6>"
#   BH_IP_GEO keeps the country token only
#   AllowUsers/AllowGroups usernames -> "(N users)" (count, never the names)
# The already-rendered audit lines (BH_SEC_LINES) are rewritten here too so
# usernames cannot leak through the [5] section of any sink.
bh_redact_sink() {
  [ "${BH_REDACT:-0}" = "1" ] || return 0
  # NAT strings embed the egress IP — scrub before masking the sources
  if [ -n "${BH_NAT_MODE:-}" ] && [ -n "${BH_IPV4:-}" ]; then
    BH_NAT_MODE="${BH_NAT_MODE//$BH_IPV4/<redacted-ip>}"
  fi
  if [ -n "${BH_NAT_SRC:-}" ]; then
    case "$BH_NAT_SRC" in *.*) BH_NAT_SRC="<redacted-ip>" ;; esac
  fi
  [ -n "${BH_IPV4:-}" ] && BH_IPV4="<redacted-ip>"
  [ -n "${BH_IPV6:-}" ] && BH_IPV6="<redacted-ip6>"
  # geo: keep the country only ("US / Ashburn (colo IAD)" -> "US")
  if [ -n "${BH_IP_GEO:-}" ]; then
    case "$BH_IP_GEO" in
      *redacted*) : ;;
      *)
        case "$BH_IP_GEO" in *" "*) BH_IP_GEO="${BH_IP_GEO%% *}" ;; esac
        case "$BH_IP_GEO" in */*)     BH_IP_GEO="${BH_IP_GEO%%/*}"   ;; esac
        ;;
    esac
  fi
  # AllowUsers/AllowGroups -> count only (tr-based count: no glob side effects)
  # Idempotency guard: when the value is already "(N users)" leave it alone,
  # otherwise chained emitters would shrink the count on every pass.
  if [ -n "${BH_SSH_ALLOWUSERS:-}" ]; then
    case "$BH_SSH_ALLOWUSERS" in
      "("*" users)") : ;;
      *)
        local _aun _ali
        # shellcheck disable=SC2020  # both ',' and ' ' map to newline on purpose
        _aun="$(printf '%s\n' "$BH_SSH_ALLOWUSERS" | tr ', ' '\n\n' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
        case "$_aun" in ''|*[!0-9]*) _aun=0 ;; esac
        BH_SSH_ALLOWUSERS="($_aun users)"
        if [ "${#BH_SEC_LINES[@]}" -gt 0 ] 2>/dev/null; then
          for _ali in "${!BH_SEC_LINES[@]}"; do
            case "${BH_SEC_LINES[$_ali]}" in
              *"SSH access restricted to"*)
                BH_SEC_LINES[_ali]="  [OK]  SSH access restricted to: ($_aun users) (AllowUsers/AllowGroups)" ;;
            esac
          done
        fi
        ;;
    esac
  fi
  # ---- v5 redaction (C14): container/runtime + net identity + hardware ----
  # Idempotency: every branch skips values already carrying a mask marker
  # ("redacted" / trailing ellipsis), so chained emitters cannot double-mask.
  if [ -n "${BH_RT_CTR_ID:-}" ]; then
    case "$BH_RT_CTR_ID" in
      *"…"*) : ;;
      *)     BH_RT_CTR_ID="${BH_RT_CTR_ID:0:8}…" ;;   # 8-char prefix + ellipsis
    esac
  fi
  if [ -n "${BH_POD_UID:-}" ]; then
    case "$BH_POD_UID" in
      *"…"*) : ;;
      *)     BH_POD_UID="${BH_POD_UID:0:8}…" ;;
    esac
  fi
  if [ -n "${BH_PTR_HOST:-}" ]; then
    case "$BH_PTR_HOST" in
      *redacted*) : ;;
      *)
        if [ -n "${BH_PTR_CLASS:-}" ]; then
          BH_PTR_HOST="${BH_PTR_CLASS} (host redacted)"   # keep class only
        else
          BH_PTR_HOST="<redacted-ptr>"
        fi ;;
    esac
  fi
  if [ -n "${BH_K8S_CTX:-}" ]; then
    case "$BH_K8S_CTX" in
      *redacted*) : ;;
      */*)        BH_K8S_CTX="${BH_K8S_CTX%%/*}/<redacted-domain>" ;;  # ns ok, domain masked
      *.*)        BH_K8S_CTX="<redacted-domain>" ;;
    esac
  fi
  if [ -n "${BH_DIMM_TXT:-}" ]; then
    # DIMM text is already serial-free in v5; scrub defensively anyway
    case "$BH_DIMM_TXT" in
      *redacted*) : ;;
      *) BH_DIMM_TXT="$(printf '%s' "$BH_DIMM_TXT" | sed 's/[Ss][Nn][:=][A-Za-z0-9_-]\{4,\}/SN=<redacted>/g')" ;;
    esac
  fi
  if [ -n "${BH_CLOUD_META2:-}" ]; then
    case "$BH_CLOUD_META2" in
      *redacted*) : ;;
      *) BH_CLOUD_META2="$(printf '%s' "$BH_CLOUD_META2" \
           | sed -e 's/i-[0-9a-fA-F]\{8,\}/<redacted-id>/g' -e 's/[0-9a-fA-F]\{16,\}/<redacted-id>/g')" ;;
    esac
  fi
  return 0
}

# bh_oversell_verdict — wow#1: oversold-VPS detector (pure render logic).
# Evidence: steal-under-load > 5% (strong), idle steal > 5% (strong),
# KSM pages_sharing > 0 (medium), live disk busy% > 85 (medium).
# BH_OVERSELL = "LIKELY (...)" | "POSSIBLE (...)" | "no evidence".
bh_oversell_verdict() {
  local strong=0 medium=0 parts=""
  case "${BH_STEAL_UNDER_LOAD:-}" in
    ''|*[!0-9.]*) : ;;
    *) if awk -v s="$BH_STEAL_UNDER_LOAD" 'BEGIN{exit !(s+0>5)}' 2>/dev/null; then
         strong=1; parts="steal ${BH_STEAL_UNDER_LOAD}% under load"
       fi ;;
  esac
  case "${BH_STEAL_PCT:-}" in
    ''|*[!0-9.]*) : ;;
    *) if awk -v s="$BH_STEAL_PCT" 'BEGIN{exit !(s+0>5)}' 2>/dev/null; then
         strong=1; parts="${parts:+$parts + }steal ${BH_STEAL_PCT}% idle"
       fi ;;
  esac
  case "${BH_KSM_SHARING:-}" in
    ''|*[!0-9]*) : ;;
    *) if [ "$BH_KSM_SHARING" -gt 0 ] 2>/dev/null; then
         medium=1; parts="${parts:+$parts + }KSM sharing ${BH_KSM_SHARING} pages"
       fi ;;
  esac
  case "${BH_LIVE_BUSY_PCT:-}" in
    ''|*[!0-9.]*) : ;;
    *) if awk -v b="$BH_LIVE_BUSY_PCT" 'BEGIN{exit !(b+0>85)}' 2>/dev/null; then
         medium=1; parts="${parts:+$parts + }disk busy ${BH_LIVE_BUSY_PCT}% during bench"
       fi ;;
  esac
  if [ "$strong" = "1" ]; then
    BH_OVERSELL="LIKELY (${parts:-multiple signals})"
  elif [ "$medium" = "1" ]; then
    BH_OVERSELL="POSSIBLE (${parts})"
  else
    BH_OVERSELL="no evidence"
  fi
  return 0
}

# bh_share_card — wow#9: one compact shareable line built from existing
# globals only; empty parts are omitted. Result lands in BH_SHARE_CARD:
#   "cloud · kind/type · Nc/NG · disk class · down/up Mbps · grade (total/max)"
bh_share_card() {
  BH_SHARE_CARD=""
  local p="" g=""
  [ -n "${BH_CLOUD:-}" ]   && p="$BH_CLOUD"
  [ -n "${BH_GEO_LOC:-}" ] && p="${p:+$p }$BH_GEO_LOC"
  [ -n "$p" ] && BH_SHARE_CARD="$p"
  case "${BH_KIND:-}" in
    ""|unknown) : ;;
    *) BH_SHARE_CARD="${BH_SHARE_CARD:+$BH_SHARE_CARD · }$BH_KIND/${BH_TYPE:-?}" ;;
  esac
  case "${BH_MEM_TOTAL_MB:-0}" in
    ''|*[!0-9]*) : ;;
    *) [ "$BH_MEM_TOTAL_MB" -gt 0 ] 2>/dev/null && g="$(awk -v m="$BH_MEM_TOTAL_MB" 'BEGIN{printf "%.0fG", m/1024}')" ;;
  esac
  [ -n "$g" ] && BH_SHARE_CARD="${BH_SHARE_CARD:+$BH_SHARE_CARD · }${BH_EFF_CORES:-?}c/$g"
  p="$(tier_disk_seq "${BH_SEQW:-}")"
  [ -n "$p" ] && BH_SHARE_CARD="${BH_SHARE_CARD:+$BH_SHARE_CARD · }$p"
  if [ -n "${BH_DOWN_MBPS:-}" ] && [ -n "${BH_UP_MBPS:-}" ]; then
    BH_SHARE_CARD="${BH_SHARE_CARD:+$BH_SHARE_CARD · }$BH_DOWN_MBPS/$BH_UP_MBPS Mbps"
  fi
  [ -n "${BH_GRADE:-}" ] && BH_SHARE_CARD="${BH_SHARE_CARD:+$BH_SHARE_CARD · }$BH_GRADE ($BH_SCORE_TOTAL/$BH_SCORE_MAX)"
  return 0
}

# bh_compute_verdicts — render-time derivations shared by every sink.
bh_compute_verdicts() { bh_oversell_verdict; bh_share_card; return 0; }

# ======================================================= v5.0 (C14) =========
# v5 render helpers — same contract as the v4 block above: pure render logic,
# every module global ${BH_X:-} guarded, every new global referenced with a
# default so the tool never crashes under `set -u` when an optional module
# did not run. Private helpers carry the bhv5c14_ prefix; the two public
# entry points (bh_fingerprint / bh_fp_sanitize) are consumed by selftest.
BH_ORCH=""   # runtime orchestrator (assigned at runtime by 25-env; default for lint/set -u)

# bh_fp_sanitize TOKEN — fingerprint token sanitizer (PURE, stdout only):
# lowercase, map anything outside [A-Za-z0-9._-] to '_', collapse '//' runs,
# return EMPTY for empty/private/identity-looking tokens (selftest-covered).
bh_fp_sanitize() {
  local s="${1:-}"
  [ -n "$s" ] || return 0
  case "$s" in
    *redacted*|*private*|*Private*|*reserved*|*Reserved*|*internal*) return 0 ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.*|169.254.*|fc*|fd*) return 0 ;;
    10-*|192-168-*|127-*) return 0 ;;
  esac
  # collapse '//' runs first (so a slash never survives into the joined tag),
  # then lowercase and map everything outside [A-Za-z0-9._-] to '_'
  s="$(printf '%s' "$s" | sed 's;//*;/;g' | tr '[:upper:]' '[:lower:]' | tr -c 'A-Za-z0-9._-' '_')"
  case "$s" in
    *[!._-]*) printf '%s' "$s" ;;
    *) : ;;
  esac
  return 0
}

# bh_fingerprint — machine-tag one-liner into BH_FINGERPRINT (no "tag: " prefix;
# build_report renders "  tag: $BH_FINGERPRINT" and build_json the "fingerprint" key):
#   "kvm/aws/t3.medium/ubuntu-22.04/2c4g/500mbps/s612"
# Empty/private tokens are skipped (no empty "//" slots).
bh_fingerprint() {
  BH_FINGERPRINT=""
  local tok out="" _g
  tok="$(bh_fp_sanitize "${BH_TYPE:-}")"
  [ -n "$tok" ] || tok="$(bh_fp_sanitize "${BH_KIND:-}")"
  [ -n "$tok" ] && out="$tok"
  tok="$(bh_fp_sanitize "${BH_CLOUD:-}")"
  [ -n "$tok" ] && out="${out:+$out/}$tok"
  tok="$(bh_fp_sanitize "${BH_CLOUD_DETAIL:-}")"
  [ -n "$tok" ] && out="${out:+$out/}$tok"
  tok="$(bh_fp_sanitize "${BH_OS:-}")"
  [ -n "$tok" ] && out="${out:+$out/}$tok"
  if [ -n "${BH_EFF_CORES:-}" ] && [ "${BH_EFF_CORES:-0}" -ge 1 ] 2>/dev/null &&
     [ -n "${BH_MEM_TOTAL_MB:-}" ] && [ "${BH_MEM_TOTAL_MB:-0}" -gt 0 ] 2>/dev/null; then
    _g="$(awk -v m="${BH_MEM_TOTAL_MB:-0}" 'BEGIN{printf "%.0f", m/1024}')"
    out="${out:+$out/}${BH_EFF_CORES:-?}c${_g}g"
  fi
  case "${BH_DOWN_MBPS:-}" in
    ''|*[!0-9.]*) : ;;
    *) out="${out:+$out/}$(awk -v d="${BH_DOWN_MBPS:-}" 'BEGIN{printf "%.0fmbps", d+0}')" ;;
  esac
  case "${BH_SCORE_TOTAL:-0}" in
    ''|0|*[!0-9]*) : ;;
    *) out="${out:+$out/}s${BH_SCORE_TOTAL:-0}" ;;
  esac
  BH_FINGERPRINT="$out"
  return 0
}

# bhv5c14_truth_strip — machine-greppable honesty strip built from the v4
# globals (steal-under-load / efficiency / live busy / net tries-loss) plus
# the new v5 signals (cgroup throttling, KSM, PSI):
#   "truth: cpu=ok mem=ok disk=warn net=ok"   (values: ok|warn|bad)
bhv5c14_truth_strip() {
  local cpu="ok" mem="ok" disk="ok" net="ok" _psiv
  case "${BH_STEAL_UNDER_LOAD:-}" in
    ''|*[!0-9.]*) : ;;
    *) awk -v s="${BH_STEAL_UNDER_LOAD:-}" 'BEGIN{exit !(s+0>5)}' 2>/dev/null && cpu="bad" ;;
  esac
  if [ "$cpu" != "bad" ]; then
    case "${BH_STEAL_PCT:-}" in
      ''|*[!0-9.]*) : ;;
      *) awk -v s="${BH_STEAL_PCT:-}" 'BEGIN{exit !(s+0>5)}' 2>/dev/null && cpu="warn" ;;
    esac
  fi
  if [ "$cpu" != "bad" ]; then
    case "${BH_CPU_EFFICIENCY:-}" in
      ''|*[!0-9.]*) : ;;
      *)
        if awk -v e="${BH_CPU_EFFICIENCY:-}" 'BEGIN{exit !(e+0<50)}' 2>/dev/null; then cpu="bad"
        elif awk -v e="${BH_CPU_EFFICIENCY:-}" 'BEGIN{exit !(e+0<75)}' 2>/dev/null; then cpu="warn"
        fi ;;
    esac
  fi
  if [ "$cpu" != "bad" ] && [ "$cpu" != "warn" ]; then
    case "${BH_THROTTLE_PCT:-}" in
      ''|*[!0-9.]*) : ;;
      *) awk -v t="${BH_THROTTLE_PCT:-}" 'BEGIN{exit !(t+0>5)}' 2>/dev/null && cpu="warn" ;;
    esac
  fi
  case "${BH_KSM_SHARING:-}" in
    ''|*[!0-9]*) : ;;
    *) [ "${BH_KSM_SHARING:-0}" -gt 0 ] 2>/dev/null && mem="warn" ;;
  esac
  if [ "$mem" != "warn" ]; then
    case "${BH_PSI_TXT:-}" in
      *"mem s="*)
        _psiv="$(awk -v t="${BH_PSI_TXT:-}" 'BEGIN{
          if (match(t, /mem s=[0-9.]+/)) print substr(t, RSTART + 6, RLENGTH - 6)
        }' 2>/dev/null)"
        case "$_psiv" in
          ''|*[!0-9.]*) : ;;
          *) awk -v v="$_psiv" 'BEGIN{exit !(v+0>10)}' 2>/dev/null && mem="warn" ;;
        esac ;;
    esac
  fi
  case "${BH_LIVE_BUSY_PCT:-}" in
    ''|*[!0-9.]*) : ;;
    *) awk -v b="${BH_LIVE_BUSY_PCT:-}" 'BEGIN{exit !(b+0>85)}' 2>/dev/null && disk="warn" ;;
  esac
  [ -n "${BH_DISK_WARN:-}" ] && disk="warn"
  case "${BH_NET_TRIES:-}" in
    *:fail*) net="bad" ;;
  esac
  case "${BH_PACKET_LOSS:-}" in
    ""|"0%"|"0.0%"|"n/a (no icmp)") : ;;
    *) net="warn" ;;
  esac
  BH_TRUTH="truth: cpu=$cpu mem=$mem disk=$disk net=$net"
  return 0
}

# bhv5c14_chip_rpt CHIP TEXT — rpt with the house chip padding
# ("  [OK]   t" / "  [WARN] t" / "  [BAD]  t"; empty chip -> plain dim line).
bhv5c14_chip_rpt() {
  case "$1" in
    "[OK]")   rpt "  [OK]   $2" ;;
    "[WARN]") rpt "  [WARN] $2" ;;
    "[BAD]")  rpt "  [BAD]  $2" ;;
    *)        rpt "  $2" ;;
  esac
  return 0
}

# bhv5c14_verdict_chip VALUE — [OK]/[WARN]/[BAD] for ok/warn/bad, "" otherwise.
bhv5c14_verdict_chip() {
  case "$1" in
    ok)   printf '[OK]' ;;
    warn) printf '[WARN]' ;;
    bad)  printf '[BAD]' ;;
  esac
  return 0
}

# ---- [1] virt extras — accel / VMM tells / DMI spoof / Xen / ACPI OEM -------
bhv5c14_render_virt_extras() {
  case "${BH_QEMU_ACCEL:-}" in
    "") : ;;
    *tcg*|*TCG*) rpt "  [WARN] accel: ${BH_QEMU_ACCEL:-} (EMULATED — benchmarks meaningless)" ;;
    *)           rpt "  Accel   : ${BH_QEMU_ACCEL:-}" ;;
  esac
  [ -n "${BH_VMM_TELLS:-}" ] && rpt "  VMMtells: ${BH_VMM_TELLS:-}"
  [ "${BH_DMI_SPOOF:-0}" = "1" ] && rpt "  [WARN] DMI contradicts hypervisor evidence — custom/spoofed DMI"
  [ -n "${BH_XEN_VER:-}" ]  && rpt "  Xen     : ${BH_XEN_VER:-}"
  [ -n "${BH_ACPI_OEM:-}" ] && rpt "  ACPI OEM: ${BH_ACPI_OEM:-}"
  return 0
}

# ---- cloud-init / meta2 / hints / spec lie-check (rendered inside [1]) ------
bhv5c14_render_cloud_extras() {
  if [ -n "${BH_CI_CLOUD:-}" ]; then
    rpt "  cloud-init: ${BH_CI_CLOUD:-}${BH_CI_REGION:+ ${BH_CI_REGION:-}}${BH_CI_AZ:+ ${BH_CI_AZ:-}}"
  fi
  [ -n "${BH_CLOUD_META2:-}" ] && rpt "  meta2   : ${BH_CLOUD_META2:-}"
  local _hints=""
  [ -n "${BH_RESOLV_HINT:-}" ]    && _hints="resolv: ${BH_RESOLV_HINT:-}"
  [ -n "${BH_NTP_HINT:-}" ]       && _hints="${_hints:+$_hints · }ntp: ${BH_NTP_HINT:-}"
  [ -n "${BH_V6_PREFIX_HINT:-}" ] && _hints="${_hints:+$_hints · }v6-prefix: ${BH_V6_PREFIX_HINT:-}"
  [ -n "$_hints" ] && rpt "  Hints   : $_hints"
  if [ -z "${BH_SPEC_SUMMARY:-}" ] && [ -z "${BH_SPEC_CPU_V:-}" ] &&
     [ -z "${BH_SPEC_RAM_V:-}" ] && [ -z "${BH_SPEC_BURST:-}" ]; then
    return 0
  fi
  local _chip _skip=0
  case "${BH_SPEC_SUMMARY:-}" in
    "") : ;;
    *no-plan*) rpt "  plan    : no-plan (provider advertises no specs — nothing to verify)"; _skip=1 ;;
    *)         rpt "  plan    : ${BH_SPEC_SUMMARY:-}" ;;
  esac
  [ "$_skip" = "1" ] && return 0
  if [ -n "${BH_SPEC_CPU_V:-}" ]; then
    _chip="$(bhv5c14_verdict_chip "${BH_SPEC_CPU_V%% *}")"
    bhv5c14_chip_rpt "$_chip" "LIE-CHECK cpu: ${BH_SPEC_CPU_V:-}"
  fi
  if [ -n "${BH_SPEC_RAM_V:-}" ]; then
    _chip="$(bhv5c14_verdict_chip "${BH_SPEC_RAM_V%% *}")"
    bhv5c14_chip_rpt "$_chip" "LIE-CHECK ram: ${BH_SPEC_RAM_V:-}"
  fi
  if [ -n "${BH_SPEC_BURST:-}" ]; then
    _chip="$(bhv5c14_verdict_chip "${BH_SPEC_BURST%% *}")"
    bhv5c14_chip_rpt "$_chip" "LIE-CHECK burst: ${BH_SPEC_BURST:-}"
  fi
  return 0
}

# ---- [2] info extras — cache / block queue / NUMA / freq / thermal / DIMM ---
bhv5c14_render_info_extras() {
  [ -n "${BH_CACHE_TXT:-}" ]    && rpt "  Cache   : ${BH_CACHE_TXT:-}"
  [ -n "${BH_BLOCKQ_TXT:-}" ]   && rpt "  BlkQ    : ${BH_BLOCKQ_TXT:-}"
  [ -n "${BH_NUMA_TXT:-}" ]     && rpt "  NUMA    : ${BH_NUMA_TXT:-}${BH_NUMA_OFFLINE:+ (offline: ${BH_NUMA_OFFLINE:-})}"
  [ -n "${BH_CPUFREQ_TXT:-}" ]  && rpt "  CpuFreq : ${BH_CPUFREQ_TXT:-}"
  [ -n "${BH_THERMAL_TXT:-}" ]  && rpt "  Thermal : ${BH_THERMAL_TXT:-}"
  [ -n "${BH_THROTTLE_CNT:-}" ] && rpt "  Throttle: ${BH_THROTTLE_CNT:-}"
  [ -n "${BH_HWERR_TXT:-}" ]    && rpt "  HWErr   : ${BH_HWERR_TXT:-}"
  [ -n "${BH_DIMM_TXT:-}" ]     && rpt "  DIMM    : ${BH_DIMM_TXT:-}"
  return 0
}

# ---- [ENV] container / runtime / pressure -----------------------------------
bhv5c14_render_env_extras() {
  local _any="${BH_UIDMAP_MODE:-}${BH_SECCOMP_MODE:-}${BH_PSI_TXT:-}${BH_RT_NAME:-}${BH_ORCH:-}${BH_RT_CTR_ID:-}${BH_K8S_CTX:-}${BH_SA_TXT:-}${BH_POD_UID:-}${BH_PROJ_VOL:-}${BH_NS_FP:-}"
  [ -n "$_any" ] || return 0
  # open a header only when the v4 [ENV] section did not render
  if [ -z "${BH_CAPS_CLASS:-}${BH_DEV_MAP:-}${BH_PIDS_MAX:-}${BH_PID1_LSM:-}${BH_CG_CONTROLLERS:-}${BH_RL_NOFILE:-}${BH_OOM_ADJ:-}" ]; then
    rpt ""
    rpt "[ENV] container runtime & pressure"
  fi
  [ -n "${BH_UIDMAP_MODE:-}" ]  && rpt "  Uidmap  : ${BH_UIDMAP_MODE:-}"
  [ -n "${BH_SECCOMP_MODE:-}" ] && rpt "  Seccomp : ${BH_SECCOMP_MODE:-}"
  case "${BH_PSI_TXT:-}" in ""|off) : ;; *) rpt "  PSI     : ${BH_PSI_TXT:-}" ;; esac
  if [ -n "${BH_RT_NAME:-}" ] || [ -n "${BH_ORCH:-}" ] || [ -n "${BH_RT_CTR_ID:-}" ]; then
    rpt "  Runtime : ${BH_RT_NAME:-?}${BH_ORCH:+ (${BH_ORCH:-})}${BH_RT_CTR_ID:+ id=${BH_RT_CTR_ID:-}}"
  fi
  [ -n "${BH_K8S_CTX:-}" ]  && rpt "  K8s     : ${BH_K8S_CTX:-}"
  [ -n "${BH_SA_TXT:-}" ]   && rpt "  SvcAcct : ${BH_SA_TXT:-}"
  [ -n "${BH_POD_UID:-}" ]  && rpt "  PodUID  : ${BH_POD_UID:-}"
  [ -n "${BH_PROJ_VOL:-}" ] && rpt "  ProjVol : ${BH_PROJ_VOL:-}"
  [ -n "${BH_NS_FP:-}" ]    && rpt "  NsFp    : ${BH_NS_FP:-}"
  return 0
}

# ---- [STORAGE] queue / mdraid / zfs / btrfs / lvm / smart / trim ------------
bhv5c14_render_storage_extras() {
  local _any="${BH_QUEUE_MATRIX:-}${BH_MDRAID_TXT:-}${BH_ZFS_TXT:-}${BH_BTRFS_TXT:-}${BH_LVM_TXT:-}${BH_SMART_TXT:-}${BH_NVME_TXT:-}${BH_CG_IO_TXT:-}${BH_MOUNT_FLAGS_TXT:-}${BH_INODE_TXT:-}${BH_FSTRIM_TXT:-}"
  [ -n "$_any" ] || return 0
  # open a header only when the v4 [STORAGE] section did not render
  if [ -z "${BH_STORAGE_SUMMARY:-}${BH_ROOT_STACK:-}" ]; then
    rpt ""
    rpt "[STORAGE] extras"
  fi
  [ -n "${BH_QUEUE_MATRIX:-}" ]    && rpt "  Queue   : ${BH_QUEUE_MATRIX:-}"
  [ -n "${BH_MDRAID_TXT:-}" ]      && rpt "  MDRAID  : ${BH_MDRAID_TXT:-}"
  [ -n "${BH_ZFS_TXT:-}" ]         && rpt "  ZFS     : ${BH_ZFS_TXT:-}"
  [ -n "${BH_BTRFS_TXT:-}" ]       && rpt "  BTRFS   : ${BH_BTRFS_TXT:-}"
  [ -n "${BH_LVM_TXT:-}" ]         && rpt "  LVM     : ${BH_LVM_TXT:-}"
  [ -n "${BH_SMART_TXT:-}" ]       && rpt "  SMART   : ${BH_SMART_TXT:-}"
  [ -n "${BH_NVME_TXT:-}" ]        && rpt "  NVMeTxt : ${BH_NVME_TXT:-}"
  [ -n "${BH_CG_IO_TXT:-}" ]       && rpt "  CgIO    : ${BH_CG_IO_TXT:-}"
  [ -n "${BH_MOUNT_FLAGS_TXT:-}" ] && rpt "  MntFlags: ${BH_MOUNT_FLAGS_TXT:-}"
  [ -n "${BH_INODE_TXT:-}" ]       && rpt "  Inodes  : ${BH_INODE_TXT:-}"
  [ -n "${BH_FSTRIM_TXT:-}" ]      && rpt "  Fstrim  : ${BH_FSTRIM_TXT:-}"
  return 0
}

# ---- [4] net extras — skew / egress / PTR / PMTU / DNS / jitter / TLS -------
bhv5c14_render_net_extras() {
  local _any="${BH_CLOCK_SKEW_S:-}${BH_EGRESS_PROXY:-}${BH_PTR_CLASS:-}${BH_PTR_HOST:-}${BH_PMTU:-}${BH_DNS_NS:-}${BH_DNS_HIJACK:-}${BH_TCP_JITTER:-}${BH_CONNTRACK_PCT:-}${BH_SOCKSTAT_TXT:-}${BH_IPV6_MBPS:-}${BH_TLS_MS:-}"
  [ -n "$_any" ] || return 0
  # open a header only when the v4 [4] section did not render
  if [ -z "${BH_GEO_LOC:-}${BH_GEO_CLO:-}${BH_LAT_MATRIX:-}${BH_NAT_MODE:-}${BH_DNS_MS:-}${BH_PACKET_LOSS:-}${BH_IPV4:-}${BH_IPV6:-}${BH_IP_GEO:-}${BH_IP_ASN:-}${BH_IPV6_GRADE:-}" ]; then
    rpt ""
    rpt "[NET] extras"
  fi
  case "${BH_CLOCK_SKEW_S:-}" in
    "") : ;;
    *[!0-9.+-]*) rpt "  Skew    : clock skew: ${BH_CLOCK_SKEW_S:-}" ;;
    *)
      if awk -v s="${BH_CLOCK_SKEW_S:-}" 'BEGIN{ s=(s<0)?-s:s; exit !(s>5) }' 2>/dev/null; then
        rpt "  [WARN] clock skew: ${BH_CLOCK_SKEW_S:-} (>5s)"
      else
        rpt "  Skew    : clock skew: ${BH_CLOCK_SKEW_S:-} [OK]"
      fi ;;
  esac
  [ -n "${BH_EGRESS_PROXY:-}" ]  && rpt "  Egress  : ${BH_EGRESS_PROXY:-}"
  if [ -n "${BH_PTR_CLASS:-}" ] || [ -n "${BH_PTR_HOST:-}" ]; then
    rpt "  PTR     : class ${BH_PTR_CLASS:-?} · host ${BH_PTR_HOST:-?}"
  fi
  [ -n "${BH_PMTU:-}" ]          && rpt "  PMTU    : ${BH_PMTU:-}"
  [ -n "${BH_DNS_NS:-}" ]        && rpt "  DNS NS  : ${BH_DNS_NS:-}"
  case "${BH_DNS_HIJACK:-}" in
    clean)            rpt "  [OK] DNS: clean (NXDOMAIN + known-host checks passed)" ;;
    *hijack*|*spoof*) rpt "  [WARN] DNS: ${BH_DNS_HIJACK:-}" ;;
    ?*)               rpt "  [INFO] DNS: ${BH_DNS_HIJACK:-}" ;;
  esac
  [ -n "${BH_TCP_JITTER:-}" ]    && rpt "  Jitter  : ${BH_TCP_JITTER:-}"
  [ -n "${BH_CONNTRACK_PCT:-}" ] && rpt "  ConnTrk : ${BH_CONNTRACK_PCT:-}"
  [ -n "${BH_SOCKSTAT_TXT:-}" ]  && rpt "  Socks   : ${BH_SOCKSTAT_TXT:-}"
  [ -n "${BH_IPV6_MBPS:-}" ]     && rpt "  IPv6 thr: ${BH_IPV6_MBPS:-}"
  [ -n "${BH_TLS_MS:-}" ]        && rpt "  TLS     : handshake ${BH_TLS_MS:-} ms"
  return 0
}

# ---- [3] bench extras — throttle / noisy / memlat / micro-bench / fsync -----
bhv5c14_render_bench_extras() {
  if [ -n "${BH_THROTTLE_PCT:-}" ]; then
    local _thr="  Throttle: ${BH_THROTTLE_PCT:-}%"
    [ -n "${BH_THROTTLE_NR:-}" ] && _thr="$_thr across ${BH_THROTTLE_NR:-} windows"
    case "${BH_THROTTLE_PCT:-}" in
      *[!0-9.]*) rpt "$_thr" ;;
      *)
        if awk -v t="${BH_THROTTLE_PCT:-}" 'BEGIN{exit !(t+0>5)}' 2>/dev/null; then
          rpt "  [WARN] Throttle: cgroup CPU throttling ${BH_THROTTLE_PCT:-}%${BH_THROTTLE_NR:+ across ${BH_THROTTLE_NR:-} windows}"
        else
          rpt "$_thr"
        fi ;;
    esac
  fi
  [ -n "${BH_NOISY_PCT:-}" ]    && rpt "  Noisy   : ${BH_NOISY_PCT:-}"
  [ -n "${BH_MEM_LAT_NS:-}" ]   && rpt "  MemLat  : ${BH_MEM_LAT_NS:-} ns"
  [ -n "${BH_PGFAULT_RATE:-}" ] && rpt "  PgFlt   : ${BH_PGFAULT_RATE:-}${BH_PGFAULT_SCOPE:+ (${BH_PGFAULT_SCOPE:-})}"
  [ -n "${BH_PIPE_US:-}" ]      && rpt "  Pipe    : ${BH_PIPE_US:-} us"
  [ -n "${BH_SQLITE_RPS:-}" ]   && rpt "  SQLite  : ${BH_SQLITE_RPS:-} rps${BH_SQLITE_BATCH:+ (batch ${BH_SQLITE_BATCH:-})}"
  [ -n "${BH_STAT_KPS:-}" ]     && rpt "  Stat    : ${BH_STAT_KPS:-} k calls/s"
  [ -n "${BH_URANDOM_MBPS:-}" ] && rpt "  URand   : ${BH_URANDOM_MBPS:-} MB/s"
  # fsync durability: p99 >25ms = bad, >10ms = warn, otherwise the plain row
  if [ -n "${BH_FSYNC_P50_MS:-}" ] || [ -n "${BH_FSYNC_P99_MS:-}" ] || [ -n "${BH_FSYNC_RPS:-}" ]; then
    local _fs="  Fsync   : p50 ${BH_FSYNC_P50_MS:-?} ms · p99 ${BH_FSYNC_P99_MS:-?} ms"
    [ -n "${BH_FSYNC_RPS:-}" ] && _fs="$_fs · ${BH_FSYNC_RPS:-} fs/s"
    case "${BH_FSYNC_P99_MS:-}" in
      ''|*[!0-9.]*) rpt "$_fs" ;;
      *)
        if awk -v v="${BH_FSYNC_P99_MS:-}" 'BEGIN{exit !(v+0>25)}' 2>/dev/null; then
          rpt "  [BAD]  Fsync   : p99 ${BH_FSYNC_P99_MS:-} ms (>25ms — slow durability)"
        elif awk -v v="${BH_FSYNC_P99_MS:-}" 'BEGIN{exit !(v+0>10)}' 2>/dev/null; then
          rpt "  [WARN] Fsync   : p99 ${BH_FSYNC_P99_MS:-} ms (>10ms)"
        else
          rpt "$_fs"
        fi ;;
    esac
  fi
  # run-to-run trend — only when the sparkline module produced data
  [ -n "${BH_SPARKLINE:-}" ] && rpt "  trend: ${BH_SPARKLINE:-}${BH_TREND:+ ${BH_TREND:-}}"
  return 0
}

# ---- [T] TOP TIPS — top 3 records from 63-tips.sh + fix command lines -------
bhv5c14_render_tips_section() {
  rpt ""
  rpt "[T] TOP TIPS"
  if declare -F bh_tips_engine >/dev/null 2>&1; then
    bh_tips_engine
  fi
  local _rec _sev _title _fix _n=0
  if [ -n "${BH_TIPS:-}" ]; then
    while IFS= read -r _rec; do
      [ -n "$_rec" ] || continue
      [ "$_n" -lt 3 ] || break
      _sev="${_rec%%|*}"
      _title="${_rec#*|}"
      case "$_title" in
        *'|'*) _fix="${_title#*|}"; _title="${_title%%|*}" ;;
        *)     _fix="" ;;
      esac
      _n=$((_n + 1))
      case "$_sev" in
        bad)  rpt "  [BAD]  $_title" ;;
        warn) rpt "  [WARN] $_title" ;;
        *)    rpt "  [INFO]  $_title" ;;
      esac
      [ -n "$_fix" ] && rpt "         fix: $_fix"
    done <<BHV5C14TIPS
${BH_TIPS:-}
BHV5C14TIPS
  fi
  [ "$_n" -eq 0 ] && rpt "  [INFO]  no tips — nothing flagged by the tips engine"
  return 0
}

# ---- sinks: JSON numeric-key helper (skips empty / non-numeric values) ------
bhv5c14_json_num() { # KEY VALUE — emits "key":<number>, when VALUE is a clean number
  case "${2:-}" in
    ''|*[!0-9.]*) return 0 ;;
  esac
  case "$(awk -v v="$2" 'BEGIN{print (v ~ /^[0-9]+(\.[0-9]+)?$/) ? "ok" : "no"}' 2>/dev/null)" in
    ok) printf '"%s":%s,' "$1" "$2" ;;
  esac
  return 0
}

# ---- sinks: Prometheus numeric gauge helper ---------------------------------
bhv5c14_prom_gauge() { # NAME HELP VALUE — HELP/TYPE/gauge triple, skipped when non-numeric
  case "${3:-}" in
    ''|*[!0-9.]*) return 0 ;;
  esac
  printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' "$1" "$2" "$1" "$1" "$3"
  return 0
}

# ---- sinks: shields.io endpoint JSON badge (atomic tmp+mv) ------------------
build_badge() {
  [ -n "${BH_BADGE_OUT:-}" ] || return 0
  case "${BH_BADGE_OUT#-}" in "") return 0 ;; esac
  local color="lightgrey" msg grade="${BH_GRADE:-}"
  case "$grade" in
    S|A) color="good" ;;
    B)   color="yellowgreen" ;;
    C)   color="yellow" ;;
    D)   color="orange" ;;
    F)   color="red" ;;
    *)   color="lightgrey" ;;
  esac
  if [ -n "$grade" ]; then
    msg="$(num_or_0 "${BH_SCORE_TOTAL:-0}") | $grade"
  else
    msg="$(num_or_0 "${BH_SCORE_TOTAL:-0}")"   # no grade yet -> lightgrey badge
  fi
  local tmp="${BH_BADGE_OUT}.tmp" _json
  _json="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  {
    printf '{"schemaVersion":1,"label":"BH-SCORE","message":"%s","color":"%s"}' "$_json" "$color"
  } > "$tmp" 2>/dev/null
  if mv -f "$tmp" "${BH_BADGE_OUT}" 2>/dev/null; then
    log "badge JSON written to ${BH_BADGE_OUT}"
  else
    rm -f "$tmp" 2>/dev/null
    warn "cannot write badge output ${BH_BADGE_OUT}"
  fi
  return 0
}

# ---- sinks: static SVG gauge chart (atomic tmp+mv, pure printf, no deps) ----
bhv5c14_xml_esc() { # escape & < > for XML text nodes
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
  return 0
}

build_svg() {
  [ -n "${BH_SVG_OUT:-}" ] || return 0
  case "${BH_SVG_OUT#-}" in "") return 0 ;; esac
  local color grade="${BH_GRADE:-}" dash tmp bars="" _pair lbl val w y
  case "$grade" in
    S|A) color="#4c1" ;;    # shields brightgreen
    B)   color="#a4a61d" ;; # yellowgreen
    C)   color="#dfb317" ;; # yellow
    D)   color="#fe7d37" ;; # orange
    F)   color="#e05d44" ;; # red
    *)   color="#9f9f9f" ;; # lightgrey
  esac
  # donut arc: circumference 2*pi*80, filled share = total/max (awk float math)
  dash="$(awk -v t="$(num_or_0 "${BH_SCORE_TOTAL:-0}")" -v m="$(num_or_0 "${BH_SCORE_MAX:-700}")" 'BEGIN{
    c = 2 * 3.14159265358979 * 80
    p = (m + 0 > 0) ? t / m : 0
    if (p < 0) p = 0
    if (p > 1) p = 1
    printf "%.2f %.2f", c * p, c - c * p
  }')"
  y=46
  while IFS= read -r _pair; do
    [ -n "$_pair" ] || continue
    lbl="${_pair%%|*}"
    val="${_pair#*|}"
    case "$val" in ''|*[!0-9.]*) val=0 ;; esac
    w="$(awk -v v="$val" 'BEGIN{ v=(v<0)?0:v; v=(v>100)?100:v; printf "%.1f", v*0.8 }')"
    bars="${bars}  <text x=\"230\" y=\"$((y + 9))\" font-family=\"monospace\" font-size=\"11\" fill=\"#444444\">$(bhv5c14_xml_esc "${lbl} ${val}")</text>
  <rect x=\"330\" y=\"${y}\" width=\"80\" height=\"10\" fill=\"#eeeeee\"/>
  <rect x=\"330\" y=\"${y}\" width=\"${w}\" height=\"10\" fill=\"${color}\"/>
"
    y=$((y + 28))
  done <<BHV5C14BARS
CPU 1c|${BH_SCORE_CPU1C:-0}
CPU mul|${BH_SCORE_CPUMC:-0}
Memory|${BH_SCORE_MEM:-0}
Disk seq|${BH_SCORE_DSEQ:-0}
Disk 4k|${BH_SCORE_D4K:-0}
Net down|${BH_SCORE_NDOWN:-0}
Net up|${BH_SCORE_NUP:-0}
BHV5C14BARS
  tmp="${BH_SVG_OUT}.tmp"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<svg xmlns="http://www.w3.org/2000/svg" width="420" height="260" viewBox="0 0 420 260">\n'
    printf '  <rect width="420" height="260" fill="#ffffff"/>\n'
    printf '  <text x="16" y="26" font-family="monospace" font-size="13" fill="#222222">%s</text>\n' \
      "$(bhv5c14_xml_esc "${BH_TOOL:-blackhole-vps-bench} v${BH_VERSION:-5}")"
    printf '  <circle cx="110" cy="150" r="80" fill="none" stroke="#e8e8e8" stroke-width="22"/>\n'
    printf '  <circle cx="110" cy="150" r="80" fill="none" stroke="%s" stroke-width="22" stroke-dasharray="%s" transform="rotate(-90 110 150)" stroke-linecap="butt"/>\n' \
      "$color" "$dash"
    printf '  <text x="110" y="146" text-anchor="middle" font-family="monospace" font-size="32" fill="#222222">%s</text>\n' \
      "$(bhv5c14_xml_esc "$(num_or_0 "${BH_SCORE_TOTAL:-0}")")"
    printf '  <text x="110" y="170" text-anchor="middle" font-family="monospace" font-size="13" fill="#777777">/ %s · grade %s</text>\n' \
      "$(bhv5c14_xml_esc "$(num_or_0 "${BH_SCORE_MAX:-700}")")" "$(bhv5c14_xml_esc "${BH_GRADE:-n/a}")"
    printf '%s\n' "$bars"
    printf '</svg>\n'
  } > "$tmp" 2>/dev/null
  if mv -f "$tmp" "${BH_SVG_OUT}" 2>/dev/null; then
    log "SVG gauge written to ${BH_SVG_OUT}"
  else
    rm -f "$tmp" 2>/dev/null
    warn "cannot write SVG output ${BH_SVG_OUT}"
  fi
  return 0
}

# ---- sinks: Markdown "## v5 extras" compact table ----------------------------
bhv5c14_md_row() { # FIELD VALUE — one markdown table row, pipes escaped
  printf '| %s | %s |\n' "$1" "$(printf '%s' "$2" | sed 's/|/\\|/g')"
  return 0
}

bhv5c14_md_extras() {
  local _any="${BH_QEMU_ACCEL:-}${BH_CI_CLOUD:-}${BH_SPEC_SUMMARY:-}${BH_UIDMAP_MODE:-}${BH_SECCOMP_MODE:-}${BH_RT_NAME:-}${BH_ORCH:-}${BH_MEM_LAT_NS:-}${BH_THROTTLE_PCT:-}${BH_SQLITE_RPS:-}${BH_FSYNC_P99_MS:-}${BH_CLOCK_SKEW_S:-}${BH_EGRESS_PROXY:-}${BH_K8S_CTX:-}${BH_TIPS:-}${BH_FINGERPRINT:-}${BH_TRUTH:-}"
  [ -n "$_any" ] || return 0
  printf '\n## v5 extras\n\n| Field | Value |\n|---|---|\n'
  [ -n "${BH_QEMU_ACCEL:-}" ]   && bhv5c14_md_row "Accel" "${BH_QEMU_ACCEL:-}"
  [ -n "${BH_CI_CLOUD:-}" ]     && bhv5c14_md_row "cloud-init" "${BH_CI_CLOUD:-} ${BH_CI_REGION:-} ${BH_CI_AZ:-}"
  [ -n "${BH_SPEC_SUMMARY:-}" ] && bhv5c14_md_row "Plan check" "${BH_SPEC_SUMMARY:-} cpu=${BH_SPEC_CPU_V:-?} ram=${BH_SPEC_RAM_V:-?} burst=${BH_SPEC_BURST:-?}"
  [ -n "${BH_UIDMAP_MODE:-}" ]  && bhv5c14_md_row "Uid map" "${BH_UIDMAP_MODE:-}"
  [ -n "${BH_SECCOMP_MODE:-}" ] && bhv5c14_md_row "Seccomp" "${BH_SECCOMP_MODE:-}"
  [ -n "${BH_RT_NAME:-}${BH_ORCH:-}" ] && bhv5c14_md_row "Runtime" "${BH_RT_NAME:-?} ${BH_ORCH:-}"
  [ -n "${BH_K8S_CTX:-}" ]      && bhv5c14_md_row "K8s context" "${BH_K8S_CTX:-}"
  [ -n "${BH_MEM_LAT_NS:-}" ]   && bhv5c14_md_row "Memory latency (ns)" "${BH_MEM_LAT_NS:-}"
  [ -n "${BH_THROTTLE_PCT:-}" ] && bhv5c14_md_row "cgroup throttling" "${BH_THROTTLE_PCT:-}%${BH_THROTTLE_NR:+ / ${BH_THROTTLE_NR:-} windows}"
  [ -n "${BH_SQLITE_RPS:-}" ]   && bhv5c14_md_row "SQLite (rps)" "${BH_SQLITE_RPS:-}"
  [ -n "${BH_FSYNC_P99_MS:-}" ] && bhv5c14_md_row "fsync p50/p99 (ms)" "${BH_FSYNC_P50_MS:-?} / ${BH_FSYNC_P99_MS:-?}"
  [ -n "${BH_CLOCK_SKEW_S:-}" ] && bhv5c14_md_row "Clock skew" "${BH_CLOCK_SKEW_S:-}"
  [ -n "${BH_EGRESS_PROXY:-}" ] && bhv5c14_md_row "Egress" "${BH_EGRESS_PROXY:-}"
  bhv5c14_truth_strip
  [ -n "${BH_TRUTH:-}" ]        && bhv5c14_md_row "Truth strip" "${BH_TRUTH#truth: }"
  bh_fingerprint
  [ -n "${BH_FINGERPRINT:-}" ]  && bhv5c14_md_row "Fingerprint" "${BH_FINGERPRINT:-}"
  if declare -F bh_tips_engine >/dev/null 2>&1; then
    bh_tips_engine
  fi
  if [ -n "${BH_TIPS:-}" ]; then
    local _top
    _top="$(printf '%s\n' "${BH_TIPS:-}" | awk -F'|' 'NF { print $2 }' | head -n 3 | tr '\n' ';')"
    bhv5c14_md_row "Tips (top 3)" "${_top%;}"
  fi
  return 0
}

# BH_GAUGE_OK — 1 when the bh_gauge helper (00-core, another owner) exists;
# when it does not, the score section silently keeps its plain-number rows.
BH_GAUGE_OK=0

# bh_score_gauge_line LABEL VALUE — one score row:
#   "  CPU 1c      85/100 ▰▰▰▰▰▰▰▱▱▱"  (label padded, 10-char bar gauge)
bh_score_gauge_line() {
  [ "$BH_GAUGE_OK" = "1" ] || return 0
  local bar
  bar="$(bh_gauge "$2" 100 2>/dev/null)" || bar=""
  [ -n "$bar" ] || { BH_GAUGE_OK=0; return 0; }
  rpt "$(printf '  %-10s%4s/100 %s' "$1" "$2" "$bar")"
  return 0
}

# render_compare — when BH_COMPARE_IN points at a readable previous JSON
# report, print a "metric old→new ▲/▼ delta" table for the 7 score components
# + total + grade. jq first, python3 fallback; a note line when neither
# exists. Appends to the report body via rpt() — build_report calls it right
# after the score section so print_report emits it in place.
render_compare() {
  [ -n "${BH_COMPARE_IN:-}" ] || return 0
  [ "$BH_COMPARE_IN" != "-" ] || return 0
  if [ ! -r "$BH_COMPARE_IN" ]; then
    rpt "  [WARN] compare: cannot read $BH_COMPARE_IN"
    return 0
  fi
  local tsv=""
  if command_exists jq; then
    tsv="$(jq -r '[.score.cpu_1c,.score.cpu_multi,.score.memory,.score.disk_seq,.score.disk_4k,.score.net_down,.score.net_up,(.score.total // 0),(.score.grade // "")] | @tsv' "$BH_COMPARE_IN" 2>/dev/null)"
  elif command_exists python3; then
    tsv="$(python3 - "$BH_COMPARE_IN" <<'BHCMPPY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
s = d.get("score") or {}
def g(k):
    v = s.get(k)
    return "" if v is None else str(v)
print("\t".join([g("cpu_1c"), g("cpu_multi"), g("memory"), g("disk_seq"),
                 g("disk_4k"), g("net_down"), g("net_up"), g("total"), g("grade")]))
BHCMPPY
)"
  else
    rpt "  [INFO]  compare needs jq/python3"
    return 0
  fi
  [ -n "$tsv" ] || { rpt "  [INFO]  compare: no parseable score in $BH_COMPARE_IN"; return 0; }
  local o1c="" omc="" omem="" odseq="" od4k="" ond="" onup="" otot="" ograde="" _rest=""
  while IFS="$(printf '\t')" read -r o1c omc omem odseq od4k ond onup otot ograde _rest; do
    break
  done <<BHCMPEOF
$tsv
BHCMPEOF
  rpt ""
  rpt "  compare vs previous run ($BH_COMPARE_IN):"
  bh_cmp_row() { # LABEL OLD NEW — one aligned "old → new ▲ delta" row
    local o="${2:-}" n="${3:-}" d="" arrow
    case "${o}${n}" in
      ''|*[!0-9.-]*)
        rpt "$(printf '  %-10s %s → %s' "$1" "${o:-n/a}" "${n:-n/a}")"
        return 0 ;;
    esac
    d="$(awk -v o="$o" -v n="$n" 'BEGIN{ if (o=="" || n=="") exit; printf "%+.0f", n-o }' 2>/dev/null)"
    case "$d" in
      ''|'+0'|'-0') rpt "$(printf '  %-10s %s → %s  =' "$1" "${o:-n/a}" "${n:-n/a}")" ;;
      +*)           rpt "$(printf '  %-10s %s → %s  ▲ %s' "$1" "$o" "$n" "$d")" ;;
      *)            rpt "$(printf '  %-10s %s → %s  ▼ %s' "$1" "$o" "$n" "$d")" ;;
    esac
    return 0
  }
  bh_cmp_row "CPU 1c"   "$o1c"   "$BH_SCORE_CPU1C"
  bh_cmp_row "CPU mul"  "$omc"   "$BH_SCORE_CPUMC"
  bh_cmp_row "Memory"   "$omem"  "$BH_SCORE_MEM"
  bh_cmp_row "Disk seq" "$odseq" "$BH_SCORE_DSEQ"
  bh_cmp_row "Disk 4k"  "$od4k"  "$BH_SCORE_D4K"
  bh_cmp_row "Net down" "$ond"   "$BH_SCORE_NDOWN"
  bh_cmp_row "Net up"   "$onup"  "$BH_SCORE_NUP"
  bh_cmp_row "Total"    "$otot"  "$BH_SCORE_TOTAL"
  [ -n "$ograde" ] || ograde="n/a"
  rpt "$(printf '  %-10s %s → %s' "grade" "$ograde" "${BH_GRADE:-n/a}")"
  return 0
}

# build_prom — Prometheus node_exporter textfile export (W3-O).
# Emit # HELP/# TYPE + the core gauges, write to "$BH_PROM_OUT.tmp" then mv
# (atomic rename, node_exporter textfile convention). Empty source values are
# skipped; score components are always defined (0 when the bench was skipped)
# so the family stays complete. BH_PROM_OUT="-" is refused (stdout sinks).
build_prom() {
  [ -n "${BH_PROM_OUT:-}" ] || return 0
  case "${BH_PROM_OUT#-}" in "") return 0 ;; esac
  local tmp="${BH_PROM_OUT}.tmp"
  {
    printf '# HELP bh_score_total Total BH-SCORE (sum of 7 capped components).\n'
    printf '# TYPE bh_score_total gauge\n'
    printf 'bh_score_total %s\n' "$(num_or_0 "$BH_SCORE_TOTAL")"
    printf '# HELP bh_score_max Maximum achievable BH-SCORE.\n'
    printf '# TYPE bh_score_max gauge\n'
    printf 'bh_score_max %s\n' "$(num_or_0 "$BH_SCORE_MAX")"
    printf '# HELP bh_score_component BH-SCORE component, 0-100.\n'
    printf '# TYPE bh_score_component gauge\n'
    printf 'bh_score_component{metric="cpu_1c"} %s\n'    "$(num_or_0 "$BH_SCORE_CPU1C")"
    printf 'bh_score_component{metric="cpu_multi"} %s\n' "$(num_or_0 "$BH_SCORE_CPUMC")"
    printf 'bh_score_component{metric="memory"} %s\n'    "$(num_or_0 "$BH_SCORE_MEM")"
    printf 'bh_score_component{metric="disk_seq"} %s\n'  "$(num_or_0 "$BH_SCORE_DSEQ")"
    printf 'bh_score_component{metric="disk_4k"} %s\n'   "$(num_or_0 "$BH_SCORE_D4K")"
    printf 'bh_score_component{metric="net_down"} %s\n'  "$(num_or_0 "$BH_SCORE_NDOWN")"
    printf 'bh_score_component{metric="net_up"} %s\n'    "$(num_or_0 "$BH_SCORE_NUP")"
    case "${BH_SEC_BAD:-}" in
      '') : ;;
      *) printf '# HELP bh_security_bad Security audit BAD findings.\n# TYPE bh_security_bad gauge\nbh_security_bad %s\n' "$BH_SEC_BAD" ;;
    esac
    case "${BH_SEC_WARN:-}" in
      '') : ;;
      *) printf '# HELP bh_security_warn Security audit WARN findings.\n# TYPE bh_security_warn gauge\nbh_security_warn %s\n' "$BH_SEC_WARN" ;;
    esac
    case "${BH_SHA1C:-}" in
      '') : ;;
      *) printf '# HELP bh_cpu_sha256_1c_mbps sha256 throughput, one core (MB/s).\n# TYPE bh_cpu_sha256_1c_mbps gauge\nbh_cpu_sha256_1c_mbps %s\n' "$BH_SHA1C" ;;
    esac
    case "${BH_MEM_GBS:-}" in
      '') : ;;
      *) printf '# HELP bh_mem_gbs Memory copy bandwidth (GB/s).\n# TYPE bh_mem_gbs gauge\nbh_mem_gbs %s\n' "$BH_MEM_GBS" ;;
    esac
    case "${BH_SEQW:-}" in
      '') : ;;
      *) printf '# HELP bh_disk_seq_mbps Disk sequential write (MB/s).\n# TYPE bh_disk_seq_mbps gauge\nbh_disk_seq_mbps %s\n' "$BH_SEQW" ;;
    esac
    case "${BH_DOWN_MBPS:-}" in
      '') : ;;
      *) printf '# HELP bh_net_down_mbps Download throughput (Mbps).\n# TYPE bh_net_down_mbps gauge\nbh_net_down_mbps %s\n' "$BH_DOWN_MBPS" ;;
    esac
    case "${BH_UP_MBPS:-}" in
      '') : ;;
      *) printf '# HELP bh_net_up_mbps Upload throughput (Mbps).\n# TYPE bh_net_up_mbps gauge\nbh_net_up_mbps %s\n' "$BH_UP_MBPS" ;;
    esac
    # ---- v5 numeric extras (C14) — only when the value is present ----
    bhv5c14_prom_gauge bh_vps5_mem_latency_ns "Memory access latency (ns)."   "${BH_MEM_LAT_NS:-}"
    bhv5c14_prom_gauge bh_vps5_pipe_us        "Pipe round-trip (microseconds)." "${BH_PIPE_US:-}"
    bhv5c14_prom_gauge bh_vps5_stat_kps       "stat() syscall rate (k/s)."    "${BH_STAT_KPS:-}"
    bhv5c14_prom_gauge bh_vps5_sqlite_rps     "SQLite insert rate (rows/s)."  "${BH_SQLITE_RPS:-}"
    bhv5c14_prom_gauge bh_vps5_fsync_p50_ms   "fsync latency p50 (ms)."       "${BH_FSYNC_P50_MS:-}"
    bhv5c14_prom_gauge bh_vps5_fsync_p99_ms   "fsync latency p99 (ms)."       "${BH_FSYNC_P99_MS:-}"
    bhv5c14_prom_gauge bh_vps5_throttle_pct   "cgroup CPU throttling (pct)."  "${BH_THROTTLE_PCT:-}"
    bhv5c14_prom_gauge bh_vps5_tls_ms         "TLS handshake time (ms)."      "${BH_TLS_MS:-}"
    bhv5c14_prom_gauge bh_vps5_clock_skew_s   "Clock skew vs reference (s)."  "${BH_CLOCK_SKEW_S:-}"
    bhv5c14_prom_gauge bh_vps5_pmtu           "Path MTU (bytes)."             "${BH_PMTU:-}"
  } > "$tmp" 2>/dev/null
  local _prom_rc=$?
  if [ "$_prom_rc" -eq 0 ] && mv -f "$tmp" "$BH_PROM_OUT" 2>/dev/null; then
    log "Prometheus textfile written to $BH_PROM_OUT"
  else
    rm -f "$tmp" 2>/dev/null
    warn "cannot write Prometheus output $BH_PROM_OUT"
  fi
  return 0
}

build_report() {
  bh_lines=()
  bh_redact_sink
  bh_compute_verdicts
  # gauge helper (00-core, another owner): render bar rows when present,
  # silently keep the plain-number score rows below when missing.
  if command -v bh_gauge >/dev/null 2>&1; then BH_GAUGE_OK=1; else BH_GAUGE_OK=0; fi
  rpt "+----------------------------------------------------------------+"
  rpt "$(printf '| %-62s |' "BLACKHOLE VPS BENCH v$BH_VERSION")"
  rpt "$(printf '| %-62s |' "github.com/$BH_REPO")"
  rpt "+----------------------------------------------------------------+"

  rpt ""
  rpt "[1] VIRTUALIZATION VERDICT"
  rpt "  Kind    : $BH_KIND"
  rpt "  Type    : $BH_TYPE"
  rpt "  Product : $BH_PRODUCT"
  [ -n "${BH_WSL_GEN:-}" ] && rpt "  WSL gen : $BH_WSL_GEN"
  [ -n "${BH_CHASSIS_CLASS:-}" ] && rpt "  Chassis : type ${BH_CHASSIS_TYPE:-?} ($BH_CHASSIS_CLASS)"
  if [ "$BH_KIND" = "container" ] && [ -n "$BH_HOST_PRODUCT" ]; then
    rpt "  Host VM : $BH_HOST_PRODUCT"
  fi
  if [ -n "$BH_CLOUD" ]; then
    rpt "  Cloud   : $BH_CLOUD${BH_CLOUD_DETAIL:+ ($BH_CLOUD_DETAIL)}${BH_AWS_GEN:+ ($BH_AWS_GEN)}"
  fi
  # v4 deep-scan verdicts (10-detect; each renders only when determined)
  [ -n "${BH_VIRT_NESTED:-}" ]    && rpt "  Nested  : $BH_VIRT_NESTED"
  [ -n "${BH_CONF_COMPUTING:-}" ] && rpt "  ConfCmp : $BH_CONF_COMPUTING (confidential computing)"
  [ -n "${BH_IRQ_VMM:-}" ]        && rpt "  VMM irq : $BH_IRQ_VMM"
  [ -n "${BH_VIRTIO_DEVS:-}" ]    && rpt "  Virtio  : $BH_VIRTIO_DEVS"
  [ "${BH_IS_CHROOT:-0}" = "1" ] && rpt "  Chroot  : yes (/, /proc/1/root differ)"
  rpt "  Verdict : $(verdict_text)"
  rpt "  Evidence:"
  print_evidence
  # ---- v5 virt extras (accel / VMM tells / DMI spoof / Xen / ACPI OEM) ----
  bhv5c14_render_virt_extras
  # ---- v5 cloud-init / meta2 / hints / spec lie-check ----
  bhv5c14_render_cloud_extras

  # ---- [GPU] — optional module 15-gpu.sh: every reference is ${BH_GPU_X:-}
  # guarded so the report renders identically when the module is absent.
  if [ -n "${BH_GPU_SUMMARY:-}${BH_GPU_PCI:-}${BH_GPU_NVIDIA:-}${BH_GPU_MIG:-}${BH_GPU_VRAM_SYSFS:-}${BH_GPU_VRAM:-}${BH_GPU_LIBS:-}${BH_GPU_PASSTHROUGH:-}${BH_GPU_NODES:-}" ]; then
    rpt ""
    rpt "[GPU] GRAPHICS / ACCELERATORS"
    [ -n "${BH_GPU_SUMMARY:-}" ] && rpt "  Summary : $BH_GPU_SUMMARY"
    [ -n "${BH_GPU_PCI:-}" ]     && rpt "  PCI     : $BH_GPU_PCI"
    [ -n "${BH_GPU_NVIDIA:-}" ]  && rpt "  NVIDIA  : $BH_GPU_NVIDIA"
    [ -n "${BH_GPU_MIG:-}" ]     && rpt "  MIG     : $BH_GPU_MIG"
    [ -n "${BH_GPU_VRAM_SYSFS:-}${BH_GPU_VRAM:-}" ] && rpt "  VRAM    : ${BH_GPU_VRAM_SYSFS:-${BH_GPU_VRAM:-}}"
    case "${BH_GPU_LIBS:-}" in
      "") : ;;
      *mismatch*|*Mismatch*|*older*|*newer*) rpt "  [WARN]  libs: $BH_GPU_LIBS — userland/driver mismatch" ;;
      *)                                     rpt "  Libs    : $BH_GPU_LIBS" ;;
    esac
    [ -n "${BH_GPU_PASSTHROUGH:-}" ] && rpt "  Passthru: $BH_GPU_PASSTHROUGH"
    [ -n "${BH_GPU_NODES:-}" ]       && rpt "  Nodes   : $BH_GPU_NODES"
  fi

  rpt ""
  rpt "[2] SYSTEM / REAL CONFIG"
  rpt "  Hostname: $BH_HOSTNAME"
  rpt "  OS      : $BH_OS"
  rpt "  Kernel  : $BH_KERNEL ($BH_ARCH), uptime $BH_UPTIME"
  # CPU vulnerability matrix (20-info): worst list + whose kernel it describes
  if [ -n "${BH_VULN_WORST:-}" ]; then
    rpt "  Vulns   : Vulnerable: $BH_VULN_WORST (scope: ${BH_VULN_SCOPE:-kernel})"
  elif [ "${BH_VULN_SCOPE:-}" = "host-kernel" ]; then
    rpt "  Vulns   : none vulnerable (host-kernel scope)"
  fi
  local cpuline="  CPU     : ${BH_CPU_MODEL:-n/a}"
  [ -n "${BH_CPU_FREQ_MHZ:-}" ] && cpuline="$cpuline, ${BH_CPU_FREQ_MHZ} MHz"
  case "${BH_CPUSET_N:-}" in
    ''|0) : ;;
    *) [ "${BH_CPUSET_N:-0}" -gt 0 ] 2>/dev/null && cpuline="$cpuline, cpuset cores ${BH_CPUSET_N}" ;;
  esac
  rpt "$cpuline"
  rpt "            ${BH_CPU_LOGICAL:-?} logical / ${BH_CPU_PHYS:-?} physical cores"
  local effline="            effective: ${BH_EFF_CORES:-?} core(s)"
  if [ -n "$BH_CPU_QUOTA_TXT" ]; then effline="$effline, cgroup quota $BH_CPU_QUOTA_TXT cores"; fi
  if [ -n "$CPUSET" ]; then effline="$effline, cpuset [$CPUSET]"; fi
  rpt "$effline"
  if [ -n "${BH_CPU_UCODE:-}" ] || [ -n "${BH_CPU_STEPPING:-}" ]; then
    rpt "            microcode: ${BH_CPU_UCODE:-?} · stepping: ${BH_CPU_STEPPING:-?}"
  fi
  [ -n "$BH_CPU_FLAGS_HI" ] && rpt "            features: $BH_CPU_FLAGS_HI"
  [ -n "${BH_CPU_AI_FEAT:-}" ]     && rpt "            AI: $BH_CPU_AI_FEAT"
  [ -n "${BH_CPU_CRYPTO_FEAT:-}" ] && rpt "            CRYPTO: $BH_CPU_CRYPTO_FEAT"
  local stealline="  Steal   : ${BH_STEAL_PCT:-n/a}%"
  case "${BH_STEAL_PCT:-}" in
    ''|*[!0-9.]*) : ;;
    *) awk -v s="$BH_STEAL_PCT" 'BEGIN{exit !(s+0>5)}' && stealline="$stealline — noisy neighbor!" ;;
  esac
  rpt "$stealline"
  local memline
  memline="  RAM     : total $(fmt_mbint "$BH_MEM_TOTAL_MB"), avail $(fmt_mbint "$BH_MEM_AVAIL_MB"), swap $(fmt_mbint "$BH_MEM_SWAP_MB")"
  if [ "${BH_MEM_LIMIT_MB:-0}" -gt 0 ] 2>/dev/null; then
    memline="$memline | container limit $(fmt_mbint "$BH_MEM_LIMIT_MB")"
  fi
  rpt "$memline"
  rpt "  Swap    : ${BH_SWAP_DETAIL:-none}"
  # KSM = kernel same-page merging — active dedup is a memory-oversell clue
  [ "${BH_KSM_STATE:-}" = "on" ] && rpt "  KSM     : on${BH_KSM_SHARING:+, $BH_KSM_SHARING pages sharing (oversell clue)}"
  local diskline
  diskline="  Disk    : $BH_DISK_DEV ($BH_DISK_FS) on $BH_DISK_DIR — total $(fmt_mbint "$BH_DISK_TOTAL_MB"), avail $(fmt_mbint "$BH_DISK_AVAIL_MB")"
  if [ -n "${BH_DISK_CLASS:-}${BH_DISK_SCHED:-}${BH_DISK_ROTA:-}" ]; then
    diskline="$diskline | class=${BH_DISK_CLASS:-?} sched=${BH_DISK_SCHED:-?} rota=${BH_DISK_ROTA:-?}"
  fi
  rpt "$diskline"
  rpt "  NetEnv  : TCP cc ${BH_TCPCC:-n/a}${BH_TCPCC_AVAIL:+ (avail: $BH_TCPCC_AVAIL)} | entropy ${BH_ENTROPY:-n/a} | DNS: ${BH_DNS:-n/a}"
  local tunline=""
  [ -n "${BH_THP:-}" ]             && tunline="thp=$BH_THP"
  [ -n "${BH_HUGEPAGES_TOTAL:-}" ] && tunline="${tunline:+$tunline }hugepages=$BH_HUGEPAGES_TOTAL"
  [ -n "${BH_NET_MTU:-}" ]         && tunline="${tunline:+$tunline }mtu=$BH_NET_MTU"
  [ -n "$tunline" ] && rpt "  Tunables: $tunline"
  rpt "  Devices : TUN/TAP $( [ "${BH_TUN:-0}" = "1" ] && echo yes || echo no )$( [ "${BH_TUN:-0}" = "1" ] && printf ' (VPN-capable)' ) | FUSE $( [ "${BH_FUSE:-0}" = "1" ] && echo yes || echo no ) | PPP $( [ "${BH_PPP:-0}" = "1" ] && echo yes || echo no ) | tz: ${BH_TZ:-n/a}"
  rpt "  Load    : ${BH_LOAD:-n/a} (1/5/15 min) | processes: ${BH_PROCS:-?}"
  # ---- v5 info extras (cache / block queue / NUMA / freq / thermal / DIMM) ----
  bhv5c14_render_info_extras

  rpt ""
  if [ "${BH_BENCH_SKIPPED:-0}" = "1" ]; then
    rpt "[3] BENCHMARK — skipped in $BH_MODE mode (run: all | bench)"
  else
    rpt "[3] BENCHMARK"
    local btier bline
    btier="$(tier_cpu1c "$BH_SHA1C")"
    bline="  CPU     : sha256 $(fmt_mb "$BH_SHA1C") (1 core) | $(fmt_mb "$BH_SHANC") (${BH_PAR_JOBS} threads)"
    [ -n "$btier" ] && bline="$bline [$btier]"
    rpt "$bline"
    [ -n "$BH_OPENSSL_K" ] && rpt "            openssl sha256 cross-check: $BH_OPENSSL_K k/s"
    [ -n "${BH_CPU_EFFICIENCY:-}" ] && rpt "            multi-thread efficiency: ${BH_CPU_EFFICIENCY}% of linear scaling"
    # v4: steal sampled ACROSS the multi-core window (30-cpu) — the honest
    # noisy-neighbor probe; only shown when it actually bit (>5%)
    case "${BH_STEAL_UNDER_LOAD:-}" in
      ''|*[!0-9.]*) : ;;
      *) if awk -v s="$BH_STEAL_UNDER_LOAD" 'BEGIN{exit !(s+0>5)}' 2>/dev/null; then
           rpt "            steal under load: $BH_STEAL_UNDER_LOAD% ← noisy neighbor WHILE benching!"
         fi ;;
    esac
    if [ -n "${BH_BASH_OPS:-}" ] || [ -n "${BH_AWK_OPS:-}" ]; then
      rpt "            ops/s cross-check: bash ${BH_BASH_OPS:-n/a} · awk ${BH_AWK_OPS:-n/a}"
    fi
    btier="$(tier_mem_gbs "$BH_MEM_GBS")"
    bline="  Memory  : $(fmt_gbs "$BH_MEM_GBS")  [$BH_MEM_METHOD]"
    [ -n "$btier" ] && bline="$bline  [$btier]"
    rpt "$bline"
    btier="$(tier_disk_seq "$BH_SEQW")"
    bline="  Disk    : seq w $(fmt_mb "$BH_SEQW") | seq r $(fmt_mb "$BH_SEQR") | 4k w $(fmt_mb "$BH_4KW") | 4k r $(fmt_mb "$BH_4KR")"
    [ -n "$btier" ] && bline="$bline  [$btier]"
    if [ -n "${BH_4K_IOPS_W:-}" ] || [ -n "${BH_4K_IOPS_R:-}" ]; then
      bline="$bline | 4k iops w/r: ${BH_4K_IOPS_W:-?}/${BH_4K_IOPS_R:-?}"
    fi
    rpt "$bline  [$BH_DISK_DIR, mode: $BH_DISK_MODE]"
    if [ -n "$BH_FIO_RIOPS" ] || [ -n "$BH_FIO_WIOPS" ]; then
      rpt "            fio 4k randrw IOPS: r=${BH_FIO_RIOPS:-n/a} w=${BH_FIO_WIOPS:-n/a}"
    fi
    # ---- v4 disk extras (50-disk): latency / live proof / TRIM / warn ----
    if [ -n "${BH_4K_LAT_P50_MS:-}" ]; then
      rpt "            4k rand latency p50/p90/p99: $BH_4K_LAT_P50_MS/$BH_4K_LAT_P90_MS/$BH_4K_LAT_P99_MS ms [${BH_4K_LAT_LABEL:-n/a}]"
    fi
    if [ -n "${BH_LIVE_IOPS:-}" ]; then
      local _live_h="$BH_LIVE_IOPS"
      case "$_live_h" in
        ''|*[!0-9]*) : ;;
        *) [ "$_live_h" -ge 1000 ] 2>/dev/null && _live_h="$(awk -v i="$_live_h" 'BEGIN{printf "%.1fk", i/1000}')" ;;
      esac
      rpt "            live ${BH_LIVE_DEV:-dev}: ${_live_h} IOPS, ${BH_LIVE_MBPS:-?} MB/s, ${BH_LIVE_BUSY_PCT:-?}% busy — measured during bench"
    fi
    if [ -n "${BH_TRIM_SUPPORT:-}" ] && [ "${BH_TRIM_SUPPORT:-}" != "unknown" ]; then
      local _trimline="            trim: $BH_TRIM_SUPPORT"
      [ -n "${BH_DISCARD_MOUNT:-}" ] && _trimline="$_trimline (mount discard: $BH_DISCARD_MOUNT)"
      rpt "$_trimline"
    fi
    [ -n "${BH_DISK_WARN:-}" ] && rpt "            [WARN] $BH_DISK_WARN"
    if [ "$BH_NO_NET" = "1" ]; then
      rpt "  Network : skipped (--no-net)"
    else
      local netline ntier
      netline="Network : down $(fmt_mbps "$BH_DOWN_MBPS") | up $(fmt_mbps "$BH_UP_MBPS") | connect $(fmt_ms "$BH_LAT_MS")  [$BH_NET_METHOD]"
      [ -n "$BH_LAT_ICMP" ] && netline="$netline | icmp ${BH_LAT_ICMP} ms${BH_LAT_JITTER:+ ± $BH_LAT_JITTER jitter} (${BH_LAT_TARGET})"
      ntier="$(tier_net "$BH_DOWN_MBPS")"
      [ -n "$ntier" ] && netline="$netline [$ntier]"
      [ -n "${BH_NET_ENDPOINT:-}" ] && netline="$netline | endpoint: $BH_NET_ENDPOINT"
      rpt "  $netline"
      [ -n "${BH_NET_TRIES:-}" ] && rpt "            attempts: $BH_NET_TRIES"
    fi
    # ---- v5 bench extras (throttle / noisy / memlat / micro-bench / fsync / trend) ----
    bhv5c14_render_bench_extras
  fi

  # ---- [BENCH-EXTRA] — module 35 info-only micro-benchmarks (renders when
  # any of its globals is set; omitted entirely otherwise) ----
  if [ -n "${BH_AES_GCM_MBPS:-}${BH_CHACHA_MBPS:-}${BH_AES_CBC_MBPS:-}${BH_GZIP_MBPS:-}${BH_ZSTD_MBPS:-}${BH_FORK_RATE:-}${BH_PIPE_GBS:-}${BH_PIPE4K_GBS:-}${BH_SMALLFILE_RATE:-}" ]; then
    local _bx_sep _bx_line
    rpt ""
    rpt "[BENCH-EXTRA] info-only micro-benchmarks"
    if [ -n "${BH_AES_GCM_MBPS:-}" ] || [ -n "${BH_CHACHA_MBPS:-}" ] || [ -n "${BH_AES_CBC_MBPS:-}" ]; then
      _bx_sep=""; _bx_line="  Crypto  :"
      [ -n "${BH_AES_GCM_MBPS:-}" ] && { _bx_line="$_bx_line$_bx_sep AES-256-GCM $BH_AES_GCM_MBPS MB/s"; _bx_sep=" |"; }
      [ -n "${BH_CHACHA_MBPS:-}" ]  && { _bx_line="$_bx_line$_bx_sep ChaCha20 $BH_CHACHA_MBPS MB/s"; _bx_sep=" |"; }
      [ -n "${BH_AES_CBC_MBPS:-}" ] && { _bx_line="$_bx_line$_bx_sep AES-256-CBC(fallback) $BH_AES_CBC_MBPS MB/s"; _bx_sep=" |"; }
      [ -n "${BH_AES_METHOD:-}" ]   && _bx_line="$_bx_line  [$BH_AES_METHOD]"
      rpt "$_bx_line"
    fi
    if [ -n "${BH_GZIP_MBPS:-}" ] || [ -n "${BH_ZSTD_MBPS:-}" ]; then
      _bx_sep=""; _bx_line="  Compress:"
      [ -n "${BH_GZIP_MBPS:-}" ] && { _bx_line="$_bx_line$_bx_sep gzip $BH_GZIP_MBPS MB/s"; _bx_sep=" |"; }
      [ -n "${BH_ZSTD_MBPS:-}" ] && { _bx_line="$_bx_line$_bx_sep zstd $BH_ZSTD_MBPS MB/s"; _bx_sep=" |"; }
      [ -n "${BH_GZIP_METHOD:-}" ] && _bx_line="$_bx_line  [$BH_GZIP_METHOD]"
      rpt "$_bx_line"
    fi
    [ -n "${BH_FORK_RATE:-}" ] && rpt "  Forkexec: $BH_FORK_RATE exec/s"
    if [ -n "${BH_PIPE_GBS:-}" ] || [ -n "${BH_PIPE4K_GBS:-}" ]; then
      _bx_sep=""; _bx_line="  Pipe IPC:"
      [ -n "${BH_PIPE_GBS:-}" ]   && { _bx_line="$_bx_line$_bx_sep $BH_PIPE_GBS GB/s"; _bx_sep=" |"; }
      [ -n "${BH_PIPE4K_GBS:-}" ] && { _bx_line="$_bx_line$_bx_sep 4k $BH_PIPE4K_GBS GB/s"; _bx_sep=" |"; }
      rpt "$_bx_line"
    fi
    [ -n "${BH_SMALLFILE_RATE:-}" ] && rpt "  Smallfile: $BH_SMALLFILE_RATE files/s (fs: ${BH_SMALLFILE_FS:-?})"
  fi

  # ---- [STORAGE] — module 55 passive topology map ----
  if [ -n "${BH_STORAGE_SUMMARY:-}" ] || [ -n "${BH_ROOT_STACK:-}" ]; then
    local _fst
    rpt ""
    rpt "[STORAGE] topology (passive map)"
    [ -n "${BH_STORAGE_SUMMARY:-}" ] && rpt "  Summary : $BH_STORAGE_SUMMARY"
    [ -n "${BH_ROOT_STACK:-}" ]      && rpt "  Root    : $BH_ROOT_STACK${BH_ROOT_CLASS:+ (class: $BH_ROOT_CLASS)}"
    [ -n "${BH_STORAGE_STACKS:-}" ]  && rpt "  Stacks  : $BH_STORAGE_STACKS"
    if [ -n "${BH_FS_TREE:-}" ]; then
      _fst="$BH_FS_TREE"
      [ "${#_fst}" -gt 200 ] && _fst="${_fst:0:200}…"
      rpt "  FStree  : $_fst"
    fi
    if [ -n "${BH_ZRAM:-}${BH_ZSWAP:-}${BH_SWAP_KIND:-}" ]; then
      rpt "  SwapKind: zram: ${BH_ZRAM:-n/a} · zswap: ${BH_ZSWAP:-n/a} · swap: ${BH_SWAP_KIND:-n/a}"
    fi
    [ -n "${BH_NVME_INFO:-}" ]   && rpt "  NVMe    : $BH_NVME_INFO"
    [ -n "${BH_DISK_MODELS:-}" ] && rpt "  Models  : host disks: $BH_DISK_MODELS"
  fi
  # ---- v5 storage extras (queue / mdraid / zfs / btrfs / lvm / smart / trim) ----
  bhv5c14_render_storage_extras

  # ---- [ENV] — module 25 capabilities & limits (renders when it ran) ----
  if [ -n "${BH_CAPS_CLASS:-}${BH_DEV_MAP:-}${BH_PIDS_MAX:-}${BH_PID1_LSM:-}${BH_CG_CONTROLLERS:-}${BH_RL_NOFILE:-}${BH_OOM_ADJ:-}" ]; then
    local _env_line
    rpt ""
    rpt "[ENV] capabilities & limits"
    if [ -n "${BH_CAPS_CLASS:-}" ]; then
      _env_line="  Caps    : $BH_CAPS_CLASS"
      [ -n "${BH_CAPS_MISSING:-}" ] && _env_line="$_env_line — $BH_CAPS_MISSING"
      [ "$BH_CAPS_CLASS" = "unprivileged" ] && _env_line="$_env_line → cannot mount/load-kernel"
      rpt "$_env_line"
    fi
    [ -n "${BH_PIDS_MAX:-}" ] && rpt "  Pids    : max $BH_PIDS_MAX, current ${BH_PIDS_CUR:-?}"
    if [ -n "${BH_PID1_LSM:-}" ] || [ -n "${BH_PID1_CMD:-}" ]; then
      rpt "  PID1    : lsm ${BH_PID1_LSM:-?} · cmd ${BH_PID1_CMD:-?}"
    fi
    if [ -n "${BH_RL_NOFILE:-}" ] || [ -n "${BH_RL_NPROC:-}" ]; then
      rpt "  Rlimits : nofile ${BH_RL_NOFILE:-n/a} · nproc ${BH_RL_NPROC:-n/a}"
    fi
    if [ -n "${BH_DEV_MAP:-}" ]; then
      _env_line="  Devs    : $BH_DEV_MAP"
      case "$BH_DEV_MAP" in *kvm:yes*) _env_line="$_env_line → can run KVM VMs" ;; esac
      case "$BH_DEV_MAP" in *tun:yes*) _env_line="$_env_line → VPN server possible" ;; esac
      rpt "$_env_line"
    fi
    [ -n "${BH_OOM_ADJ:-}${BH_OOM_SCORE:-}" ] && rpt "  OOM     : adj ${BH_OOM_ADJ:-?} · score ${BH_OOM_SCORE:-?}"
    [ -n "${BH_CG_CONTROLLERS:-}" ] && rpt "  Cgroup  : controllers: $BH_CG_CONTROLLERS"
  fi
  # ---- v5 container / runtime / pressure lines (module 25 + runtime extras) ----
  bhv5c14_render_env_extras

  if [ -n "$BH_IPV4$BH_IPV6$BH_IP_GEO$BH_IP_ASN${BH_GEO_CLO:-}${BH_LAT_MATRIX:-}${BH_NAT_MODE:-}${BH_DNS_MS:-}${BH_PACKET_LOSS:-}${BH_IPV6_GRADE:-}" ]; then
    rpt ""
    rpt "[4] LOCATION / NETWORK IDENTITY"
    [ -n "$BH_IPV4" ]   && rpt "  IPv4    : $BH_IPV4"
    [ -n "$BH_IPV6" ]   && rpt "  IPv6    : $BH_IPV6"
    [ -n "$BH_IP_GEO" ] && rpt "  Geo/ISP : $BH_IP_GEO"
    [ -n "$BH_IP_ASN" ] && rpt "  ASN     : $BH_IP_ASN"
    # ---- v4 geo/colo truth + NAT + ports + DNS + NIC honesty (module 60) ----
    local _egtxt=""
    [ -n "${BH_GEO_LOC:-}" ]    && _egtxt="egress: $BH_GEO_LOC"
    [ -n "${BH_GEO_CLO:-}" ]    && _egtxt="${_egtxt:+$_egtxt · }CF colo: $BH_GEO_CLO"
    [ -n "${BH_IP_ASN:-}" ]     && _egtxt="${_egtxt:+$_egtxt · }ASN: $BH_IP_ASN"
    [ -n "${BH_LAT_MATRIX:-}" ] && _egtxt="${_egtxt:+$_egtxt · }region matrix: $BH_LAT_MATRIX"
    [ -n "$_egtxt" ] && rpt "  $_egtxt"
    if [ -n "${BH_NAT_MODE:-}" ] && [ "${BH_NAT_MODE:-}" != "unknown" ]; then
      local _natline="  NAT     : $BH_NAT_MODE"
      case "$BH_NAT_MODE" in
        nat*|cgnat*) _natline="$_natline → no inbound ports (mail/web hosting needs port-forward)" ;;
      esac
      rpt "$_natline"
    fi
    local _ports="" _pp _pv
    for _pp in "25:${BH_PORT_25:-}" "465:${BH_PORT_465:-}" "587:${BH_PORT_587:-}" "1194:${BH_PORT_1194:-}" "51820:${BH_PORT_51820:-}"; do
      _pv="${_pp#*:}"
      [ -n "$_pv" ] && _ports="$_ports ${_pp%%:*}:$_pv"
    done
    [ -n "$_ports" ] && rpt "  Ports   : outbound$_ports"
    [ -n "${BH_DNS_MS:-}" ] && rpt "  DNS     : ${BH_DNS_MS} ms (${BH_DNS_TAG:-resolver})"
    if [ -n "${BH_NIC_DRIVER:-}" ] && [ "${BH_NIC_DRIVER:-}" != "unknown" ]; then
      local _nicline="  NIC     : driver $BH_NIC_DRIVER${BH_NIC_QUEUES:+, queues $BH_NIC_QUEUES}${BH_NIC_OFFLOADS:+, offloads: $BH_NIC_OFFLOADS}"
      case "$BH_NIC_DRIVER" in
        e1000|rtl8139|pcnet) _nicline="$_nicline ← emulated NIC, 2-5x slower than virtio" ;;
      esac
      rpt "$_nicline"
    fi
    case "${BH_PACKET_LOSS:-}" in
      "") : ;;
      *%) rpt "  Loss    : $BH_PACKET_LOSS packet loss" ;;
      *)  rpt "  Loss    : $BH_PACKET_LOSS" ;;
    esac
    [ -n "${BH_IPV6_GRADE:-}" ] && rpt "  IPv6    : grade $BH_IPV6_GRADE"
  fi
  # ---- v5 net extras (skew / egress / PTR / PMTU / DNS / jitter / TLS) ----
  bhv5c14_render_net_extras

  rpt ""
  if [ "${BH_SEC_SKIPPED:-0}" = "1" ]; then
    rpt "[5] SSH & SECURITY AUDIT — skipped (--no-sec or detect mode)"
  else
    rpt "[5] SSH & SECURITY AUDIT (scope: this machine only)"
    local n_sec=0 secl post_line=""
    [ "${#BH_SEC_LINES[@]}" -gt 0 ] 2>/dev/null && n_sec=${#BH_SEC_LINES[@]}
    if [ "$n_sec" -gt 0 ]; then
      # keep the [POST] posture summary as the final audit line:
      # audit body -> v3 deep-scan extras -> posture
      case "${BH_SEC_LINES[$((n_sec - 1))]}" in
        "  [POST]"*) post_line="${BH_SEC_LINES[$((n_sec - 1))]}"; n_sec=$((n_sec - 1)) ;;
      esac
      for secl in "${BH_SEC_LINES[@]:0:$n_sec}"; do rpt "$secl"; done
    else
      rpt "  [INFO]  no audit data"
    fi
    sec_report_extras
    if [ "${#BH_SEC_EXTRA_LINES[@]}" -gt 0 ] 2>/dev/null; then
      for secl in "${BH_SEC_EXTRA_LINES[@]}"; do rpt "$secl"; done
    fi
    [ -n "$post_line" ] && rpt "$post_line"
  fi

  rpt ""
  if [ "${BH_BENCH_SKIPPED:-0}" = "1" ]; then
    rpt "[6] BH-SCORE — n/a (no benchmark in $BH_MODE mode)"
  else
    rpt "[6] BH-SCORE"
    rpt "  CPU 1-core ${BH_SCORE_CPU1C}/100 | CPU multi ${BH_SCORE_CPUMC}/100 | Memory ${BH_SCORE_MEM}/100"
    rpt "  Disk seq ${BH_SCORE_DSEQ}/100 | Disk 4k ${BH_SCORE_D4K}/100 | Net down ${BH_SCORE_NDOWN}/100 | Net up ${BH_SCORE_NUP}/100"
    # bar gauges — bh_gauge comes from 00-core (another owner); when it is
    # absent BH_GAUGE_OK=0 and these rows are skipped silently.
    if [ "$BH_GAUGE_OK" = "1" ]; then
      bh_score_gauge_line "CPU 1c"   "$BH_SCORE_CPU1C"
      bh_score_gauge_line "CPU mul"  "$BH_SCORE_CPUMC"
      bh_score_gauge_line "Memory"   "$BH_SCORE_MEM"
      bh_score_gauge_line "Disk seq" "$BH_SCORE_DSEQ"
      bh_score_gauge_line "Disk 4k"  "$BH_SCORE_D4K"
      bh_score_gauge_line "Net down" "$BH_SCORE_NDOWN"
      bh_score_gauge_line "Net up"   "$BH_SCORE_NUP"
    fi
    if [ -n "$BH_GRADE" ]; then
      rpt "  TOTAL: $BH_SCORE_TOTAL / $BH_SCORE_MAX (grade $BH_GRADE)"
    else
      rpt "  TOTAL: $BH_SCORE_TOTAL / $BH_SCORE_MAX"
    fi
    rpt "  grade S >=630 | A >=525 | B >=420 | C >=315 | D >=210 | F below"
  fi

  # ---- oversell verdict (wow#1) — pure render logic, rendered under BH-SCORE
  bh_oversell_verdict
  case "$BH_OVERSELL" in
    LIKELY*)   rpt "  [BAD]  Oversell: $BH_OVERSELL" ;;
    POSSIBLE*) rpt "  [WARN] Oversell: $BH_OVERSELL" ;;
    *)         rpt "  [OK]   Oversell: $BH_OVERSELL" ;;
  esac
  # ---- run-to-run compare — jq/python3, rendered right after the score section
  render_compare
  # ---- v5 truth strip — machine-greppable one-liner right after the scores ----
  bhv5c14_truth_strip
  [ -n "${BH_TRUTH:-}" ] && rpt "  ${BH_TRUTH:-}"
  # ---- v5 [T] TOP TIPS — top 3 actionable fixes (engine in 63-tips.sh) ----
  bhv5c14_render_tips_section

  rpt ""
  rpt "generated $(date -u '+%Y-%m-%d %H:%M:%S UTC') by $BH_TOOL v$BH_VERSION"
  # ---- share card (wow#9) — one compact line at the very end of the report
  [ -n "${BH_SHARE_CARD:-}" ] && rpt "  share: $BH_SHARE_CARD"
  # ---- v5 fingerprint tag — sanitized single-line machine tag ----
  bh_fingerprint
  [ -n "${BH_FINGERPRINT:-}" ] && rpt "  tag: ${BH_FINGERPRINT:-}"

  # ---- Prometheus textfile export (guarded; atomic tmp+mv inside build_prom)
  if [ -n "${BH_PROM_OUT:-}" ] && [ -n "${BH_PROM_OUT#-}" ]; then
    build_prom
  fi
  # ---- v5 sinks: shields.io badge JSON + static SVG gauge (atomic inside) ----
  if [ -n "${BH_BADGE_OUT:-}" ] && [ -n "${BH_BADGE_OUT#-}" ]; then
    build_badge
  fi
  if [ -n "${BH_SVG_OUT:-}" ] && [ -n "${BH_SVG_OUT#-}" ]; then
    build_svg
  fi
}

print_report() {
  if [ -n "$BH_TXT_OUT" ] && [ "$BH_TXT_OUT" != "-" ]; then
    printf '%s\n' "${bh_lines[@]}" > "$BH_TXT_OUT"
    log "text report written to $BH_TXT_OUT"
  fi
  # banner in color on TTY, then the body (badges/headers colorized on TTY)
  if [ -n "$C_CYN" ]; then
    printf '%s%s%s\n' "$C_B$C_CYN" "${bh_lines[0]}" "$C_RST"
  else
    printf '%s\n' "${bh_lines[0]}"
  fi
  local _pl
  for _pl in "${bh_lines[@]:1}"; do print_line_color "$_pl"; done
}

# ---------------------------------------------------------------- JSON
build_json() {
  bh_redact_sink
  bh_compute_verdicts
  local ev_json="" first=1 ev
  while IFS= read -r ev; do
    [ -z "$ev" ] && continue
    if [ "$first" = "1" ]; then first=0; else ev_json="$ev_json,"; fi
    ev_json="$ev_json\"$(json_esc "$ev")\""
  done <<EOF2
$BH_EVIDENCE
EOF2

  local skipped
  if [ "${BH_BENCH_SKIPPED:-0}" = "1" ]; then skipped=true; else skipped=false; fi
  local netskipped
  if [ "$BH_NO_NET" = "1" ]; then netskipped=true; else netskipped=false; fi

  printf '{'
  printf '"tool":"%s","version":"%s","generated_at":"%s","mode":"%s",' \
    "$(json_esc "$BH_TOOL")" "$(json_esc "$BH_VERSION")" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(json_esc "$BH_MODE")"
  printf '"hostname":%s,' "$(json_val "$BH_HOSTNAME")"
  printf '"virtualization":{"kind":%s,"type":%s,"product":%s,"host_type":%s,"host_product":%s,"cloud":%s,"cloud_detail":%s,"evidence":[%s],' \
    "$(json_val "$BH_KIND")" "$(json_val "$BH_TYPE")" "$(json_val "$BH_PRODUCT")" \
    "$(json_val "$BH_HOST_TYPE")" "$(json_val "$BH_HOST_PRODUCT")" \
    "$(json_val "$BH_CLOUD")" "$(json_val "$BH_CLOUD_DETAIL")" "$ev_json"
  printf '"chassis_type":%s,"chassis_class":%s,"wsl_gen":%s,"is_chroot":%s,"aws_gen":%s,"cloud_method":%s,' \
    "$(json_val "${BH_CHASSIS_TYPE:-}")" "$(json_val "${BH_CHASSIS_CLASS:-}")" "$(json_val "${BH_WSL_GEN:-}")" \
    "$(json_val "${BH_IS_CHROOT:-}")" "$(json_val "${BH_AWS_GEN:-}")" "$(json_val "${BH_CLOUD_METHOD:-}")"
  printf '"nested":%s,"conf_computing":%s,"irq_vmm":%s,"virtio_devices":%s,"chassis_weak":%s},' \
    "$(json_val "${BH_VIRT_NESTED:-}")" "$(json_val "${BH_CONF_COMPUTING:-}")" "$(json_val "${BH_IRQ_VMM:-}")" \
    "$(json_val "${BH_VIRTIO_DEVS:-}")" "$(json_val "${BH_CHASSIS_WEAK:-0}")"
  printf '"system":{"os":%s,"kernel":%s,"arch":%s,"uptime":%s,"steal_pct":%s,"net_mtu":%s,' \
    "$(json_val "$BH_OS")" "$(json_val "$BH_KERNEL")" "$(json_val "$BH_ARCH")" "$(json_val "$BH_UPTIME")" \
    "$(json_val "${BH_STEAL_PCT:-}")" "$(json_val "${BH_NET_MTU:-}")"
  printf '"vuln_worst":%s,"vuln_scope":%s,' \
    "$(json_val "${BH_VULN_WORST:-}")" "$(json_val "${BH_VULN_SCOPE:-}")"
  printf '"cpu":{"model":%s,"logical_cores":%s,"physical_cores":%s,"effective_cores":%s,"features":%s,"cpu_freq_mhz":%s,' \
    "$(json_val "$BH_CPU_MODEL")" "$(json_val "$BH_CPU_LOGICAL")" "$(json_val "$BH_CPU_PHYS")" "$(json_val "$BH_EFF_CORES")" "$(json_val "$BH_CPU_FLAGS_HI")" "$(json_val "${BH_CPU_FREQ_MHZ:-}")"
  printf '"ai_features":%s,"crypto_features":%s,"microcode":%s,"stepping":%s,' \
    "$(json_val "${BH_CPU_AI_FEAT:-}")" "$(json_val "${BH_CPU_CRYPTO_FEAT:-}")" \
    "$(json_val "${BH_CPU_UCODE:-}")" "$(json_val "${BH_CPU_STEPPING:-}")"
  printf '"bash_ops":%s,"awk_ops":%s,"steal_under_load":%s,"input_src":%s},' \
    "$(json_val "${BH_BASH_OPS:-}")" "$(json_val "${BH_AWK_OPS:-}")" \
    "$(json_val "${BH_STEAL_UNDER_LOAD:-}")" "$(json_val "${BH_CPU_INPUT_SRC:-}")"
  printf '"memory":{"total_mb":%s,"available_mb":%s,"swap_mb":%s,"thp":%s,"hugepages":%s,"swap":%s,"ksm":%s}},' \
    "$(json_val "$BH_MEM_TOTAL_MB")" "$(json_val "$BH_MEM_AVAIL_MB")" "$(json_val "$BH_MEM_SWAP_MB")" \
    "$(json_val "${BH_THP:-}")" "$(json_val "${BH_HUGEPAGES_TOTAL:-}")" "$(json_val "${BH_SWAP_DETAIL:-}")" \
    "$(json_val "${BH_KSM_STATE:-}")"
  printf '"limits":{"cgroup_version":%s,"cpu_quota_cores":%s,"memory_limit_mb":%s,"cpuset":%s,"cpuset_cores":%s},' \
    "$(json_val "$CG_VER")" "$(json_val "$BH_CPU_QUOTA_TXT")" "$(json_val "$BH_MEM_LIMIT_MB")" "$(json_val "$CPUSET")" "$(json_val "${BH_CPUSET_N:-}")"
  printf '"net_env":{"tcp_cc":%s,"tcp_cc_available":%s,"dns":%s,"entropy":%s,"tun":%s,"fuse":%s,"ppp":%s,"load":%s,"processes":%s},' \
    "$(json_val "$BH_TCPCC")" "$(json_val "$BH_TCPCC_AVAIL")" "$(json_val "$BH_DNS")" "$(json_val "$BH_ENTROPY")" \
    "$(json_val "$BH_TUN")" "$(json_val "$BH_FUSE")" "$(json_val "$BH_PPP")" "$(json_val "$BH_LOAD")" "$(json_val "$BH_PROCS")"
  # ---- v4: GPU (module 15, optional — object emitted only when it ran) ----
  if [ -n "${BH_GPU_SUMMARY:-}${BH_GPU_PCI:-}${BH_GPU_NVIDIA:-}${BH_GPU_MIG:-}${BH_GPU_VRAM_SYSFS:-}${BH_GPU_VRAM:-}${BH_GPU_LIBS:-}${BH_GPU_PASSTHROUGH:-}${BH_GPU_NODES:-}" ]; then
    printf '"gpu":{"summary":%s,"pci":%s,"nvidia":%s,"mig":%s,"vram_sysfs":%s,"libs":%s,"passthrough":%s,"nodes":%s},' \
      "$(json_val "${BH_GPU_SUMMARY:-}")" "$(json_val "${BH_GPU_PCI:-}")" "$(json_val "${BH_GPU_NVIDIA:-}")" \
      "$(json_val "${BH_GPU_MIG:-}")" "$(json_val "${BH_GPU_VRAM_SYSFS:-${BH_GPU_VRAM:-}}")" \
      "$(json_val "${BH_GPU_LIBS:-}")" "$(json_val "${BH_GPU_PASSTHROUGH:-}")" "$(json_val "${BH_GPU_NODES:-}")"
  fi
  # ---- v4: network truth (module 60 — geo/colo, NAT, ports, DNS, NIC) ----
  if [ -n "${BH_GEO_LOC:-}${BH_GEO_CLO:-}${BH_NET_CLO:-}${BH_LAT_MATRIX:-}${BH_NAT_MODE:-}${BH_DNS_MS:-}${BH_PACKET_LOSS:-}${BH_IPV6_GRADE:-}${BH_PORT_25:-}${BH_NIC_DRIVER:-}" ]; then
    printf '"network":{"geo_loc":%s,"geo_clo":%s,"net_clo":%s,"asn":%s,' \
      "$(json_val "${BH_GEO_LOC:-}")" "$(json_val "${BH_GEO_CLO:-}")" "$(json_val "${BH_NET_CLO:-}")" "$(json_val "${BH_IP_ASN:-}")"
    printf '"nat_mode":%s,"nat_iface":%s,"lat_matrix":%s,' \
      "$(json_val "${BH_NAT_MODE:-}")" "$(json_val "${BH_NAT_IFACE:-}")" "$(json_val "${BH_LAT_MATRIX:-}")"
    printf '"port_25":%s,"port_465":%s,"port_587":%s,"port_1194":%s,"port_51820":%s,' \
      "$(json_val "${BH_PORT_25:-}")" "$(json_val "${BH_PORT_465:-}")" "$(json_val "${BH_PORT_587:-}")" \
      "$(json_val "${BH_PORT_1194:-}")" "$(json_val "${BH_PORT_51820:-}")"
    printf '"dns_ms":%s,"dns_tag":%s,"nic_driver":%s,"nic_queues":%s,"nic_offloads":%s,' \
      "$(json_val "${BH_DNS_MS:-}")" "$(json_val "${BH_DNS_TAG:-}")" "$(json_val "${BH_NIC_DRIVER:-}")" \
      "$(json_val "${BH_NIC_QUEUES:-}")" "$(json_val "${BH_NIC_OFFLOADS:-}")"
    printf '"packet_loss":%s,"ipv6_grade":%s},' \
      "$(json_val "${BH_PACKET_LOSS:-}")" "$(json_val "${BH_IPV6_GRADE:-}")"
  fi
  # ---- v4: environment deep-dive (module 25 — object only when it ran) ----
  if [ -n "${BH_CAPS_CLASS:-}${BH_DEV_MAP:-}${BH_PIDS_MAX:-}${BH_PID1_LSM:-}${BH_CG_CONTROLLERS:-}${BH_RL_NOFILE:-}${BH_OOM_ADJ:-}" ]; then
    printf '"env":{"caps_class":%s,"caps_eff":%s,"caps_missing":%s,' \
      "$(json_val "${BH_CAPS_CLASS:-}")" "$(json_val "${BH_CAPS_EFF:-}")" "$(json_val "${BH_CAPS_MISSING:-}")"
    printf '"pids_max":%s,"pids_cur":%s,"nnp":%s,"pid1_lsm":%s,"pid1_cmd":%s,' \
      "$(json_val "${BH_PIDS_MAX:-}")" "$(json_val "${BH_PIDS_CUR:-0}")" "$(json_val "${BH_NNP:-}")" \
      "$(json_val "${BH_PID1_LSM:-}")" "$(json_val "${BH_PID1_CMD:-}")"
    printf '"rl_nofile":%s,"rl_nproc":%s,"dev_map":%s,"shm_mb":%s,"oom_adj":%s,"cg_controllers":%s},' \
      "$(json_val "${BH_RL_NOFILE:-}")" "$(json_val "${BH_RL_NPROC:-}")" "$(json_val "${BH_DEV_MAP:-}")" \
      "$(json_val "${BH_SHM_MB:-}")" "$(json_val "${BH_OOM_ADJ:-}")" "$(json_val "${BH_CG_CONTROLLERS:-}")"
  fi
  printf '"disk":{"dir":%s,"device":%s,"fs":%s,"total_mb":%s,"available_mb":%s,"disk_class":%s,"disk_scheduler":%s,"disk_rotational":%s},' \
    "$(json_val "$BH_DISK_DIR")" "$(json_val "$BH_DISK_DEV")" "$(json_val "$BH_DISK_FS")" "$(json_val "$BH_DISK_TOTAL_MB")" "$(json_val "$BH_DISK_AVAIL_MB")" \
    "$(json_val "${BH_DISK_CLASS:-}")" "$(json_val "${BH_DISK_SCHED:-}")" "$(json_val "${BH_DISK_ROTA:-}")"
  printf '"bench":{"skipped":%s,' "$skipped"
  printf '"cpu":{"sha256_1c_mbps":%s,"sha256_mc_mbps":%s,"threads":%s,"openssl_sha256_kbs":%s,"efficiency_pct":%s},' \
    "$(json_val "$(num_or_0 "$BH_SHA1C")")" "$(json_val "$(num_or_0 "$BH_SHANC")")" "$(json_val "$BH_PAR_JOBS")" "$(json_val "$BH_OPENSSL_K")" "$(json_val "${BH_CPU_EFFICIENCY:-}")"
  printf '"memory":{"gbps":%s,"method":%s},' "$(json_val "$(num_or_0 "$BH_MEM_GBS")")" "$(json_val "$BH_MEM_METHOD")"
  printf '"disk":{"mode":%s,"seq_write_mbps":%s,"seq_read_mbps":%s,"k4_write_mbps":%s,"k4_read_mbps":%s,"fio_randread_iops":%s,"fio_randwrite_iops":%s,"iops_4k_write":%s,"iops_4k_read":%s,' \
    "$(json_val "$BH_DISK_MODE")" "$(json_val "$(num_or_0 "$BH_SEQW")")" "$(json_val "$(num_or_0 "$BH_SEQR")")" \
    "$(json_val "$(num_or_0 "$BH_4KW")")" "$(json_val "$(num_or_0 "$BH_4KR")")" \
    "$(json_val "$(num_or_0 "$BH_FIO_RIOPS")")" "$(json_val "$(num_or_0 "$BH_FIO_WIOPS")")" \
    "$(json_val "${BH_4K_IOPS_W:-}")" "$(json_val "${BH_4K_IOPS_R:-}")"
  printf '"lat_p50_ms":%s,"lat_p90_ms":%s,"lat_p99_ms":%s,"lat_label":%s,' \
    "$(json_val "${BH_4K_LAT_P50_MS:-}")" "$(json_val "${BH_4K_LAT_P90_MS:-}")" \
    "$(json_val "${BH_4K_LAT_P99_MS:-}")" "$(json_val "${BH_4K_LAT_LABEL:-}")"
  printf '"live_iops":%s,"live_mbps":%s,"live_busy_pct":%s,"live_dev":%s,' \
    "$(json_val "${BH_LIVE_IOPS:-}")" "$(json_val "${BH_LIVE_MBPS:-}")" \
    "$(json_val "${BH_LIVE_BUSY_PCT:-}")" "$(json_val "${BH_LIVE_DEV:-}")"
  printf '"trim_support":%s,"discard_mount":%s,"bench_fs":%s},' \
    "$(json_val "${BH_TRIM_SUPPORT:-}")" "$(json_val "${BH_DISCARD_MOUNT:-}")" "$(json_val "${BH_DISK_BENCH_FS:-}")"
  printf '"extra":{"aes_gcm_mbps":%s,"chacha_mbps":%s,"aes_method":%s,' \
    "$(json_val "${BH_AES_GCM_MBPS:-}")" "$(json_val "${BH_CHACHA_MBPS:-}")" "$(json_val "${BH_AES_METHOD:-}")"
  printf '"gzip_mbps":%s,"zstd_mbps":%s,"fork_rate":%s,' \
    "$(json_val "${BH_GZIP_MBPS:-}")" "$(json_val "${BH_ZSTD_MBPS:-}")" "$(json_val "${BH_FORK_RATE:-}")"
  printf '"pipe_gbs":%s,"pipe4k_gbs":%s,' \
    "$(json_val "${BH_PIPE_GBS:-}")" "$(json_val "${BH_PIPE4K_GBS:-}")"
  printf '"smallfile_rate":%s,"smallfile_fs":%s},' \
    "$(json_val "${BH_SMALLFILE_RATE:-}")" "$(json_val "${BH_SMALLFILE_FS:-}")"
  printf '"network":{"skipped":%s,"method":%s,"download_mbps":%s,"upload_mbps":%s,"connect_ms":%s,"icmp_latency_ms":%s,"icmp_jitter_ms":%s,' \
    "$netskipped" "$(json_val "$BH_NET_METHOD")" "$(json_val "$(num_or_0 "$BH_DOWN_MBPS")")" \
    "$(json_val "$(num_or_0 "$BH_UP_MBPS")")" "$(json_val "$(num_or_0 "$BH_LAT_MS")")" \
    "$(json_val "$(num_or_0 "$BH_LAT_ICMP")")" "$(json_val "$(num_or_0 "$BH_LAT_JITTER")")"
  printf '"endpoint":%s,"attempts":%s,"ipv4":%s,"ipv6":%s,"geo":%s,"asn":%s}},' \
    "$(json_val "${BH_NET_ENDPOINT:-}")" "$(json_val "${BH_NET_TRIES:-}")" \
    "$(json_val "$BH_IPV4")" "$(json_val "$BH_IPV6")" "$(json_val "$BH_IP_GEO")" "$(json_val "$BH_IP_ASN")"
  if [ "${BH_SEC_SKIPPED:-0}" = "1" ]; then
    printf '"security":{"skipped":true},'
  else
    printf '"security":{"sshd_found":%s,"password_auth":%s,"pubkey_auth":%s,"root_login":%s,"ports":%s,' \
      "$(json_val "$BH_SSH_FOUND")" "$(json_val "${BH_SSH_PWDAUTH:-unset}")" "$(json_val "${BH_SSH_PUBKEY:-unset}")" \
      "$(json_val "${BH_SSH_ROOTLOGIN:-default}")" "$(json_val "$BH_SSH_PORTS")"
    printf '"authorized_keys":%s,"key_types":%s,"weak_keys":%s,"failed_logins":%s,' \
      "$(json_val "$BH_AK_TOTAL")" "$(json_val "$BH_AK_TYPES")" "$(json_val "$BH_AK_WEAK")" "$(json_val "$BH_SSH_FAILS")"
    printf '"firewall":%s,"fail2ban":%s,"uid0_accounts":%s,"empty_passwords":%s,"sudo_nopasswd":%s,' \
      "$(json_val "$BH_FW")" "$(json_val "$BH_F2B")" "$(json_val "${BH_UID0:-unknown}")" "$(json_val "$BH_EMPTY_PW")" "$(json_val "$BH_SUDO_NOPASS")"
    printf '"aslr":%s,"auto_updates":%s,"listening_ports":%s,' \
      "$(json_val "$BH_ASLR")" "$(json_val "$BH_AUTO_UPD")" "$(json_val "$BH_LISTEN")"
    printf '"sshd_version":%s,"sshd_running":%s,"permit_empty_passwords":%s,"login_grace_time":%s,"x11_forwarding":%s,"allow_users":%s,"auth_key_perm_issues":%s,' \
      "$(json_val "${BH_SSH_VERSION:-}")" "$(json_val "${BH_SSH_RUNNING:-}")" "$(json_val "${BH_SSH_PERMPTY:-}")" \
      "$(json_val "${BH_SSH_LOGINGRACE:-}")" "$(json_val "${BH_SSH_X11:-}")" "$(json_val "${BH_SSH_ALLOWUSERS:-}")" \
      "$(json_val "${BH_AK_PERM_BAD:-}")"
    printf '"mac":%s,"updates":%s,"updates_n":%s,"risky_ports":%s,"miners":%s,"docker_sock":%s,' \
      "$(json_val "${BH_MAC:-}")" "$(json_val "${BH_UPDATES:-}")" "$(json_val "${BH_UPDATES_N:-}")" \
      "$(json_val "${BH_RISKY_PORTS:-}")" "$(json_val "${BH_MINERS:-}")" "$(json_val "${BH_DOCKER_SOCK:-}")"
    printf '"sysctl":{"kptr_restrict":%s,"dmesg_restrict":%s,"unprivileged_bpf":%s,"yama_ptrace":%s},"tmp_opts":%s,"timers":%s,"cron_files":%s,"sshguard":%s,"crowdsec":%s,' \
      "$(json_val "${BH_SYSCTL_KPTR:-}")" "$(json_val "${BH_SYSCTL_DMESG:-}")" "$(json_val "${BH_SYSCTL_BPF:-}")" "$(json_val "${BH_SYSCTL_YAMA:-}")" \
      "$(json_val "${BH_TMP_OPTS:-}")" "$(json_val "${BH_TIMERS_N:-}")" "$(json_val "${BH_CRON_N:-}")" \
      "$(json_val "${BH_SSHGUARD:-}")" "$(json_val "${BH_CROWDSEC:-}")"
    printf '"weak_crypto":%s,"ciphers":%s,"kex":%s,"maxstartups":%s,"alive":%s,"authkeys_path":%s,' \
      "$(json_val "${BH_SEC_WEAK_CRYPTO:-}")" "$(json_val "${BH_SEC_CIPHERS:-}")" "$(json_val "${BH_SEC_KEX:-}")" \
      "$(json_val "${BH_SEC_MAXSTARTUPS:-}")" "$(json_val "${BH_SEC_ALIVE:-}")" "$(json_val "${BH_SEC_AUTHKEYS_PATH:-}")"
    printf '"pam_pw":%s,"pass_max_days":%s,"root_expire":%s,"auditd":%s,"ntp":%s,"banner":%s,' \
      "$(json_val "${BH_SEC_PAM_PW:-}")" "$(json_val "${BH_SEC_PASS_MAX_DAYS:-}")" "$(json_val "${BH_SEC_ROOT_EXPIRE:-}")" \
      "$(json_val "${BH_SEC_AUDITD:-}")" "$(json_val "${BH_SEC_NTP:-}")" "$(json_val "${BH_SEC_BANNER:-}")"
    printf '"path_world_writable":%s,"suid_count":%s,"suid_odd":%s,"core_dumps":%s,"protected_sysctl":%s,' \
      "$(json_val "${BH_SEC_PATH_WW:-}")" "$(json_val "${BH_SEC_SUID_COUNT:-}")" "$(json_val "${BH_SEC_SUID_ODD:-}")" \
      "$(json_val "${BH_SEC_CORE:-}")" "$(json_val "${BH_SEC_PROTECTED_SYSCTL:-}")"
    printf '"legacy_pkgs":%s,"sudo_ver":%s,"pkexec_ver":%s,"umask":%s,"forensics":%s,' \
      "$(json_val "${BH_SEC_LEGACY_PKGS:-}")" "$(json_val "${BH_SEC_SUDO_VER:-}")" "$(json_val "${BH_SEC_PKEXEC_VER:-}")" \
      "$(json_val "${BH_SEC_UMASK:-}")" "$(json_val "${BH_SEC_FORENSICS:-}")"
    printf '"pass":%s,"warn":%s,"bad":%s,"posture":%s},' \
      "$(json_val "$BH_SEC_PASS")" "$(json_val "$BH_SEC_WARN")" "$(json_val "$BH_SEC_BAD")" "$(json_val "$BH_SEC_POSTURE")"
  fi
  # top-level convenience mirror of the system.cpu v4 fields (the v4 suite
  # asserts .cpu.ai_features at the top level; system.cpu stays canonical)
  printf '"cpu":{"ai_features":%s,"crypto_features":%s,"microcode":%s,"stepping":%s,"bash_ops":%s,"awk_ops":%s,"steal_under_load":%s,"input_src":%s},' \
    "$(json_val "${BH_CPU_AI_FEAT:-}")" "$(json_val "${BH_CPU_CRYPTO_FEAT:-}")" \
    "$(json_val "${BH_CPU_UCODE:-}")" "$(json_val "${BH_CPU_STEPPING:-}")" \
    "$(json_val "${BH_BASH_OPS:-}")" "$(json_val "${BH_AWK_OPS:-}")" \
    "$(json_val "${BH_STEAL_UNDER_LOAD:-}")" "$(json_val "${BH_CPU_INPUT_SRC:-}")"
  printf '"score":{"cpu_1c":%s,"cpu_multi":%s,"memory":%s,"disk_seq":%s,"disk_4k":%s,"net_down":%s,"net_up":%s,"total":%s,"max":%s,"grade":%s,"oversell":%s,"share_card":%s},' \
    "$(json_val "$BH_SCORE_CPU1C")" "$(json_val "$BH_SCORE_CPUMC")" "$(json_val "$BH_SCORE_MEM")" \
    "$(json_val "$BH_SCORE_DSEQ")" "$(json_val "$BH_SCORE_D4K")" "$(json_val "$BH_SCORE_NDOWN")" \
    "$(json_val "$BH_SCORE_NUP")" "$(json_val "$BH_SCORE_TOTAL")" "$(json_val "$BH_SCORE_MAX")" "$(json_val "$BH_GRADE")" \
    "$(json_val "${BH_OVERSELL:-}")" "$(json_val "${BH_SHARE_CARD:-}")"
  # ---- v5 extras (C14): speccheck / container / hardware objects ----
  if [ -n "${BH_SPEC_SUMMARY:-}${BH_SPEC_CPU_V:-}${BH_SPEC_RAM_V:-}${BH_SPEC_BURST:-}" ]; then
    printf '"speccheck":{"summary":%s,"cpu":%s,"ram":%s,"burst":%s},' \
      "$(json_val "${BH_SPEC_SUMMARY:-}")" "$(json_val "${BH_SPEC_CPU_V:-}")" \
      "$(json_val "${BH_SPEC_RAM_V:-}")" "$(json_val "${BH_SPEC_BURST:-}")"
  fi
  if [ -n "${BH_UIDMAP_MODE:-}${BH_SECCOMP_MODE:-}${BH_PSI_TXT:-}${BH_RT_NAME:-}${BH_ORCH:-}${BH_RT_CTR_ID:-}${BH_K8S_CTX:-}${BH_SA_TXT:-}${BH_POD_UID:-}${BH_PROJ_VOL:-}${BH_NS_FP:-}" ]; then
    printf '"container":{"uidmap_mode":%s,"seccomp":%s,"psi":%s,"runtime":%s,"orchestrator":%s,"container_id":%s,"k8s_context":%s,"service_account":%s,"pod_uid":%s,"projected_volume":%s,"ns_fingerprint":%s},' \
      "$(json_val "${BH_UIDMAP_MODE:-}")" "$(json_val "${BH_SECCOMP_MODE:-}")" "$(json_val "${BH_PSI_TXT:-}")" \
      "$(json_val "${BH_RT_NAME:-}")" "$(json_val "${BH_ORCH:-}")" "$(json_val "${BH_RT_CTR_ID:-}")" \
      "$(json_val "${BH_K8S_CTX:-}")" "$(json_val "${BH_SA_TXT:-}")" "$(json_val "${BH_POD_UID:-}")" \
      "$(json_val "${BH_PROJ_VOL:-}")" "$(json_val "${BH_NS_FP:-}")"
  fi
  if [ -n "${BH_CACHE_TXT:-}${BH_BLOCKQ_TXT:-}${BH_NUMA_TXT:-}${BH_NUMA_OFFLINE:-}${BH_CPUFREQ_TXT:-}${BH_THERMAL_TXT:-}${BH_THROTTLE_CNT:-}${BH_HWERR_TXT:-}${BH_DIMM_TXT:-}" ]; then
    printf '"hardware":{"cache":%s,"block_queue":%s,"numa":%s,"numa_offline":%s,"cpufreq":%s,"thermal":%s,"throttle_events":%s,"hw_errors":%s,"dimm":%s},' \
      "$(json_val "${BH_CACHE_TXT:-}")" "$(json_val "${BH_BLOCKQ_TXT:-}")" "$(json_val "${BH_NUMA_TXT:-}")" \
      "$(json_val "${BH_NUMA_OFFLINE:-}")" "$(json_val "${BH_CPUFREQ_TXT:-}")" "$(json_val "${BH_THERMAL_TXT:-}")" \
      "$(json_val "${BH_THROTTLE_CNT:-}")" "$(json_val "${BH_HWERR_TXT:-}")" "$(json_val "${BH_DIMM_TXT:-}")"
  fi
  # ---- v5 numeric extras — flat keys, emitted only for clean numbers ----
  bhv5c14_json_num mem_lat_ns   "${BH_MEM_LAT_NS:-}"
  bhv5c14_json_num pipe_us      "${BH_PIPE_US:-}"
  bhv5c14_json_num stat_kps     "${BH_STAT_KPS:-}"
  bhv5c14_json_num sqlite_rps   "${BH_SQLITE_RPS:-}"
  bhv5c14_json_num fsync_p50_ms "${BH_FSYNC_P50_MS:-}"
  bhv5c14_json_num fsync_p99_ms "${BH_FSYNC_P99_MS:-}"
  bhv5c14_json_num throttle_pct "${BH_THROTTLE_PCT:-}"
  bhv5c14_json_num tls_ms       "${BH_TLS_MS:-}"
  bhv5c14_json_num clock_skew_s "${BH_CLOCK_SKEW_S:-}"
  bhv5c14_json_num pmtu         "${BH_PMTU:-}"
  # ---- v5 tips array (full list) + fingerprint + truth (closing keys) ----
  if declare -F bh_tips_engine >/dev/null 2>&1; then
    bh_tips_engine
  fi
  local _tip _tips_json="" _tsep=""
  if [ -n "${BH_TIPS:-}" ]; then
    while IFS= read -r _tip; do
      [ -n "$_tip" ] || continue
      _tips_json="${_tips_json}${_tsep}\"$(json_esc "$_tip")\""
      _tsep=","
    done <<BHV5C14JSONTIPS
${BH_TIPS:-}
BHV5C14JSONTIPS
  fi
  printf '"tips":[%s],' "$_tips_json"
  bh_fingerprint
  bhv5c14_truth_strip
  printf '"fingerprint":%s,"truth":%s}' \
    "$(json_val "${BH_FINGERPRINT:-}")" "$(json_val "${BH_TRUTH:-}")"
}

# ---------------------------------------------------------------- Markdown
build_markdown() {
  bh_redact_sink
  bh_compute_verdicts
  printf '# BLACKHOLE VPS BENCH v%s\n\n' "$BH_VERSION"
  printf '> Generated: %s · mode: `%s` · repo: [%s](https://github.com/%s)\n\n' \
    "$(date -u '+%Y-%m-%d %H:%M UTC')" "$BH_MODE" "$BH_REPO" "$BH_REPO"
  printf '## Verdict\n\n| Field | Value |\n|---|---|\n'
  printf '| Kind | **%s** |\n' "$BH_KIND"
  printf '| Type | %s |\n' "$BH_TYPE"
  printf '| Product | %s |\n' "$BH_PRODUCT"
  [ -n "$BH_HOST_PRODUCT" ] && printf '| Host | %s |\n' "$BH_HOST_PRODUCT"
  [ -n "$BH_CLOUD" ] && printf '| Cloud | %s %s |\n' "$BH_CLOUD" "$BH_CLOUD_DETAIL"
  printf '\n## System\n\n| Field | Value |\n|---|---|\n'
  printf '| OS | %s (%s) |\n' "$BH_OS" "$BH_KERNEL"
  printf '| CPU | %s — %s logical / %s physical, effective %s |\n' "$BH_CPU_MODEL" "$BH_CPU_LOGICAL" "$BH_CPU_PHYS" "$BH_EFF_CORES"
  [ -n "$BH_CPU_QUOTA_TXT" ] && printf '| CPU quota (cgroup) | %s cores |\n' "$BH_CPU_QUOTA_TXT"
  [ -n "$CPUSET" ] && printf '| cpuset | `%s` |\n' "$CPUSET"
  printf '| RAM | %s total / %s avail |\n' "$(fmt_mbint "$BH_MEM_TOTAL_MB")" "$(fmt_mbint "$BH_MEM_AVAIL_MB")"
  [ "${BH_MEM_LIMIT_MB:-0}" -gt 0 ] 2>/dev/null && printf '| RAM limit (cgroup) | %s |\n' "$(fmt_mbint "$BH_MEM_LIMIT_MB")"
  [ -n "${BH_STEAL_PCT:-}" ] && printf '| CPU steal | %s%% |\n' "$BH_STEAL_PCT"
  printf '| Disk | %s (%s) %s total |\n' "$BH_DISK_DEV" "$BH_DISK_FS" "$(fmt_mbint "$BH_DISK_TOTAL_MB")"
  if [ -n "${BH_DISK_CLASS:-}${BH_DISK_SCHED:-}${BH_DISK_ROTA:-}" ]; then
    printf '| Disk class | %s (sched %s, rota %s) |\n' "${BH_DISK_CLASS:-?}" "${BH_DISK_SCHED:-?}" "${BH_DISK_ROTA:-?}"
  fi
  if [ "${BH_BENCH_SKIPPED:-0}" != "1" ]; then
    printf '\n## Benchmark\n\n| Metric | Value |\n|---|---|\n'
    printf '| CPU sha256 (1 core) | %s |\n' "$(fmt_mb "$BH_SHA1C")"
    printf '| CPU sha256 (%s threads) | %s |\n' "$BH_PAR_JOBS" "$(fmt_mb "$BH_SHANC")"
    [ -n "${BH_CPU_EFFICIENCY:-}" ] && printf '| Multi-thread efficiency | %s%% of linear scaling |\n' "$BH_CPU_EFFICIENCY"
    printf '| Memory bandwidth | %s (%s) |\n' "$(fmt_gbs "$BH_MEM_GBS")" "$BH_MEM_METHOD"
    printf '| Disk seq write | %s |\n' "$(fmt_mb "$BH_SEQW")"
    printf '| Disk seq read | %s |\n' "$(fmt_mb "$BH_SEQR")"
    printf '| Disk 4K write / read | %s / %s |\n' "$(fmt_mb "$BH_4KW")" "$(fmt_mb "$BH_4KR")"
    if [ -n "${BH_4K_IOPS_W:-}" ] || [ -n "${BH_4K_IOPS_R:-}" ]; then
      printf '| Disk 4K IOPS (w/r) | %s / %s |\n' "${BH_4K_IOPS_W:-n/a}" "${BH_4K_IOPS_R:-n/a}"
    fi
    [ -n "$BH_FIO_RIOPS" ] && printf '| fio 4k rand IOPS | r %s / w %s |\n' "$BH_FIO_RIOPS" "${BH_FIO_WIOPS:-n/a}"
    if [ "$BH_NO_NET" != "1" ]; then
      printf '| Network download | %s |\n' "$(fmt_mbps "$BH_DOWN_MBPS")"
      printf '| Network upload | %s |\n' "$(fmt_mbps "$BH_UP_MBPS")"
      printf '| TCP connect | %s |\n' "$(fmt_ms "$BH_LAT_MS")"
      [ -n "$BH_LAT_ICMP" ] && printf '| ICMP latency / jitter | %s ms%s (%s) |\n' "$BH_LAT_ICMP" "${BH_LAT_JITTER:+ ± $BH_LAT_JITTER}" "$BH_LAT_TARGET"
      [ -n "${BH_NET_ENDPOINT:-}" ] && printf '| Test endpoint | %s |\n' "$BH_NET_ENDPOINT"
    fi
  fi
  if [ "${BH_SEC_SKIPPED:-0}" != "1" ] && [ "${#BH_SEC_LINES[@]}" -gt 0 ] 2>/dev/null; then
    printf '\n## SSH & Security\n\n| Status | Check |\n|---|---|\n'
    local ml badge txt post_row=""
    md_sec_row() { # one table row from a "  [TAG]  text" audit line
      txt="${1##*]  }"
      badge="${1#*\[}"; badge="${badge%%\]*}"
      printf '| %s | %s |\n' "$badge" "$(printf '%s' "$txt" | sed 's/|/\\|/g')"
    }
    # v3 deep-scan extras sit between the audit body and the posture summary
    for ml in "${BH_SEC_LINES[@]}"; do
      case "$ml" in "  [POST]"*) post_row="$ml"; continue ;; esac
      md_sec_row "$ml"
    done
    sec_report_extras
    if [ "${#BH_SEC_EXTRA_LINES[@]}" -gt 0 ] 2>/dev/null; then
      for ml in "${BH_SEC_EXTRA_LINES[@]}"; do md_sec_row "$ml"; done
    fi
    [ -n "$post_row" ] && md_sec_row "$post_row"
  fi
  if [ "${BH_BENCH_SKIPPED:-0}" != "1" ]; then
    if [ -n "$BH_GRADE" ]; then
      printf '\n## BH-SCORE\n\n**%s / %s (grade %s)**\n\n' "$BH_SCORE_TOTAL" "$BH_SCORE_MAX" "$BH_GRADE"
    else
      printf '\n## BH-SCORE\n\n**%s / %s**\n\n' "$BH_SCORE_TOTAL" "$BH_SCORE_MAX"
    fi
    printf 'cpu1c %s · cpumc %s · mem %s · disk-seq %s · disk-4k %s · net-down %s · net-up %s\n' \
      "$BH_SCORE_CPU1C" "$BH_SCORE_CPUMC" "$BH_SCORE_MEM" "$BH_SCORE_DSEQ" "$BH_SCORE_D4K" "$BH_SCORE_NDOWN" "$BH_SCORE_NUP"
  fi
  # v4: oversell verdict + share card (wow#1 / wow#9) in the markdown sink too
  if [ -n "${BH_OVERSELL:-}" ]; then
    printf '\n**Oversell verdict:** %s\n' "$BH_OVERSELL"
  fi
  [ -n "${BH_SHARE_CARD:-}" ] && printf '\n> Share: %s\n' "$BH_SHARE_CARD"
  # ---- v5 extras (C14) — one compact table, skipped when nothing to show ----
  bhv5c14_md_extras
  if [ -n "$BH_IPV4$BH_IP_GEO$BH_IP_ASN" ]; then
    printf '\n## Location\n\n| Field | Value |\n|---|---|\n'
    [ -n "$BH_IPV4" ] && printf '| IPv4 | `%s` |\n' "$BH_IPV4"
    [ -n "$BH_IPV6" ] && printf '| IPv6 | `%s` |\n' "$BH_IPV6"
    [ -n "$BH_IP_GEO" ] && printf '| Geo/ISP | %s |\n' "$BH_IP_GEO"
    [ -n "$BH_IP_ASN" ] && printf '| ASN | %s |\n' "$BH_IP_ASN"
  fi
  if [ -n "$BH_EVIDENCE" ]; then
    printf '\n<details><summary>Detection evidence</summary>\n\n```\n%s\n```\n\n</details>\n' "$BH_EVIDENCE"
  fi
  printf '\n> Methodology: CPU = sha256 throughput (dd|sha256sum); Memory = C memcpy-style loop (or dd proxy); Disk = dd (direct I/O when supported); Network = Cloudflare speed endpoints. BH-SCORE caps each of the 7 components at 100 (max 700).\n'
}

# ---------------------------------------------------------------- Discord
discord_send() {
  [ -n "$BH_WEBHOOK" ] || return 0
  bh_redact_sink
  bh_compute_verdicts
  log "sending report to Discord webhook..."

  local desc
  desc="$(printf '%s\n' "${bh_lines[@]}" | tail -c 1900)"
  desc="${desc//$\\/\\\\}"; desc="${desc//\"/\\\"}"; desc="${desc//$'\n'/\\n}"; desc="${desc//$'\t'/ }"

  # colors must be DECIMAL: hex literals (9B59B6) are invalid JSON numbers
  local color=10181046 # 0x9B59B6 (purple)
  case "$BH_KIND" in
    container)  color=3447003 ;;  # 0x3498DB (blue)
    vm)         color=15494310 ;; # 0x9B59B6
    bare-metal) color=3066993 ;;  # green
  esac

  local fields="["
  local sep=""
  add_field() {
    fields="$fields$sep{\"name\":\"$(json_esc "$1")\",\"value\":\"$(json_esc "$2")\",\"inline\":true}"
    sep=","
  }
  add_field "Verdict" "$(verdict_text)"
  if [ "${BH_BENCH_SKIPPED:-0}" != "1" ]; then
    add_field "BH-SCORE" "$BH_SCORE_TOTAL / $BH_SCORE_MAX"
    add_field "CPU sha256" "$(fmt_mb "$BH_SHA1C") (1c) / $(fmt_mb "$BH_SHANC") (${BH_PAR_JOBS}thr)"
    add_field "Memory" "$(fmt_gbs "$BH_MEM_GBS")"
    add_field "Disk" "seq $(fmt_mb "$BH_SEQW") | 4k $(fmt_mb "$BH_4KW")"
    if [ "$BH_NO_NET" != "1" ]; then
      add_field "Network" "down $(fmt_mbps "$BH_DOWN_MBPS") / up $(fmt_mbps "$BH_UP_MBPS")"
    fi
  fi
  [ -n "$BH_IP_GEO" ] && add_field "Location" "$BH_IP_GEO"
  if [ "${BH_SEC_SKIPPED:-0}" != "1" ]; then
    add_field "SSH auth" "password=${BH_SSH_PWDAUTH:-unset} · root=${BH_SSH_ROOTLOGIN:-default} · keys=$BH_AK_TOTAL"
    add_field "Security posture" "$BH_SEC_POSTURE — $BH_SEC_PASS pass / $BH_SEC_WARN warn / $BH_SEC_BAD bad"
  fi
  case "${BH_OVERSELL:-}" in
    ''|"no evidence") : ;;
    *) add_field "Oversell" "$BH_OVERSELL" ;;
  esac
  [ -n "${BH_SHARE_CARD:-}" ] && add_field "Share" "$BH_SHARE_CARD"
  fields="$fields]"

  local payload="$BH_RUNDIR/dh_payload.json"
  {
    printf '{"username":"Blackhole VPS Bench",'
    printf '"embeds":[{"title":"%s — %s",' "$(json_esc "$BH_TOOL")" "$(json_esc "$BH_HOSTNAME")"
    printf '"description":"```\\n%s\\n```",' "$desc"
    printf '"color":%s,' "$color"
    printf '"fields":%s,' "$fields"
    printf '"footer":{"text":"%s v%s · %s"},' "$(json_esc "$BH_TOOL")" "$(json_esc "$BH_VERSION")" "$(json_esc "$BH_REPO")"
    printf '"timestamp":"%s"}]}' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$payload"

  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Content-Type: application/json' -X POST --data-binary @"$payload" "$BH_WEBHOOK" 2>/dev/null)"
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    log "Discord webhook delivered (HTTP $code)"
  else
    warn "Discord webhook returned HTTP ${code:-none}"
  fi
}
