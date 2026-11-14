# =====================================================================
# blackhole-vps-bench · 85-hardening.sh — system hardening audit
# Appended to the SSH & security section: sec_audit (80-ssh.sh) calls
# sec_hardening through a guarded `command -v` so this module stays
# optional and standalone-sourceable.
# Checks: MAC layer (SELinux/AppArmor), pending package updates, risky
# wildcard listeners, cryptominer processes, docker.sock permissions,
# kernel security sysctls, /tmp mount hardening, cron/systemd timers.
# No root required — every command is guarded and degrades gracefully
# (busybox/alpine safe: no GNU-only flags, stderr always discarded).
# POSIX-ish bash; no set -e; no sudo.
# =====================================================================
# shellcheck shell=bash

# ------- module globals (raw values; the report layer may read them) -------
BH_MAC=""            # SELinux state | "apparmor" | "none" | ""
BH_UPDATES="n/a"     # "N pending" | "n/a"
BH_UPDATES_N=-1      # pending update count (-1 = unknown)
BH_RISKY_PORTS=""    # e.g. "redis(6379),mysql(3306)" — wildcard binds only
BH_MINERS=0          # cryptominer process hits
BH_MINER_NAMES=""    # deduped, truncated to 120 chars
BH_DOCKER_SOCK=""    # "absent" | "mode NNN" | "unknown"
BH_SYSCTL_KPTR=""    # kernel.kptr_restrict raw value
BH_SYSCTL_DMESG=""   # kernel.dmesg_restrict raw value
BH_SYSCTL_BPF=""     # kernel.unprivileged_bpf_disabled raw ("" = file absent)
BH_SYSCTL_YAMA=""    # kernel.yama.ptrace_scope raw ("" = file absent)
BH_TMP_OPTS=""       # /tmp mount options (raw)
BH_TIMERS_N=""       # systemd timer count ("" = systemctl missing)
BH_CRON_N=""         # file count under /etc/cron*

# bh_run_to SECS CMD... — run a possibly-slow command under `timeout` when
# available; stderr and stdin are neutralized so audit output stays clean.
bh_run_to() {
  local secs="$1"; shift
  if command_exists timeout; then
    timeout "$secs" "$@" 2>/dev/null </dev/null
  else
    "$@" 2>/dev/null </dev/null
  fi
}

# 45s ceiling for package-manager update queries (they may refresh metadata;
# local caches answer in well under that).
bh_run45() { bh_run_to 45 "$@"; }

# ---- 1. MAC layer: SELinux first, then AppArmor, then "none" ----
sec_hardening_mac() {
  if command_exists getenforce; then
    BH_MAC="$(getenforce 2>/dev/null)"
    case "$BH_MAC" in
      Enforcing)  sec_line ok   "MAC: SELinux enforcing" ;;
      Permissive) sec_line warn "MAC: SELinux permissive — 'setenforce 1' would harden" ;;
      *)          BH_MAC="Disabled"
                  sec_line info "MAC: SELinux disabled" ;;
    esac
    return 0
  fi
  if grep -q '^Y' /sys/module/apparmor/parameters/enabled 2>/dev/null; then
    BH_MAC="apparmor"
    # aa-status usually wants root; on failure just report "enabled" plain.
    local profs
    profs="$(bh_run45 aa-status | awk '/profiles are loaded/{print $1; exit}')"
    case "$profs" in
      ''|*[!0-9]*) sec_line ok "MAC: AppArmor enabled" ;;
      *)           sec_line ok "MAC: AppArmor enabled ($profs profiles loaded)" ;;
    esac
    return 0
  fi
  BH_MAC="none"
  sec_line info "MAC: none (no SELinux/AppArmor)"
}

# ---- 2. pending package updates — first usable package manager wins ----
# Local-cache based where possible, so BH_NO_NET does not skip this; every
# query is still wrapped in a timeout to bound worst-case metadata refreshes.
sec_hardening_updates() {
  local n=-1 mgr="" alist aout cout rc
  if command_exists apt; then
    mgr="apt"
    alist="$(bh_run45 apt list --upgradable)"
    if [ -n "$alist" ]; then
      # line 1 is the "Listing..." header; WARNING chatter filtered out
      n="$(printf '%s\n' "$alist" | tail -n +2 | grep -vc '^WARNING')"
    else
      # old/broken apt: simulate the upgrade set from the local cache
      n="$(bh_run45 apt-get -s dist-upgrade | grep -c '^Inst ')"
    fi
  elif command_exists dnf || command_exists yum; then
    mgr="dnf/yum"
    local pkg=dnf
    command_exists dnf || pkg=yum
    aout="$(bh_run45 "$pkg" check-update -q)"; rc=$?
    # rc 100 = updates available, 0 = none, anything else = check failed
    case "$rc" in
      0)   n=0 ;;
      100) n="$(printf '%s\n' "$aout" | grep -cE '.+-[0-9]')"
           [ "$n" -gt 0 ] 2>/dev/null || n=-1 ;;
      *)   n=-1 ;;
    esac
  elif command_exists apk; then
    mgr="apk"
    # busybox apk prints one "<" per upgradable package; empty = nothing pending
    n="$(bh_run45 apk version -l '<' | tail -n +2 | grep -c '<')"
  elif command_exists pacman; then
    mgr="pacman"
    if command_exists checkupdates; then
      cout="$(bh_run45 checkupdates)"; rc=$?
      case "$rc" in
        0) n="$(printf '%s\n' "$cout" | grep -c .)" ;;
        *) n=-1 ;;
      esac
    fi # checkupdates missing (pacman-contrib not installed) -> stays -1
  fi
  case "$n" in ''|*[!0-9]*) n=-1 ;; esac
  BH_UPDATES_N="$n"
  if [ "$n" -lt 0 ]; then
    BH_UPDATES="n/a"
    if [ -n "$mgr" ]; then
      sec_line info "pending updates: unknown ($mgr present, update check failed)"
    else
      sec_line info "pending updates: unknown (no package manager usable)"
    fi
  elif [ "$n" -eq 0 ]; then
    BH_UPDATES="0 pending"
    sec_line ok "all packages up to date (or repo metadata fresh)"
  elif [ "$n" -le 50 ]; then
    BH_UPDATES="$n pending"
    sec_line info "$n package updates pending"
  else
    BH_UPDATES="$n pending"
    sec_line warn "$n package updates pending — patch cycle looks stale"
  fi
}

# ---- 3. risky services bound on wildcard addresses ----
# bad: telnet/redis/memcached/mongodb (unauthenticated root-equivalent access)
# warn: ftp/smb/mssql/mysql/rdp/postgres/vnc/elasticsearch
sec_hardening_listeners() {
  if ! command_exists ss; then
    sec_line info "listening-service scan skipped (ss unavailable)"
    return 0
  fi
  local ssout rc found="" seen="|" entry addr port svc
  ssout="$(ss -tulnH 2>/dev/null)"; rc=$?
  if [ "$rc" != "0" ]; then
    ssout="$(ss -tuln 2>/dev/null)"; rc=$?   # old ss without -H; awk drops header
  fi
  if [ "$rc" != "0" ]; then
    sec_line info "listening-service scan skipped (ss unusable)"
    return 0
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    addr="${entry%:*}"; port="${entry##*:}"
    case "$port" in ''|*[!0-9]*) continue ;; esac
    addr="${addr#\[}"; addr="${addr%\]}"   # [::] -> ::
    case "$addr" in
      0.0.0.0|::|\*|"") : ;;               # wildcard binds only
      *) continue ;;
    esac
    case "$seen" in *"|$port|"*) continue ;; esac
    seen="$seen$port|"
    case "$port" in
      21)    svc="ftp" ;;
      23)    svc="telnet" ;;
      445)   svc="smb" ;;
      1433)  svc="mssql" ;;
      3306)  svc="mysql" ;;
      3389)  svc="rdp" ;;
      5432)  svc="postgres" ;;
      5900)  svc="vnc" ;;
      6379)  svc="redis" ;;
      9200)  svc="elasticsearch" ;;
      11211) svc="memcached" ;;
      27017) svc="mongodb" ;;
      *)     continue ;;
    esac
    found="${found:+$found,}$svc($port)"
    case "$port" in
      23|6379|11211|27017)
        sec_line bad "port $port ($svc) exposed on all interfaces — bind to 127.0.0.1 or firewall it" ;;
      *)
        sec_line warn "port $port ($svc) exposed on all interfaces — bind to 127.0.0.1 or firewall it" ;;
    esac
  done < <(printf '%s\n' "$ssout" | awk '$1 ~ /^(tcp|udp|tcp6|udp6)$/ && NF>=5 {print $5}')
  if [ -n "$found" ]; then
    BH_RISKY_PORTS="$found"
    sec_line info "risky wildcard binds: $BH_RISKY_PORTS"
  else
    sec_line ok "no risky services on wildcard binds"
  fi
}

# ---- 4. known cryptominer processes ----
sec_hardening_miners() {
  if ! command_exists pgrep; then
    sec_line info "cryptominer scan skipped (pgrep unavailable)"
    return 0
  fi
  local pid ppid gp cl comm n=0 names=""
  # NOTE: intentionally NOT wrapped in timeout — `timeout 45 pgrep -f PATTERN`
  # would put PATTERN into the timeout process argv and pgrep would flag it.
  # Self-match guard (QA v3): skip our own PID, our direct forks (PPid == $$),
  # our parent/grandparent shells, and any cmdline that merely mentions this
  # tool or the test suite — otherwise a report saved as /tmp/xmrig-report.txt
  # would flag the tool itself as a miner.
  gp="$(awk '/^PPid/{print $2}' "/proc/$$/status" 2>/dev/null)"
  for pid in $(pgrep -f 'xmrig|kdevtmpfsi|kinsing|minergate|stratum\+tcp|cpuminer' 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    ppid="$(awk '/^PPid/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    [ "$ppid" = "$$" ] && continue
    [ -n "$gp" ] && [ "$ppid" = "$gp" ] && continue
    cl="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    # vanished race (process exited between pgrep and this read) or kernel
    # thread with empty cmdline — cannot verify, must NOT flag
    [ -n "$cl" ] || continue
    case "$cl" in
      *blackhole-vps-bench*|*run-tests.sh*) continue ;;
    esac
    comm="$(awk '{print $1}' "/proc/$pid/comm" 2>/dev/null)"
    [ -n "$comm" ] || comm="pid:$pid"
    n=$((n + 1))
    names="$names $comm"
  done
  if [ "$n" -eq 0 ]; then
    BH_MINERS=0
    BH_MINER_NAMES=""
    sec_line ok "no known cryptominer processes"
    return 0
  fi
  BH_MINERS="$n"
  names="$(printf '%s\n' "$names" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd ',' -)"
  BH_MINER_NAMES="${names:0:120}"
  sec_line bad "possible cryptominer: $BH_MINER_NAMES ($BH_MINERS process(es))"
}

# ---- 5. docker.sock permissions (world/group access = root-equivalent) ----
sec_hardening_docker() {
  if [ ! -S /var/run/docker.sock ]; then
    BH_DOCKER_SOCK="absent"
    return 0   # no docker here — no verdict line by design
  fi
  local perms
  perms="$(stat -c %a /var/run/docker.sock 2>/dev/null)"
  case "$perms" in
    ''|*[!0-9]*)
      BH_DOCKER_SOCK="unknown"
      sec_line info "docker.sock present but mode unknown (stat unavailable)"
      return 0 ;;
  esac
  BH_DOCKER_SOCK="mode $perms"
  local others group
  others="${perms: -1}"     # other-bits digit
  group="${perms: -2:1}"    # group-bits digit
  case "$others" in
    0) : ;;
    *) sec_line bad "docker.sock world-accessible (root-equivalent) — mode $perms"
       return 0 ;;
  esac
  case "$group" in
    2|3|6|7) sec_line warn "docker.sock group-writable — mode $perms (group members get root)" ;;
    *)       sec_line ok "docker.sock root:docker only — mode $perms" ;;
  esac
}

# ---- 6. kernel security sysctls ----
sec_hardening_sysctl() {
  BH_SYSCTL_KPTR="$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)"
  BH_SYSCTL_DMESG="$(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null)"
  BH_SYSCTL_BPF="$(cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null)"
  BH_SYSCTL_YAMA="$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null)"
  if [ ! -d /proc/sys/kernel ]; then
    sec_line info "kernel sysctls: n/a (/proc/sys not readable)"
    return 0
  fi
  case "$BH_SYSCTL_KPTR" in
    ''|*[!0-9]*) : ;;   # unreadable/absent — skip quietly
    0) sec_line warn "kptr_restrict=0 — kernel pointers exposed to unprivileged users" ;;
    *) sec_line ok "kptr_restrict=$BH_SYSCTL_KPTR — kernel pointers hidden" ;;
  esac
  case "$BH_SYSCTL_DMESG" in
    ''|*[!0-9]*) : ;;
    0) sec_line warn "dmesg_restrict=0 — dmesg open to unprivileged users" ;;
    *) sec_line ok "dmesg_restrict=$BH_SYSCTL_DMESG — dmesg restricted" ;;
  esac
  case "$BH_SYSCTL_BPF" in
    ''|*[!0-9]*) : ;;   # often missing on older kernels — skip
    0) sec_line warn "unprivileged BPF enabled (unprivileged_bpf_disabled=0)" ;;
    *) sec_line ok "unprivileged BPF disabled (unprivileged_bpf_disabled=$BH_SYSCTL_BPF)" ;;
  esac
  case "$BH_SYSCTL_YAMA" in
    ''|*[!0-9]*) : ;;   # Yama is optional — skip when absent
    0) sec_line info "ptrace_scope=0 — Yama not restricting ptrace" ;;
    *) sec_line ok "ptrace_scope=$BH_SYSCTL_YAMA — ptrace restricted (Yama)" ;;
  esac
}

# ---- 7. /tmp mount hardening (noexec + nosuid) ----
sec_hardening_tmp() {
  BH_TMP_OPTS="$(findmnt -no OPTIONS /tmp 2>/dev/null)"
  if [ -z "$BH_TMP_OPTS" ]; then
    # fallback for busybox/alpine (no findmnt): /proc/mounts field 4
    BH_TMP_OPTS="$(grep ' /tmp ' /proc/mounts 2>/dev/null | awk '{print $4; exit}')"
  fi
  local noexec=0 nosuid=0
  case ",${BH_TMP_OPTS:-}," in *,noexec,*) noexec=1 ;; esac
  case ",${BH_TMP_OPTS:-}," in *,nosuid,*) nosuid=1 ;; esac
  if [ -z "$BH_TMP_OPTS" ]; then
    sec_line info "/tmp: not a separate mount — options unknown"
  elif [ "$noexec" = "1" ] && [ "$nosuid" = "1" ]; then
    sec_line ok "/tmp hardened (noexec,nosuid)"
  elif [ "$noexec" = "1" ] || [ "$nosuid" = "1" ]; then
    sec_line info "/tmp: $BH_TMP_OPTS (partial — add the missing noexec/nosuid)"
  else
    sec_line info "/tmp: $BH_TMP_OPTS (consider noexec,nosuid)"
  fi
}

# ---- 8. cron entries and systemd timers (informational) ----
sec_hardening_cron() {
  local d seen="|" n=0
  for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
    [ -d "$d" ] || continue
    d="$(readlink -f "$d" 2>/dev/null || echo "$d")"   # dedupe aliased dirs
    case "$seen" in *"|$d|"*) continue ;; esac
    seen="$seen$d|"
    # find (not ls) — handles dotfiles and any filename; busybox-safe
    n=$(( n + $(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ') ))
  done
  BH_CRON_N="$n"
  if [ "$n" -gt 0 ] 2>/dev/null; then
    sec_line info "cron entries: $n file(s) in /etc/cron*"
  fi
  if command_exists systemctl; then
    BH_TIMERS_N="$(systemctl list-timers --no-legend 2>/dev/null | wc -l | tr -d ' ')"
    case "$BH_TIMERS_N" in ''|*[!0-9]*) BH_TIMERS_N="" ;; esac
    if [ -n "$BH_TIMERS_N" ] && [ "$BH_TIMERS_N" -gt 0 ] 2>/dev/null; then
      sec_line info "systemd timers: $BH_TIMERS_N active"
    fi
  fi
}

# sec_hardening — entry point called (guarded) at the end of sec_audit.
# Every verdict goes through sec_line; posture counting is automatic.
sec_hardening() {
  sec_hardening_mac
  sec_hardening_updates
  sec_hardening_listeners
  sec_hardening_miners
  sec_hardening_docker
  sec_hardening_sysctl
  sec_hardening_tmp
  sec_hardening_cron
}
