# =====================================================================
# blackhole-vps-bench · 20-info.sh — system info + cgroup limits + IP/cloud
# =====================================================================
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

# bh_bracketed FILE — print the value of the [bracketed] token in FILE ("" if none)
bh_bracketed() {
  [ -r "$1" ] || return 0
  awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\[.*\]$/) { gsub(/[\[\]]/, "", $i); print $i; exit } }' "$1" 2>/dev/null
  return 0
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
  local fl
  fl="$(awk '/^flags/{for(i=2;i<=NF;i++){f[$i]=1}} END{print (f["avx512f"]?"avx512 ":"") (f["avx2"]?"avx2 ":"") (f["aes"]?"aes ":"") (f["vmx"]?"vmx ":"") (f["svm"]?"svm ":"")}' /proc/cpuinfo 2>/dev/null)"
  BH_CPU_FLAGS_HI="${fl% }"

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

  # ---- network identity (optional) ----
  if [ "$BH_NO_NET" != "1" ] && command_exists curl; then
    BH_IPV4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null | head -c 64)"
    local geo
    geo="$(curl -fsS --max-time 8 'http://ip-api.com/line/?fields=country,regionName,city,isp' 2>/dev/null | tr '\n' '|' )"
    BH_IP_GEO="${geo%|}"
    BH_IP_ASN="$(curl -fsS --max-time 8 'http://ip-api.com/line/?fields=as' 2>/dev/null | head -c 128)"
    BH_IPV6="$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null | head -c 64)"
    # cloud metadata probing moved to 12-cloud.sh (cloud_metadata_probe)
    if command_exists cloud_metadata_probe; then
      cloud_metadata_probe
    fi
  fi
}
