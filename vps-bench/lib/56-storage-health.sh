# =====================================================================
# blackhole-vps-bench · 56-storage-health.sh — storage health (passive)
# =====================================================================
# v5.0 (C8): read-only storage-health signals. This module NEVER writes
# to any device: no smartctl -t (self-tests), no fstrim, no hdparm. It
# only reads sysfs/procfs and queries short-lived CLI states.
#   S1  SMART overall health via smartctl -H (root + smartctl + not
#       BH_FAST) plus nonzero raw counters of attribute IDs 5/197/198
#       via smartctl -A   -> BH_SMART_TXT
#       "sda: PASSED | sdb: FAILED reloc=8 pending=3"
#   S2  NVMe health: `nvme smart-log` when root+nvme, else the sysfs
#       hwmon temperature fallback
#                     -> BH_NVME_TXT "nvme0: used=12% spare=100% T=41C"
#       fallback:     "nvme0: T=41C (limited, no root)"
#   S3  cgroup v2 io.stat sampled ~1s apart -> per-device rates
#                     -> BH_CG_IO_TXT "vda r=1.2MB/s w=0.3MB/s"
#       all-zero deltas -> "io idle"   (the "(cgroup v2)" label is added
#       by the renderer, the data stays bare)
#   BH_PSI_TXT is owned by 25-env.sh (bh_psi) and is NOT touched here.
#
# Globals are initialized inside gather_storage_health(); sourcing this
# file has zero side effects (function definitions only, no top-level
# assignments). Serial numbers are never read, parsed or printed.
# Contract: sets BH_* globals only (never stdout); every external
# command runs under `timeout` (bhv5c8_to); unreadable/missing input =>
# "" (clean); mawk-safe awk only (no gawk-isms, no POSIX classes in awk
# regex). Budget: <2s full (soft deadline aborts the disk walk), ~0s
# when BH_FAST=1 (no smartctl, no io.stat sampling; the cheap sysfs
# NVMe fallback still runs).
# =====================================================================
# shellcheck shell=bash

# bhv5c8_to SECS CMD... — run CMD under `timeout` when available (same
# pattern as bh_dsk_to / bh_t2). Stdin passes through so in-memory
# pipes into awk work too.
bhv5c8_to() {
  local s="$1"; shift
  if command_exists timeout; then
    timeout "$s" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# bhv5c8_trim — pure-bash leading/trailing whitespace strip (CLI output
# padding; same helper as in 57-mount-audit.sh, kept file-local so each
# file can be sourced standalone).
bhv5c8_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# bhv5c8_is_root — true when running as uid 0
bhv5c8_is_root() {
  local u
  u="$(bhv5c8_to 2 id -u)"
  [ "$u" = "0" ]
}

# bhv5c8_timeleft START_MS LIMIT_MS — true while the wall-time budget
# remains (guards the multi-disk walks against slow/hung probes).
bhv5c8_timeleft() {
  [ $(( $(now_ms) - ${1:-0} )) -lt "${2:-2000}" ]
}

# bhv5c8_smart_health TXT — extract the overall verdict from smartctl -H
# output ("... overall-health ... result: PASSED"; SAS drives report
# "SMART Health Status: OK"). Prints PASSED | FAILED | "" (unknown ->
# disk is skipped, clean missing). Pure text parse, no re-reads.
bhv5c8_smart_health() {
  [ -n "${1:-}" ] || { printf ''; return 0; }
  printf '%s\n' "$1" | awk '
    {
      l = tolower($0)
      if (l ~ /result:/ || l ~ /overall-health/) {
        if (match(l, /passed/))      r = "PASSED"
        else if (match(l, /failed/)) r = "FAILED"
      } else if (l ~ /health status/) {
        if (l ~ /: *ok/)             r = "PASSED"
        else if (l ~ /fail/)         r = "FAILED"
      }
    }
    END { print r }' 2>/dev/null
}

# bhv5c8_smart_attrs TXT — raw values of SMART attribute IDs 5/197/198
# from smartctl -A output; only nonzero counters are reported:
# "reloc=N pending=N uncorr=N" ("" when all zero / not parseable /
# NVMe-style output without numeric IDs). Never contains serial data.
bhv5c8_smart_attrs() {
  [ -n "${1:-}" ] || { printf ''; return 0; }
  printf '%s\n' "$1" | awk '
    $1 == "5" || $1 == "197" || $1 == "198" {
      raw = $NF
      if (raw ~ /^[0-9]+$/ && raw + 0 > 0) {
        if ($1 == "5")        rel = raw
        else if ($1 == "197") pen = raw
        else                  unc = raw
      }
    }
    END {
      s = ""
      if (rel + 0 > 0) s = "reloc=" rel
      if (pen + 0 > 0) s = s (s == "" ? "" : " ") "pending=" pen
      if (unc + 0 > 0) s = s (s == "" ? "" : " ") "uncorr=" unc
      print s
    }' 2>/dev/null
}

# bhv5c8_nvme_log TXT — parse `nvme smart-log` text into
# "used=N% spare=N% T=NC" plus a trailing " WARN" when percentage_used
# >= 80, available_spare < 10, temperature >= 70C, or critical_warning
# is nonzero. "" when none of the keys parse (clean missing).
bhv5c8_nvme_log() {
  [ -n "${1:-}" ] || { printf ''; return 0; }
  printf '%s\n' "$1" | awk '
    function num(s) { if (match(s, /[0-9]+/)) return substr(s, RSTART, RLENGTH); return "" }
    $1 == "critical_warning" { cw = num($0) }
    $1 == "available_spare"  { sp = num($0) }
    $1 == "percentage_used"  { pu = num($0) }
    $1 == "temperature"      { tp = num($0) }
    END {
      if (pu == "" && sp == "" && tp == "") exit
      s = ""
      if (pu != "") s = "used=" pu "%"
      if (sp != "") s = s (s == "" ? "" : " ") "spare=" sp "%"
      if (tp != "") s = s (s == "" ? "" : " ") "T=" tp "C"
      w = 0
      if (pu + 0 >= 80)            w = 1
      if (sp != "" && sp + 0 < 10) w = 1
      if (tp + 0 >= 70)            w = 1
      if (cw != "" && cw + 0 != 0) w = 1
      print s (w ? " WARN" : "")
    }' 2>/dev/null
}

# bhv5c8_iodump FILE — cgroup v2 io.stat -> "maj:min rbytes wbytes"
# numeric lines ("" when the file is unreadable/empty).
bhv5c8_iodump() {
  [ -r "${1:-}" ] || return 0
  bhv5c8_to 2 awk '
    {
      dev = $1; r = ""; w = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^rbytes=/)      { sub(/^rbytes=/, "", $i); r = $i }
        else if ($i ~ /^wbytes=/) { sub(/^wbytes=/, "", $i); w = $i }
      }
      if (dev ~ /^[0-9]+:[0-9]+$/ && r ~ /^[0-9]+$/ && w ~ /^[0-9]+$/) print dev, r, w
    }' "$1"
}

# bhv5c8_iorate A_TXT B_TXT MS — pure rate calc between two bhv5c8_iodump
# dumps taken MS ms apart: per-device KB/s floats, top 3 by total rate,
# "maj:min r=X w=Y" lines; "io idle" when every delta is zero; "" when
# no device overlaps both samples (counter reset / no data).
bhv5c8_iorate() {
  { [ -n "${1:-}" ] && [ -n "${2:-}" ]; } || { printf ''; return 0; }
  bhv5c8_to 2 awk -v a="$1" -v b="$2" -v ms="${3:-0}" '
    function fkb(kb) {
      if (kb >= 102.4) return sprintf("%.1fMB/s", kb / 1024)
      return sprintf("%.1fKB/s", kb)
    }
    BEGIN {
      ts = ms / 1000
      if (ts <= 0) exit
      n = split(a, L0, "\n")
      for (i = 1; i <= n; i++) {
        m = split(L0[i], f, " ")
        if (m >= 3) { R0[f[1]] = f[2]; W0[f[1]] = f[3] }
      }
      n = split(b, L1, "\n")
      cnt = 0
      for (i = 1; i <= n; i++) {
        m = split(L1[i], f, " ")
        if (m < 3) continue
        d = f[1]
        if (!(d in R0) || !(d in W0)) continue   # new/gone device: no trusted delta
        dr = f[2] - R0[d]; dw = f[3] - W0[d]
        if (dr < 0) dr = 0
        if (dw < 0) dw = 0
        rk = dr / ts / 1024; wk = dw / ts / 1024
        if (rk + wk <= 0) continue
        cnt++
        TOT[d] = rk + wk; RK[d] = rk; WK[d] = wk
      }
      if (cnt == 0) { print "io idle"; exit }
      for (k = 1; k <= 3 && k <= cnt; k++) {
        best = ""; bt = -1
        for (d in TOT) {
          if (DONE[d]) continue
          if (TOT[d] > bt) { bt = TOT[d]; best = d }
        }
        if (best == "") break
        DONE[best] = 1
        printf "%s r=%s w=%s\n", best, fkb(RK[best]), fkb(WK[best])
      }
    }'
}

# bhv5c8_devname MAJ:MIN — resolve to the kernel block name ("vda") via
# the /sys/dev/block symlink; falls back to the raw maj:min token.
bhv5c8_devname() {
  local nm
  nm="$(bhv5c8_to 2 readlink -f "/sys/dev/block/${1:-}")"
  nm="${nm##*/}"
  [ -n "$nm" ] || nm="${1:-}"
  printf '%s' "$nm"
}

gather_storage_health() {
  BH_SMART_TXT=""
  BH_NVME_TXT=""
  BH_CG_IO_TXT=""

  local t_start isroot=0
  t_start="$(now_ms)"
  if bhv5c8_is_root; then isroot=1; fi

  # ------------- S1: SMART health (root + smartctl + not fast) ----------
  # Physical disks only, whitelisted from /sys/block: sd*/nvme* (vd*
  # virtio, loop, ram, zram, sr and every other virtual/odd device is
  # excluded by the whitelist). Max 3 disks, soft deadline guarded.
  if [ "$isroot" = "1" ] && [ "$BH_FAST" != "1" ] && command_exists smartctl; then
    local dpath dname htxt atxt h a entry scnt=0
    for dpath in /sys/block/*; do
      [ -e "$dpath" ] || continue
      [ "$scnt" -lt 3 ] || break
      bhv5c8_timeleft "$t_start" 1200 || break
      dname="${dpath##*/}"
      case "$dname" in
        sd*|nvme*) : ;;
        *) continue ;;
      esac
      htxt="$(bhv5c8_to 3 smartctl -H "/dev/$dname")"
      h="$(bhv5c8_smart_health "$htxt")"
      [ -n "$h" ] || continue                  # unreadable/unknown -> skip, clean
      entry="$dname: $h"
      atxt="$(bhv5c8_to 3 smartctl -A "/dev/$dname")"
      a="$(bhv5c8_smart_attrs "$atxt")"
      [ -n "$a" ] && entry="$entry $a"         # reloc=/pending=/uncorr= only when >0
      BH_SMART_TXT="${BH_SMART_TXT:+$BH_SMART_TXT | }$entry"
      scnt=$(( scnt + 1 ))
    done
  fi

  # ------------- S2: NVMe health ----------------------------------------
  local nseg nname nlog e nvcnt=0 tf tval lim
  if [ "$isroot" = "1" ] && command_exists nvme; then
    for nseg in /sys/class/nvme/nvme*; do
      [ -e "$nseg" ] || continue
      [ "$nvcnt" -lt 3 ] || break
      bhv5c8_timeleft "$t_start" 1600 || break
      nname="${nseg##*/}"
      [ -e "/dev/$nname" ] || continue
      nlog="$(bhv5c8_to 3 nvme smart-log "/dev/$nname")"
      e="$(bhv5c8_nvme_log "$nlog")"
      [ -n "$e" ] || continue
      BH_NVME_TXT="${BH_NVME_TXT:+$BH_NVME_TXT | }$nname: $e"
      nvcnt=$(( nvcnt + 1 ))
    done
  fi
  if [ -z "$BH_NVME_TXT" ]; then
    # Fallback: hwmon temperature only (works unprivileged). Label says
    # what the reader is missing.
    lim="(limited)"; [ "$isroot" = "1" ] || lim="(limited, no root)"
    for nseg in /sys/class/nvme/nvme*; do
      [ -e "$nseg" ] || continue
      [ "$nvcnt" -lt 6 ] || break
      tf=""
      for tval in "$nseg"/hwmon*/temp1_input; do
        [ -r "$tval" ] && { tf="$tval"; break; }
      done
      [ -n "$tf" ] || continue
      tval=""
      IFS= read -r tval < "$tf" || tval=""
      tval="$(bhv5c8_trim "$tval")"
      case "$tval" in ''|*[!0-9]*) continue ;; esac
      BH_NVME_TXT="${BH_NVME_TXT:+$BH_NVME_TXT | }${nseg##*/}: T=$(( tval / 1000 ))C $lim"
      nvcnt=$(( nvcnt + 1 ))
    done
  fi

  # ------------- S3: cgroup v2 io.stat rate sample ----------------------
  # Only on real cgroup v2 mounts and never in fast mode. The 1s sleep
  # is the only wait; skipped entirely when earlier probes already ate
  # the module budget.
  if [ "$BH_FAST" != "1" ] \
     && [ "$(bhv5c8_to 2 stat -f -c %T /sys/fs/cgroup)" = "cgroup2fs" ] \
     && [ -r /sys/fs/cgroup/io.stat ] \
     && bhv5c8_timeleft "$t_start" 900; then
    local t_io0 t_io1 s_dt s0 s1 sraw sline sdev snm
    t_io0="$(now_ms)"
    s0="$(bhv5c8_iodump /sys/fs/cgroup/io.stat)"
    bhv5c8_to 3 sleep 1
    t_io1="$(now_ms)"
    s1="$(bhv5c8_iodump /sys/fs/cgroup/io.stat)"
    s_dt=$(( t_io1 - t_io0 ))
    if [ -n "$s0" ] && [ -n "$s1" ] && [ "$s_dt" -ge 500 ]; then
      sraw="$(bhv5c8_iorate "$s0" "$s1" "$s_dt")"
      if [ "$sraw" = "io idle" ]; then
        BH_CG_IO_TXT="io idle"
      elif [ -n "$sraw" ]; then
        while IFS= read -r sline; do
          [ -n "$sline" ] || continue
          sdev="${sline%% *}"
          snm="$(bhv5c8_devname "$sdev")"
          BH_CG_IO_TXT="${BH_CG_IO_TXT:+$BH_CG_IO_TXT | }$snm ${sline#* }"
        done <<< "$sraw"
      fi
    fi
  fi

  return 0
}
