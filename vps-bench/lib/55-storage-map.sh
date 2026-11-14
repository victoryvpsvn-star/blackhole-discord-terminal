# =====================================================================
# blackhole-vps-bench · 55-storage-map.sh — storage topology map (passive)
# =====================================================================
#
# v4.0 (W3-I): answers "what storage am I REALLY on?" without writing a
# single byte to disk (throughput numbers live in 50-disk.sh, never here):
#   S1  real-fs tree from /proc/mounts        -> BH_FS_TREE, BH_MOUNT_FLAGS_ROOT
#   S2  root backing stack resolution         -> BH_ROOT_STACK (+ BH_ROOT_CLASS)
#   S3  stacking detection md / LVM / zfs     -> BH_STORAGE_STACKS
#   S4  zram config + compression ratio       -> BH_ZRAM
#   S5  zswap + swap kinds                    -> BH_ZSWAP, BH_SWAP_KIND
#   S8  NVMe controller detail (PCIe gen)     -> BH_NVME_INFO
#   R5  raw disk model strings (oversell ev.) -> BH_DISK_MODELS
#   one-line verdict                          -> BH_STORAGE_SUMMARY
#
# Contract: sets BH_* globals only (never stdout); every potentially-slow
# external command is guarded (command_exists + `timeout 2` via bh_t2);
# NO network access; no `set -e`; bash-3.2 compatible (no assoc arrays /
# mapfile); never fails: unreadable input => ""/no/unknown.
#
# Semantics of a few tokens:
#   BH_FS_TREE:  "<mnt>:<fstype>(<opts>)" joined by " | ", root first, max 4
#                entries; an asterisk on the fstype ("overlay*") marks a
#                COW/overlay stack — the classic container "disk" that is
#                not a disk at all.
#   BH_ROOT_STACK: resolved chain, e.g. "vda (virtio)" or
#                "dm-0 -> LVM lv_root -> sda+sdb". Container/COW roots show
#                the real visible backing devices instead:
#                "overlay (container root) -> vda (virtio)".
#   BH_ROOT_CLASS: hardware class of the real backing storage:
#                virtio|nvme|scsi|xen|pmem|zram|loop|overlay/<class>|unknown.
#   BH_TRIM_SUPPORT is OWNED BY 50-disk.sh — read here when set, never
#   recomputed ("?" in the summary when 50-disk did not run/measure it).
# shellcheck shell=bash

# ------- globals (empty / neutral defaults) -------
BH_FS_TREE=""          # "/:overlay*(rw,relatime) | /data:ext4(rw)" (max 4)
BH_MOUNT_FLAGS_ROOT="" # "relatime" | "noatime commit=30" | "" = plain defaults
BH_ROOT_STACK=""       # "vda (virtio)" | "dm-0 -> LVM lv_root -> sda+sdb"
BH_ROOT_CLASS=""       # virtio|nvme|scsi|xen|pmem|zram|loop|overlay/<x>|unknown
BH_STORAGE_STACKS=""   # "md:no lvm:yes zfs:no btrfs:no"
BH_ZRAM=""             # "1 dev 4.0G ratio 2.7x" | "no" | "no (unconfigured dev)"
BH_ZSWAP=""            # "on 20% lzo" | "off" | "off (not loaded)"
BH_SWAP_KIND=""        # "zram none | disk none" | "zram 2G prio100 | disk 4G"
BH_NVME_INFO=""        # "nvme0 SAMSUNG MZQL296H, PCIe4 x4 pcie" | "" = no nvme
BH_DISK_MODELS=""      # "QEMU_HARDDISK,INTEL SSDSC2KB019T" (max 3, deduped)
BH_STORAGE_SUMMARY=""  # "root=virtio stack=none zram=no trim=yes"

# bh_t2 CMD... — run a possibly-hanging external command under `timeout 2`
# when available (same pattern as 85-hardening.sh / 10-detect.sh).
bh_t2() {
  if command_exists timeout; then
    timeout 2 "$@" 2>/dev/null </dev/null
  else
    "$@" 2>/dev/null </dev/null
  fi
}

# bh_trim — pure-bash leading/trailing whitespace strip (model strings are
# space-padded in sysfs and DMI garbage may trail them).
bh_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# bh_humansz BYTES — compact size token: 4294967296 -> "4.0G", 0 -> "0B".
bh_humansz() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b+0 <= 0) { print "0B"; exit }
    split("B,K,M,G,T,P", u, ","); i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%dB", int(b)
    else if (b >= 100) printf "%.0f%s", b, u[i]
    else printf "%.1f%s", b, u[i]
  }' 2>/dev/null
}

# bh_opts_compact RAW_OPTS — drop the per-fs mega options (overlay lowerdir/
# upperdir/workdir lists can be kilobytes) and cap the rest at 48 chars.
bh_opts_compact() {
  # shellcheck disable=SC2086  # intentional word split on commas
  local t o=""
  for t in $(printf '%s' "$1" | tr ',' ' '); do
    case "$t" in
      lowerdir=*|upperdir=*|workdir=*) continue ;;
    esac
    o="${o:+$o,}$t"
  done
  if [ "${#o}" -gt 48 ]; then o="${o:0:48}..."; fi
  printf '%s' "$o"
}

# bh_parent_disk NAME — fold a partition name to its sysfs disk parent:
# vda1->vda, sda12->sda, nvme0n1p2->nvme0n1, mmcblk0p3->mmcblk0. Prints ""
# when NAME is already a disk (or has no /sys/block entry).
bh_parent_disk() {
  local d="$1" p
  [ -n "$d" ] || { printf ''; return 0; }
  [ -d "/sys/block/$d" ] && { printf ''; return 0; }
  # nvme/mmcblk-style partitions first: nvme0n1p2 -> nvme0n1, mmcblk0p3 -> mmcblk0
  case "$d" in
    *p[0-9]*) p="${d%p*}"; [ -d "/sys/block/$p" ] && { printf '%s' "$p"; return 0; } ;;
  esac
  p="${d%[0-9]}"                       # vda1->vda, sda12->sda1->sda
  while [ -n "$p" ] && [ "$p" != "$d" ]; do
    [ -d "/sys/block/$p" ] && { printf '%s' "$p"; return 0; }
    d="$p"; p="${d%[0-9]}"
  done
  printf ''
  return 0
}

# bh_transport_of DEV — bus/driver class of a sysfs block device:
# virtio | virtio-scsi | nvme | scsi | xen | pmem | usb | loop | "" unknown.
bh_transport_of() {
  local d="$1" drv sub
  [ -n "$d" ] || { printf ''; return 0; }
  case "$d" in
    pmem*) printf 'pmem'; return 0 ;;
    loop*) printf 'loop'; return 0 ;;
    ram*)  printf 'ram';  return 0 ;;
    zram*) printf 'zram'; return 0 ;;
  esac
  if [ -L "/sys/block/$d/device/driver" ]; then
    drv="$(basename "$(readlink -f "/sys/block/$d/device/driver" 2>/dev/null)" 2>/dev/null)"
  fi
  case "$drv" in
    virtio_blk)  printf 'virtio';      return 0 ;;
    virtio_scsi) printf 'virtio-scsi'; return 0 ;;
    virtio_pmem) printf 'pmem';        return 0 ;;
    xen_blk|xen_vbd) printf 'xen';     return 0 ;;
    nvme)        printf 'nvme';        return 0 ;;
    sd|sr)       printf 'scsi';        return 0 ;;
    usb_storage|uas) printf 'usb';     return 0 ;;
  esac
  if [ -L "/sys/block/$d/device/subsystem" ]; then
    sub="$(basename "$(readlink -f "/sys/block/$d/device/subsystem" 2>/dev/null)" 2>/dev/null)"
    case "$sub" in
      virtio|nvme|scsi|usb) printf '%s' "$sub"; return 0 ;;
      nd)                   printf 'pmem';      return 0 ;;
      *) [ -n "$sub" ] && [ "$sub" != "block" ] && { printf '%s' "$sub"; return 0; } ;;
    esac
  fi
  printf ''
  return 0
}

# bh_chain_of DEV DEPTH — resolve one backing-stack level, printing a chain
# fragment: "vda (virtio)", "dm-0 -> LVM lv_root -> sda+sdb", "md0(raid1) ->
# sda+sdb", "zram". Recursion depth capped at 3 (subshell recursion, so no
# global state leaks between levels).
bh_chain_of() {
  local d="$1" depth="$2" p uuid dmname lvl sl s frag out
  [ "$depth" -le 3 ] 2>/dev/null || { printf '?'; return 0; }
  d="${d#/dev/}"
  [ -n "$d" ] || { printf '?'; return 0; }
  if [ ! -d "/sys/block/$d" ]; then
    p="$(bh_parent_disk "$d")"
    if [ -n "$p" ]; then d="$p"; else printf '%s' "$d"; return 0; fi
  fi
  case "$d" in
    dm-*)
      uuid="$(tr -d ' \t\n\r' < "/sys/block/$d/dm/uuid" 2>/dev/null)"
      dmname="$(tr -d ' \t\n\r' < "/sys/block/$d/dm/name" 2>/dev/null)"
      case "$uuid" in
        LVM-*)   frag="LVM ${dmname:-$d}" ;;
        CRYPT-*) frag="crypt ${dmname:-$d}" ;;
        *)       frag="dm ${dmname:-$d}" ;;
      esac
      out=""
      for sl in /sys/block/"$d"/slaves/*; do
        [ -e "$sl" ] || continue
        s="$(bh_chain_of "${sl##*/}" $(( depth + 1 )))"
        out="${out:+$out+}$s"
      done
      if [ -n "$out" ]; then printf '%s -> %s' "$frag" "$out"; else printf '%s' "$frag"; fi
      return 0
      ;;
    md*)
      lvl="$(awk -v m="$d" '$1==m{for(i=1;i<=NF;i++) if ($i ~ /^raid[0-9]+$/ || $i=="linear" || $i=="multipath") {print $i; exit}}' /proc/mdstat 2>/dev/null)"
      out=""
      for sl in /sys/block/"$d"/slaves/*; do
        [ -e "$sl" ] || continue
        s="$(bh_chain_of "${sl##*/}" $(( depth + 1 )))"
        out="${out:+$out+}$s"
      done
      if [ -n "$lvl" ]; then printf '%s(%s)' "$d" "$lvl"; else printf '%s' "$d"; fi
      [ -n "$out" ] && printf ' -> %s' "$out"
      return 0
      ;;
    zram*) printf 'zram'; return 0 ;;
    loop*) printf 'loop'; return 0 ;;
    ram*)  printf 'ram';  return 0 ;;
  esac
  s="$(bh_transport_of "$d")"
  if [ -n "$s" ]; then printf '%s (%s)' "$d" "$s"; else printf '%s' "$d"; fi
  return 0
}

# bh_root_class_from_stack STACK — extract the hardware class of the backing
# leaf from a rendered chain/vis string ("(virtio)" / "(nvme)" markers).
bh_root_class_from_stack() {
  # shellcheck disable=SC2254  # intentional whole-word case matching
  case "$1" in
    *"(virtio)"*|*"(virtio-scsi)"*) printf 'virtio' ;;
    *"(nvme)"*)                     printf 'nvme' ;;
    *"(pmem)"*)                     printf 'pmem' ;;
    *"(xen)"*)                      printf 'xen' ;;
    *"(scsi)"*|*"(usb)"*|*"(sata)"*) printf 'scsi' ;;
    *"(loop)"*)                     printf 'loop' ;;
    *"zram"*)                       printf 'zram' ;;
    *)                              printf '' ;;
  esac
  return 0
}

gather_storage_map() {
  # ================= S1: real-fs tree from /proc/mounts =================
  BH_FS_TREE=""
  BH_MOUNT_FLAGS_ROOT=""
  local ents="" root_e="" e mnt fst opts root_opts=""
  if [ -r /proc/mounts ]; then
    while read -r _bhdev mnt fst opts _bhrest; do
      [ -n "$fst" ] || continue
      case "$fst" in
        proc|sysfs|devtmpfs|devpts|mqueue|securityfs|selinuxfs|tmpfs|ramfs|\
        cgroup|cgroup2|hugetlbfs|bpf|debugfs|tracefs|fusectl|configfs|pstore|\
        autofs|binfmt_misc|nsfs|rpc_pipefs|efivarfs|openpromfs|none) continue ;;
      esac
      [ "$mnt" = "/" ] && root_opts="$opts"
      case "$fst" in overlay) fst="overlay*" ;; esac   # * = COW/overlay stack marker
      e="$mnt:$fst($(bh_opts_compact "$opts"))"
      if [ "$mnt" = "/" ]; then
        root_e="$e"
      else
        ents="${ents}${e}"$'\n'
      fi
    done < /proc/mounts
    if [ -n "$root_e" ]; then BH_FS_TREE="$root_e"; fi
    local tn=0
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      tn=$(( tn + 1 )); [ "$tn" -gt 3 ] && break
      BH_FS_TREE="${BH_FS_TREE:+$BH_FS_TREE | }$e"
    done <<< "$ents"
    # root mount flags: atime behaviour + commit=N when present
    if [ -n "$root_opts" ]; then
      local atok atflg=""
      # shellcheck disable=SC2086  # intentional word split on commas
      for atok in $(printf '%s' "$root_opts" | tr ',' ' '); do
        case "$atok" in
          noatime|nodiratime|relatime|strictatime) atflg="${atflg:+$atflg }$atok" ;;
          commit=*) atflg="${atflg:+$atflg }$atok" ;;
        esac
      done
      BH_MOUNT_FLAGS_ROOT="$(bh_trim "$atflg")"
    fi
  fi

  # ================= S2: root backing stack =================
  BH_ROOT_STACK=""
  BH_ROOT_CLASS=""
  local rsrc="" rdev="" rfs="" vis="" vname vtra pass cnt cls tag
  if command_exists findmnt; then
    rsrc="$(bh_t2 findmnt -no SOURCE / | head -n 1)"
  fi
  [ -n "$rsrc" ] || rsrc="$(awk '$2=="/" && $1!="" {print $1; exit}' /proc/mounts 2>/dev/null)"
  rfs="$(awk '$2=="/" {print $3; exit}' /proc/mounts 2>/dev/null)"
  if [ -n "$rsrc" ]; then
    rdev="${rsrc#/dev/}"
    if [ -d "/sys/block/$rdev" ] || [ -n "$(bh_parent_disk "$rdev")" ]; then
      BH_ROOT_STACK="$(bh_chain_of "$rdev" 1)"
    fi
  fi
  if [ -z "$BH_ROOT_STACK" ]; then
    # not a plain block device: container overlay / virtiofs / 9p / NFS root.
    # Show the COW/network marker plus the real block devices visible here
    # (those are what actually backs the data — instant oversell evidence).
    # Prefer classic disks first, exotic (pmem) second, max 2 entries.
    cnt=0
    for pass in 1 2; do
      for vname in /sys/block/*; do
        [ -e "$vname" ] || continue
        vname="${vname##*/}"
        case "$vname" in zram*|loop*|ram*|sr*|fd*|md*|dm-*) continue ;; esac
        case "$pass" in
          1) case "$vname" in vd*|sd*|nvme*|hd*|xvd*) : ;; *) continue ;; esac ;;
          2) case "$vname" in vd*|sd*|nvme*|hd*|xvd*) continue ;; esac ;;
        esac
        vtra="$(bh_transport_of "$vname")"
        vis="${vis:+$vis + }${vname}${vtra:+ ($vtra)}"
        cnt=$(( cnt + 1 )); [ "$cnt" -ge 2 ] && break
      done
      [ "$cnt" -ge 2 ] && break
    done
    tag="${rfs:-unknown}"
    if [ -n "$vis" ]; then
      BH_ROOT_STACK="$tag (container root) -> $vis"
    else
      BH_ROOT_STACK="$tag (container root, no block dev visible)"
    fi
  fi
  cls="$(bh_root_class_from_stack "$BH_ROOT_STACK")"
  case "$rfs" in
    overlay) [ -n "$cls" ] && BH_ROOT_CLASS="overlay/$cls" || BH_ROOT_CLASS="overlay" ;;
    *)       [ -n "$cls" ] && BH_ROOT_CLASS="$cls" || BH_ROOT_CLASS="unknown" ;;
  esac

  # ================= S3: stacking detection (md / LVM / zfs / btrfs) =====
  local mdcnt=0 lvm="no" zhas="no" btrcnt=0 btrtxt mdtxt dmu
  mdcnt="$(awk '$1 ~ /^md[0-9]+$/ && $3 ~ /^active/ {c++} END{print c+0}' /proc/mdstat 2>/dev/null)"
  case "$mdcnt" in ''|*[!0-9]*) mdcnt=0 ;; esac
  for dmu in /sys/block/dm-*/dm/uuid; do
    [ -e "$dmu" ] || continue
    case "$(tr -d ' \t\n\r' < "$dmu" 2>/dev/null)" in
      LVM-*) lvm="yes" ;;
    esac
  done
  if command_exists zfs; then
    [ -n "$(bh_t2 zfs list -H -o name | head -n 3)" ] && zhas="yes"
  fi
  if command_exists btrfs; then
    btrcnt="$(bh_t2 btrfs filesystem show | awk '/^Label:/{c++} END{print c+0}' 2>/dev/null)"
    case "$btrcnt" in ''|*[!0-9]*) btrcnt=0 ;; esac
  fi
  [ "$btrcnt" -gt 0 ] 2>/dev/null && btrtxt="$btrcnt" || btrtxt="no"
  [ "$mdcnt" -gt 0 ] 2>/dev/null && mdtxt="$mdcnt" || mdtxt="no"
  BH_STORAGE_STACKS="md:$mdtxt lvm:$lvm zfs:$zhas btrfs:$btrtxt"

  # ================= S4: zram =================
  BH_ZRAM="no"
  local zdevs=0 zd zsz ztot=0 zorig=0 zmem=0 zo zm ratio
  for zd in /sys/block/zram*; do
    [ -e "$zd" ] || continue
    zdevs=$(( zdevs + 1 ))
    zsz="$(tr -d ' \t\n\r' < "$zd/disksize" 2>/dev/null)"
    case "$zsz" in ''|*[!0-9]*) zsz=0 ;; esac
    ztot=$(( ztot + zsz ))
    if [ -r "$zd/mm_stat" ]; then
      read -r _zds zo zm _zmrest < "$zd/mm_stat" 2>/dev/null || { zo=0; zm=0; }
      case "$zo" in ''|*[!0-9]*) zo=0 ;; esac
      case "$zm" in ''|*[!0-9]*) zm=0 ;; esac
      zorig=$(( zorig + zo ))
      zmem=$(( zmem + zm ))
    fi
  done
  if [ "$zdevs" -gt 0 ]; then
    if [ "$ztot" -gt 0 ]; then
      BH_ZRAM="$zdevs dev $(bh_humansz "$ztot")"
      if [ "$zmem" -gt 0 ]; then
        ratio="$(awk -v o="$zorig" -v m="$zmem" 'BEGIN{ if (m+0>0) printf "%.1f", o/m; else print "" }' 2>/dev/null)"
        [ -n "$ratio" ] && BH_ZRAM="$BH_ZRAM ratio ${ratio}x" || BH_ZRAM="$BH_ZRAM (idle)"
      else
        BH_ZRAM="$BH_ZRAM (idle)"
      fi
    else
      BH_ZRAM="no (unconfigured dev)"
    fi
  fi

  # ================= S5: zswap + swap kinds =================
  BH_ZSWAP="off"
  local zp="/sys/module/zswap/parameters" zen zmp zc
  if [ -d "$zp" ]; then
    zen="$(tr -d ' \t\n\r' < "$zp/enabled" 2>/dev/null)"
    case "$zen" in
      Y|y|1)
        zmp="$(tr -d ' \t\n\r' < "$zp/max_pool_percent" 2>/dev/null)"
        zc="$(tr -d ' \t\n\r' < "$zp/compressor" 2>/dev/null)"
        case "$zmp" in ''|*[!0-9]*) zmp="" ;; esac
        BH_ZSWAP="on${zmp:+ ${zmp}%}${zc:+ ${zc}}"
        ;;
      *) BH_ZSWAP="off" ;;
    esac
  else
    BH_ZSWAP="off (not loaded)"
  fi
  BH_SWAP_KIND=""
  if [ -r /proc/swaps ]; then
    local zsztot=0 dsztot=0 zsprio="" sfn ssz sprio zpart="none" dpart="none"
    while read -r sfn _stype ssz _sused sprio _srest; do
      [ -n "$sfn" ] || continue
      case "$ssz" in ''|*[!0-9]*) ssz=0 ;; esac
      case "$sfn" in
        *zram*)
          zsztot=$(( zsztot + ssz ))
          case "$sprio" in ''|*[!0-9-]*) : ;;
            *) { [ -z "$zsprio" ] || [ "$sprio" -gt "$zsprio" ] 2>/dev/null; } && zsprio="$sprio" ;;
          esac
          ;;
        *) dsztot=$(( dsztot + ssz )) ;;
      esac
    done < /proc/swaps
    [ "$zsztot" -gt 0 ] && zpart="$(bh_humansz $(( zsztot * 1024 )))${zsprio:+ prio$zsprio}"
    [ "$dsztot" -gt 0 ] && dpart="$(bh_humansz $(( dsztot * 1024 )))"
    BH_SWAP_KIND="zram $zpart | disk $dpart"
  fi

  # ================= S8: NVMe controller detail =================
  BH_NVME_INFO=""
  local nseg nmodel nlsp pg nlw ntra nout=0
  for nseg in /sys/class/nvme/nvme*; do
    [ -e "$nseg" ] || continue
    nout=$(( nout + 1 )); [ "$nout" -gt 3 ] && break
    nmodel="$(tr -d '\r\n\t' < "$nseg/model" 2>/dev/null)"
    [ -n "$nmodel" ] || nmodel="$(tr -d '\r\n\t' < "$nseg/device/model" 2>/dev/null)"
    nmodel="${nmodel//[[:cntrl:]]/}"
    nmodel="$(bh_trim "$nmodel")"
    nlsp="$(tr -d ' \t\n\r' < "$nseg/device/current_link_speed" 2>/dev/null)"
    [ -n "$nlsp" ] || nlsp="$(tr -d ' \t\n\r' < "$nseg/device/max_link_speed" 2>/dev/null)"
    case "$nlsp" in
      2.5*) pg="PCIe1" ;;
      5.0*|5*)  pg="PCIe2" ;;
      8.0*|8*)  pg="PCIe3" ;;
      16.0*|16*) pg="PCIe4" ;;
      32.0*|32*) pg="PCIe5" ;;
      64.0*)    pg="PCIe6" ;;
      *)        pg="" ;;
    esac
    nlw="$(tr -d ' \t\n\r' < "$nseg/device/current_link_width" 2>/dev/null)"
    [ -n "$nlw" ] || nlw="$(tr -d ' \t\n\r' < "$nseg/device/max_link_width" 2>/dev/null)"
    case "$nlw" in ''|*[!0-9]*) nlw="" ;; esac
    ntra="$(tr -d ' \t\n\r' < "$nseg/transport" 2>/dev/null)"
    [ -n "$ntra" ] || ntra="$(basename "$(readlink -f "$nseg/device/driver" 2>/dev/null)" 2>/dev/null)"
    e="${nseg##*/}${nmodel:+ ${nmodel},}${pg:+ ${pg}}${nlw:+ x$nlw}${ntra:+ ${ntra}}"
    BH_NVME_INFO="${BH_NVME_INFO:+$BH_NVME_INFO | }$e"
  done

  # ================= R5: real disk model strings =================
  BH_DISK_MODELS=""
  local mf m mcnt=0
  for mf in /sys/block/*/device/model; do
    [ -f "$mf" ] && [ -r "$mf" ] || continue
    m="$(tr -d '\r\n\t' < "$mf" 2>/dev/null)"
    m="${m//[[:cntrl:]]/}"          # DMI/model strings can contain garbage bytes
    m="$(bh_trim "$m")"
    [ -n "$m" ] || continue
    case ",${BH_DISK_MODELS}," in *",$m,"*) continue ;; esac
    BH_DISK_MODELS="${BH_DISK_MODELS:+$BH_DISK_MODELS,}$m"
    mcnt=$(( mcnt + 1 )); [ "$mcnt" -ge 3 ] && break
  done

  # ================= one-line verdict =================
  local pair k v stackwords="" zr trs
  # shellcheck disable=SC2086  # intentional word split of "md:0 lvm:yes ..."
  for pair in $BH_STORAGE_STACKS; do
    k="${pair%%:*}"; v="${pair#*:}"
    case "$k:$v" in
      md:0|md:no|lvm:no|zfs:no|btrfs:0|btrfs:no) : ;;
      md:*)      stackwords="${stackwords:+$stackwords+}md" ;;
      lvm:yes)   stackwords="${stackwords:+$stackwords+}lvm" ;;
      zfs:yes)   stackwords="${stackwords:+$stackwords+}zfs" ;;
      btrfs:*)   stackwords="${stackwords:+$stackwords+}btrfs" ;;
    esac
  done
  [ -n "$stackwords" ] || stackwords="none"
  zr="no"; case "$BH_ZRAM" in no*) : ;; ?*) zr="yes" ;; esac
  trs="${BH_TRIM_SUPPORT:-}"
  [ -n "$trs" ] || trs="?"   # owned by 50-disk.sh; not recomputed here
  BH_STORAGE_SUMMARY="root=${BH_ROOT_CLASS:-unknown} stack=$stackwords zram=$zr trim=$trs"

  return 0
}
