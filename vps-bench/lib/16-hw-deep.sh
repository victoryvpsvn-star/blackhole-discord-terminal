# =====================================================================
# blackhole-vps-bench · 16-hw-deep.sh — deep hardware context (v5.0.0)
# =====================================================================
#
# v5.0 (C05): passive one-line hardware facts the fast modules do not cover.
# sysfs / procfs only, every probe is a 1-token file read, zero network,
# zero writes, no PCI walk here on purpose (VMM/PCI evidence is owned by
# another module):
#   N1 NUMA topology    /sys/devices/system/node/node*          -> BH_NUMA_TXT
#   N2 offline CPUs     /sys/devices/system/cpu/offline         -> BH_NUMA_OFFLINE
#   F1 cpufreq policy   .../cpufreq/policy0 + turbo switches    -> BH_CPUFREQ_TXT
#   T1 thermal sensors  /sys/class/hwmon -> /sys/class/thermal  -> BH_THERMAL_TXT
#   T2 throttle events  .../cpu0/thermal_throttle/*_count       -> BH_THROTTLE_CNT
#   E1 machine checks   /proc/interrupts MCE + EDAC counters    -> BH_HWERR_TXT
#   M1 DIMM inventory   dmidecode -t memory (root only)         -> BH_DIMM_TXT
#                                                               BH_DIMM_NOTE
#
# Contract: function definitions only — nothing is read at source time.
# gather_hwdeep() resets every global to "" and fills what it can; any probe
# that comes up empty stays "" and the report simply omits the line (never a
# warning: cpufreq and thermal are routinely absent in VMs and containers).
# Every sysfs path is guarded with [ -r ] / [ -d ]; an unmatched glob is
# caught by the same guards. Budget: well under 0.5s — the ONLY external
# process is `dmidecode -t memory` under `timeout 2`, and only as root with
# BH_REDACT!=1. Serial numbers / vendor / locator strings are deliberately
# never parsed, so BH_DIMM_TXT cannot leak an identity even unredacted.
# shellcheck shell=bash

# ------- private helpers (prefix bhv5c5_ — owned by C05) -------

# bhv5c5_trim S — strip leading/trailing whitespace (sysfs label files are
# space-padded); pure parameter expansion, no external tool, no subshell.
bhv5c5_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# bhv5c5_sys1 FILE — first line of a one-token sysfs file, trimmed; "" when
# the file is missing or unreadable (the caller treats "" as n/a). The [ -r ]
# guard lives here so every read site is covered; plain `read`, no subshell,
# no external tool.
bhv5c5_sys1() {
  local v=""
  if [ -r "$1" ]; then
    IFS= read -r v < "$1" 2>/dev/null || v=""
  fi
  bhv5c5_trim "$v"
}

# bhv5c5_temp_c V — millidegrees Celsius -> integer degrees ("45000" -> "45",
# "-2500" -> "-2"); prints nothing when V is not a plain integer. mawk-safe:
# plain regex, %d stays far inside the int range.
bhv5c5_temp_c() {
  awk -v m="${1:-}" 'BEGIN{ if (m ~ /^-?[0-9]+$/) printf "%d", m / 1000 }' 2>/dev/null
}

# bhv5c5_cpuset_overlap A B — print "1" when the two cpulist strings ("0-3,8"
# style) share at least one logical CPU, else print nothing. Ranges are
# compared pairwise as intervals and never expanded, so huge masks cost the
# same as tiny ones.
bhv5c5_cpuset_overlap() {
  awk -v a="${1:-}" -v b="${2:-}" 'BEGIN{
    m = split(a, A, ",")
    for (i = 1; i <= m; i++) {
      if (A[i] !~ /^[0-9]+(-[0-9]+)?$/) continue
      k = split(A[i], r, "-")
      a1 = r[1] + 0; a2 = (k == 2) ? r[2] + 0 : r[1] + 0
      if (a2 < a1) { t = a1; a1 = a2; a2 = t }
      n = split(b, B, ",")
      for (j = 1; j <= n; j++) {
        if (B[j] !~ /^[0-9]+(-[0-9]+)?$/) continue
        kk = split(B[j], s, "-")
        b1 = s[1] + 0; b2 = (kk == 2) ? s[2] + 0 : s[1] + 0
        if (b2 < b1) { t = b1; b1 = b2; b2 = t }
        if (a1 <= b2 && b1 <= a2) { print "1"; exit 0 }
      }
    }
  }' 2>/dev/null
}

# bhv5c5_t2 CMD... — the only external command this module may run
# (dmidecode): always under `timeout 2` when available, stderr dropped,
# stdin detached so it can never sit on a prompt.
bhv5c5_t2() {
  if command_exists timeout; then
    timeout 2 "$@" 2>/dev/null </dev/null
  else
    "$@" 2>/dev/null </dev/null
  fi
}

# bhv5c5_dimm_line DMI_TEXT — condense `dmidecode -t memory` output into one
# report line: "dimm=<installed>/<slots> <type> <speed> ecc=<type>".
# Counts and types only: locators, vendors and serial numbers are never
# extracted, so no serial can ever reach a sink. Prints "" when the dump has
# no populated memory device. dmidecode prints Size as "N GB" (new) or
# "N MB" (old), Speed as "N MT/s" (new) or "N MHz" (old); both accepted.
bhv5c5_dimm_line() {
  printf '%s\n' "${1:-}" | awk '
    /^[ \t]*Memory Device$/ {
      slots++; devok = 0
    }
    /^[ \t]*Size:/ {
      sub(/^[^:]*:[ \t]*/, "")
      if ($0 ~ /^[0-9]+ (MB|GB)$/) { inst++; devok = 1 }
    }
    /^[ \t]*Type:/ {
      if (devok && type == "") {
        sub(/^[^:]*:[ \t]*/, "")
        sub(/[ \t]+$/, "")
        if ($0 ~ /^(LP)?DDR[0-9]?$/) type = $0
      }
    }
    /^[ \t]*Speed:/ {
      if (devok && speed == "") {
        sub(/^[^:]*:[ \t]*/, "")
        sub(/\(.*/, "")            # "3200 MT/s (2666 MT/s)" -> "3200 MT/s"
        sub(/[ \t]+$/, "")
        if ($0 ~ /^[0-9]+ (MT\/s|MHz)$/) speed = $0
      }
    }
    /^[ \t]*Error Correction Type:/ {
      if (ecc == "") {
        sub(/^[^:]*:[ \t]*/, "")
        sub(/[ \t]+$/, "")
        if ($0 != "" && $0 != "Unknown") ecc = $0
      }
    }
    END {
      if (slots + 0 > 0 && inst + 0 > 0) {
        gsub(/[^A-Za-z0-9 .(),_-]/, "", ecc)
        ecc = substr(ecc, 1, 32)
        line = "dimm=" inst "/" slots
        if (type != "")  line = line " " type
        if (speed != "") line = line " " speed
        if (ecc != "")   line = line " ecc=" ecc
        print line
      }
    }
  ' 2>/dev/null
}

# ---------------------------------------------------------------------
# gather_hwdeep — fill the BH_* deep-hardware globals (see header).
# ---------------------------------------------------------------------
gather_hwdeep() {
  # ---- globals: every value defaults to "" at function start ----
  BH_NUMA_TXT="";      BH_NUMA_OFFLINE=""
  BH_CPUFREQ_TXT="";   BH_THERMAL_TXT=""
  BH_THROTTLE_CNT="";  BH_HWERR_TXT=""
  BH_DIMM_TXT="";      BH_DIMM_NOTE=""

  local node_dir cl offline pdir fmin fmax gov drv seg turbo
  local nturbo hw hw_i tname tvals tf tcount tvc tlab parts
  local tz tz_i tztype tzv tpkg tcore hwerr mce
  local edir ce ue ecc_ce ecc_ue ecc_k got dmi is_root

  # ================= N1: NUMA topology =================
  # Count /sys/devices/system/node/node*, join the cpulists of the first 4
  # nodes, add the distance row (first 8 values) of the first node, and —
  # best effort — map the self cpuset onto the first overlapping node.
  local nscan=0 nodes=0 cl4="" first_node="" self_node=""
  for node_dir in /sys/devices/system/node/node*; do
    [ -d "$node_dir" ] || continue               # unmatched glob / hotplug race
    nscan=$(( nscan + 1 ))
    [ "$nscan" -gt 32 ] && break                 # huge-host cost cap
    nodes=$(( nodes + 1 ))
    cl="$(bhv5c5_sys1 "$node_dir/cpulist")"
    if [ "$nodes" -le 4 ] && [ -n "$cl" ]; then
      case "$cl" in *[!0-9,-]*) cl="" ;; esac    # malformed -> drop
      [ -n "$cl" ] && cl4="${cl4:+$cl4,}$cl"
    fi
    # self mapping: first node whose cpulist overlaps $CPUSET (skip on fail)
    if [ -z "$self_node" ] && [ -n "${CPUSET:-}" ] && [ -n "$cl" ]; then
      case "$cl" in
        *[!0-9,-]*) : ;;
        *)
          if [ -n "$(bhv5c5_cpuset_overlap "${CPUSET:-}" "$cl")" ]; then
            self_node="${node_dir##*/}"
          fi
          ;;
      esac
    fi
    [ -n "$first_node" ] || first_node="$node_dir"
  done
  if [ "$nodes" -gt 16 ]; then
    BH_NUMA_TXT="numa=16+"
  elif [ "$nodes" -gt 0 ]; then
    BH_NUMA_TXT="numa=$nodes"
    [ -n "$cl4" ] && BH_NUMA_TXT="$BH_NUMA_TXT cpulists=$cl4"
    # inter-node distance row of the first node, first 8 values, comma-joined
    if [ -n "$first_node" ] && [ -r "$first_node/distance" ]; then
      local drow dist8
      drow="$(bhv5c5_sys1 "$first_node/distance")"
      dist8="$(printf '%s\n' "$drow" | awk '{
        out = ""
        for (i = 1; i <= NF && i <= 8; i++) {
          if ($i !~ /^[0-9]+$/) break
          out = out (i > 1 ? "," : "") $i
        }
        print out
      }' 2>/dev/null)"
      [ -n "$dist8" ] && BH_NUMA_TXT="$BH_NUMA_TXT dist=$dist8"
    fi
    [ -n "$self_node" ] && BH_NUMA_TXT="$BH_NUMA_TXT self=$self_node"
  fi

  # ============ N2: offline CPUs (oversell evidence) ============
  # Non-empty means the kernel itself says some cores are offline — the
  # report renders this; empty stays "" (no line).
  offline="$(bhv5c5_sys1 /sys/devices/system/cpu/offline)"
  case "$offline" in
    ''|*[!0-9,-]*) BH_NUMA_OFFLINE="" ;;
    *)             BH_NUMA_OFFLINE="$offline" ;;
  esac

  # ===== F1: cpufreq policy (routinely absent in VMs -> "") =====
  # kHz sysfs values -> integer MHz; NEVER warn when the tree is missing.
  pdir="/sys/devices/system/cpu/cpufreq/policy0"
  if [ -d "$pdir" ]; then
    fmin="$(bhv5c5_sys1 "$pdir/scaling_min_freq")"
    fmax="$(bhv5c5_sys1 "$pdir/scaling_max_freq")"
    gov="$(bhv5c5_sys1 "$pdir/scaling_governor")"
    drv="$(bhv5c5_sys1 "$pdir/scaling_driver")"
    case "$fmin" in ''|*[!0-9]*) fmin="" ;; esac
    case "$fmax" in ''|*[!0-9]*) fmax="" ;; esac
    case "$gov" in *[!A-Za-z0-9_-]*) gov="" ;; esac
    case "$drv" in *[!A-Za-z0-9_-]*) drv="" ;; esac
    seg=""
    [ -n "$fmin" ] && [ -n "$fmax" ] && \
      seg="$(awk -v lo="$fmin" -v hi="$fmax" 'BEGIN{ printf "%d-%dMHz", lo / 1000, hi / 1000 }')"
    # turbo: intel_pstate no_turbo=1, else cpufreq boost=0, else amd_pstate
    # status "disable" — all three mean turbo is off
    nturbo="$(bhv5c5_sys1 /sys/devices/system/cpu/intel_pstate/no_turbo)"
    if [ "$nturbo" = "1" ]; then
      turbo="turbo=off"
    elif [ "$(bhv5c5_sys1 /sys/devices/system/cpu/cpufreq/boost)" = "0" ]; then
      turbo="turbo=off"
    elif [ "$(bhv5c5_sys1 /sys/devices/system/cpu/amd_pstate/status)" = "disable" ]; then
      turbo="turbo=off"
    else
      turbo=""
    fi
    BH_CPUFREQ_TXT="$seg"
    [ -n "$gov" ] && BH_CPUFREQ_TXT="${BH_CPUFREQ_TXT:+$BH_CPUFREQ_TXT }governor=$gov"
    [ -n "$drv" ] && BH_CPUFREQ_TXT="${BH_CPUFREQ_TXT:+$BH_CPUFREQ_TXT }driver=$drv"
    [ -n "$turbo" ] && BH_CPUFREQ_TXT="${BH_CPUFREQ_TXT:+$BH_CPUFREQ_TXT }$turbo"
  fi

  # ====== T1: thermal sensors (typical VMs -> "", never a warn) ======
  # hwmon first: chip name + up to 4 temp*_input values per chip, 8 chips
  # max. A temp*_label can stand in for a missing chip name (some drivers
  # expose labels but no name); it is read at most once per chip. Fallback
  # (only when hwmon yielded nothing): /sys/class/thermal thermal zones.
  parts=""
  hw_i=0
  for hw in /sys/class/hwmon/hwmon*; do
    [ -d "$hw" ] || continue
    hw_i=$(( hw_i + 1 ))
    [ "$hw_i" -gt 8 ] && break
    tname="$(bhv5c5_sys1 "$hw/name")"
    case "$tname" in *[!A-Za-z0-9_.[:space:]-]*) tname="" ;; esac
    tvals=""
    tcount=0
    tlab=""
    # note: the glob is lexicographic, so on many-temp chips an arbitrary
    # (not strictly lowest) subset of 4 sensors is shown — fine for a report
    for tf in "$hw"/temp*_input; do
      [ -r "$tf" ] || continue                   # unmatched glob -> skip
      tcount=$(( tcount + 1 ))
      [ "$tcount" -gt 4 ] && break
      tvc="$(bhv5c5_temp_c "$(bhv5c5_sys1 "$tf")")"
      [ -n "$tvc" ] && tvals="${tvals:+$tvals }${tvc}°C"
      if [ -z "$tname" ] && [ -z "$tlab" ]; then
        tlab="$(bhv5c5_sys1 "${tf%_input}_label")"
        case "$tlab" in *[!A-Za-z0-9_.[:space:]-]*) tlab="" ;; esac
      fi
    done
    [ -z "$tname" ] && tname="$tlab"
    if [ -z "$tname" ] && [ -n "$hw" ]; then
      case "$hw" in */hwmon*) tname="hwmon${hw##*/hwmon}" ;; esac
    fi
    if [ -n "$tname" ] && [ -n "$tvals" ]; then
      parts="${parts:+$parts | }${tname}: $tvals"
    fi
  done
  if [ -z "$parts" ]; then
    tz_i=0
    for tz in /sys/class/thermal/thermal_zone*; do
      [ -d "$tz" ] || continue
      tz_i=$(( tz_i + 1 ))
      [ "$tz_i" -gt 8 ] && break
      tztype="$(bhv5c5_sys1 "$tz/type")"
      case "$tztype" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
      tzv="$(bhv5c5_temp_c "$(bhv5c5_sys1 "$tz/temp")")"
      [ -n "$tzv" ] || continue
      parts="${parts:+$parts | }${tztype}: ${tzv}°C"
    done
  fi
  BH_THERMAL_TXT="$parts"

  # ============ T2: thermal throttle event counters ============
  # Non-zero counts are hard evidence the package/cores ran hot enough to
  # throttle — a VM cannot fake these away (host-owned sysfs).
  tpkg="$(bhv5c5_sys1 /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count)"
  tcore="$(bhv5c5_sys1 /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count)"
  case "$tpkg" in ''|*[!0-9]*) tpkg="" ;; esac
  case "$tcore" in ''|*[!0-9]*) tcore="" ;; esac
  if [ -n "$tpkg" ] && [ -n "$tcore" ] && [ $(( tpkg + tcore )) -gt 0 ]; then
    BH_THROTTLE_CNT="pkg=$tpkg core=$tcore"
  fi

  # ============ E1: hardware error counters ============
  # MCE: per-CPU machine-check event total from /proc/interrupts; EDAC:
  # corrected/uncorrectable ECC counters summed over all memory controllers.
  # Only pieces that are readable get rendered; none -> "".
  hwerr=""
  if [ -r /proc/interrupts ]; then
    # the MCE row is "MCE:  <per-cpu counts ...>  Machine check errors" —
    # trailing text adds 0, per-CPU columns are summed
    mce="$(awk '/^[ \t]*MCE:/ { s = 0; for (i = 2; i <= NF; i++) s += ($i + 0); print s + 0; exit }' /proc/interrupts 2>/dev/null)"
    case "$mce" in ''|*[!0-9]*) mce="" ;; esac
    [ -n "$mce" ] && hwerr="mce=$mce"
  fi
  ecc_ce=0; ecc_ue=0; ecc_k=0
  for edir in /sys/devices/system/edac/mc/mc*; do
    [ -d "$edir" ] || continue
    ce="$(bhv5c5_sys1 "$edir/ce_count")"
    ue="$(bhv5c5_sys1 "$edir/ue_count")"
    case "$ce" in ''|*[!0-9]*) ce="" ;; esac
    case "$ue" in ''|*[!0-9]*) ue="" ;; esac
    got=0
    [ -n "$ce" ] && { ecc_ce=$(( ecc_ce + ce )); got=1; }
    [ -n "$ue" ] && { ecc_ue=$(( ecc_ue + ue )); got=1; }
    [ "$got" -eq 1 ] && ecc_k=$(( ecc_k + 1 ))
  done
  [ "$ecc_k" -gt 0 ] && hwerr="${hwerr:+$hwerr }ecc corr=$ecc_ce unc=$ecc_ue (${ecc_k} ctrl)"
  BH_HWERR_TXT="$hwerr"

  # ============ M1: DIMM inventory (root + dmidecode only) ============
  # The ONLY timeout-wrapped external call in this module (timeout 2), and
  # only when root and BH_REDACT!=1. Non-root / redacted -> "" plus the
  # BH_DIMM_NOTE="root-only" hint; dmidecode simply missing -> clean "".
  is_root=0
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && is_root=1
  if [ "$is_root" -eq 1 ] && [ "${BH_REDACT:-0}" != "1" ] && command_exists dmidecode; then
    dmi="$(bhv5c5_t2 dmidecode -t memory)"
    [ -n "$dmi" ] && BH_DIMM_TXT="$(bhv5c5_dimm_line "$dmi")"
  elif [ "$is_root" -ne 1 ] || [ "${BH_REDACT:-0}" = "1" ]; then
    BH_DIMM_NOTE="root-only"
  fi

  return 0
}
