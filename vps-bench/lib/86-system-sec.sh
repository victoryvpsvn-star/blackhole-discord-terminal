# =====================================================================
# blackhole-vps-bench · 86-system-sec.sh — system security posture (v5, C09)
# Called (via a guarded `declare -F sec_system_sec`) from run_sec_audit
# (80-ssh.sh) alongside sec_hardening; standalone-sourceable like
# 85-hardening.sh (its sec_line fallback guard is replicated here).
# Checks (all passive, all read-only, all degrade to n/a):
#   1. PAM 2FA + login lockout (pam_google_authenticator/u2f/oath/duo,
#      pam_faillock/pam_tally2) — WARN only when PasswordAuthentication
#      is "yes" (BH_SSH_PWDAUTH, set by 80-ssh.sh) and no lockout exists.
#   2. EDR/monitoring census — INFO only, never a verdict: osquery, wazuh,
#      falco, suricata, ossec, elastic-agent, zabbix, crowdsec (from v4's
#      BH_CROWDSEC), plus the auditd rule count when auditd is running.
#   3. cron content triage — pipe-to-shell / base64-decode / /dev/tcp
#      one-liners in the readable cron trees (the \b guard keeps
#      "flush"/"shadow" style words from false-matching).
#   4. reboot-required — /var/run/reboot-required flag (+ package names),
#      running-vs-newest-installed kernel (exact sort -V compare of kernel
#      RELEASES, not package versions), needs-restarting -r on RHEL.
#   5. journald persistence — volatile logs with no syslog fallback mean a
#      forensic evidence gap after the next reboot.
#   6. auto-update timer truth — a configured-but-inactive timer means
#      patching is NOT actually happening (reuses v4's BH_AUTO_UPD).
# Offline contract: nothing here touches the network, ever. No root
# required — unreadable paths degrade gracefully and say so.
# Every external command is timeout-wrapped: bhv5c9_to reuses bh_run_to
# from 85-hardening.sh when present (plain timeout fallback otherwise).
# Verdicts go through sec_line EXACTLY like 85-hardening.sh, so the
# BH_SEC_WARN / BH_SEC_BAD counters (and the --fail-on exit gate) stay
# consistent. mawk-safe (no gawk-isms); POSIX-ish bash; no set -e; no
# sudo; English only, no emoji. BH_REDACT=1: cron paths under /var/spool
# (which carry the owning username) are never printed.
# =====================================================================
# shellcheck shell=bash

# ------- module globals (raw values; the report layer may read them) -------
BH_SYSSEC_PAM_2FA="n/a"        # wired | none | unknown
BH_SYSSEC_PAM_LOCKOUT="n/a"    # pam_faillock | pam_tally2 | none | unknown
BH_SYSSEC_EDR="n/a"            # census string (crowdsec, falco, auditd N rules, …)
BH_SYSSEC_AUDIT_RULES="n/a"    # auditd rule count ("n/a" = not counted)
BH_SYSSEC_CRON_SUSPECT=0       # cron files matching the pipe-to-shell patterns
BH_SYSSEC_REBOOT="unknown"     # "required (…)" | "kernel-pending" | "none" | "unknown"
BH_SYSSEC_JOURNAL="n/a"        # persistent | volatile | syslog | n/a
BH_SYSSEC_TIMER="n/a"          # "active: <timer>" | "inactive" | "none" | "n/a"

# Standalone-sourceable: the real sec_line lives in 80-ssh.sh. When this
# module is sourced on its own (tests, one-off debugging) provide a quiet
# fallback so nothing ever errors; 80-ssh.sh overrides it when loaded.
if ! command -v sec_line >/dev/null 2>&1; then
  sec_line() { return 0; }
fi
# Posture counters live in 80-ssh.sh; fill them ONLY when missing so a
# standalone source still reports sane numbers (never clobbers 80's values).
: "${BH_SEC_PASS:=0}"; : "${BH_SEC_WARN:=0}"; : "${BH_SEC_BAD:=0}"

# bhv5c9_to SECS CMD... — bh_run_to (85-hardening.sh) when available, else a
# plain `timeout` wrapper. Guarantees no external call here can hang.
bhv5c9_to() {
  local secs="$1"; shift
  if command -v bh_run_to >/dev/null 2>&1; then
    bh_run_to "$@"
    return $?
  fi
  if command_exists timeout; then
    timeout "$secs" "$@" 2>/dev/null </dev/null
  else
    "$@" 2>/dev/null </dev/null
  fi
}

# bhv5c9_redact_on — true when BH_REDACT=1 (reuses 12-cloud's bh_redact_on
# when loaded; same env contract, so behaviour is identical either way).
bhv5c9_redact_on() {
  if command -v bh_redact_on >/dev/null 2>&1; then
    bh_redact_on
    return $?
  fi
  [ "${BH_REDACT:-0}" = "1" ]
}

# bhv5c9_disp_path PATH — display form for cron-file paths. /var/spool/cron
# entries are NAMED AFTER their owning user, so with BH_REDACT=1 the username
# must never be printed: spool paths collapse to the fixed prefix; /etc/cron*
# names (system job names, not users) shrink to the basename.
bhv5c9_disp_path() {
  local p="$1"
  case "$p" in
    /var/spool/*)
      if bhv5c9_redact_on; then printf '%s' "/var/spool/cron/*"; else printf '%s' "$p"; fi
      return 0 ;;
  esac
  if bhv5c9_redact_on; then printf '%s' "${p##*/}"; else printf '%s' "$p"; fi
}

# ---- 1. PAM 2FA + login lockout -------------------------------------------
bhv5c9_pam_2fa() {
  local lockout=""
  # grep -s: silently skip the files that do not exist (distro layouts differ)
  if grep -qsE 'pam_google_authenticator|pam_u2f|pam_oath|pam_duo' \
       /etc/pam.d/sshd /etc/pam.d/common-auth /etc/pam.d/system-auth 2>/dev/null; then
    BH_SYSSEC_PAM_2FA="wired"
    sec_line ok "2FA module wired in PAM (google-authenticator/u2f/oath/duo)"
  else
    BH_SYSSEC_PAM_2FA="none"
    sec_line info "PAM 2FA: no TOTP/U2F/oath/duo module in sshd/common-auth/system-auth (second factor absent)"
  fi
  if grep -qsE 'pam_faillock' /etc/pam.d/sshd /etc/pam.d/common-auth /etc/pam.d/system-auth 2>/dev/null; then
    lockout="pam_faillock"
  elif grep -qsE 'pam_tally2' /etc/pam.d/sshd /etc/pam.d/common-auth /etc/pam.d/system-auth 2>/dev/null; then
    lockout="pam_tally2"
  fi
  case "$lockout" in
    pam_faillock|pam_tally2)
      BH_SYSSEC_PAM_LOCKOUT="$lockout"
      sec_line ok "login lockout: $lockout active in PAM (brute-force lockout)" ;;
    *)
      BH_SYSSEC_PAM_LOCKOUT="none"
      # WARN only when passwords can actually reach PAM (BH_SSH_PWDAUTH=yes,
      # set by 80-ssh.sh); unset/unknown degrades to a plain info line.
      case "${BH_SSH_PWDAUTH:-}" in
        yes) sec_line warn "no PAM lockout (pam_faillock/pam_tally2) while PasswordAuthentication: yes — enable faillock" ;;
        *)   sec_line info "login lockout: none in PAM (password auth off or unknown — low exposure)" ;;
      esac ;;
  esac
}

# ---- 2. EDR / monitoring census (INFO only — never a verdict) -------------
bhv5c9_edr_census() {
  local found="" a f cnt n=0 audit_running=0
  case "${BH_CROWDSEC:-x}" in
    1) found="crowdsec (from v4)" ;;
    # BH_CROWDSEC unset (standalone source): self-detect, quietly
    x) if [ -d /etc/crowdsec ] || command_exists cscli; then found="crowdsec"; fi ;;
  esac
  for a in osqueryd wazuh-agent falco suricata ossec-analysisd elastic-agent zabbix-agent2; do
    command_exists "$a" && { found="${found:+$found, }$a"; continue; }
    command_exists pgrep && pgrep -x "$a" >/dev/null 2>&1 && found="${found:+$found, }$a"
  done
  # auditd rule count — only meaningful when the daemon is actually running
  case "${BH_SEC_AUDITD:-}" in
    running) audit_running=1 ;;
    "")      command_exists pgrep && pgrep -x auditd >/dev/null 2>&1 && audit_running=1 ;;
  esac
  if [ "$audit_running" = "1" ]; then
    for f in /etc/audit/rules.d/*.rules /etc/audit/audit.rules; do
      if [ ! -f "$f" ] || [ ! -r "$f" ]; then continue; fi
      cnt="$(grep -cvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null)"
      case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
      n=$(( n + cnt ))
    done
    BH_SYSSEC_AUDIT_RULES="$n"
    found="${found:+$found, }auditd $n rules"
  fi
  if [ -n "$found" ]; then
    BH_SYSSEC_EDR="$found"
    sec_line info "edr/monitor census: $found (INFO only — no verdict)"
  else
    BH_SYSSEC_EDR="none"
    sec_line info "edr/monitor census: none detected (osquery/wazuh/falco/suricata/ossec/elastic-agent/zabbix — INFO only)"
  fi
}

# ---- 3. cron content triage ------------------------------------------------
# Looks for the classic persistence one-liners: curl|wget piped straight into
# a shell, base64 -d stagers, /dev/tcp reverse shells. The (ba)?sh\b guard
# keeps words like "flush" or "shadow" from matching. Readable files only —
# root-only spool crontabs can hide more (noted on the line).
bhv5c9_cron_triage() {
  BH_SYSSEC_CRON_SUSPECT=0
  local d any=0 f hits n=0 d1="" d2="" cnt=0 list=""
  for d in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /var/spool/cron; do
    [ -e "$d" ] && { any=1; break; }
  done
  if [ "$any" = "0" ]; then
    sec_line info "cron triage skipped (no cron dirs present)"
    return 0
  fi
  hits="$(bhv5c9_to 3 grep -RIlE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh\b|base64[[:space:]]+(-d|--decode)|/dev/tcp/' \
        /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /var/spool/cron)"
  n="$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  BH_SYSSEC_CRON_SUSPECT="$n"
  if [ "$n" -eq 0 ]; then
    sec_line ok "cron content: no pipe-to-shell / base64-decode / /dev/tcp patterns (readable files only)"
    return 0
  fi
  # up to 2 filenames, redact-safe (spool paths embed the owning username)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cnt=$((cnt + 1))
    if [ -z "$d1" ]; then d1="$(bhv5c9_disp_path "$f")"
    elif [ -z "$d2" ]; then d2="$(bhv5c9_disp_path "$f")"
    fi
    [ "$cnt" -ge 2 ] && break
  done <<< "$hits"
  list="$d1"
  [ -n "$d2" ] && list="$list $d2"
  sec_line warn "cron pipes to shell: $n file(s) — $list (readable files only; root-only spool entries may hide more)"
}

# ---- 4. reboot required -----------------------------------------------------
# Precedence: flag file > running-vs-installed kernel > needs-restarting.
# The kernel compare uses the RELEASE embedded in the package NAME (and an
# exact sort -V compare) — comparing package Versions would fire whenever a
# metapackage (linux-image-generic) had a newer packaging version than the
# running kernel, i.e. a false "reboot pending" on every apt run.
bhv5c9_reboot() {
  BH_SYSSEC_REBOOT="unknown"
  local pkgs="" line cnt=0 run="" newest="" rel="" ver="" rc=0
  if [ -f /var/run/reboot-required ]; then
    if [ -r /var/run/reboot-required.pkgs ]; then
      while IFS= read -r line && [ "$cnt" -lt 3 ]; do
        [ -n "$line" ] || continue
        pkgs="${pkgs:+$pkgs, }$line"
        cnt=$((cnt + 1))
      done < /var/run/reboot-required.pkgs
    fi
    BH_SYSSEC_REBOOT="required${pkgs:+ (packages: $pkgs)}"
    sec_line warn "reboot required (flag file /var/run/reboot-required present)${pkgs:+ — packages: $pkgs}"
    return 0
  fi
  run="$(bhv5c9_to 2 uname -r)"
  # sort -V feature test (busybox sort may lack it); without it we cannot
  # order versions confidently, so the compare is skipped entirely.
  if printf 'a\nb\n' | sort -V >/dev/null 2>&1; then
    if command_exists dpkg-query; then
      newest="$(bhv5c9_to 5 dpkg-query -W -f='${db:Status-Abbrev}${Package} ${Version}\n' 'linux-image*' \
                | grep '^ii' \
                | sed -e 's/^ii[[:space:]]*//' -e 's/^linux-image-unsigned-//' -e 's/^linux-image-//' \
                | awk '$1 ~ /^[0-9]/ { print }' | sort -V | tail -n 1)"
      rel="${newest%% *}"; ver="${newest#* }"
      [ "$ver" = "$rel" ] && ver=""       # single-field line → no version part
      case "$rel" in
        ''|*[!0-9A-Za-z._-]*) rel="" ;;   # defensive: junk line → skip
      esac
      case "$rel" in [0-9]*) : ;; *) rel="" ;; esac
      if [ -n "$rel" ] && [ -n "$run" ]; then
        if [ "$run" = "$rel" ]; then
          BH_SYSSEC_REBOOT="none"
          sec_line ok "running kernel $run is the newest installed (dpkg)"
          return 0
        fi
        if [ "$(printf '%s\n%s\n' "$run" "$rel" | sort -V | tail -n 1)" = "$rel" ]; then
          BH_SYSSEC_REBOOT="kernel-pending"
          sec_line warn "running kernel $run older than installed $rel${ver:+ (pkg $ver)} — reboot pending"
          return 0
        fi
        BH_SYSSEC_REBOOT="none"
        sec_line ok "running kernel $run is the newest installed (dpkg)"
        return 0
      fi
    elif command_exists rpm; then
      newest="$(bhv5c9_to 5 rpm -q kernel 2>/dev/null | sed 's/^kernel-//' | sort -V | tail -n 1)"
      case "$newest" in
        ''|*[!0-9A-Za-z._-]*) newest="" ;;
      esac
      if [ -n "$newest" ] && [ -n "$run" ]; then
        if [ "$run" = "$newest" ]; then
          BH_SYSSEC_REBOOT="none"
          sec_line ok "running kernel $run is the newest installed (rpm)"
          return 0
        fi
        if [ "$(printf '%s\n%s\n' "$run" "$newest" | sort -V | tail -n 1)" = "$newest" ]; then
          BH_SYSSEC_REBOOT="kernel-pending"
          sec_line warn "running kernel $run older than installed $newest — reboot pending"
          return 0
        fi
        BH_SYSSEC_REBOOT="none"
        sec_line ok "running kernel $run is the newest installed (rpm)"
        return 0
      fi
    fi
  fi
  # RHEL belt: needs-restarting -r exits 1 when a core update needs a reboot
  if command_exists needs-restarting; then
    bhv5c9_to 10 needs-restarting -r >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 1 ]; then
      BH_SYSSEC_REBOOT="required (needs-restarting)"
      sec_line warn "reboot required (needs-restarting -r reports core updates pending a reboot)"
      return 0
    fi
  fi
  BH_SYSSEC_REBOOT="unknown"
  sec_line info "reboot status unknown (no dpkg/rpm kernel data and no reboot-required flag)"
}

# ---- 5. journald persistence ------------------------------------------------
bhv5c9_journal() {
  BH_SYSSEC_JOURNAL="n/a"
  if [ ! -d /run/systemd/system ]; then
    sec_line info "journald persistence: n/a (no systemd)"
    return 0
  fi
  local st="" syslog=0
  # first Storage= line wins (journald.conf semantics); default is auto
  st="$(grep -hE '^[[:space:]]*Storage[[:space:]]*=' /etc/systemd/journald.conf 2>/dev/null \
        | head -n 1 | sed 's/^[^=]*=//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$st" in
    ""|auto)
      if [ -d /var/log/journal ]; then st="persistent"; else st="volatile"; fi ;;
  esac
  command_exists pgrep && \
    { pgrep -x rsyslogd >/dev/null 2>&1 || pgrep -x syslog-ng >/dev/null 2>&1; } && syslog=1
  case "$st" in
    persistent)
      BH_SYSSEC_JOURNAL="persistent"
      sec_line ok "journald: persistent on disk (/var/log/journal — logs survive reboot)" ;;
    volatile|none)
      BH_SYSSEC_JOURNAL="volatile"
      if [ "$syslog" = "1" ]; then
        sec_line ok "journald: volatile but logs forwarded to a syslog daemon (rsyslogd/syslog-ng running)"
      else
        sec_line warn "journald: volatile — logs lost on reboot (forensic evidence gap; mkdir /var/log/journal or set Storage=persistent)"
      fi ;;
    *)
      BH_SYSSEC_JOURNAL="$st"
      sec_line info "journald: Storage=$st (unrecognized journald.conf value)" ;;
  esac
}

# ---- 6. auto-update timer truth ---------------------------------------------
bhv5c9_timer() {
  BH_SYSSEC_TIMER="n/a"
  if [ ! -d /run/systemd/system ] || ! command_exists systemctl; then
    sec_line info "auto-update timer: n/a (no systemd)"
    return 0
  fi
  local t=""
  if bhv5c9_to 3 systemctl is-active apt-daily-upgrade.timer >/dev/null 2>&1; then
    t="apt-daily-upgrade.timer"
  elif bhv5c9_to 3 systemctl is-active dnf-automatic.timer >/dev/null 2>&1; then
    t="dnf-automatic.timer"
  fi
  if [ -n "$t" ]; then
    BH_SYSSEC_TIMER="active: $t"
    sec_line ok "auto-update timer active: $t (patching will actually run)"
    return 0
  fi
  # configured-but-inactive: reuse v4's BH_AUTO_UPD (set by sec_misc in 80)
  case "${BH_AUTO_UPD:-not detected}" in
    ""|"not detected"|"n/a")
      BH_SYSSEC_TIMER="none"
      sec_line info "auto-update timer: none active (auto-updates not configured — patch manually)" ;;
    *)
      BH_SYSSEC_TIMER="inactive"
      sec_line warn "auto-upgrade configured ($BH_AUTO_UPD) but timer inactive — updates are NOT being applied automatically" ;;
  esac
}

# sec_system_sec — entry point, called (guarded `declare -F`) from
# run_sec_audit in 80-ssh.sh. Every verdict goes through sec_line, so
# BH_SEC_WARN/BH_SEC_BAD and the posture/exit gates pick these up.
sec_system_sec() {
  [ "${BH_NO_SEC:-0}" = "1" ] && return 0   # belt & braces (run_sec_audit gates too)
  bhv5c9_pam_2fa
  bhv5c9_edr_census
  bhv5c9_cron_triage
  bhv5c9_reboot
  bhv5c9_journal
  bhv5c9_timer
  return 0
}
