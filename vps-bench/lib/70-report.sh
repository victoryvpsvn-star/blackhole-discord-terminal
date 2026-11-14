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

build_report() {
  bh_lines=()
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
  [ "${BH_IS_CHROOT:-0}" = "1" ] && rpt "  Chroot  : yes (/, /proc/1/root differ)"
  rpt "  Verdict : $(verdict_text)"
  rpt "  Evidence:"
  print_evidence

  rpt ""
  rpt "[2] SYSTEM / REAL CONFIG"
  rpt "  Hostname: $BH_HOSTNAME"
  rpt "  OS      : $BH_OS"
  rpt "  Kernel  : $BH_KERNEL ($BH_ARCH), uptime $BH_UPTIME"
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
  [ -n "$BH_CPU_FLAGS_HI" ] && rpt "            features: $BH_CPU_FLAGS_HI"
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
  fi

  if [ -n "$BH_IPV4$BH_IPV6$BH_IP_GEO$BH_IP_ASN" ]; then
    rpt ""
    rpt "[4] LOCATION / NETWORK IDENTITY"
    [ -n "$BH_IPV4" ]   && rpt "  IPv4    : $BH_IPV4"
    [ -n "$BH_IPV6" ]   && rpt "  IPv6    : $BH_IPV6"
    [ -n "$BH_IP_GEO" ] && rpt "  Geo/ISP : $BH_IP_GEO"
    [ -n "$BH_IP_ASN" ] && rpt "  ASN     : $BH_IP_ASN"
  fi

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
    if [ -n "$BH_GRADE" ]; then
      rpt "  TOTAL: $BH_SCORE_TOTAL / $BH_SCORE_MAX (grade $BH_GRADE)"
    else
      rpt "  TOTAL: $BH_SCORE_TOTAL / $BH_SCORE_MAX"
    fi
    rpt "  grade S >=630 | A >=525 | B >=420 | C >=315 | D >=210 | F below"
  fi
  rpt ""
  rpt "generated $(date -u '+%Y-%m-%d %H:%M:%S UTC') by $BH_TOOL v$BH_VERSION"
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
  printf '"chassis_type":%s,"chassis_class":%s,"wsl_gen":%s,"is_chroot":%s,"aws_gen":%s,"cloud_method":%s},' \
    "$(json_val "${BH_CHASSIS_TYPE:-}")" "$(json_val "${BH_CHASSIS_CLASS:-}")" "$(json_val "${BH_WSL_GEN:-}")" \
    "$(json_val "${BH_IS_CHROOT:-}")" "$(json_val "${BH_AWS_GEN:-}")" "$(json_val "${BH_CLOUD_METHOD:-}")"
  printf '"system":{"os":%s,"kernel":%s,"arch":%s,"uptime":%s,"steal_pct":%s,"net_mtu":%s,' \
    "$(json_val "$BH_OS")" "$(json_val "$BH_KERNEL")" "$(json_val "$BH_ARCH")" "$(json_val "$BH_UPTIME")" \
    "$(json_val "${BH_STEAL_PCT:-}")" "$(json_val "${BH_NET_MTU:-}")"
  printf '"cpu":{"model":%s,"logical_cores":%s,"physical_cores":%s,"effective_cores":%s,"features":%s,"cpu_freq_mhz":%s},' \
    "$(json_val "$BH_CPU_MODEL")" "$(json_val "$BH_CPU_LOGICAL")" "$(json_val "$BH_CPU_PHYS")" "$(json_val "$BH_EFF_CORES")" "$(json_val "$BH_CPU_FLAGS_HI")" "$(json_val "${BH_CPU_FREQ_MHZ:-}")"
  printf '"memory":{"total_mb":%s,"available_mb":%s,"swap_mb":%s,"thp":%s,"hugepages":%s,"swap":%s}},' \
    "$(json_val "$BH_MEM_TOTAL_MB")" "$(json_val "$BH_MEM_AVAIL_MB")" "$(json_val "$BH_MEM_SWAP_MB")" \
    "$(json_val "${BH_THP:-}")" "$(json_val "${BH_HUGEPAGES_TOTAL:-}")" "$(json_val "${BH_SWAP_DETAIL:-}")"
  printf '"limits":{"cgroup_version":%s,"cpu_quota_cores":%s,"memory_limit_mb":%s,"cpuset":%s,"cpuset_cores":%s},' \
    "$(json_val "$CG_VER")" "$(json_val "$BH_CPU_QUOTA_TXT")" "$(json_val "$BH_MEM_LIMIT_MB")" "$(json_val "$CPUSET")" "$(json_val "${BH_CPUSET_N:-}")"
  printf '"net_env":{"tcp_cc":%s,"tcp_cc_available":%s,"dns":%s,"entropy":%s,"tun":%s,"fuse":%s,"ppp":%s,"load":%s,"processes":%s},' \
    "$(json_val "$BH_TCPCC")" "$(json_val "$BH_TCPCC_AVAIL")" "$(json_val "$BH_DNS")" "$(json_val "$BH_ENTROPY")" \
    "$(json_val "$BH_TUN")" "$(json_val "$BH_FUSE")" "$(json_val "$BH_PPP")" "$(json_val "$BH_LOAD")" "$(json_val "$BH_PROCS")"
  printf '"disk":{"dir":%s,"device":%s,"fs":%s,"total_mb":%s,"available_mb":%s,"disk_class":%s,"disk_scheduler":%s,"disk_rotational":%s},' \
    "$(json_val "$BH_DISK_DIR")" "$(json_val "$BH_DISK_DEV")" "$(json_val "$BH_DISK_FS")" "$(json_val "$BH_DISK_TOTAL_MB")" "$(json_val "$BH_DISK_AVAIL_MB")" \
    "$(json_val "${BH_DISK_CLASS:-}")" "$(json_val "${BH_DISK_SCHED:-}")" "$(json_val "${BH_DISK_ROTA:-}")"
  printf '"bench":{"skipped":%s,' "$skipped"
  printf '"cpu":{"sha256_1c_mbps":%s,"sha256_mc_mbps":%s,"threads":%s,"openssl_sha256_kbs":%s,"efficiency_pct":%s},' \
    "$(json_val "$(num_or_0 "$BH_SHA1C")")" "$(json_val "$(num_or_0 "$BH_SHANC")")" "$(json_val "$BH_PAR_JOBS")" "$(json_val "$BH_OPENSSL_K")" "$(json_val "${BH_CPU_EFFICIENCY:-}")"
  printf '"memory":{"gbps":%s,"method":%s},' "$(json_val "$(num_or_0 "$BH_MEM_GBS")")" "$(json_val "$BH_MEM_METHOD")"
  printf '"disk":{"mode":%s,"seq_write_mbps":%s,"seq_read_mbps":%s,"k4_write_mbps":%s,"k4_read_mbps":%s,"fio_randread_iops":%s,"fio_randwrite_iops":%s,"iops_4k_write":%s,"iops_4k_read":%s},' \
    "$(json_val "$BH_DISK_MODE")" "$(json_val "$(num_or_0 "$BH_SEQW")")" "$(json_val "$(num_or_0 "$BH_SEQR")")" \
    "$(json_val "$(num_or_0 "$BH_4KW")")" "$(json_val "$(num_or_0 "$BH_4KR")")" \
    "$(json_val "$(num_or_0 "$BH_FIO_RIOPS")")" "$(json_val "$(num_or_0 "$BH_FIO_WIOPS")")" \
    "$(json_val "${BH_4K_IOPS_W:-}")" "$(json_val "${BH_4K_IOPS_R:-}")"
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
    printf '"pass":%s,"warn":%s,"bad":%s,"posture":%s},' \
      "$(json_val "$BH_SEC_PASS")" "$(json_val "$BH_SEC_WARN")" "$(json_val "$BH_SEC_BAD")" "$(json_val "$BH_SEC_POSTURE")"
  fi
  printf '"score":{"cpu_1c":%s,"cpu_multi":%s,"memory":%s,"disk_seq":%s,"disk_4k":%s,"net_down":%s,"net_up":%s,"total":%s,"max":%s,"grade":%s}}' \
    "$(json_val "$BH_SCORE_CPU1C")" "$(json_val "$BH_SCORE_CPUMC")" "$(json_val "$BH_SCORE_MEM")" \
    "$(json_val "$BH_SCORE_DSEQ")" "$(json_val "$BH_SCORE_D4K")" "$(json_val "$BH_SCORE_NDOWN")" \
    "$(json_val "$BH_SCORE_NUP")" "$(json_val "$BH_SCORE_TOTAL")" "$(json_val "$BH_SCORE_MAX")" "$(json_val "$BH_GRADE")"
}

# ---------------------------------------------------------------- Markdown
build_markdown() {
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
