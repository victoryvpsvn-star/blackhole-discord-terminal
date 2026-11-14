# =====================================================================
# blackhole-vps-bench · 70-report.sh — scoring + human/JSON/Markdown/Discord output
# =====================================================================
# shellcheck shell=bash

BH_SCORE_CPU1C=0; BH_SCORE_CPUMC=0; BH_SCORE_MEM=0; BH_SCORE_DSEQ=0
BH_SCORE_D4K=0; BH_SCORE_NDOWN=0; BH_SCORE_NUP=0; BH_SCORE_TOTAL=0
BH_SCORE_MAX=700

num_or_0() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf '0'; fi; }

cap100() { awk -v v="$1" 'BEGIN{ if (v+0<=0) print 0; else if (v>100) print 100; else printf "%.0f", v }'; }

compute_scores() {
  BH_SCORE_CPU1C="$(cap100 "$(awk -v v="$(num_or_0 "$BH_SHA1C")" 'BEGIN{print v/5}')")"
  BH_SCORE_CPUMC="$(cap100 "$(awk -v v="$(num_or_0 "$BH_SHANC")" 'BEGIN{print v/20}')")"
  BH_SCORE_MEM="$(cap100 "$(awk -v v="$(num_or_0 "$BH_MEM_GBS")" 'BEGIN{print v*8}')")"
  BH_SCORE_DSEQ="$(cap100 "$(awk -v v="$(num_or_0 "$BH_SEQW")" 'BEGIN{print v/10}')")"
  BH_SCORE_D4K="$(cap100 "$(awk -v w="$(num_or_0 "$BH_4KW")" -v r="$(num_or_0 "$BH_4KR")" 'BEGIN{print (w+r)/4}')")"
  BH_SCORE_NDOWN="$(cap100 "$(awk -v v="$(num_or_0 "$BH_DOWN_MBPS")" 'BEGIN{print v/20}')")"
  BH_SCORE_NUP="$(cap100 "$(awk -v v="$(num_or_0 "$BH_UP_MBPS")" 'BEGIN{print v/20}')")"
  BH_SCORE_TOTAL="$(( BH_SCORE_CPU1C + BH_SCORE_CPUMC + BH_SCORE_MEM + BH_SCORE_DSEQ + BH_SCORE_D4K + BH_SCORE_NDOWN + BH_SCORE_NUP ))"
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

print_evidence() {
  if [ -n "$BH_EVIDENCE" ]; then
    while IFS= read -r ev; do
      rpt "  $ev"
    done <<< "$BH_EVIDENCE"
  else
    rpt "  (no evidence collected)"
  fi
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
  if [ "$BH_KIND" = "container" ] && [ -n "$BH_HOST_PRODUCT" ]; then
    rpt "  Host VM : $BH_HOST_PRODUCT"
  fi
  if [ -n "$BH_CLOUD" ]; then
    rpt "  Cloud   : $BH_CLOUD${BH_CLOUD_DETAIL:+ ($BH_CLOUD_DETAIL)}"
  fi
  rpt "  Verdict : $(verdict_text)"
  rpt "  Evidence:"
  print_evidence

  rpt ""
  rpt "[2] SYSTEM / REAL CONFIG"
  rpt "  Hostname: $BH_HOSTNAME"
  rpt "  OS      : $BH_OS"
  rpt "  Kernel  : $BH_KERNEL ($BH_ARCH), uptime $BH_UPTIME"
  rpt "  CPU     : ${BH_CPU_MODEL:-n/a}"
  rpt "            ${BH_CPU_LOGICAL:-?} logical / ${BH_CPU_PHYS:-?} physical cores"
  local effline="            effective: ${BH_EFF_CORES:-?} core(s)"
  if [ -n "$BH_CPU_QUOTA_TXT" ]; then effline="$effline, cgroup quota $BH_CPU_QUOTA_TXT cores"; fi
  if [ -n "$CPUSET" ]; then effline="$effline, cpuset [$CPUSET]"; fi
  rpt "$effline"
  [ -n "$BH_CPU_FLAGS_HI" ] && rpt "            features: $BH_CPU_FLAGS_HI"
  local memline
  memline="  RAM     : total $(fmt_mbint "$BH_MEM_TOTAL_MB"), avail $(fmt_mbint "$BH_MEM_AVAIL_MB"), swap $(fmt_mbint "$BH_MEM_SWAP_MB")"
  if [ "${BH_MEM_LIMIT_MB:-0}" -gt 0 ] 2>/dev/null; then
    memline="$memline | container limit $(fmt_mbint "$BH_MEM_LIMIT_MB")"
  fi
  rpt "$memline"
  rpt "  Disk    : $BH_DISK_DEV ($BH_DISK_FS) on $BH_DISK_DIR — total $(fmt_mbint "$BH_DISK_TOTAL_MB"), avail $(fmt_mbint "$BH_DISK_AVAIL_MB")"

  rpt ""
  if [ "${BH_BENCH_SKIPPED:-0}" = "1" ]; then
    rpt "[3] BENCHMARK — skipped in $BH_MODE mode (run: all | bench)"
  else
    rpt "[3] BENCHMARK"
    rpt "  CPU     : sha256 $(fmt_mb "$BH_SHA1C") (1 core) | $(fmt_mb "$BH_SHANC") (${BH_PAR_JOBS} threads)"
    [ -n "$BH_OPENSSL_K" ] && rpt "            openssl sha256 cross-check: $BH_OPENSSL_K k/s"
    rpt "  Memory  : $(fmt_gbs "$BH_MEM_GBS")  [$BH_MEM_METHOD]"
    rpt "  Disk    : seq w $(fmt_mb "$BH_SEQW") | seq r $(fmt_mb "$BH_SEQR") | 4k w $(fmt_mb "$BH_4KW") | 4k r $(fmt_mb "$BH_4KR")  [$BH_DISK_DIR, mode: $BH_DISK_MODE]"
    if [ -n "$BH_FIO_RIOPS" ] || [ -n "$BH_FIO_WIOPS" ]; then
      rpt "            fio 4k randrw IOPS: r=${BH_FIO_RIOPS:-n/a} w=${BH_FIO_WIOPS:-n/a}"
    fi
    if [ "$BH_NO_NET" = "1" ]; then
      rpt "  Network : skipped (--no-net)"
    else
      rpt "  Network : down $(fmt_mbps "$BH_DOWN_MBPS") | up $(fmt_mbps "$BH_UP_MBPS") | connect $(fmt_ms "$BH_LAT_MS")  [$BH_NET_METHOD]"
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
  if [ "${BH_BENCH_SKIPPED:-0}" = "1" ]; then
    rpt "[5] BH-SCORE — n/a (no benchmark in $BH_MODE mode)"
  else
    rpt "[5] BH-SCORE"
    rpt "  CPU 1-core ${BH_SCORE_CPU1C}/100 | CPU multi ${BH_SCORE_CPUMC}/100 | Memory ${BH_SCORE_MEM}/100"
    rpt "  Disk seq ${BH_SCORE_DSEQ}/100 | Disk 4k ${BH_SCORE_D4K}/100 | Net down ${BH_SCORE_NDOWN}/100 | Net up ${BH_SCORE_NUP}/100"
    rpt "  TOTAL: $BH_SCORE_TOTAL / $BH_SCORE_MAX"
  fi
  rpt ""
  rpt "generated $(date -u '+%Y-%m-%d %H:%M:%S UTC') by $BH_TOOL v$BH_VERSION"
}

print_report() {
  if [ -n "$BH_TXT_OUT" ] && [ "$BH_TXT_OUT" != "-" ]; then
    printf '%s\n' "${bh_lines[@]}" > "$BH_TXT_OUT"
    log "text report written to $BH_TXT_OUT"
  fi
  # banner in color on TTY, then the plain body
  if [ -n "$C_CYN" ]; then
    printf '%s%s%s\n' "$C_B$C_CYN" "${bh_lines[0]}" "$C_RST"
  else
    printf '%s\n' "${bh_lines[0]}"
  fi
  printf '%s\n' "${bh_lines[@]:1}"
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
  printf '"virtualization":{"kind":%s,"type":%s,"product":%s,"host_type":%s,"host_product":%s,"cloud":%s,"cloud_detail":%s,"evidence":[%s]},' \
    "$(json_val "$BH_KIND")" "$(json_val "$BH_TYPE")" "$(json_val "$BH_PRODUCT")" \
    "$(json_val "$BH_HOST_TYPE")" "$(json_val "$BH_HOST_PRODUCT")" \
    "$(json_val "$BH_CLOUD")" "$(json_val "$BH_CLOUD_DETAIL")" "$ev_json"
  printf '"system":{"os":%s,"kernel":%s,"arch":%s,"uptime":%s,' \
    "$(json_val "$BH_OS")" "$(json_val "$BH_KERNEL")" "$(json_val "$BH_ARCH")" "$(json_val "$BH_UPTIME")"
  printf '"cpu":{"model":%s,"logical_cores":%s,"physical_cores":%s,"effective_cores":%s,"features":%s},' \
    "$(json_val "$BH_CPU_MODEL")" "$(json_val "$BH_CPU_LOGICAL")" "$(json_val "$BH_CPU_PHYS")" "$(json_val "$BH_EFF_CORES")" "$(json_val "$BH_CPU_FLAGS_HI")"
  printf '"memory":{"total_mb":%s,"available_mb":%s,"swap_mb":%s}},' \
    "$(json_val "$BH_MEM_TOTAL_MB")" "$(json_val "$BH_MEM_AVAIL_MB")" "$(json_val "$BH_MEM_SWAP_MB")"
  printf '"limits":{"cgroup_version":%s,"cpu_quota_cores":%s,"memory_limit_mb":%s,"cpuset":%s},' \
    "$(json_val "$CG_VER")" "$(json_val "$BH_CPU_QUOTA_TXT")" "$(json_val "$BH_MEM_LIMIT_MB")" "$(json_val "$CPUSET")"
  printf '"disk":{"dir":%s,"device":%s,"fs":%s,"total_mb":%s,"available_mb":%s},' \
    "$(json_val "$BH_DISK_DIR")" "$(json_val "$BH_DISK_DEV")" "$(json_val "$BH_DISK_FS")" "$(json_val "$BH_DISK_TOTAL_MB")" "$(json_val "$BH_DISK_AVAIL_MB")"
  printf '"bench":{"skipped":%s,' "$skipped"
  printf '"cpu":{"sha256_1c_mbps":%s,"sha256_mc_mbps":%s,"threads":%s,"openssl_sha256_kbs":%s},' \
    "$(json_val "$(num_or_0 "$BH_SHA1C")")" "$(json_val "$(num_or_0 "$BH_SHANC")")" "$(json_val "$BH_PAR_JOBS")" "$(json_val "$BH_OPENSSL_K")"
  printf '"memory":{"gbps":%s,"method":%s},' "$(json_val "$(num_or_0 "$BH_MEM_GBS")")" "$(json_val "$BH_MEM_METHOD")"
  printf '"disk":{"mode":%s,"seq_write_mbps":%s,"seq_read_mbps":%s,"k4_write_mbps":%s,"k4_read_mbps":%s,"fio_randread_iops":%s,"fio_randwrite_iops":%s},' \
    "$(json_val "$BH_DISK_MODE")" "$(json_val "$(num_or_0 "$BH_SEQW")")" "$(json_val "$(num_or_0 "$BH_SEQR")")" \
    "$(json_val "$(num_or_0 "$BH_4KW")")" "$(json_val "$(num_or_0 "$BH_4KR")")" \
    "$(json_val "$(num_or_0 "$BH_FIO_RIOPS")")" "$(json_val "$(num_or_0 "$BH_FIO_WIOPS")")"
  printf '"network":{"skipped":%s,"method":%s,"download_mbps":%s,"upload_mbps":%s,"connect_ms":%s,' \
    "$netskipped" "$(json_val "$BH_NET_METHOD")" "$(json_val "$(num_or_0 "$BH_DOWN_MBPS")")" \
    "$(json_val "$(num_or_0 "$BH_UP_MBPS")")" "$(json_val "$(num_or_0 "$BH_LAT_MS")")"
  printf '"ipv4":%s,"ipv6":%s,"geo":%s,"asn":%s}},' \
    "$(json_val "$BH_IPV4")" "$(json_val "$BH_IPV6")" "$(json_val "$BH_IP_GEO")" "$(json_val "$BH_IP_ASN")"
  printf '"score":{"cpu_1c":%s,"cpu_multi":%s,"memory":%s,"disk_seq":%s,"disk_4k":%s,"net_down":%s,"net_up":%s,"total":%s,"max":%s}}' \
    "$(json_val "$BH_SCORE_CPU1C")" "$(json_val "$BH_SCORE_CPUMC")" "$(json_val "$BH_SCORE_MEM")" \
    "$(json_val "$BH_SCORE_DSEQ")" "$(json_val "$BH_SCORE_D4K")" "$(json_val "$BH_SCORE_NDOWN")" \
    "$(json_val "$BH_SCORE_NUP")" "$(json_val "$BH_SCORE_TOTAL")" "$(json_val "$BH_SCORE_MAX")"
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
  printf '| Disk | %s (%s) %s total |\n' "$BH_DISK_DEV" "$BH_DISK_FS" "$(fmt_mbint "$BH_DISK_TOTAL_MB")"
  if [ "${BH_BENCH_SKIPPED:-0}" != "1" ]; then
    printf '\n## Benchmark\n\n| Metric | Value |\n|---|---|\n'
    printf '| CPU sha256 (1 core) | %s |\n' "$(fmt_mb "$BH_SHA1C")"
    printf '| CPU sha256 (%s threads) | %s |\n' "$BH_PAR_JOBS" "$(fmt_mb "$BH_SHANC")"
    printf '| Memory bandwidth | %s (%s) |\n' "$(fmt_gbs "$BH_MEM_GBS")" "$BH_MEM_METHOD"
    printf '| Disk seq write | %s |\n' "$(fmt_mb "$BH_SEQW")"
    printf '| Disk seq read | %s |\n' "$(fmt_mb "$BH_SEQR")"
    printf '| Disk 4K write / read | %s / %s |\n' "$(fmt_mb "$BH_4KW")" "$(fmt_mb "$BH_4KR")"
    [ -n "$BH_FIO_RIOPS" ] && printf '| fio 4k rand IOPS | r %s / w %s |\n' "$BH_FIO_RIOPS" "${BH_FIO_WIOPS:-n/a}"
    if [ "$BH_NO_NET" != "1" ]; then
      printf '| Network download | %s |\n' "$(fmt_mbps "$BH_DOWN_MBPS")"
      printf '| Network upload | %s |\n' "$(fmt_mbps "$BH_UP_MBPS")"
      printf '| TCP connect | %s |\n' "$(fmt_ms "$BH_LAT_MS")"
    fi
    printf '\n## BH-SCORE\n\n**%s / %s**\n\n' "$BH_SCORE_TOTAL" "$BH_SCORE_MAX"
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
