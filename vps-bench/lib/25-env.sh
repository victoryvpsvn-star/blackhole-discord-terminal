# =====================================================================
# blackhole-vps-bench · 25-env.sh — capabilities, rlimits, device exposure
# =====================================================================
# shellcheck shell=bash
#
# Environment deep-dive (module 25): what this box is ALLOWED to do.
#   E1 capability inventory (/proc/self/status CapEff/CapBnd, pure-bash bit decode)
#   E2 process-count limits (cgroup v2/v1 pids.max + pids.current)
#   E3 no-new-privs posture (/proc/self/status NoNewPrivs + Securebits)
#   E4 PID 1 identity       (LSM label + cmdline preview)
#   E5 rlimits              (ulimit -S/-H probes, read-only, in subshells)
#   E6 device exposure      (/dev/kvm tun dri fuse ppp + /dev/shm size)
#   E7 OOM posture          (oom_score_adj / oom_score)
#   E8 cgroup controllers   (v2 cgroup.controllers | "cgroup-v1" | unknown)
#
# Contract: sets BH_* globals only (never stdout); every external command is
# guarded (command_exists + `timeout 2`); NO network access in this module;
# no `set -e`; bash-3.2 compatible (no assoc arrays / mapfile — pure-bash bit
# decode with case/while loops); never fails: unreadable input => ""/0/unknown.
# NOTE: entropy is intentionally NOT read here — 20-info.sh owns BH_ENTROPY.

# ------- globals (empty / 0 defaults) -------
BH_CAPS_EFF=""        # comma list of effective caps | none | unknown
BH_CAPS_CLASS=""      # privileged | semi-privileged | unprivileged | unknown
BH_CAPS_MISSING=""    # "dropped:a,b bounded-out:c,d" | none | unknown
BH_CAPS_EFF_HEX=""    # raw CapEff hex from /proc/self/status (debug aid)
BH_CAPS_BND_HEX=""    # raw CapBnd hex from /proc/self/status (debug aid)
BH_CAPS_CAPSH=""      # capsh --print cross-check: match | mismatch | ""=skipped
BH_PIDS_MAX=""        # unlimited | <number> | unknown
BH_PIDS_CUR=0
BH_NNP=""             # NoNewPrivs: 0 | 1 | ""=unknown (line absent)
BH_SECUREBITS=""      # first token of the Securebits line | ""=unknown
BH_PID1_LSM=""        # /proc/1/attr/current content | unconfined
BH_PID1_CMD=""        # first 40 chars of /proc/1/cmdline, NULs -> spaces
BH_RL_NOFILE=""       # soft/hard
BH_RL_NPROC=""        # soft/hard
BH_RL_STACK_KB=""
BH_RL_MEMLOCK_KB=""
BH_RL_CORE=""
BH_DEV_MAP=""         # "kvm:yes tun:no dri:no fuse:no ppp:no shm:64M"
BH_SHM_MB=""          # /dev/shm size in MB | ""=unknown
BH_OOM_ADJ=""         # /proc/self/oom_score_adj | ""=unknown
BH_OOM_SCORE=""       # /proc/self/oom_score | ""=unknown
BH_CG_CONTROLLERS=""  # v2 controller list | cgroup-v1 | unknown

# ------- v5 (C11) additions — identity & pressure truth -------
#   E9 uid/gid map truth  (/proc/self/{uid,gid}_map: real root vs mapped root)
#   E10 seccomp posture   (/proc/self/status Seccomp[+Seccomp_filters] + uid)
#   E11 PSI snapshot      (core's bh_psi; labelled host-wide because
#                          /proc/pressure is host-wide inside containers)
BH_UIDMAP_MODE=""     # initial user-ns (real root) | rootless (mapped
                      # container root)[; note] | mapped (idmapped?) | unknown
BH_SECCOMP_MODE=""    # none | strict | filter [+ filters=N][+ note] | unknown
BH_PSI_TXT=""         # "psi(host): cpu s=.. f=.. | mem .. | io .." |
                      # "psi(host): off" [+ " (CPU throttling evidence)"]

# canonical capability names, bits 0..40 (include/uapi/linux/capability.h)
BH_CAP_NAMES=(
  cap_chown dac_override dac_read_search fowner fsetid kill setgid setuid
  setpcap linux_immutable net_bind_service net_broadcast net_admin net_raw
  ipc_lock ipc_owner sys_module sys_rawio sys_chroot sys_ptrace sys_pacct
  sys_admin sys_boot sys_nice sys_resource sys_time sys_tty_config mknod
  lease audit_write audit_control setfcap mac_override mac_admin syslog
  wake_alarm block_suspend audit_read perfmon bpf checkpoint_restore
)

# bh_hex_norm HEX — validate a hex string ("" when invalid/empty); keep only
# the low 64 bits (last 16 chars) — more than enough for bits 0..40.
bh_hex_norm() {
  local h="$1"
  case "$h" in ''|*[!0-9a-fA-F]*) printf ''; return 0 ;; esac
  while [ "${#h}" -gt 16 ]; do h="${h#?}"; done
  printf '%s' "$h"
  return 0
}

# bh_cap_list_has LIST NAME — exact element test on a comma list (0 = present)
bh_cap_list_has() {
  case ",${1}," in *",${2},"*) return 0 ;; esac
  return 1
}

# bh_cap_decode HEX — pure-bash decode of capability bits 0..40 via
# $(( (16#$hex >> i) & 1 )); prints the comma list of set bits ("" = none).
bh_cap_decode() {
  local hex="$1" i=0 bit out=""
  case "$hex" in ''|*[!0-9a-fA-F]*) printf ''; return 0 ;; esac
  while [ "$i" -le 40 ]; do
    bit=$(( (16#$hex >> i) & 1 ))
    if [ "$bit" -eq 1 ]; then out="${out:+$out,}${BH_CAP_NAMES[$i]}"; fi
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
  return 0
}

# bh_rl_val SOFT_OR_HARD OPTION — read one ulimit value inside a $( ) subshell
# (ulimit is a shell builtin: cannot hang, no timeout possible/needed).
# Prints: number | unlimited | "" (unsupported/failed).
bh_rl_val() {
  local v
  v="$(ulimit "$1" "$2" 2>/dev/null)" || v=""
  case "$v" in
    unlimited)   printf 'unlimited' ;;
    ''|*[!0-9]*) printf '' ;;
    *)           printf '%s' "$v" ;;
  esac
  return 0
}

# bh_yn 0|1 — yes/no token for the device map
bh_yn() {
  if [ "$1" = "1" ]; then printf 'yes'; else printf 'no'; fi
  return 0
}

# =====================================================================
# v5 (C11) private helpers — identity & pressure truth (no stdout except
# where a helper is documented to print; all guarded, read-only, pure
# bash so the module stays mawk-safe by construction)
# =====================================================================

# bhv5c11_map_mode IN OUT COUNT — classify one user-ns map line
# ("id-inside id-outside map-length", all three must be numeric).
# Prints: initial | rootless | mapped | unknown. Pure bash, no forks.
bhv5c11_map_mode() {
  local a="$1" b="$2" c="$3"
  case "$a$b$c" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  if [ "$a" = "0" ] && [ "$b" = "0" ] && [ "$c" = "4294967295" ]; then
    printf 'initial'                 # full map: we are the initial user-ns
  elif [ "$a" = "0" ] && [ "$b" != "0" ] && [ "$c" = "1" ]; then
    printf 'rootless'                # container root 0 -> host uid N, length 1
  else
    printf 'mapped'                  # partial / idmapped-style mapping
  fi
  return 0
}

# bhv5c11_dec_gt0 DECIMAL — return 0 when DECIMAL ("12" | "0.42" | "00.10")
# parses and is strictly greater than zero. Pure bash integer/fraction
# digit walk (mawk-safe: no floating-point arithmetic anywhere).
bhv5c11_dec_gt0() {
  local s="$1" ip fp i c
  case "$s" in ''|*[!0-9.]*) return 1 ;; esac
  case "$s" in *.*) ip="${s%%.*}"; fp="${s#*.}" ;; *) ip="$s"; fp="" ;; esac
  case "$ip" in ''|*[!0-9]*) return 1 ;; esac
  case "$fp" in *.*|*[!0-9]*) return 1 ;; esac   # reject "1.2.3" / "1.2a"
  while [ "${#ip}" -gt 1 ] && [ "${ip:0:1}" = "0" ]; do ip="${ip:1}"; done
  if [ "$ip" != "0" ]; then return 0; fi
  i=0
  while [ "$i" -lt "${#fp}" ]; do
    c="${fp:i:1}"
    [ "$c" != "0" ] && return 0
    i=$(( i + 1 ))
  done
  return 1
}

# bhv5c11_priv_truth — called at the end of gather_env. Fills:
#   BH_UIDMAP_MODE  BH_SECCOMP_MODE  BH_PSI_TXT  (see globals above)
bhv5c11_priv_truth() {
  # ---- E9: uid/gid map truth ----
  local u_in="" u_out="" u_cnt="" g_in="" g_out="" g_cnt=""
  local uid_mode="unknown" gid_mode="unknown" mode=""
  if [ -r /proc/self/uid_map ]; then
    read -r u_in u_out u_cnt < /proc/self/uid_map 2>/dev/null || u_in=""
  fi
  if [ -r /proc/self/gid_map ]; then
    read -r g_in g_out g_cnt < /proc/self/gid_map 2>/dev/null || g_in=""
  fi
  uid_mode="$(bhv5c11_map_mode "$u_in" "$u_out" "$u_cnt")"
  gid_mode="$(bhv5c11_map_mode "$g_in" "$g_out" "$g_cnt")"
  mode="$uid_mode"
  if [ "$mode" = "unknown" ]; then mode="$gid_mode"; fi
  # uid and gid maps both readable but disagree: treat as mapped, not trusted
  if [ "$uid_mode" != "unknown" ] && [ "$gid_mode" != "unknown" ] \
    && [ "$uid_mode" != "$gid_mode" ]; then
    mode="mapped"
  fi
  case "$mode" in
    initial)  BH_UIDMAP_MODE="initial user-ns (real root)" ;;
    rootless) BH_UIDMAP_MODE="rootless (mapped container root); root but confined (unprivileged container)" ;;
    mapped)   BH_UIDMAP_MODE="mapped (idmapped?)" ;;
    *)        BH_UIDMAP_MODE="unknown" ;;
  esac

  # ---- E10: seccomp posture (Seccomp / Seccomp_filters / Uid) ----
  local key val seccomp="" sfilt="" realuid=""
  if [ -r /proc/self/status ]; then
    while read -r key val _ || [ -n "${key:-}" ]; do
      case "$key" in
        Seccomp:)         seccomp="${val:-}" ;;
        Seccomp_filters:) sfilt="${val:-}" ;;
        Uid:)             realuid="${val:-}" ;;
      esac
    done < /proc/self/status
  fi
  case "$seccomp" in
    0) BH_SECCOMP_MODE="none" ;;
    1) BH_SECCOMP_MODE="strict" ;;
    2) BH_SECCOMP_MODE="filter" ;;
    *) BH_SECCOMP_MODE="unknown" ;;
  esac
  if [ "$BH_SECCOMP_MODE" != "unknown" ]; then
    case "$sfilt" in ''|*[!0-9]*) : ;; *)
      BH_SECCOMP_MODE="$BH_SECCOMP_MODE filters=$sfilt" ;;
    esac
  fi
  # uid 0 with seccomp fully off is the classic "privileged-looking but
  # actually unprivileged container" tell (no filter => no syscall jail)
  if [ "$seccomp" = "0" ] && [ "$realuid" = "0" ]; then
    BH_SECCOMP_MODE="${BH_SECCOMP_MODE} (unprivileged container without seccomp)"
  fi

  # ---- E11: PSI snapshot, labelled host-wide ----
  # /proc/pressure reflects the HOST, not this cgroup, when we run inside a
  # container — hence the "psi(host): " prefix on whatever bh_psi returns.
  local psi cpu_s=""
  psi="$(bh_psi)"
  case "$psi" in
    off) BH_PSI_TXT="psi(host): off" ;;
    *)
      BH_PSI_TXT="psi(host): $psi"
      case "$psi" in
        cpu\ s=*)
          cpu_s="${psi#cpu s=}"
          cpu_s="${cpu_s%%[!0-9.]*}"
          if bhv5c11_dec_gt0 "$cpu_s"; then
            BH_PSI_TXT="$BH_PSI_TXT (CPU throttling evidence)"
          fi
          ;;
      esac
      ;;
  esac
  return 0
}

gather_env() {
  # ---- E1: capability inventory (CapEff / CapBnd) ----
  local key val _ cap_eff_hex="" cap_bnd_hex="" nnp="" sbits=""
  if [ -r /proc/self/status ]; then
    while read -r key val _ || [ -n "${key:-}" ]; do
      case "$key" in
        CapEff:)     cap_eff_hex="${val:-}" ;;
        CapBnd:)     cap_bnd_hex="${val:-}" ;;
        NoNewPrivs:) nnp="${val:-}" ;;
        Securebits:) sbits="${val:-}" ;;
      esac
    done < /proc/self/status
  fi
  cap_eff_hex="$(bh_hex_norm "$cap_eff_hex")"
  cap_bnd_hex="$(bh_hex_norm "$cap_bnd_hex")"
  BH_CAPS_EFF_HEX="$cap_eff_hex"
  BH_CAPS_BND_HEX="$cap_bnd_hex"
  if [ -n "$cap_eff_hex" ]; then
    BH_CAPS_EFF="$(bh_cap_decode "$cap_eff_hex")"
    [ -n "$BH_CAPS_EFF" ] || BH_CAPS_EFF="none"
  else
    BH_CAPS_EFF="unknown"
  fi
  if [ -n "$cap_eff_hex" ]; then
    if bh_cap_list_has "$BH_CAPS_EFF" sys_admin; then
      BH_CAPS_CLASS="privileged"
    elif bh_cap_list_has "$BH_CAPS_EFF" net_admin \
      || bh_cap_list_has "$BH_CAPS_EFF" sys_ptrace \
      || bh_cap_list_has "$BH_CAPS_EFF" net_raw; then
      BH_CAPS_CLASS="semi-privileged"
    else
      BH_CAPS_CLASS="unprivileged"
    fi
  else
    BH_CAPS_CLASS="unknown"
  fi
  # notable caps the bounding set still allows but the effective set dropped
  # ("dropped:"), vs caps the kernel never granted at all ("bounded-out:")
  if [ -n "$cap_eff_hex" ] && [ -n "$cap_bnd_hex" ]; then
    local ndrop="" nbnd="" c bnd_list
    bnd_list="$(bh_cap_decode "$cap_bnd_hex")"
    for c in net_admin sys_admin net_raw sys_ptrace sys_time; do
      if bh_cap_list_has "$BH_CAPS_EFF" "$c"; then continue; fi
      if bh_cap_list_has "$bnd_list" "$c"; then
        ndrop="${ndrop:+$ndrop,}$c"
      else
        nbnd="${nbnd:+$nbnd,}$c"
      fi
    done
    if [ -n "$ndrop" ] || [ -n "$nbnd" ]; then
      BH_CAPS_MISSING=""
      if [ -n "$ndrop" ]; then BH_CAPS_MISSING="dropped:$ndrop"; fi
      if [ -n "$nbnd" ]; then
        BH_CAPS_MISSING="${BH_CAPS_MISSING:+$BH_CAPS_MISSING }bounded-out:$nbnd"
      fi
    else
      BH_CAPS_MISSING="none"
    fi
  else
    BH_CAPS_MISSING="unknown"
  fi
  # optional cross-check with libcap's capsh (best effort, ignore failures).
  # capsh quirks: empty set renders as "Current: =", every name carries a
  # "cap_" prefix, and our first canonical name is "cap_chown" (task table) —
  # so normalize both sides to a prefix-free comma list before comparing.
  if [ -n "$cap_eff_hex" ] && command_exists capsh && command_exists timeout; then
    local cs_cur cs_norm my_norm
    cs_cur="$(timeout 2 capsh --print 2>/dev/null | awk '/^Current:/{ $1=""; gsub(/[ \t]/, ""); print; exit }')"
    while [ "${cs_cur%,}" != "$cs_cur" ]; do cs_cur="${cs_cur%,}"; done
    cs_norm=""
    if [ "$cs_cur" = "=" ]; then
      cs_norm="none"                    # capsh renders an empty set as "="
    elif [ -n "$cs_cur" ]; then
      cs_norm="${cs_cur#cap_}"          # capsh prefixes every name with "cap_"
      cs_norm="${cs_norm//,cap_/,}"
    fi
    if [ -n "$cs_norm" ]; then
      my_norm="${BH_CAPS_EFF/#cap_chown/chown}"   # compare in capsh's prefix-free form
      if [ "$cs_norm" = "$my_norm" ]; then
        BH_CAPS_CAPSH="match"
      else
        BH_CAPS_CAPSH="mismatch"
        warn "capsh disagrees with /proc cap decode: capsh='${cs_norm:0:64}' proc='${my_norm:0:64}'"
      fi
    fi
  fi

  # ---- E3: no-new-privs posture ----
  case "$nnp" in 0|1) BH_NNP="$nnp" ;; *) BH_NNP="" ;; esac
  BH_SECUREBITS="$sbits"

  # ---- E4: PID 1 identity (LSM label + cmdline preview) ----
  BH_PID1_LSM="unconfined"
  local lsm=""
  if [ -r /proc/1/attr/current ]; then
    read -r lsm < /proc/1/attr/current 2>/dev/null || lsm="${lsm:-}"
  fi
  if [ -z "$lsm" ] && [ -r /proc/1/attr/apparmor/current ]; then
    read -r lsm < /proc/1/attr/apparmor/current 2>/dev/null || lsm="${lsm:-}"
  fi
  if [ -n "$lsm" ]; then BH_PID1_LSM="$lsm"; fi
  BH_PID1_CMD=""
  if [ -r /proc/1/cmdline ]; then
    local c1=""
    if command_exists tr && command_exists timeout; then
      c1="$(timeout 2 tr '\0' ' ' < /proc/1/cmdline 2>/dev/null || true)"
    else
      # no tr: bash read() silently drops NULs — argv[0] only, still useful
      IFS= read -r -d '' c1 < /proc/1/cmdline 2>/dev/null || c1="${c1:-}"
    fi
    c1="${c1:-}"
    while [ -n "$c1" ] && [ "${c1#"${c1%?}"}" = " " ]; do c1="${c1%?}"; done
    BH_PID1_CMD="${c1:0:40}"
  fi

  # ---- E2: process-count limits (cgroup pids controller) ----
  local pmax_f="" pcur_f="" pv
  case "$CG_VER" in
    2) pmax_f="/sys/fs/cgroup/pids.max";      pcur_f="/sys/fs/cgroup/pids.current" ;;
    1) pmax_f="/sys/fs/cgroup/pids/pids.max"; pcur_f="/sys/fs/cgroup/pids/pids.current" ;;
  esac
  BH_PIDS_MAX="unknown"
  BH_PIDS_CUR=0
  if [ -n "$pmax_f" ] && [ -r "$pmax_f" ]; then
    pv=""
    read -r pv < "$pmax_f" 2>/dev/null || pv="${pv:-}"
    pv="${pv//[[:space:]]/}"
    case "$pv" in
      max|-1)   BH_PIDS_MAX="unlimited" ;;
      ''|*[!0-9]*) : ;;
      *)        BH_PIDS_MAX="$pv" ;;
    esac
  fi
  if [ -n "$pcur_f" ] && [ -r "$pcur_f" ]; then
    pv=""
    read -r pv < "$pcur_f" 2>/dev/null || pv="${pv:-}"
    pv="${pv//[[:space:]]/}"
    case "$pv" in
      ''|*[!0-9]*) : ;;
      *)           BH_PIDS_CUR="$pv" ;;
    esac
  fi

  # ---- E5: rlimits (read-only probes; builtin => cannot hang) ----
  local sn hn su hu
  sn="$(bh_rl_val -S -n)"; hn="$(bh_rl_val -H -n)"
  if [ -n "$sn$hn" ]; then BH_RL_NOFILE="${sn:-unknown}/${hn:-unknown}"; fi
  su="$(bh_rl_val -S -u)"; hu="$(bh_rl_val -H -u)"
  if [ -n "$su$hu" ]; then BH_RL_NPROC="${su:-unknown}/${hu:-unknown}"; fi
  BH_RL_STACK_KB="$(bh_rl_val -S -s)"
  BH_RL_MEMLOCK_KB="$(bh_rl_val -S -l)"
  BH_RL_CORE="$(bh_rl_val -S -c)"

  # ---- E6: device exposure (existence checks only) ----
  local dkvm=0 dtun=0 ddri=0 dfuse=0 dppp=0 skb=""
  if [ -e /dev/kvm ];     then dkvm=1;  fi
  if [ -e /dev/net/tun ]; then dtun=1;  fi
  if [ -d /dev/dri ];     then ddri=1;  fi
  if [ -e /dev/fuse ];    then dfuse=1; fi
  if [ -e /dev/ppp ];     then dppp=1;  fi
  if command_exists df; then
    if command_exists timeout; then
      skb="$(timeout 2 df -k /dev/shm 2>/dev/null | awk 'NR==2 { print $2 }')"
    else
      skb="$(df -k /dev/shm 2>/dev/null | awk 'NR==2 { print $2 }')"
    fi
  fi
  case "$skb" in
    ''|*[!0-9]*) BH_SHM_MB="" ;;
    *)           BH_SHM_MB=$(( skb / 1024 )) ;;
  esac
  local shm_part="unknown"
  case "$BH_SHM_MB" in
    ''|*[!0-9]*) : ;;
    *)           shm_part="${BH_SHM_MB}M" ;;
  esac
  BH_DEV_MAP="kvm:$(bh_yn "$dkvm") tun:$(bh_yn "$dtun") dri:$(bh_yn "$ddri") fuse:$(bh_yn "$dfuse") ppp:$(bh_yn "$dppp") shm:$shm_part"

  # ---- E7: OOM posture ----
  local oomv
  if [ -r /proc/self/oom_score_adj ]; then
    oomv=""
    read -r oomv < /proc/self/oom_score_adj 2>/dev/null || oomv="${oomv:-}"
    oomv="${oomv//[[:space:]]/}"
    case "$oomv" in
      ''|*[!0-9]*) : ;;
      *)           BH_OOM_ADJ="$oomv" ;;
    esac
  fi
  if [ -r /proc/self/oom_score ]; then
    oomv=""
    read -r oomv < /proc/self/oom_score 2>/dev/null || oomv="${oomv:-}"
    oomv="${oomv//[[:space:]]/}"
    case "$oomv" in
      ''|*[!0-9]*) : ;;
      *)           BH_OOM_SCORE="$oomv" ;;
    esac
  fi

  # ---- E8: cgroup controllers ----
  case "$CG_VER" in
    2)
      local ctl=""
      if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
        read -r ctl < /sys/fs/cgroup/cgroup.controllers 2>/dev/null || ctl="${ctl:-}"
      fi
      if [ -n "$ctl" ]; then
        BH_CG_CONTROLLERS="$ctl"
      else
        BH_CG_CONTROLLERS="unknown"
      fi
      ;;
    1) BH_CG_CONTROLLERS="cgroup-v1" ;;
    *) BH_CG_CONTROLLERS="unknown" ;;
  esac

  # ---- E9/E10/E11 (v5, C11): uid-map / seccomp / PSI truth ----
  bhv5c11_priv_truth

  return 0
}
