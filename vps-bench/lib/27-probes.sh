# =====================================================================
# blackhole-vps-bench · 27-probes.sh — v5.1 deep probes (offline, read-only)
# =====================================================================
# shellcheck shell=bash
#
# Module 27 (v5.1): the "it even sees that" truth rows — SMT topology,
# CPU hotplug delta, OOM/overcommit posture, TCP kernel knobs, default
# qdisc, microVM sandbox class, user-ns budget and the guest-agent census.
#
#   P1 SMT truth         (cpu0 thread_siblings_list, bh_cpuset_count-style
#                         awk range count; NCPU==1 cross-check)
#   P2 CPU hotplug delta (/sys/devices/system/cpu/possible vs online →
#                         "N offline")
#   P3 OOM posture       (overcommit_memory mode/ratio + Committed_AS vs
#                         CommitLimit when mode 2)
#   P4 TCP kernel knobs  (syncookies, fastopen, tcp_rmem/tcp_wmem max in
#                         KB, rp_filter all/default)
#   P5 default qdisc     (default-route iface from /proc/net/route — no
#                         ip(8) — then one guarded `tc qdisc show` read;
#                         BBR-vs-fq note)
#   P6 sandbox class     (kata > gVisor > firecracker, signal list kept)
#   P7 userns budget     (/proc/sys/user/max_user_namespaces)
#   P8 guest agents      (presence-only census: cloud-init, qemu-ga,
#                         vmtoolsd, waagent, google-guest-agent,
#                         amazon-ssm-agent)
#
# Contract: defines gather_probes() ONLY — no top-level side effects, so
# this file may be sourced even when the module is disabled. Prints NOTHING
# to stdout; every file access is guarded with 2>/dev/null; works
# unprivileged and on Alpine/busybox (coreutils + awk only; tc optional via
# command_exists); no pgrep, no agent config reads, no /var/lib/cloud
# listings, no instance ids. Never fails: unreadable input => ""/"none".

# ------- globals (safe empty/zero defaults; filled by gather_probes) -------
BH_SMT_THREADS=""     # integer threads-per-core from cpu0 topology | "" unknown
BH_CPU_HOTPLUG=""     # "N offline" when possible > online | ""
BH_OOM_MODE=""        # /proc/sys/vm/overcommit_memory first line: 0|1|2 | ""
BH_OOM_RATIO=""       # overcommit_ratio, only when mode 2 | ""
BH_OOM_COMMIT_PCT=""  # Committed_AS*100/CommitLimit (awk integer), mode 2 only
BH_TCP_SYNCOOKIES=""  # /proc/sys/net/ipv4/tcp_syncookies: 0|1 | ""
BH_TCP_FASTOPEN=""    # /proc/sys/net/ipv4/tcp_fastopen: 0|1|2|3 | ""
BH_TCP_RMEM_MAX_KB="" # 3rd field of tcp_rmem (bytes -> KB integer) | ""
BH_TCP_WMEM_MAX_KB="" # 3rd field of tcp_wmem (bytes -> KB integer) | ""
BH_RP_FILTER=""       # "all/default" (e.g. "2/1") | single value | ""
BH_QDISC=""           # qdisc name (2nd word) of the default-route iface | ""
BH_QDISC_IFACE=""     # iface used for the tc query | ""
BH_QDISC_NOTE=""      # "fq recommended with BBR" when BBR + non-fq qdisc | ""
BH_SANDBOX="none"     # kata | gvisor | firecracker | none
BH_SANDBOX_TXT=""     # human text naming the signals that fired | "" when none
BH_USERNS_MAX=""      # /proc/sys/user/max_user_namespaces first line | ""
BH_GUEST_AGENTS=""    # comma list of DETECTED guest agents | "" when none

# =====================================================================
# gather_probes — fill every BH_* global above. Prints NOTHING to stdout;
# read-only everywhere; every probe re-initialises its global first, so the
# function is idempotent and never fails.
# =====================================================================
gather_probes() {
  # ---- defaults (idempotent reset) ----
  BH_SMT_THREADS=""
  BH_CPU_HOTPLUG=""
  BH_OOM_MODE=""
  BH_OOM_RATIO=""
  BH_OOM_COMMIT_PCT=""
  BH_TCP_SYNCOOKIES=""
  BH_TCP_FASTOPEN=""
  BH_TCP_RMEM_MAX_KB=""
  BH_TCP_WMEM_MAX_KB=""
  BH_RP_FILTER=""
  BH_QDISC=""
  BH_QDISC_IFACE=""
  BH_QDISC_NOTE=""
  BH_SANDBOX="none"
  BH_SANDBOX_TXT=""
  BH_USERNS_MAX=""
  BH_GUEST_AGENTS=""

  # ---- P1: SMT truth (cpu0 thread_siblings_list, bh_cpuset_count-style) ----
  # "0-3" -> 4, "0" -> 1, "0-1,4" -> 3, ""/garbage -> "". Same awk range
  # count as core's bh_cpuset_count, hardened to reject malformed members.
  local sib=""
  if [ -r /sys/devices/system/cpu/cpu0/topology/thread_siblings_list ]; then
    read -r sib < /sys/devices/system/cpu/cpu0/topology/thread_siblings_list 2>/dev/null || sib=""
  fi
  if [ -n "$sib" ]; then
    BH_SMT_THREADS="$(awk -v s="$sib" 'BEGIN{
      n = 0; bad = 0; m = split(s, a, ",")
      for (i = 1; i <= m; i++) {
        p = split(a[i], r, "-")
        if (p == 2) {
          if (r[1] == "" || r[2] == "" || r[1] !~ /^[0-9]+$/ || r[2] !~ /^[0-9]+$/) { bad = 1; break }
          if (r[2] + 0 < r[1] + 0) { bad = 1; break }
          n += r[2] - r[1] + 1
        } else if (p == 1) {
          if (a[i] == "" || a[i] !~ /^[0-9]+$/) { bad = 1; break }
          n++
        } else { bad = 1; break }
      }
      if (!bad && n > 0) print n
    }')"
  fi
  # cross-check: exactly one online CPU can only mean one thread per core
  if [ -e /sys/devices/system/cpu/cpu0/topology/core_id ] \
    && [ "${NCPU:-1}" -eq 1 ] 2>/dev/null; then
    BH_SMT_THREADS=1
  fi

  # ---- P2: CPU hotplug delta (possible vs online) ----
  local poss="" onl=""
  if [ -r /sys/devices/system/cpu/possible ]; then
    read -r poss < /sys/devices/system/cpu/possible 2>/dev/null || poss=""
  fi
  if [ -r /sys/devices/system/cpu/online ]; then
    read -r onl < /sys/devices/system/cpu/online 2>/dev/null || onl=""
  fi
  poss="${poss%%[[:space:]]*}"
  onl="${onl%%[[:space:]]*}"
  if [ -n "$poss" ] && [ -n "$onl" ]; then
    BH_CPU_HOTPLUG="$(awk -v p="$poss" -v o="$onl" '
      function cnt(s,   n, m, i, pp, r, a) {
        n = 0; m = split(s, a, ",")
        for (i = 1; i <= m; i++) {
          pp = split(a[i], r, "-")
          if (pp == 2) {
            if (r[1] == "" || r[2] == "" || r[1] !~ /^[0-9]+$/ || r[2] !~ /^[0-9]+$/) return -1
            if (r[2] + 0 < r[1] + 0) return -1
            n += r[2] - r[1] + 1
          } else if (pp == 1) {
            if (a[i] == "" || a[i] !~ /^[0-9]+$/) return -1
            n++
          } else return -1
        }
        return n
      }
      BEGIN {
        pc = cnt(p); oc = cnt(o)
        if (pc < 0 || oc < 0) exit 0
        d = pc - oc
        if (d > 0) printf "%d offline", d
      }')"
  fi

  # ---- P3: OOM / overcommit posture ----
  local ocm="" orat=""
  if [ -r /proc/sys/vm/overcommit_memory ]; then
    read -r ocm < /proc/sys/vm/overcommit_memory 2>/dev/null || ocm=""
  fi
  ocm="${ocm%%[[:space:]]*}"
  case "$ocm" in
    0|1|2) BH_OOM_MODE="$ocm" ;;
  esac
  if [ "$BH_OOM_MODE" = "2" ]; then
    if [ -r /proc/sys/vm/overcommit_ratio ]; then
      read -r orat < /proc/sys/vm/overcommit_ratio 2>/dev/null || orat=""
    fi
    orat="${orat%%[[:space:]]*}"
    case "$orat" in
      ''|*[!0-9]*) : ;;
      *)           BH_OOM_RATIO="$orat" ;;
    esac
    # committed fraction of the CommitLimit ceiling (both kB in /proc/meminfo)
    local mkey="" mval="" cas="" clt=""
    if [ -r /proc/meminfo ]; then
      while read -r mkey mval _ || [ -n "${mkey:-}" ]; do
        case "$mkey" in
          Committed_AS:) cas="${mval:-}" ;;
          CommitLimit:)  clt="${mval:-}" ;;
        esac
      done < /proc/meminfo
    fi
    case "$cas" in ''|*[!0-9]*) cas="" ;; esac
    case "$clt" in ''|*[!0-9]*) clt="" ;; esac
    if [ -n "$cas" ] && [ -n "$clt" ] && [ "$clt" -gt 0 ]; then
      BH_OOM_COMMIT_PCT="$(awk -v a="$cas" -v l="$clt" 'BEGIN{ printf "%d", a * 100 / l }')"
    fi
  fi

  # ---- P4: TCP kernel knobs ----
  local tv=""
  if [ -r /proc/sys/net/ipv4/tcp_syncookies ]; then
    read -r tv < /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || tv=""
  fi
  tv="${tv%%[[:space:]]*}"
  case "$tv" in
    0|1) BH_TCP_SYNCOOKIES="$tv" ;;
  esac
  if [ -r /proc/sys/net/ipv4/tcp_fastopen ]; then
    read -r tv < /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || tv=""
  fi
  tv="${tv%%[[:space:]]*}"
  case "$tv" in
    0|1|2|3) BH_TCP_FASTOPEN="$tv" ;;
  esac

  # tcp_rmem / tcp_wmem: 3rd field is the max buffer size in bytes -> KB
  local rv=""
  if [ -r /proc/sys/net/ipv4/tcp_rmem ]; then
    read -r _ _ rv _ < /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || rv=""
  fi
  case "$rv" in
    ''|*[!0-9]*) : ;;
    *) BH_TCP_RMEM_MAX_KB=$(( 10#$rv / 1024 )) ;;
  esac
  if [ -r /proc/sys/net/ipv4/tcp_wmem ]; then
    read -r _ _ rv _ < /proc/sys/net/ipv4/tcp_wmem 2>/dev/null || rv=""
  fi
  case "$rv" in
    ''|*[!0-9]*) : ;;
    *) BH_TCP_WMEM_MAX_KB=$(( 10#$rv / 1024 )) ;;
  esac

  # rp_filter: "all/default" (e.g. "2/1"); fall back to whichever exists
  local rfa="" rfd=""
  if [ -r /proc/sys/net/ipv4/conf/all/rp_filter ]; then
    read -r rfa < /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || rfa=""
  fi
  if [ -r /proc/sys/net/ipv4/conf/default/rp_filter ]; then
    read -r rfd < /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || rfd=""
  fi
  rfa="${rfa%%[[:space:]]*}"
  rfd="${rfd%%[[:space:]]*}"
  case "$rfa" in ''|*[!0-9]*) rfa="" ;; esac
  case "$rfd" in ''|*[!0-9]*) rfd="" ;; esac
  if [ -n "$rfa" ] && [ -n "$rfd" ]; then
    BH_RP_FILTER="$rfa/$rfd"
  elif [ -n "$rfa" ]; then
    BH_RP_FILTER="$rfa"
  elif [ -n "$rfd" ]; then
    BH_RP_FILTER="$rfd"
  fi

  # ---- P5: default-route qdisc (no ip(8): /proc/net/route picks the iface) ----
  local defif="" r_if="" r_dst=""
  if [ -r /proc/net/route ]; then
    while read -r r_if r_dst _ || [ -n "${r_if:-}" ]; do
      if [ "$r_dst" = "00000000" ]; then
        defif="$r_if"
        break
      fi
    done < /proc/net/route
  fi
  if [ -n "$defif" ] && command_exists tc; then
    local tcline="" tq=""
    if command_exists timeout; then
      tcline="$(timeout 2 tc qdisc show dev "$defif" 2>/dev/null | head -n 1)"
    else
      tcline="$(tc qdisc show dev "$defif" 2>/dev/null | head -n 1)"
    fi
    tq="$(printf '%s\n' "$tcline" | awk 'NF >= 2 { print $2 }')"
    if [ -n "$tq" ]; then
      BH_QDISC="$tq"
      BH_QDISC_IFACE="$defif"
    fi
  fi
  # BBR wants fq for pacing: flag any qdisc that does not start with "fq"
  local cc=""
  if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
    read -r cc < /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || cc=""
  fi
  cc="${cc%%[[:space:]]*}"
  if [ "$cc" = "bbr" ]; then
    case "$BH_QDISC" in
      fq*) : ;;
      *)   BH_QDISC_NOTE="fq recommended with BBR" ;;
    esac
  fi

  # ---- P6: sandbox class (precedence kata > gvisor > firecracker) ----
  # kata signals: mountinfo marker, /run/kata-containers dir, KATA_CONTAINER
  # or FC_CONTAINER_ID env (kata's firecracker runtime). Signals are kept so
  # the report can show exactly what fired.
  local sig=""
  if command_exists grep && grep -q kata-containers /proc/self/mountinfo 2>/dev/null; then
    sig="mountinfo"
  fi
  if [ -d /run/kata-containers ]; then
    sig="${sig:+$sig + }dir"
  fi
  if [ -n "${KATA_CONTAINER:-}" ] || [ -n "${FC_CONTAINER_ID:-}" ]; then
    sig="${sig:+$sig + }env"
  fi
  if [ -n "$sig" ]; then
    BH_SANDBOX="kata"
    BH_SANDBOX_TXT="kata microVM sandbox (signals: $sig)"
  else
    local pver=""
    if [ -r /proc/version ]; then
      read -r pver < /proc/version 2>/dev/null || pver=""
    fi
    case "$pver" in
      *gVisor*|*gvisor*)
        BH_SANDBOX="gvisor"
        BH_SANDBOX_TXT="gVisor user-space kernel"
        ;;
      *firecracker*|*Firecracker*)
        BH_SANDBOX="firecracker"
        BH_SANDBOX_TXT="Firecracker microVM"
        ;;
    esac
  fi

  # ---- P7: user-namespace budget ----
  local un=""
  if [ -r /proc/sys/user/max_user_namespaces ]; then
    read -r un < /proc/sys/user/max_user_namespaces 2>/dev/null || un=""
  fi
  un="${un%%[[:space:]]*}"
  case "$un" in
    ''|*[!0-9]*) : ;;
    *)           BH_USERNS_MAX="$un" ;;
  esac

  # ---- P8: guest/provisioning agents (presence-only; configs NEVER read) ----
  local agents=""
  if command_exists cloud-init || [ -d /var/lib/cloud ]; then
    agents="cloud-init"
  fi
  if command_exists qemu-ga \
    || [ -e /usr/lib/systemd/system/qemu-guest-agent.service ] \
    || [ -e /lib/systemd/system/qemu-guest-agent.service ]; then
    agents="${agents:+$agents,}qemu-ga"
  fi
  if command_exists vmtoolsd; then
    agents="${agents:+$agents,}vmtoolsd"
  fi
  if command_exists waagent \
    || [ -e /usr/lib/systemd/system/walinuxagent.service ] \
    || [ -e /lib/systemd/system/walinuxagent.service ] \
    || [ -e /usr/lib/systemd/system/waagent.service ] \
    || [ -e /lib/systemd/system/waagent.service ]; then
    agents="${agents:+$agents,}waagent"
  fi
  if command_exists google-guest-agent; then
    agents="${agents:+$agents,}google-guest-agent"
  fi
  if command_exists amazon-ssm-agent \
    || [ -e /usr/lib/systemd/system/snap.amazon-ssm-agent.amazon-ssm-agent.service ] \
    || [ -e /lib/systemd/system/snap.amazon-ssm-agent.amazon-ssm-agent.service ] \
    || [ -e /usr/lib/systemd/system/amazon-ssm-agent.service ] \
    || [ -e /lib/systemd/system/amazon-ssm-agent.service ]; then
    agents="${agents:+$agents,}amazon-ssm-agent"
  fi
  BH_GUEST_AGENTS="$agents"

  return 0
}
