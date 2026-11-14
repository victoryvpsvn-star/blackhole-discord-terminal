# =====================================================================
# blackhole-vps-bench · 80-ssh.sh — SSH & local security audit (v2)
# Audits ONLY the local machine: sshd effective config (password auth,
# pubkey auth, root login), authorized_keys inventory, failed login
# attempts, firewall, fail2ban, UID-0 accounts, empty passwords,
# sudo NOPASSWD, ASLR, auto updates, listening ports.
# No root required — checks degrade gracefully and say so.
# =====================================================================
# shellcheck shell=bash

BH_SSH_FOUND=0; BH_SSH_T_OK=0; BH_SSH_T_OUT=""; BH_SSH_CFG_SRC=""
BH_SSH_PWDAUTH=""; BH_SSH_PUBKEY=""; BH_SSH_ROOTLOGIN=""
BH_SSH_PORTS=""; BH_SSH_MAXAUTH=""
BH_AK_TOTAL=0; BH_AK_TYPES=""; BH_AK_WEAK=0
BH_SSH_FAILS="n/a"; BH_SSH_FAILS_N=-1
BH_FW="unknown"; BH_F2B=0
BH_UID0=""; BH_EMPTY_PW="n/a"; BH_LOGIN_SHELLS=""
BH_SUDO_NOPASS="n/a"
BH_ASLR=""; BH_AUTO_UPD="n/a"
BH_LISTEN=""
BH_SEC_PASS=0; BH_SEC_WARN=0; BH_SEC_BAD=0
BH_SEC_POSTURE="n/a"
BH_SEC_LINES=()
BH_SSH_CFG_LINES=()

# sec_line STATUS TEXT — record one audit line (plain, badged) and count it.
# STATUS: ok | warn | bad | info (info is not counted in the posture score)
sec_line() {
  local st="$1" txt="$2" tag
  case "$st" in
    ok)   tag="[OK]";   BH_SEC_PASS=$((BH_SEC_PASS + 1)) ;;
    warn) tag="[WARN]"; BH_SEC_WARN=$((BH_SEC_WARN + 1)) ;;
    bad)  tag="[BAD]";  BH_SEC_BAD=$((BH_SEC_BAD + 1)) ;;
    *)    tag="[INFO]" ;;
  esac
  BH_SEC_LINES+=("  $tag  $txt")
}

sec_sshd_load() {
  if command_exists sshd; then
    BH_SSH_FOUND=1
    BH_SSH_T_OUT="$(sshd -T 2>/dev/null || true)"
    if [ -n "$BH_SSH_T_OUT" ]; then
      BH_SSH_T_OK=1
      BH_SSH_CFG_SRC="sshd -T (effective config)"
    fi
  fi
  if [ "$BH_SSH_FOUND" = "0" ] && [ -f /etc/ssh/sshd_config ]; then
    BH_SSH_FOUND=1
  fi
  if [ "$BH_SSH_T_OK" = "0" ]; then
    # OpenSSH uses FIRST-MATCH semantics; Include is normally the first
    # directive of sshd_config, so include-dir files win over the main file.
    local f line
    for f in /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config; do
      [ -f "$f" ] || continue
      while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        BH_SSH_CFG_LINES+=("$line")
      done < "$f"
    done
    BH_SSH_CFG_SRC="config files, first-match (drop-in dir wins)"
  fi
}

sec_sshd_opt() { # KEY DEFAULT — first match wins (mirrors sshd semantics)
  local key="$1" def="$2" out=""
  if [ "$BH_SSH_T_OK" = "1" ]; then
    out="$(printf '%s\n' "$BH_SSH_T_OUT" | awk -v k="$key" 'tolower($1)==tolower(k){ $1=""; sub(/^[ \t]+/, ""); print; exit }')"
  elif [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null; then
    # sshd -T already resolves everything; for raw config lines: strip inline
    # comments ("PermitRootLogin yes # ansible"), skip Match blocks (their
    # settings are not global), and lowercase the value — sec_audit compares
    # lowercase but real files often say "PasswordAuthentication YES".
    out="$(printf '%s\n' "${BH_SSH_CFG_LINES[@]}" | awk -v k="$key" '
      { sub(/#.*/, "") }
      tolower($1)=="match" { inmatch=1; next }
      inmatch { next }
      tolower($1)==tolower(k){ $1=""; sub(/^[ \t]+/, ""); print tolower($0); exit }')"
  fi
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$def"; fi
}

sec_sshd_all() { # KEY — every match joined by ',' (for multi-Port configs)
  local key="$1" out=""
  if [ "$BH_SSH_T_OK" = "1" ]; then
    out="$(printf '%s\n' "$BH_SSH_T_OUT" | awk -v k="$key" 'tolower($1)==tolower(k){print $2}')"
  elif [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null; then
    out="$(printf '%s\n' "${BH_SSH_CFG_LINES[@]}" | awk -v k="$key" '
      { sub(/#.*/, "") }
      tolower($1)=="match" { inmatch=1; next }
      inmatch { next }
      tolower($1)==tolower(k){print $2}')"
  fi
  printf '%s' "$out" | paste -sd ',' -
}

sec_auth_keys() {
  local d kf line kt homes="/root"
  for d in /home/*; do [ -d "$d" ] && homes="$homes $d"; done
  for d in $homes; do
    kf="$d/.ssh/authorized_keys"
    [ -f "$kf" ] || continue
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      BH_AK_TOTAL=$((BH_AK_TOTAL + 1))
      kt="${line%%[[:space:]]*}"
      case "$kt" in
        ssh-ed25519|sk-ssh-ed25519@openssh.com) kt="ed25519" ;;
        ssh-rsa)                                kt="RSA" ;;
        ecdsa-sha2-*)                           kt="ECDSA" ;;
        *)                                      kt="${kt%%@*}" ;;
      esac
      BH_AK_TYPES="$BH_AK_TYPES $kt"
    done < "$kf"
    if command_exists ssh-keygen; then
      while IFS= read -r bits; do
        [ -n "$bits" ] || continue
        if [ "$bits" -lt 2048 ] 2>/dev/null; then BH_AK_WEAK=$((BH_AK_WEAK + 1)); fi
      done < <(ssh-keygen -lf "$kf" 2>/dev/null | awk '{print $1}')
    fi
  done
  # BH_AK_TYPES accumulates as one space-separated line; split into one type
  # per line first or 'sort | uniq -c' counts the whole string as a single hit.
  BH_AK_TYPES="$(printf '%s\n' "$BH_AK_TYPES" | tr ' ' '\n' | sed '/^$/d' | sort | uniq -c | awk '{printf "%sx%d ", $2, $1}')"
  BH_AK_TYPES="${BH_AK_TYPES% }"
}

sec_failed_logins() {
  local n jerr="$BH_RUNDIR/journal.err"
  # journalctl exits 0 even when no journal files exist (stderr: "No journal
  # files were found.", stdout: "-- No entries --") — that must NOT be
  # reported as "0 failed logins", so bail to the auth.log fallback instead.
  if command_exists journalctl && journalctl -n 1 >/dev/null 2>&1; then
    n="$(journalctl -u ssh -u sshd --since '-24 hours' --no-pager 2>"$jerr" | grep -c 'Failed password' || true)"
    if [ -n "$n" ] && ! grep -qi 'no journal files' "$jerr" 2>/dev/null; then
      BH_SSH_FAILS_N="$n"
      BH_SSH_FAILS="$n in last 24h (journalctl)"
      return
    fi
  fi
  if [ -r /var/log/auth.log ]; then
    n="$(grep -hc 'Failed password' /var/log/auth.log 2>/dev/null)"
    case "$n" in
      ''|*[!0-9]*) # keep BH_SSH_FAILS_N numeric for the -ge comparisons below
        BH_SSH_FAILS_N=-1
        BH_SSH_FAILS="n/a (auth.log present but not parseable)"
        return
        ;;
    esac
    BH_SSH_FAILS_N="$n"
    BH_SSH_FAILS="$n in current auth.log"
    return
  fi
  BH_SSH_FAILS_N=-1
  BH_SSH_FAILS="n/a (no readable auth logs — run as root for the exact count)"
}

sec_firewall() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    BH_FW="ufw active"
  elif command_exists nft && nft list ruleset 2>/dev/null | grep -q "chain "; then
    BH_FW="nftables rules present"
  elif command_exists iptables && iptables -S 2>/dev/null | grep -qv "^-P"; then
    BH_FW="iptables rules present"
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    BH_FW="firewalld running"
  elif command_exists ufw; then
    BH_FW="ufw installed but INACTIVE"
  else
    BH_FW="no firewall detected"
  fi
}

sec_misc() {
  local uid0
  uid0="$(awk -F: '$3==0{printf "%s ", $1}' /etc/passwd 2>/dev/null)"
  BH_UID0="${uid0% }"
  BH_LOGIN_SHELLS="$(awk -F: '$7 ~ /(bash|zsh|ksh|sh)$/{n++} END{print n+0}' /etc/passwd 2>/dev/null)"
  if [ -r /etc/shadow ]; then
    BH_EMPTY_PW="$(awk -F: '$2==""{n++} END{print n+0}' /etc/shadow 2>/dev/null)"
  fi
  local nopass=0 sudoers_readable=0
  if [ -r /etc/sudoers ]; then
    sudoers_readable=1
    grep -qs 'NOPASSWD' /etc/sudoers && nopass=1
  fi
  if [ -d /etc/sudoers.d ]; then
    grep -qs 'NOPASSWD' /etc/sudoers.d/* 2>/dev/null && nopass=1
    if ls /etc/sudoers.d/* >/dev/null 2>&1; then sudoers_readable=1; fi
  fi
  if [ "$nopass" = "1" ]; then
    BH_SUDO_NOPASS="yes (NOPASSWD entries found)"
  elif [ "$sudoers_readable" = "1" ]; then
    BH_SUDO_NOPASS="no"
  fi
  BH_ASLR="$(cat /proc/sys/kernel/randomize_va_space 2>/dev/null)"
  if grep -qs 'Unattended-Upgrade' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
    BH_AUTO_UPD="enabled (unattended-upgrades)"
  elif [ -f /etc/dnf/automatic.conf ]; then
    BH_AUTO_UPD="dnf-automatic configured"
  elif command_exists dnf && [ -f /etc/dnf/dnf.conf ] && grep -qs 'automatic' /etc/dnf/dnf.conf; then
    BH_AUTO_UPD="dnf-automatic configured"
  else
    BH_AUTO_UPD="not detected"
  fi
  if command_exists ss; then
    BH_LISTEN="$(ss -tulnH 2>/dev/null | awk '$1=="tcp"||$1=="tcp6"{print $5}' | sed 's/.*://' | sort -n | uniq | paste -sd ',' - | head -c 200)"
    [ -n "$BH_LISTEN" ] || BH_LISTEN="none" # ss exists but zero listeners — don't claim "ss unavailable"
  fi
}

# run_sec_audit — gate used by main: honors --no-sec / BH_NO_SEC and sets
# BH_SEC_SKIPPED so the report can say why the audit is missing.
run_sec_audit() {
  if [ "${BH_NO_SEC:-0}" = "1" ]; then
    BH_SEC_SKIPPED=1
    log "SEC audit skipped (--no-sec)"
    return 0
  fi
  BH_SEC_SKIPPED=0
  sec_audit
}

sec_audit() {
  BH_SEC_PASS=0; BH_SEC_WARN=0; BH_SEC_BAD=0
  BH_SEC_LINES=()
  BH_SEC_POSTURE="n/a"

  log "SEC audit: sshd config, authorized_keys, firewall, local accounts..."
  sec_sshd_load

  # ---- SSH server configuration ----
  if [ "$BH_SSH_FOUND" = "1" ]; then
    BH_SSH_PORTS="$(sec_sshd_all port)"
    [ -n "$BH_SSH_PORTS" ] || BH_SSH_PORTS="22"
    BH_SSH_PWDAUTH="$(sec_sshd_opt passwordauthentication "")"
    BH_SSH_PUBKEY="$(sec_sshd_opt pubkeyauthentication "")"
    BH_SSH_ROOTLOGIN="$(sec_sshd_opt permitrootlogin "")"
    BH_SSH_MAXAUTH="$(sec_sshd_opt maxauthtries "")"

    case "$BH_SSH_PWDAUTH" in
      no)  sec_line ok   "PasswordAuthentication: no (key-only login)" ;;
      yes) sec_line warn "PasswordAuthentication: yes — brute-force surface; set 'PasswordAuthentication no'" ;;
      *)   sec_line warn "PasswordAuthentication: not set (OpenSSH default: yes)" ;;
    esac
    case "$BH_SSH_PUBKEY" in
      no)  sec_line warn "PubkeyAuthentication: no" ;;
      *)   sec_line ok   "PubkeyAuthentication: ${BH_SSH_PUBKEY:-yes (default)}" ;;
    esac
    case "$BH_SSH_ROOTLOGIN" in
      yes) sec_line bad  "PermitRootLogin: yes — direct root brute-force possible" ;;
      no)  sec_line ok   "PermitRootLogin: no" ;;
      *)   sec_line info "PermitRootLogin: ${BH_SSH_ROOTLOGIN:-prohibit-password (default)} — 'no' is safer with a sudo user" ;;
    esac
    sec_line info "SSH port(s): $BH_SSH_PORTS${BH_SSH_MAXAUTH:+ | MaxAuthTries: $BH_SSH_MAXAUTH} | source: $BH_SSH_CFG_SRC"
  else
    BH_SSH_PORTS=""
    sec_line info "sshd: not found on this machine (no SSH server installed)"
  fi

  # ---- authorized keys ----
  sec_auth_keys
  if [ "$BH_AK_TOTAL" -gt 0 ]; then
    local weaktxt=""
    [ "$BH_AK_WEAK" -gt 0 ] && weaktxt=" — $BH_AK_WEAK WEAK (<2048-bit)"
    sec_line ok "authorized_keys: $BH_AK_TOTAL key(s): ${BH_AK_TYPES:-unknown types}$weaktxt"
  else
    sec_line info "authorized_keys: none found (root + /home/*)"
  fi

  # ---- failed logins ----
  sec_failed_logins
  if [ "$BH_SSH_FAILS_N" -ge 50 ] 2>/dev/null; then
    sec_line warn "Failed SSH logins: $BH_SSH_FAILS — looks like active brute-force; consider fail2ban + key-only auth"
  elif [ "$BH_SSH_FAILS_N" -ge 1 ] 2>/dev/null; then
    sec_line info "Failed SSH logins: $BH_SSH_FAILS"
  else
    sec_line info "Failed SSH logins: $BH_SSH_FAILS"
  fi

  # ---- firewall / fail2ban ----
  sec_firewall
  case "$BH_FW" in
    *INACTIVE*|"no firewall detected") sec_line warn "Firewall: $BH_FW — enable ufw/nftables and only open needed ports" ;;
    *) sec_line ok "Firewall: $BH_FW" ;;
  esac
  if command_exists fail2ban-client; then
    BH_F2B=1
    sec_line ok "fail2ban: installed"
  else
    BH_F2B=0
    sec_line info "fail2ban: not installed (recommended when password auth is enabled)"
  fi

  # ---- local accounts / kernel / maintenance ----
  sec_misc
  if [ -n "$BH_UID0" ] && [ "$BH_UID0" != "root" ]; then
    sec_line bad "UID-0 accounts: $BH_UID0 — extra root-level accounts exist"
  else
    sec_line ok "UID-0 accounts: root only"
  fi
  case "$BH_EMPTY_PW" in
    n/a) sec_line info "Empty passwords: n/a (/etc/shadow not readable)" ;;
    0)   sec_line ok   "Empty passwords: none" ;;
    *)   sec_line bad  "Empty passwords: $BH_EMPTY_PW account(s) — CRITICAL" ;;
  esac
  sec_line info "Login-shell accounts: $BH_LOGIN_SHELLS"
  case "$BH_SUDO_NOPASS" in
    yes*) sec_line warn "sudo NOPASSWD: yes — passwordless root for some users" ;;
    no)   sec_line ok   "sudo NOPASSWD: no" ;;
    *)    sec_line info "sudo NOPASSWD: n/a (sudoers not readable)" ;;
  esac

  # ---- kernel / maintenance ----
  if [ "$BH_ASLR" = "2" ]; then
    sec_line ok "ASLR: full (randomize_va_space=2)"
  else
    sec_line info "ASLR: ${BH_ASLR:-n/a}"
  fi
  if [ "$BH_AUTO_UPD" = "not detected" ]; then
    sec_line info "Auto security updates: not detected"
  else
    sec_line ok "Auto security updates: $BH_AUTO_UPD"
  fi
  sec_line info "Listening TCP ports: ${BH_LISTEN:-n/a (ss unavailable)}"

  # ---- posture ----
  if [ "$BH_SEC_BAD" -gt 0 ]; then
    BH_SEC_POSTURE="WEAK"
  elif [ "$BH_SEC_WARN" -gt 2 ]; then
    BH_SEC_POSTURE="FAIR"
  else
    BH_SEC_POSTURE="GOOD"
  fi
  BH_SEC_LINES+=("  [POST]  Posture: $BH_SEC_POSTURE ($BH_SEC_PASS pass / $BH_SEC_WARN warn / $BH_SEC_BAD bad) — scope: this machine only")
}
