# =====================================================================
# blackhole-vps-bench · 85-hardening.sh — system hardening audit
# Appended to the SSH & security section: sec_audit (80-ssh.sh) calls
# sec_hardening through a guarded `command -v` so this module stays
# optional and standalone-sourceable.
# Checks (v3): MAC layer (SELinux/AppArmor), pending package updates,
# risky wildcard listeners, cryptominer processes, docker.sock
# permissions, kernel security sysctls, /tmp mount hardening,
# cron/systemd timers.
# Checks (v4, X1-X8 — all passive, all degrade to n/a): world-writable
# entries in PATH dirs, SUID/SGID inventory + anomalies, core-dump
# settings, fs.protected_* race sysctls, legacy network-daemon packages,
# sudo/pkexec version age (INFO only), configured umask, forensics
# toolkit presence.
# Offline contract: when BH_NO_NET=1 nothing here touches the network —
# apt reads are cache-only and stay, but dnf/yum check-update (which
# refreshes repo metadata over the network) is skipped entirely.
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

# ---- v4 hardening globals (X1-X8; raw values, the report layer may read) ----
BH_SEC_PATH_WW="n/a"           # "0" | "N: /path1 /path2 …" — world-writable in PATH dirs
BH_SEC_SUID_COUNT="n/a"        # suid/sgid file count in the same PATH dirs
BH_SEC_SUID_ODD="n/a"          # basenames outside the whitelist (comma list) | "none"
BH_SEC_CORE="n/a"              # "dumpable=N ulimit=X pattern=Y" (+ WARN:… flags inside)
BH_SEC_PROTECTED_SYSCTL="n/a"  # "hardlinks:N regular:N fifos:N symlinks:N" (0 → "0!", missing → "?")
BH_SEC_LEGACY_PKGS="unknown"   # legacy daemons (comma list) | "none" | "unknown"
BH_SEC_SUDO_VER="unknown"      # first line of `sudo -V` (INFO-level only, never a WARN)
BH_SEC_PKEXEC_VER="unknown"    # first line of `pkexec --version` (INFO-level only, never a WARN)
BH_SEC_UMASK="n/a"             # "UMASK=NN (source)" (+ WARN:permissive) | "unset→distro default"
BH_SEC_FORENSICS="n/a"         # rkhunter/chkrootkit/clamscan/freshclam/aide found | "none"
BH_SEC_SCAN_DIRS=""            # internal: resolved bin dirs (≤3) shared by the X1/X2 scans

# Standalone-sourceable: the real sec_line lives in 80-ssh.sh. When this
# module is sourced on its own (tests, one-off debugging) provide a quiet
# fallback so nothing ever errors; 80-ssh.sh overrides it when loaded.
if ! command -v sec_line >/dev/null 2>&1; then
  sec_line() { return 0; }
fi

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
# BH_NO_NET contract: apt/apk/pacman reads below are cache-only (they make
# NO network calls) and always run; dnf/yum check-update REFRESHES repo
# metadata over the network and is skipped entirely when BH_NO_NET=1.
# BH_NO_SEC contract: the whole path also bails out early (the audit entry
# point gates it too). Every query stays timeout-wrapped.
sec_hardening_updates() {
  [ "${BH_NO_SEC:-0}" = "1" ] && return 0   # no update counts when sec is off
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
    # OFFLINE GATE — dnf/yum check-update contacts the repo mirrors to
    # refresh metadata even when local caches exist, so it must never run
    # with BH_NO_NET=1. Degrade to "unknown" instead.
    if [ "$BH_NO_NET" = "1" ]; then
      mgr="dnf/yum"
      BH_UPDATES_N=-1
      BH_UPDATES="n/a"
      sec_line info "pending updates: skipped (offline mode — dnf/yum check-update refreshes repo metadata over the network)"
      return 0
    fi
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

# ---- 9. PATH-dir world-writables (X1) ----
# Scans the first 3 DISTINCT standard bin dirs (maxdepth 1, one filesystem,
# 2s budget) for world-writable FILES and for world-writable DIRECTORIES
# missing the sticky bit — both are classic root-escalation bait.
bh_sec_bin_dirs() {  # sets BH_SEC_SCAN_DIRS: deduped, capped at 3 dirs
  BH_SEC_SCAN_DIRS=""
  local d r n=0 seen="|"
  for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$d" ] || continue
    r="$(readlink -f "$d" 2>/dev/null)"
    [ -n "$r" ] && [ -d "$r" ] || r="$d"
    case "$seen" in *"|$r|"*) continue ;; esac
    seen="$seen$r|"
    BH_SEC_SCAN_DIRS="$BH_SEC_SCAN_DIRS $r"
    n=$((n + 1))
    [ "$n" -ge 3 ] && break
  done
  BH_SEC_SCAN_DIRS="${BH_SEC_SCAN_DIRS# }"
  return 0
}

sec_hardening_path_ww() {
  BH_SEC_PATH_WW="n/a"
  if ! command_exists find; then
    sec_line info "PATH world-writable scan skipped (find unavailable)"
    return 0
  fi
  bh_sec_bin_dirs
  if [ -z "$BH_SEC_SCAN_DIRS" ]; then
    sec_line info "PATH world-writable scan skipped (no standard bin dirs)"
    return 0
  fi
  # standard system bin dirs, no spaces — word splitting is intended
  # shellcheck disable=SC2086
  local out rc n disp trunc=0
  # shellcheck disable=SC2086
  out="$(bh_run_to 2 find $BH_SEC_SCAN_DIRS -maxdepth 1 -xdev \
        \( -type f -perm -0002 -o -type d -perm -0002 \! -perm -1000 \) -print)"
  rc=$?
  n="$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -eq 0 ]; then
    if [ -z "$out" ] && [ "$rc" -gt 1 ]; then
      sec_line info "PATH world-writable scan failed (find rc=$rc)"
      return 0                      # BH_SEC_PATH_WW stays "n/a"
    fi
    BH_SEC_PATH_WW="0"
    sec_line ok "PATH dirs: no world-writable files / unsticky dirs"
    return 0
  fi
  disp="$(printf '%s\n' "$out" | sed '/^$/d' | head -n 5 | tr '\n' ' ')"
  disp="${disp% }"
  [ ${#disp} -gt 140 ] && { disp="${disp:0:140}"; trunc=1; }
  [ "$n" -gt 5 ] && trunc=1
  [ "$trunc" = "1" ] && disp="$disp …"
  BH_SEC_PATH_WW="$n: $disp"
  sec_line warn "PATH world-writable entries: $BH_SEC_PATH_WW — root-escalation bait"
}

# ---- 10. SUID/SGID inventory (X2) ----
# Same dirs/budget as X1. BH_SEC_SUID_COUNT counts setuid/setgid files,
# BH_SEC_SUID_ODD lists basenames outside the known-good whitelist
# ("none" when every hit is a standard binary).
sec_hardening_suid() {
  BH_SEC_SUID_COUNT="n/a"
  BH_SEC_SUID_ODD="n/a"
  if ! command_exists find; then
    sec_line info "SUID/SGID scan skipped (find unavailable)"
    return 0
  fi
  bh_sec_bin_dirs
  if [ -z "$BH_SEC_SCAN_DIRS" ]; then
    sec_line info "SUID/SGID scan skipped (no standard bin dirs)"
    return 0
  fi
  local ok_names="|sudo|su|mount|umount|passwd|chfn|chsh|newgrp|gpasswd|chage|pkexec|mount.nfs|fusermount|fusermount3|ping|staprun|Xorg.wrap|crontab|at|bsd-write|ssh-agent|expiry|wall|"
  # shellcheck disable=SC2086
  local out rc n p b odd="" odd_n=0 seen="|"
  # shellcheck disable=SC2086
  out="$(bh_run_to 2 find $BH_SEC_SCAN_DIRS -maxdepth 1 -xdev -type f \( -perm -4000 -o -perm -2000 \) -print)"
  rc=$?
  n="$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -eq 0 ] && [ -z "$out" ] && [ "$rc" -gt 1 ]; then
    sec_line info "SUID/SGID scan failed (find rc=$rc)"
    return 0                        # globals stay "n/a"
  fi
  BH_SEC_SUID_COUNT="$n"
  if [ "$n" -gt 0 ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      b="${p##*/}"
      case "$ok_names" in *"|$b|"*) continue ;; esac
      case "$seen" in *"|$b|"*) continue ;; esac
      seen="$seen$b|"
      [ "$odd_n" -lt 8 ] && odd="${odd:+$odd,}$b"
      odd_n=$((odd_n + 1))
    done < <(printf '%s\n' "$out")
  fi
  if [ "$odd_n" -eq 0 ]; then
    BH_SEC_SUID_ODD="none"
    sec_line ok "SUID/SGID: $n file(s), all standard"
  else
    BH_SEC_SUID_ODD="$odd"
    [ "$odd_n" -gt 8 ] && BH_SEC_SUID_ODD="$odd,…"
    sec_line warn "SUID/SGID: $n file(s), non-standard: $BH_SEC_SUID_ODD — review each one"
  fi
}

# ---- 11. core dumps (X3) ----
# suid_dumpable != 0 or a piped core_pattern mean the kernel may hand out
# memory images; WARN flags go INSIDE the value string so the report layer
# can re-read BH_SEC_CORE without re-running anything.
sec_hardening_coredump() {
  local d u p flagged=0
  d="$(cat /proc/sys/fs/suid_dumpable 2>/dev/null)"
  u="$(ulimit -c 2>/dev/null)"      # $( ) runs it in a subshell — our limit is untouched
  p="$(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
  if [ -z "$d" ] && [ -z "$u" ] && [ -z "$p" ]; then
    BH_SEC_CORE="n/a"
    sec_line info "core-dump settings: n/a (nothing readable)"
    return 0
  fi
  d="${d:-?}"; u="${u:-?}"; p="${p:-n/a}"
  p="${p:0:48}"
  BH_SEC_CORE="dumpable=$d ulimit=$u pattern=$p"
  case "$d" in ''|*[!0-9]*) : ;; 0) : ;; *)
    BH_SEC_CORE="$BH_SEC_CORE WARN:dumpable!=0"; flagged=1 ;; esac
  [ "${p#|}" != "$p" ] && { BH_SEC_CORE="$BH_SEC_CORE WARN:pattern-piped"; flagged=1; }
  if [ "$flagged" = "1" ]; then
    sec_line warn "core dumps: $BH_SEC_CORE — set fs.suid_dumpable=0 and a plain 'core' pattern"
  else
    sec_line ok "core dumps: $BH_SEC_CORE"
  fi
}

# ---- 12. fs.protected_* race sysctls (X4) ----
# "!" suffix marks protection OFF (value 0), "?" marks unreadable/absent;
# all four unreadable (unprivileged container) → whole value is "n/a".
sec_hardening_race_sysctls() {
  local h r f s bad=0
  h="$(cat /proc/sys/fs/protected_hardlinks 2>/dev/null)"
  r="$(cat /proc/sys/fs/protected_regular 2>/dev/null)"
  f="$(cat /proc/sys/fs/protected_fifos 2>/dev/null)"
  s="$(cat /proc/sys/fs/protected_symlinks 2>/dev/null)"
  if [ -z "$h$r$f$s" ]; then
    BH_SEC_PROTECTED_SYSCTL="n/a"
    sec_line info "fs.protected_* sysctls: n/a (unreadable — common in unprivileged containers)"
    return 0
  fi
  case "$h" in ''|*[!0-9]*) h="?" ;; esac
  case "$r" in ''|*[!0-9]*) r="?" ;; esac
  case "$f" in ''|*[!0-9]*) f="?" ;; esac
  case "$s" in ''|*[!0-9]*) s="?" ;; esac
  case "$h" in 0) h="0!"; bad=1 ;; esac
  case "$r" in 0) r="0!"; bad=1 ;; esac
  case "$f" in 0) f="0!"; bad=1 ;; esac
  case "$s" in 0) s="0!"; bad=1 ;; esac
  BH_SEC_PROTECTED_SYSCTL="hardlinks:$h regular:$r fifos:$f symlinks:$s"
  if [ "$bad" = "1" ]; then
    sec_line warn "fs.protected_*: $BH_SEC_PROTECTED_SYSCTL — '!' marks protection OFF (symlink/hardlink/TOCTOU races)"
  else
    sec_line ok "fs.protected_*: $BH_SEC_PROTECTED_SYSCTL"
  fi
}

# ---- 13. legacy network-daemon packages (X5) ----
# nis/rsh/telnet/talk/xinetd/tftp families — plaintext creds or dead
# protocols; present on a modern VPS only by accident.
sec_hardening_legacy_pkgs() {
  BH_SEC_LEGACY_PKGS="unknown"
  local list="" hits
  if command_exists dpkg-query; then
    list="$(bh_run_to 5 dpkg-query -W -f='${Package}\n')"
  elif command_exists rpm; then
    list="$(bh_run_to 5 rpm -qa --qf '%{NAME}\n')"
  else
    sec_line info "legacy daemons (nis/rsh/telnet/talk/xinetd/tftp): unknown (no dpkg/rpm)"
    return 0
  fi
  if [ -z "$list" ]; then
    sec_line info "legacy daemons: unknown (package list empty/unreadable)"
    return 0
  fi
  hits="$(printf '%s\n' "$list" | grep -E '^(nis|rsh-client|rsh-server|telnet|telnetd|talkd|xinetd|tftpd|tftp-server|yp-tools|rsh-redone-client)$' | sort -u | paste -sd ',' -)"
  if [ -z "$hits" ]; then
    BH_SEC_LEGACY_PKGS="none"
    sec_line ok "legacy network daemons (nis/rsh/telnet/talk/xinetd/tftp): none installed"
  else
    BH_SEC_LEGACY_PKGS="$hits"
    sec_line warn "legacy network daemons installed: $hits — remove unless truly needed"
  fi
}

# ---- 14. sudo/pkexec version age (X6 — INFO only, per R3: never a WARN) ----
# Unknown or unparseable output degrades to "unknown" in the globals; no
# verdict line is emitted then at all. Version age alone is not a finding.
sec_hardening_versions() {
  BH_SEC_SUDO_VER="unknown"
  BH_SEC_PKEXEC_VER="unknown"
  local v
  if command_exists sudo; then
    v="$(bh_run_to 5 sudo -V 2>/dev/null | head -n 1)"
    if [ -n "$v" ]; then
      BH_SEC_SUDO_VER="$v"
      sec_line info "sudo version: $BH_SEC_SUDO_VER (info only — CVE fixes are distro-backported, age is not a verdict)"
    fi
  fi
  if command_exists pkexec; then
    v="$(bh_run_to 5 pkexec --version 2>/dev/null | head -n 1)"
    if [ -n "$v" ]; then
      BH_SEC_PKEXEC_VER="$v"
      sec_line info "pkexec version: $BH_SEC_PKEXEC_VER (info only — PwnKit fixes are distro-backported)"
    fi
  fi
}

# ---- 15. configured umask (X7) ----
# First hit wins: /etc/login.defs UMASK, then umask lines in
# /etc/profile.d/*.sh, then /etc/profile. 000/002 are flagged permissive
# INSIDE the value string.
sec_hardening_umask() {
  BH_SEC_UMASK="unset→distro default"
  local v="" src="" line f n permissive=0
  line="$(grep -hE '^[[:space:]]*UMASK[[:space:]]' /etc/login.defs 2>/dev/null | head -n 1)"
  if [ -n "$line" ]; then
    v="$(printf '%s\n' "$line" | awk '{print $2}')"
    src="login.defs"
  else
    for f in /etc/profile.d/*.sh /etc/profile; do
      [ -f "$f" ] || continue
      line="$(grep -hE '^[[:space:]]*umask[[:space:]]+0?[0-7]{2,4}([[:space:]]|$)' "$f" 2>/dev/null | head -n 1)"
      if [ -n "$line" ]; then
        v="$(printf '%s\n' "$line" | awk '{print $2}')"
        src="$f"
        break
      fi
    done
  fi
  if [ -z "$src" ] || [ -z "$v" ]; then
    sec_line info "umask: not configured in login.defs/profile — distro default applies"
    return 0
  fi
  case "$v" in ''|*[!0-7]*)
    BH_SEC_UMASK="UMASK=$v ($src) unparseable"
    sec_line info "umask: $BH_SEC_UMASK"
    return 0 ;;
  esac
  n=$(( 8#$v ))
  case "$n" in 0|2) permissive=1 ;; esac
  if [ "$src" = "login.defs" ]; then
    BH_SEC_UMASK="UMASK=$v ($src)"
  else
    BH_SEC_UMASK="umask=$v ($src)"
  fi
  if [ "$permissive" = "1" ]; then
    BH_SEC_UMASK="$BH_SEC_UMASK WARN:permissive"
    sec_line warn "umask: $BH_SEC_UMASK — group/other-writable files by default; use 022 or stricter"
  else
    sec_line ok "umask: $BH_SEC_UMASK"
  fi
}

# ---- 16. forensics toolkit (X8) ----
# Pure command -v probes — no execution, instant. (Password aging was
# moved to 80-ssh; do NOT re-add PASS_MAX_DAYS here.)
sec_hardening_forensics() {
  local t found=""
  for t in rkhunter chkrootkit clamscan freshclam aide; do
    command_exists "$t" && found="${found:+$found,}$t"
  done
  if [ -z "$found" ]; then
    BH_SEC_FORENSICS="none"
    sec_line info "forensics toolkit: none installed (rkhunter/chkrootkit/clamav/aide — optional)"
  else
    BH_SEC_FORENSICS="$found"
    sec_line ok "forensics toolkit present: $found"
  fi
}

# sec_hardening — entry point called (guarded) at the end of sec_audit.
# Every verdict goes through sec_line; posture counting is automatic.
sec_hardening() {
  [ "${BH_NO_SEC:-0}" = "1" ] && return 0   # belt & braces (run_sec_audit gates too)
  sec_hardening_mac
  sec_hardening_updates
  sec_hardening_listeners
  sec_hardening_miners
  sec_hardening_docker
  sec_hardening_sysctl
  sec_hardening_tmp
  sec_hardening_cron
  # v4 additions (X1-X8) — passive, every one degrades to n/a
  sec_hardening_path_ww
  sec_hardening_suid
  sec_hardening_coredump
  sec_hardening_race_sysctls
  sec_hardening_legacy_pkgs
  sec_hardening_versions
  sec_hardening_umask
  sec_hardening_forensics
  return 0
}
