# =====================================================================
# blackhole-vps-bench · 20-info.sh — system info + cgroup limits + offline extras
# =====================================================================
#
# v4.0 (W3-C):
#   - ZERO network calls from this module, ever. The egress-IP / geo / ASN
#     lookups (ipify + ip-api) moved to the net module (60-net.sh); cloud
#     metadata stays in 12-cloud.sh. BH_IPV4/BH_IPV6/BH_IP_GEO/BH_IP_ASN are
#     declared here ("" default) and filled by the module that owns them.
#   - CPU flags now work on x86_64 ("flags") AND aarch64 ("Features").
#   - New offline extras: CPU vulnerability matrix (BH_VULN_*), ISA inventory
#     (BH_CPU_AI_FEAT / BH_CPU_CRYPTO_FEAT), microcode + stepping (BH_CPU_UCODE
#     / BH_CPU_STEPPING), KSM state (BH_KSM_STATE / BH_KSM_SHARING).
# shellcheck shell=bash

BH_HOSTNAME=""; BH_OS=""; BH_KERNEL=""; BH_ARCH=""; BH_UPTIME=""
BH_CPU_MODEL=""; BH_CPU_LOGICAL=""; BH_CPU_PHYS=""; BH_CPU_FLAGS_HI=""
BH_MEM_TOTAL_MB=""; BH_MEM_AVAIL_MB=""; BH_MEM_SWAP_MB=""
BH_MEM_LIMIT_MB="0"; BH_MEM_EFF_MB=""; BH_CPU_QUOTA_TXT=""
BH_DISK_DEV=""; BH_DISK_FS=""; BH_DISK_TOTAL_MB=""; BH_DISK_AVAIL_MB=""
BH_IPV4=""; BH_IPV6=""; BH_IP_GEO=""; BH_IP_ASN=""
# deep-scan extras (v2)
BH_DNS=""; BH_TCPCC=""; BH_TCPCC_AVAIL=""; BH_ENTROPY=""
BH_TUN=0; BH_FUSE=0; BH_PPP=0
BH_LOAD=""; BH_PROCS=0; BH_TZ=""
# environment deep-dive extras (v2.1)
BH_STEAL_PCT=""; BH_CPU_FREQ_MHZ=""; BH_CPUSET_N=0; BH_THP=""
BH_HUGEPAGES_TOTAL=""; BH_DISK_SCHED=""; BH_DISK_ROTA=""; BH_DISK_CLASS=""
BH_NET_MTU=""; BH_SWAP_DETAIL=""
# offline security / CPU-identity extras (v4.0 — W3-C)
# vuln matrix: /sys/devices/system/cpu/vulnerabilities/* (C2)
BH_VULN_WORST=""; BH_VULN_TOTAL=0; BH_VULN_SCOPE=""
# ISA inventory: AI/ML + crypto extensions, comma lists (C3)
BH_CPU_AI_FEAT=""; BH_CPU_CRYPTO_FEAT=""
# microcode + stepping, x86 only (C5)
BH_CPU_UCODE=""; BH_CPU_STEPPING=""
# kernel same-page merging (C6)
BH_KSM_STATE=""; BH_KSM_SHARING=""
# v5.0 hardware extras (C6)
# CPU cache topology summary, e.g. "L1d 32K L1i 32K L2 1024K L3 36864K shared=0-31"
BH_CACHE_TXT=""
# bench-disk block queue parameters, e.g. "512e nr=256 qd=32 wc=write back maxsec=1280"
BH_BLOCKQ_TXT=""

# bh_bracketed FILE — print the value of the [bracketed] token in FILE ("" if none)
bh_bracketed() {
  [ -r "$1" ] || return 0
  awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\[.*\]$/) { gsub(/[\[\]]/, "", $i); print $i; exit } }' "$1" 2>/dev/null
  return 0
}

# bh_flag_has HAYSTACK WORD — true when WORD appears as a whole token in
# HAYSTACK (a plain space-separated flag list). Pure bash, no subshell.
bh_flag_has() {
  # shellcheck disable=SC2254
  case " $1 " in
    *" $2 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# bh_cpu_steal_pct — noisy-neighbor detector: % of CPU time stolen by the host
# between two /proc/stat samples. Runs in a ( ) subshell so the sleep never
# disturbs the caller; "" when /proc/stat is unreadable or the window is bad.
# Fields after "cpu": user nice system idle iowait irq softirq steal guest
# guest_nice — steal is the 8th value (awk $9 since "cpu" itself is $1).
bh_cpu_steal_pct() {
  (
    [ -r /proc/stat ] || exit 0
    a="$(awk '$1 == "cpu" { print $9, $2+$3+$4+$5+$6+$7+$8+$9+$10+$11; exit }' /proc/stat 2>/dev/null)"
    [ -n "$a" ] || exit 0
    delay=0.7
    [ "${BH_FAST:-0}" = "1" ] && delay=0.35
    sleep "$delay" 2>/dev/null || :
    b="$(awk '$1 == "cpu" { print $9, $2+$3+$4+$5+$6+$7+$8+$9+$10+$11; exit }' /proc/stat 2>/dev/null)"
    [ -n "$b" ] || exit 0
    awk -v a="$a" -v b="$b" 'BEGIN{
      split(a, A, " "); split(b, B, " ");
      ds = B[1] - A[1]; dt = B[2] - A[2];
      if (ds < 0) ds = 0
      if (dt > 0) printf "%.1f", ds / dt * 100
    }' 2>/dev/null
  )
}

# =====================================================================
# v5.0 hardware extras (C6) — private helpers, called from gather_info.
# Contract: read-only sysfs/procfs, every read [ -r ]-guarded, missing
# data -> "" (clean), never warn, no subshells beyond the two value
# captures, budget well under 0.3s. BH_CPUFREQ_TXT is owned by 16-hw-deep
# and is deliberately NOT touched here.
# =====================================================================

# bhv5c6_cache_txt — CPU cache topology of cpu0 (or the first cpuN that
# exposes a cache dir), from /sys/devices/system/cpu/cpuN/cache/index*.
# Output, one line: "L1d 32K L1i 32K L2 1024K L3 36864K shared=0-31"
#   - per level (ascending): Data -> "L<lvl>d", Instruction -> "L<lvl>i",
#     Unified -> "L<lvl>" (suffix "u" only when the same level also has
#     d/i entries, so a mixed level stays unambiguous)
#   - shared= is the shared_cpu_list of the highest level that exposes one
#   - sizes are the raw sysfs tokens (32K / 1024K / 36864K)
# When sysfs exposes no cache info at all: fallback to `lscpu -C`
# (L1d/L1i/L2/L3 rows, first row per NAME wins). Empty on failure; never warns.
# Prints on stdout.
bhv5c6_cache_txt() {
  local cdir="" c idx f lvl typ sz key sl out="" lv dh ih
  local best_lvl=0 best_list=""
  if [ -d /sys/devices/system/cpu/cpu0/cache ]; then
    cdir="/sys/devices/system/cpu/cpu0/cache"
  else
    for c in /sys/devices/system/cpu/cpu*; do
      [ -d "$c/cache" ] || continue
      cdir="$c/cache"
      break
    done
  fi
  if [ -n "$cdir" ]; then
    local -A csz=()   # "L<level><d|i|u>" -> size token (first index wins)
    for idx in "$cdir"/index*; do
      [ -d "$idx" ] || continue
      f="$idx/level"; [ -r "$f" ] || continue
      lvl="$(tr -d ' \t\n\r' < "$f" 2>/dev/null)"
      case "$lvl" in ''|*[!0-9]*) continue ;; esac
      f="$idx/type"; [ -r "$f" ] || continue
      typ="$(tr -d ' \t\n\r' < "$f" 2>/dev/null)"
      case "$typ" in
        Data)        typ=d ;;
        Instruction) typ=i ;;
        Unified)     typ=u ;;
        *) continue ;;
      esac
      f="$idx/size"; [ -r "$f" ] || continue
      sz="$(tr -d ' \t\n\r' < "$f" 2>/dev/null)"
      [ -n "$sz" ] || continue
      key="L${lvl}${typ}"
      [ -n "${csz[$key]:-}" ] || csz[$key]="$sz"
      # shared_cpu_list: keep the highest level that exposes one
      f="$idx/shared_cpu_list"
      if [ -r "$f" ]; then
        sl="$(tr -d ' \t\n\r' < "$f" 2>/dev/null)"
        if [ -n "$sl" ] && [ "$lvl" -ge "$best_lvl" ] 2>/dev/null; then
          best_lvl="$lvl"; best_list="$sl"
        fi
      fi
    done
    # emit per level, ascending; within a level: d, i, then unified
    for lv in 1 2 3 4 5 6 7 8; do
      dh="${csz[L${lv}d]:-}"
      ih="${csz[L${lv}i]:-}"
      if [ -n "$dh" ]; then out="${out}L${lv}d $dh "; fi
      if [ -n "$ih" ]; then out="${out}L${lv}i $ih "; fi
      sz="${csz[L${lv}u]:-}"
      if [ -n "$sz" ]; then
        # unified-only level (the common L2/L3 case) prints plain "L<lv>";
        # a level that also has d/i entries gets the "u" suffix instead
        if [ -n "$dh" ] || [ -n "$ih" ]; then
          out="${out}L${lv}u $sz "
        else
          out="${out}L${lv} $sz "
        fi
      fi
    done
    if [ -n "$best_list" ]; then out="${out}shared=$best_list "; fi
    out="${out% }"
  fi
  if [ -z "$out" ] && command_exists lscpu; then
    # fallback: lscpu -C columns (ONE-SIZE-ALL), first row per NAME, mawk-safe
    out="$(lscpu -C 2>/dev/null | awk '
      $1 == "L1d" || $1 == "L1i" || $1 == "L2" || $1 == "L3" {
        if (!seen[$1] && $2 != "" && $2 != "-") { seen[$1] = 1; printf "%s %s ", $1, $2 }
      }' 2>/dev/null)"
    out="${out% }"
  fi
  printf '%s' "$out"
  return 0
}

# bhv5c6_blockq_txt — block queue parameters of the base disk device that
# gather_info already resolved for rotational/scheduler (arg 1 = its name,
# e.g. "sda" / "nvme0n1"). Re-derivation mirrors gather_info: lsblk PKNAME
# -> readlink -f -> strip trailing digits -> /sys/block/<d>/queue; last
# resort is the first /sys/block entry that is not loop/ram/zram.
# Output: "4Kn|512e|512n nr=<n> qd=<d> wc=<write back|write through> maxsec=<kb>"
#   - 4Kn  when physical=4096 and logical=4096
#   - 512e when physical=4096 and logical=512
#   - 512n when physical=512  and logical=512 (industry naming, spec silent)
# Every piece is included only when its sysfs file is readable; write_cache
# appeared in kernel 4.10, on older kernels the file is absent and wc= is
# silently skipped. Empty on failure; never warns. Prints on stdout.
bhv5c6_blockq_txt() {
  local base="${1:-}" rp d q v out=""
  local phys="" log="" nr="" qd="" wc="" mx=""
  if [ -z "$base" ] || [ ! -d "/sys/block/$base/queue" ]; then
    base=""
    if [ -n "${BH_DISK_DEV:-}" ]; then
      if command_exists lsblk; then
        base="$(lsblk -no PKNAME "$BH_DISK_DEV" 2>/dev/null | head -n 1 | tr -d ' \t')"
      fi
      if [ -z "$base" ] || [ ! -d "/sys/block/$base/queue" ]; then
        rp="$(readlink -f "$BH_DISK_DEV" 2>/dev/null)"
        if [ -n "$rp" ]; then base="$(basename "$rp" 2>/dev/null)"; fi
      fi
      if [ -n "$base" ] && [ ! -d "/sys/block/$base/queue" ]; then
        rp="${base%[0-9]*}"
        if [ -n "$rp" ] && [ -d "/sys/block/$rp/queue" ]; then base="$rp"; fi
      fi
    fi
    if [ -z "$base" ] || [ ! -d "/sys/block/$base/queue" ]; then
      base=""
      for d in /sys/block/*; do
        [ -d "$d/queue" ] || continue
        case "${d##*/}" in loop*|ram*|zram*) continue ;; esac
        # only a device that actually reports block sizes is useful here
        [ -r "$d/queue/logical_block_size" ] || continue
        base="${d##*/}"
        break
      done
    fi
  fi
  [ -n "$base" ] && [ -d "/sys/block/$base/queue" ] || return 0
  q="/sys/block/$base/queue"
  if [ -r "$q/physical_block_size" ]; then
    phys="$(tr -d ' \t\n\r' < "$q/physical_block_size" 2>/dev/null)"
  fi
  if [ -r "$q/logical_block_size" ]; then
    log="$(tr -d ' \t\n\r' < "$q/logical_block_size" 2>/dev/null)"
  fi
  if [ -n "$phys" ] && [ -n "$log" ]; then
    case "$phys:$log" in
      4096:4096) out="4Kn"  ;;
      4096:512)  out="512e" ;;
      512:512)   out="512n" ;;
    esac
  fi
  if [ -r "$q/nr_requests" ]; then
    v="$(tr -d ' \t\n\r' < "$q/nr_requests" 2>/dev/null)"
    case "$v" in ''|*[!0-9]*) : ;; *) nr="$v" ;; esac
  fi
  if [ -r "$q/queue_depth" ]; then
    v="$(tr -d ' \t\n\r' < "$q/queue_depth" 2>/dev/null)"
    case "$v" in ''|*[!0-9]*) : ;; *) qd="$v" ;; esac
  fi
  if [ -r "$q/write_cache" ]; then
    v="$(tr -d '\n\r' < "$q/write_cache" 2>/dev/null)"
    v="${v#"${v%%[! ]*}"}"; v="${v%"${v##*[! ]}"}"   # trim edge spaces
    case "$v" in write\ back|write\ through) wc="$v" ;; esac
  fi
  if [ -r "$q/max_sectors_kb" ]; then
    v="$(tr -d ' \t\n\r' < "$q/max_sectors_kb" 2>/dev/null)"
    case "$v" in ''|*[!0-9]*) : ;; *) mx="$v" ;; esac
  fi
  if [ -n "$nr" ]; then out="${out}${out:+ }nr=$nr"; fi
  if [ -n "$qd" ]; then out="${out}${out:+ }qd=$qd"; fi
  if [ -n "$wc" ]; then out="${out}${out:+ }wc=$wc"; fi
  if [ -n "$mx" ]; then out="${out}${out:+ }maxsec=$mx"; fi
  # value goes on stdout (caller captures it) — keeps the helper subshell-safe
  printf '%s' "$out"
  return 0
}

# bhv5c6_hw_extra — v5 (C6) hardware extras; called at the end of gather_info.
# $1 (optional): base disk device name already resolved by gather_info.
bhv5c6_hw_extra() {
  BH_CACHE_TXT="$(bhv5c6_cache_txt)"
  BH_BLOCKQ_TXT="$(bhv5c6_blockq_txt "${1:-}")"
  return 0
}

gather_info() {
  BH_HOSTNAME="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
  BH_OS="$( ( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true )"
  [ -n "$BH_OS" ] || BH_OS="$(uname -s 2>/dev/null || echo unknown)"
  BH_KERNEL="$(uname -r 2>/dev/null || echo unknown)"
  BH_ARCH="$(uname -m 2>/dev/null || echo unknown)"
  BH_UPTIME="$(awk '{u=int($1); d=int(u/86400); h=int(u%86400/3600); m=int(u%3600/60); if(d>0) printf "%dd %dh %dm", d, h, m; else printf "%dh %dm", h, m}' /proc/uptime 2>/dev/null)"

  # ---- CPU ----
  BH_CPU_MODEL="$(cpu_brand)"
  BH_CPU_LOGICAL="$(awk '/^processor/{n++} END{ if (n>0) print n; else print 0 }' /proc/cpuinfo 2>/dev/null)"
  [ -z "$BH_CPU_LOGICAL" ] || [ "$BH_CPU_LOGICAL" = "0" ] && BH_CPU_LOGICAL="$NCPU"
  # physical cores: unique (socket, core) pairs via lscpu, else logical count
  BH_CPU_PHYS=""
  if command_exists lscpu; then
    BH_CPU_PHYS="$(lscpu -p=CPU,CORE,SOCKET 2>/dev/null | grep -v '^#' | awk -F, '$2!="" && $2!="-" {print $2","$3}' | sort -u | wc -l | tr -d ' ')"
  fi
  [ -n "$BH_CPU_PHYS" ] && [ "$BH_CPU_PHYS" -ge 1 ] 2>/dev/null || BH_CPU_PHYS="$BH_CPU_LOGICAL"
  # ---- CPU flags: work on x86_64 ("flags") AND aarch64 ("Features") ----
  # Collect the raw flag word list once; every feature list below derives from
  # it. ARM /proc/cpuinfo (armv7 + arm64) names the line "Features", x86
  # "flags". Starting at field $2 keeps the ":" separator (harmless — no
  # keyword contains a colon) and survives kernels that omit the space after
  # the colon. Multiple lines are merged, like the pre-v4 behaviour.
  local arch allfl kw aif crf
  arch="$BH_ARCH"
  [ -n "$arch" ] || arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    aarch64*|arm64*|armv7*|armv8*|arm*)
      allfl="$(awk '/^Features/{for(i=2;i<=NF;i++) printf "%s ", $i}' /proc/cpuinfo 2>/dev/null)"
      ;;
    *)
      allfl="$(awk '/^flags/{for(i=2;i<=NF;i++) printf "%s ", $i}' /proc/cpuinfo 2>/dev/null)"
      ;;
  esac
  # headline features — same values as v3: "avx512 avx2 aes vmx svm"
  BH_CPU_FLAGS_HI=""
  bh_flag_has "$allfl" avx512f && BH_CPU_FLAGS_HI="avx512"
  bh_flag_has "$allfl" avx2    && BH_CPU_FLAGS_HI="${BH_CPU_FLAGS_HI:+$BH_CPU_FLAGS_HI }avx2"
  bh_flag_has "$allfl" aes     && BH_CPU_FLAGS_HI="${BH_CPU_FLAGS_HI:+$BH_CPU_FLAGS_HI }aes"
  bh_flag_has "$allfl" vmx     && BH_CPU_FLAGS_HI="${BH_CPU_FLAGS_HI:+$BH_CPU_FLAGS_HI }vmx"
  bh_flag_has "$allfl" svm     && BH_CPU_FLAGS_HI="${BH_CPU_FLAGS_HI:+$BH_CPU_FLAGS_HI }svm"

  # ---- ISA inventory (C3): AI/ML + crypto extensions, comma lists ----
  # On ARM the Features list has no avx*/amx* words (so BH_CPU_AI_FEAT stays
  # "" there) but does carry "aes" and sometimes "bf16" — both are matched.
  aif=""; crf=""
  for kw in avx512f avx512_vnni avx512_fp16 amx_tile amx_int8 amx_bf16 bf16; do
    bh_flag_has "$allfl" "$kw" && aif="${aif:+$aif,}$kw"
  done
  BH_CPU_AI_FEAT="$aif"
  for kw in vaes sha_ni gfni aes vpclmulqdq; do
    bh_flag_has "$allfl" "$kw" && crf="${crf:+$crf,}$kw"
  done
  BH_CPU_CRYPTO_FEAT="$crf"

  # ---- microcode / stepping (C5, x86 only — "" on ARM) ----
  BH_CPU_UCODE=""; BH_CPU_STEPPING=""
  case "$arch" in
    aarch64*|arm64*|armv7*|armv8*|arm*) : ;;
    *)
      # field order is "stepping\t: 1" — the value is the LAST field
      BH_CPU_UCODE="$(awk '/^microcode/{print $NF; exit}' /proc/cpuinfo 2>/dev/null)"
      # fallback: x2APIC-less kernels sometimes drop the cpuinfo line
      if [ -z "$BH_CPU_UCODE" ] && [ -r /sys/devices/system/cpu/cpu0/microcode/revision ]; then
        BH_CPU_UCODE="$(tr -d ' \t\n\r' < /sys/devices/system/cpu/cpu0/microcode/revision 2>/dev/null)"
      fi
      BH_CPU_STEPPING="$(awk '/^stepping/{print $NF; exit}' /proc/cpuinfo 2>/dev/null)"
      ;;
  esac

  # ---- CPU extras: steal %, current frequency, cpuset size ----
  BH_STEAL_PCT="$(bh_cpu_steal_pct)"
  local fq
  fq=""
  if command_exists lscpu; then
    fq="$(lscpu 2>/dev/null | awk -F: '/^CPU MHz/{gsub(/[^0-9.]/, "", $2); if ($2 != "") { print $2; exit } }')"
    [ -z "$fq" ] && fq="$(lscpu 2>/dev/null | awk -F: '/^CPU max MHz/{gsub(/[^0-9.]/, "", $2); if ($2 != "") { print $2; exit } }')"
  fi
  [ -z "$fq" ] && fq="$(awk -F: '/^cpu MHz/{gsub(/[^0-9.]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  BH_CPU_FREQ_MHZ="$fq"
  # count cores in a cpuset string like "0-3,5" (=> 5); 0 when empty
  BH_CPUSET_N="$(awk -v s="$CPUSET" 'BEGIN{
    gsub(/[ \t]/, "", s)
    if (s == "") { print 0; exit }
    n = 0; m = split(s, p, ",")
    for (i = 1; i <= m; i++) {
      if (p[i] ~ /-/) { split(p[i], r, "-"); if (r[2]+0 >= r[1]+0) n += r[2] - r[1] + 1; else n++ }
      else if (p[i] != "") n++
    }
    print n
  }' 2>/dev/null)"
  case "$BH_CPUSET_N" in ''|*[!0-9]*) BH_CPUSET_N=0 ;; esac

  # ---- CPU vulnerability matrix (C2) ----
  # Worst list = every entry whose content contains "Vulnerable";
  # "Mitigation: ..." and "Not affected" are fine and NOT counted.
  # Scope says whose kernel the results describe: inside a container the
  # sysfs entries belong to the HOST kernel (BH_KIND comes from 10-detect).
  BH_VULN_WORST=""; BH_VULN_TOTAL=0; BH_VULN_SCOPE="unknown"
  local vdir vf vname vtxt
  vdir="/sys/devices/system/cpu/vulnerabilities"
  if [ -d "$vdir" ] && [ -r "$vdir" ]; then
    case "${BH_KIND:-}" in
      container) BH_VULN_SCOPE="host-kernel" ;;
      *)         BH_VULN_SCOPE="kernel" ;;
    esac
    for vf in "$vdir"/*; do
      [ -r "$vf" ] || continue  # -r implies readable+existing
      vname="${vf##*/}"
      vtxt="$(tr -d '\n\r\t' < "$vf" 2>/dev/null)"
      case "$vtxt" in
        *Vulnerable*)
          BH_VULN_WORST="${BH_VULN_WORST:+$BH_VULN_WORST,}$vname"
          BH_VULN_TOTAL=$(( BH_VULN_TOTAL + 1 ))
          ;;
      esac
    done
  fi

  # ---- cgroup limits (report the REAL config, not the host's) ----
  BH_MEM_LIMIT_MB="$MEM_LIMIT_KB"
  if [ "${MEM_LIMIT_KB:-0}" -gt 0 ] 2>/dev/null; then
    BH_MEM_LIMIT_MB=$(( MEM_LIMIT_KB / 1024 ))
  else
    BH_MEM_LIMIT_MB=0
  fi
  if [ "${QUOTA_CORES:-0}" != "0" ] 2>/dev/null; then
    BH_CPU_QUOTA_TXT=$(awk -v q="$QUOTA_CORES" 'BEGIN{printf "%.2f", q}')
  else
    BH_CPU_QUOTA_TXT=""
  fi

  # ---- memory ----
  local mt ma sw
  mt="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  ma="$(awk '/^MemAvailable:/{print $2; found=1} END{ if (!found) print "" }' /proc/meminfo 2>/dev/null)"
  [ -z "$ma" ] && ma="$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)"
  sw="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  BH_MEM_TOTAL_MB=$(( ${mt:-0} / 1024 ))
  BH_MEM_AVAIL_MB=$(( ${ma:-0} / 1024 ))
  BH_MEM_SWAP_MB=$(( ${sw:-0} / 1024 ))
  if [ "$BH_MEM_LIMIT_MB" -gt 0 ] 2>/dev/null; then
    BH_MEM_EFF_MB="$BH_MEM_LIMIT_MB"
    [ "$BH_MEM_TOTAL_MB" -gt 0 ] && [ "$BH_MEM_TOTAL_MB" -lt "$BH_MEM_EFF_MB" ] && BH_MEM_EFF_MB="$BH_MEM_TOTAL_MB"
  else
    BH_MEM_EFF_MB="$BH_MEM_TOTAL_MB"
  fi

  # ---- THP / hugepages / swap detail ----
  if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
    BH_THP="$(bh_bracketed /sys/kernel/mm/transparent_hugepage/enabled)"
  fi
  BH_HUGEPAGES_TOTAL="$(awk '/^HugePages_Total:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  # "512 MB total / 511 MB free", or "none" when there is no swap
  if [ -n "$sw" ] && [ "$sw" -gt 0 ] 2>/dev/null; then
    local swf
    swf="$(awk '/^SwapFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
    BH_SWAP_DETAIL="$(( sw / 1024 )) MB total / $(( ${swf:-0} / 1024 )) MB free"
  else
    BH_SWAP_DETAIL="none"
  fi

  # ---- KSM: kernel same-page merging (C6) ----
  # /sys/kernel/mm/ksm/run: 1 = enabled; 0 = disabled; missing -> unknown.
  # pages_sharing > 0 means dedup is actually saving memory right now.
  BH_KSM_STATE="unknown"; BH_KSM_SHARING=""
  if [ -r /sys/kernel/mm/ksm/run ]; then
    local krun ksh
    krun="$(tr -d ' \t\n\r' < /sys/kernel/mm/ksm/run 2>/dev/null)"
    case "$krun" in
      1) BH_KSM_STATE="on" ;;
      0) BH_KSM_STATE="off" ;;
      *) BH_KSM_STATE="unknown" ;;
    esac
    if [ -r /sys/kernel/mm/ksm/pages_sharing ]; then
      ksh="$(tr -d ' \t\n\r' < /sys/kernel/mm/ksm/pages_sharing 2>/dev/null)"
      case "$ksh" in
        ''|*[!0-9]*) : ;;
        *) [ "$ksh" -gt 0 ] 2>/dev/null && BH_KSM_SHARING="$ksh" ;;
      esac
    fi
  fi

  # ---- disk (target dir) ----
  mkdir -p "$BH_DISK_DIR" 2>/dev/null || true
  local dfl
  dfl="$(df -P "$BH_DISK_DIR" 2>/dev/null | awk 'NR==2{print $1, $2, $4}')"
  BH_DISK_DEV="$(printf '%s' "$dfl" | awk '{print $1}')"
  BH_DISK_TOTAL_MB=$(awk -v k="$(printf '%s' "$dfl" | awk '{print $2}')" 'BEGIN{printf "%d", k/1024}')
  BH_DISK_AVAIL_MB=$(awk -v k="$(printf '%s' "$dfl" | awk '{print $3}')" 'BEGIN{printf "%d", k/1024}')
  if command_exists df && df -T "$BH_DISK_DIR" >/dev/null 2>&1; then
    BH_DISK_FS="$(df -PT "$BH_DISK_DIR" 2>/dev/null | awk 'NR==2{print $2}')"
  else
    BH_DISK_FS=""
  fi
  [ -n "$BH_DISK_FS" ] || BH_DISK_FS="unknown"

  # ---- disk identity (physical device behind the bench dir) ----
  local base rp q rv raw nb
  base=""
  if [ -n "$BH_DISK_DEV" ] && command_exists lsblk; then
    base="$(lsblk -no PKNAME "$BH_DISK_DEV" 2>/dev/null | head -n 1 | tr -d ' \t')"
  fi
  if [ -z "$base" ] && [ -n "$BH_DISK_DEV" ]; then
    rp="$(readlink -f "$BH_DISK_DEV" 2>/dev/null)"
    [ -n "$rp" ] && base="$(basename "$rp" 2>/dev/null)"
  fi
  q="/sys/block/$base/queue"
  # fallback: partition device without lsblk — drop the trailing digits (sda1 -> sda)
  if [ -n "$base" ] && [ ! -d "$q" ]; then
    nb="${base%[0-9]*}"
    if [ -n "$nb" ] && [ -d "/sys/block/$nb/queue" ]; then
      base="$nb"; q="/sys/block/$base/queue"
    fi
  fi
  if [ -n "$base" ] && [ -d "$q" ]; then
    if [ -r "$q/rotational" ]; then
      rv="$(tr -d '\n' < "$q/rotational" 2>/dev/null)"
      case "$rv" in 0|1) BH_DISK_ROTA="$rv" ;; esac
    fi
    if [ -r "$q/scheduler" ]; then
      BH_DISK_SCHED="$(bh_bracketed "$q/scheduler")"
      if [ -z "$BH_DISK_SCHED" ]; then
        # no bracketed token: only the literal "none" is meaningful then
        raw="$(tr -d '\n' < "$q/scheduler" 2>/dev/null)"
        [ "$raw" = "none" ] && BH_DISK_SCHED="none"
      fi
    fi
  fi
  case "$base" in
    nvme*) BH_DISK_CLASS="NVMe" ;;
    *)
      case "$BH_DISK_ROTA" in
        0) BH_DISK_CLASS="SSD" ;;
        1) BH_DISK_CLASS="HDD" ;;
        *) BH_DISK_CLASS="unknown" ;;
      esac
      ;;
  esac

  # ---- deep-scan extras (v2: dò thêm nhiều thứ) ----
  BH_DNS="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | head -n 3 | paste -sd ',' -)"
  BH_TCPCC="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  BH_TCPCC_AVAIL="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  BH_ENTROPY="$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)"
  [ -c /dev/net/tun ] && BH_TUN=1
  [ -c /dev/fuse ]    && BH_FUSE=1
  [ -c /dev/ppp ]     && BH_PPP=1
  BH_LOAD="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  # count PIDs; guard against the unmatched-glob literal ("/proc/[0-9]*")
  # when /proc is not mounted, which would otherwise report 1 "process"
  BH_PROCS="$(set -- /proc/[0-9]*; if [ -d "$1" ]; then echo $#; else echo 0; fi)"
  BH_TZ="$(cat /etc/timezone 2>/dev/null || date +%Z 2>/dev/null)"

  # first non-lo interface MTU ("" unknown)
  local ndev
  for ndev in /sys/class/net/*/mtu; do
    [ -e "$ndev" ] || continue
    case "$ndev" in */lo/mtu) continue ;; esac
    [ -r "$ndev" ] || continue
    BH_NET_MTU="$(tr -d '\n' < "$ndev" 2>/dev/null)"
    [ -n "$BH_NET_MTU" ] && break
  done

  # ---- network identity — MOVED OUT (v4.0, bug G4) ----
  # The egress-IP / geo / ASN lookups (ipify + ip-api) now live in the net
  # module (60-net.sh); cloud metadata stays in 12-cloud.sh (cloud_metadata_probe).
  # This module therefore makes ZERO network calls ever: `sec` mode and
  # BH_NO_NET=1 stay fully offline. BH_IPV4 / BH_IPV6 / BH_IP_GEO / BH_IP_ASN
  # are declared above ("" default) and are filled by the module that owns them.

  # ---- v5 (C6) hardware extras: CPU cache topology + bench-disk queue params ----
  # "$base" is the disk base device resolved above (same one used for
  # rotational/scheduler); empty when unresolvable — the helper re-derives.
  # NOTE: BH_CPUFREQ_TXT belongs to 16-hw-deep and is NOT set here.
  bhv5c6_hw_extra "$base"
  return 0
}
