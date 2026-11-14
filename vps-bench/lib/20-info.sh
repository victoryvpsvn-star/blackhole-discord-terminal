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

  # ---- network identity (optional) ----
  if [ "$BH_NO_NET" != "1" ] && command_exists curl; then
    BH_IPV4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null | head -c 64)"
    local geo
    geo="$(curl -fsS --max-time 8 'http://ip-api.com/line/?fields=country,regionName,city,isp' 2>/dev/null | tr '\n' '|' )"
    BH_IP_GEO="${geo%|}"
    BH_IP_ASN="$(curl -fsS --max-time 8 'http://ip-api.com/line/?fields=as' 2>/dev/null | head -c 128)"
    BH_IPV6="$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null | head -c 64)"
    probe_cloud_meta
  fi
}

# Best-effort cloud metadata probes (only when network is allowed)
probe_cloud_meta() {
  case "$BH_DMI_VENDOR" in
    "Microsoft Corporation")
      local az
      az="$(curl -fsS --max-time 3 -H 'Metadata:true' 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' 2>/dev/null | sed -n 's/.*"vmSize"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
      if [ -n "$az" ]; then
        BH_CLOUD="Microsoft Azure"
        BH_CLOUD_DETAIL="$az"
      fi
      ;;
    Google)
      local gcp
      gcp="$(curl -fsS --max-time 3 -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/machine-type' 2>/dev/null | awk -F/ '{print $NF}')"
      if [ -n "$gcp" ]; then
        BH_CLOUD="Google Cloud"
        BH_CLOUD_DETAIL="$gcp"
      fi
      ;;
    "Amazon EC2")
      BH_CLOUD="AWS EC2"
      ;;
    *)
      :
      ;;
  esac
}
