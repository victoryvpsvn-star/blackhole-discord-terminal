# =====================================================================
# blackhole-vps-bench · 80-ssh.sh — SSH & local security audit (v4)
# Audits ONLY the local machine: sshd effective config (password auth,
# pubkey auth, root login, empty passwords, login grace, X11, keyboard-
# interactive, AllowUsers/AllowGroups), OpenSSH version, sshd runtime
# state, authorized_keys inventory + StrictModes permission audit, failed
# login attempts, firewall, brute-force protection (fail2ban / sshguard /
# crowdsec), UID-0 accounts, empty passwords, sudo NOPASSWD, ASLR, auto
# updates, listening ports.
# v4 additions (H1-H8): weak crypto algorithms in the effective
# Ciphers/MACs/KexAlgorithms (with correct OpenSSH Include semantics —
# first-match-wins, Include expands IN PLACE), MaxStartups/ClientAlive
# connection hygiene, non-default AuthorizedKeysFile paths added to the key
# inventory (%u/%h expanded), PAM password quality, password aging
# (login.defs + root chage), auditd state, time-sync status and pre-login
# banner OS-info leaks.
# No root required — checks degrade gracefully and say so.
# v5 additions (C10): sshd config syntax gate (sshd -t, root), daemon
# version, declared-vs-effective config diff (sshd -T cross-check),
# systemd socket-activation false-positive guard, authorized_keys deep scan
# (DSA keys, comment CLASS counts, >2y rotation age, RSA bit fallback),
# host key audit (type/size/mtime, 16-char fingerprints only), certificate
# auth posture, Match/SFTP block scan, forwarding sweep, port/topology
# cross-check, auth-log deep counts, MFA posture. Counts only — never key
# material, public keys, usernames or IPs in the lines (BH_REDACT-safe).
# =====================================================================
# shellcheck shell=bash

BH_SSH_FOUND=0; BH_SSH_T_OK=0; BH_SSH_T_OUT=""; BH_SSH_CFG_SRC=""
BH_SSH_PWDAUTH=""; BH_SSH_PUBKEY=""; BH_SSH_ROOTLOGIN=""
BH_SSH_PORTS=""; BH_SSH_MAXAUTH=""
BH_SSH_PERMPTY=""; BH_SSH_LOGINGRACE=""; BH_SSH_X11=""; BH_SSH_KBDINT=""
BH_SSH_ALLOWUSERS=""; BH_SSH_VERSION=""
BH_SSH_RUNNING=0; BH_SSH_LISTENING=""; BH_SSHD_BIN=""
BH_AK_TOTAL=0; BH_AK_TYPES=""; BH_AK_WEAK=0; BH_AK_PERM_BAD=0
BH_SSH_FAILS="n/a"; BH_SSH_FAILS_N=-1
BH_FW="unknown"; BH_F2B=0; BH_F2B_ACTIVE=0; BH_SSHGUARD=0; BH_CROWDSEC=0
BH_UID0=""; BH_EMPTY_PW="n/a"; BH_LOGIN_SHELLS=""
BH_SUDO_NOPASS="n/a"
BH_ASLR=""; BH_AUTO_UPD="n/a"
BH_LISTEN=""
BH_SEC_PASS=0; BH_SEC_WARN=0; BH_SEC_BAD=0
BH_SEC_POSTURE="n/a"
BH_SEC_LINES=()
BH_SSH_CFG_LINES=()
# --- v4 deep-scan additions (H1-H8) ---------------------------------------
BH_SEC_WEAK_CRYPTO=""    # weak tokens found in effective Ciphers/MACs/Kex
                         # ("" = none found / distro defaults)
BH_SEC_CIPHERS=""        # effective Ciphers, first 60 chars (INFO)
BH_SEC_KEX=""            # effective KexAlgorithms, first 60 chars (INFO)
BH_SEC_MAXSTARTUPS=""    # MaxStartups effective, or "10:30:100 default"
BH_SEC_ALIVE=""          # ClientAliveInterval/CountMax or "disabled (default)"
BH_SEC_AUTHKEYS_PATH=""  # effective AuthorizedKeysFile (or default); feeds key inventory
BH_SEC_PAM_PW=""         # pwquality (minlen N) | pwquality | cracklib | passwdqc | none | unknown
BH_SEC_PASS_MAX_DAYS=""  # login.defs PASS_MAX_DAYS ("no expiry" for 99999)
BH_SEC_ROOT_EXPIRE=""    # root password expiry: never | YYYY-MM-DD | "" (unknown)
BH_SEC_AUDITD="unknown"  # running | installed-not-running | not-installed | unknown
BH_SEC_NTP="unknown"     # synced (chronyd) | synced (timesyncd) | not-synced | unknown
BH_SEC_BANNER=""         # leaks OS info (...) | custom | none | "" (no sshd)
# --- v5.0 deep-scan additions (C10; raw values, the report layer may read) ---
BH_SSHD_CFG_VALID=""     # ok | invalid | skipped (non-root) | n/a (no binary)
BH_SSHD_VER=""           # daemon OpenSSH_x.y from sshd -V/-h ("" = unknown)
BH_SSH_EFF_DECL="n/a"    # declared=effective | overrides:N | n/a
BH_SSH_SOCKET_FP=0       # 1 = sshd answers via systemd socket-activation
BH_AK_WEAK=0             # (v4) weak authorized_keys (<2048-bit / DSA)
BH_AK_DSA=0              # DSA keys found in authorized_keys
BH_AK_STALE=0            # authorized_keys files older than 730 days
BH_AK_RSA_FB=0           # RSA keys bit-counted via the od/awk fallback
BH_AK_DEEP_KEYS=0        # key lines classified by the deep scan
BH_AK_CMT_EMAIL=0        # key comments that look like an email (count only)
BH_AK_CMT_HOST=0         # key comments that look like a host (count only)
BH_AK_CMT_NONE=0         # key comments absent (count only)
BH_AK_CMT_OTHER=0        # key comments in no known class (count only)
BH_HOSTKEY_AUDIT=""      # "keys:N dsa:M rsa_lt2048:K rsa_2048:J"
BH_SSH_CA="none"         # none | ca | command | ca+command
BH_SSH_MATCH_SFTP=""     # "N block(s)" when sftp-only chroot Match blocks found
BH_SSH_FWD=""            # forwarding sweep summary (tcp/agent/tunnel/gw/pen)
BH_SSH_TOPO=""           # ports/listen/masters/unconf/bind summary
BH_AUTH_LOG_SUM=""       # "fail:N invalid-users:M pw-accepted:K"
BH_AUTH_PW_LOGIN=0       # 'Accepted password' hits in the auth logs
BH_AUTH_INVALID_USERS=0  # distinct 'Invalid user' names (count only)
BH_LASTB_N=0             # lastb entries in /var/log/btmp (capped at 20)
BH_F2B_BANNED=-1         # fail2ban sshd jail currently-banned count (-1 unknown)
BH_SSH_MFA=""            # enforced | methods-only | usepam-no | none

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

# ---------------------------------------------------------------------------
# sec_sshd_read FILE DEPTH — append FILE's directives to BH_SSH_CFG_LINES,
# expanding Include directives IN PLACE (recursive; depth-capped; unreadable
# files are skipped silently — "Permission denied" degrades to nothing).
#
# SEMANTICS NOTE — OpenSSH Include, first-match-wins (fixes bug G5):
# sshd implements "first obtained value wins", and Include expands exactly
# where it appears in the read stream. Given a two-line /etc/ssh/sshd_config:
#
#     Port 2222
#     Include /etc/ssh/sshd_config.d/*.conf   (drop-in contains: Port 22)
#
# the effective Port is 2222 — a directive set BEFORE an Include line stays
# authoritative over the included files. A directive that exists ONLY in a
# drop-in still wins over a later (or absent) main-file directive, because
# the drop-in's line enters the stream first. The old parser read the
# drop-in dir ahead of the main file unconditionally, which wrongly let
# drop-ins beat earlier main-file settings. The common distro layout (Include
# as the very first line of sshd_config) behaves exactly as it did before.
# ---------------------------------------------------------------------------
sec_sshd_read() {
  local f="$1" depth="${2:-0}" line key rest tok g
  [ "$depth" -le 8 ] 2>/dev/null || return 0    # Include-cycle guard
  [ -r "$f" ] || return 0                       # unreadable -> graceful skip
  # shellcheck disable=SC2094  # config file is read-only here (recursion guarded)
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"     # trim leading whitespace
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%[[:space:]]*}"
    rest="${line#"$key"}"
    case "$key" in
      [Ii][Nn][Cc][Ll][Uu][Dd][Ee])
        # sshd: relative Include paths resolve against /etc/ssh; several
        # whitespace-separated globs may be given; globs matching nothing are
        # silently ignored (bash leaves the literal, the -f test rejects it).
        for tok in $rest; do
          case "$tok" in \"*\") tok="${tok#\"}"; tok="${tok%\"}" ;; esac
          case "$tok" in
            /*) : ;;
            *)  tok="/etc/ssh/$tok" ;;
          esac
          for g in $tok; do
            # shellcheck disable=SC2094  # read-only recursion; $g != $f guarded
            if [ -f "$g" ] && [ "$g" != "$f" ]; then
              sec_sshd_read "$g" $((depth + 1))
            fi
          done
        done
        ;;
      *)
        BH_SSH_CFG_LINES+=("$line")
        ;;
    esac
  done < "$f"
}

sec_sshd_load() {
  # sshd usually lives OUTSIDE a normal user's PATH (/usr/sbin) — probe the
  # usual sbin homes first, then whatever 'command -v sshd' can find.
  local b g
  for b in /usr/sbin/sshd /usr/local/sbin/sshd; do
    [ -x "$b" ] && { BH_SSHD_BIN="$b"; break; }
  done
  if [ -z "$BH_SSHD_BIN" ] && command_exists sshd; then
    BH_SSHD_BIN="$(command -v sshd)"
  fi
  if [ -n "$BH_SSHD_BIN" ]; then
    BH_SSH_FOUND=1
    # 'sshd -T' loads the 0600 root-owned host keys, so as non-root it always
    # fails — only run it when we are root; capture stderr quietly either way.
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
      BH_SSH_T_OUT="$($BH_SSHD_BIN -T 2>/dev/null || true)"
      if [ -n "$BH_SSH_T_OUT" ]; then
        BH_SSH_T_OK=1
        BH_SSH_CFG_SRC="sshd -T (effective config)"
      fi
    fi
  fi
  # no binary but a config file? still audit the raw config below
  if [ "$BH_SSH_FOUND" = "0" ] && [ -f /etc/ssh/sshd_config ]; then
    BH_SSH_FOUND=1
  fi
  if [ "$BH_SSH_T_OK" = "0" ]; then
    # Build the logical directive stream with real OpenSSH Include semantics:
    # read the main config top-to-bottom and expand Include IN PLACE, so
    # first-match-wins holds across the expanded stream (see sec_sshd_read).
    BH_SSH_CFG_LINES=()
    [ -r /etc/ssh/sshd_config ] && sec_sshd_read /etc/ssh/sshd_config 0
    # main config missing/unreadable but drop-in fragments exist? audit those
    # too (sshd itself would ignore them, but auditing beats staying blind)
    if [ ! -r /etc/ssh/sshd_config ] && [ -d /etc/ssh/sshd_config.d ]; then
      for g in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$g" ] && sec_sshd_read "$g" 0
      done
    fi
    if [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null; then
      BH_SSH_CFG_SRC="config files, first-match (Include expanded in place)"
    else
      BH_SSH_CFG_SRC="config files (none readable)"
    fi
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

# sec_trunc VALUE — first 60 chars of a (long) algorithm list, "..." when cut
sec_trunc() {
  local v="$1"
  [ -n "$v" ] || return 0
  if [ "${#v}" -gt 60 ]; then printf '%s...' "${v:0:57}"; else printf '%s' "$v"; fi
}

# sec_weak_tokens ALG_LIST — print the weak tokens found in a comma-separated
# Ciphers/MACs/KexAlgorithms list (lowercased first; both sshd -T and raw
# config use ',' as the separator). Weak families (H1): arcfour*, all *-cbc
# ciphers, hmac-md5*/hmac-sha1* MACs, and the SHA-1 DH kex family plus the
# legacy ssh-rsa/rsa-sha1 kex names. NOTE: group1 is matched as the exact
# 'diffie-hellman-group1-sha1' name — a glob 'group1*' would also swallow
# the MODERN diffie-hellman-group14-sha256, which must stay green.
sec_weak_tokens() {
  local v out="" tok
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ -n "$v" ] || return 0
  local IFS=,
  for tok in $v; do
    case "$tok" in
      arcfour*|*-cbc*|hmac-md5*|hmac-sha1*|diffie-hellman-group1-sha1|diffie-hellman-group14-sha1*|diffie-hellman-group-exchange-sha1*|ssh-rsa|rsa-sha1*)
        out="${out:+$out,}$tok"
        ;;
    esac
  done
  printf '%s' "$out"
}

# sec_perm_go_writable PATH — exit 0 when group OR other holds the WRITE bit.
# StrictModes refuses authentication when authorized_keys, ~/.ssh or the home
# directory are group/world-WRITABLE (read bits don't matter to sshd). The
# octal write bit is 2, so digits 2/3/6/7 all mean "writable".
sec_perm_go_writable() {
  local m
  m="$(stat -c %a "$1" 2>/dev/null)" || return 1
  case "$m" in ''|*[!0-7]*) return 1 ;; esac
  while [ "${#m}" -lt 3 ]; do m="0$m"; done    # normalize "44" -> "044"
  while [ "${#m}" -gt 2 ]; do m="${m#?}"; done # keep the group+other digits
  case "$m" in
    [2367]?|?[2367]) return 0 ;;
    *)               return 1 ;;
  esac
}

# sec_grace_secs VALUE — normalize a LoginGraceTime value to plain seconds.
# 'sshd -T' always reports seconds, but raw config files may say "2m"/"1h";
# anything unparseable is passed through unchanged.
sec_grace_secs() {
  local v="$1" n="" u=""
  [ -n "$v" ] || return 0
  case "$v" in
    [0-9]*) n="${v%%[!0-9]*}"; u="${v#"$n"}" ;;
    *)      printf '%s' "$v"; return 0 ;;
  esac
  case "$u" in
    ''|s|S) printf '%s' "$n" ;;
    m|M)    printf '%s' $(( n * 60 )) ;;
    h|H)    printf '%s' $(( n * 3600 )) ;;
    *)      printf '%s' "$v" ;;
  esac
}

sec_auth_keys() {
  local d kf line kt homes="/root" owner ak_bad tok path seen=""
  for d in /home/*; do [ -d "$d" ] && homes="$homes $d"; done
  for d in $homes; do
    owner="$(stat -c %U "$d" 2>/dev/null)"
    [ -n "$owner" ] || owner="${d##*/}"
    # scan every AuthorizedKeysFile path (H3): the default .ssh/authorized_keys
    # plus any non-default path from the effective config, with sshd's
    # %u (username) / %h (home directory) tokens expanded per user.
    for tok in ${BH_SEC_AUTHKEYS_PATH:-".ssh/authorized_keys"}; do
      path="$tok"
      case "$path" in *%h*) path="${path//%h/$d}" ;; esac
      case "$path" in *%u*) path="${path//%u/$owner}" ;; esac
      case "$path" in
        /*) : ;;                    # absolute (e.g. /etc/ssh/keys/%u)
        *)  path="$d/$path" ;;      # relative -> per-user, under the home
      esac
      case ",$seen," in *",${path},"*) continue ;; esac  # dedup (absolute paths repeat per user)
      seen="$seen,$path"
      kf="$path"
      [ -f "$kf" ] || continue
      # --- StrictModes permission audit: sshd REFUSES auth when the key file,
      #     ~/.ssh or the home directory are group/world-writable.
      #     Count every finding, but emit at most one warn line per file.
      ak_bad=""
      if sec_perm_go_writable "$kf"; then
        BH_AK_PERM_BAD=$((BH_AK_PERM_BAD + 1))
        ak_bad="authorized_keys of $owner is group/world-writable (StrictModes will REFUSE it)"
      elif [ "${path#"$d/.ssh"}" != "$path" ] && sec_perm_go_writable "$d/.ssh"; then
        BH_AK_PERM_BAD=$((BH_AK_PERM_BAD + 1))
        ak_bad=".ssh directory of $owner is group/world-writable (StrictModes will REFUSE its authorized_keys)"
      elif sec_perm_go_writable "$d"; then
        BH_AK_PERM_BAD=$((BH_AK_PERM_BAD + 1))
        ak_bad="home directory of $owner is group/world-writable (StrictModes will REFUSE its authorized_keys)"
      fi
      [ -n "$ak_bad" ] && sec_line warn "$ak_bad"
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

# sec_sshd_runtime — is the sshd daemon alive, and which ports does it bind?
sec_sshd_runtime() {
  BH_SSH_RUNNING=0
  BH_SSH_LISTENING=""
  if command_exists pgrep; then
    # match the classic standalone daemon or a daemonized master ('-D';
    # OpenSSH 9.8+ splits sessions into sshd-session child processes)
    if pgrep -x sshd >/dev/null 2>&1 || pgrep -f "sshd.*-D" >/dev/null 2>&1; then
      BH_SSH_RUNNING=1
    fi
  fi
  if command_exists ss; then
    local ssout p ports=""
    ssout="$(ss -tlnpH 2>/dev/null || true)"
    ports="$(printf '%s\n' "$ssout" | grep -i sshd | awk '{print $4}' | sed 's/.*://' | sort -n | uniq | paste -sd ',' -)"
    if [ -z "$ports" ] && [ -n "$BH_SSH_PORTS" ]; then
      # without root, ss hides the process column — fall back to matching the
      # configured port(s) against every listening socket instead
      for p in $(printf '%s\n' "$ssout" | awk '{print $4}' | sed 's/.*://' | sort -n | uniq); do
        case ",$BH_SSH_PORTS," in *",${p},"*) ports="${ports:+$ports,}$p" ;; esac
      done
    fi
    BH_SSH_LISTENING="$ports"
  fi
}

# sec_to SECS CMD ARGS... — run a local (no-network) command under `timeout`
# when available, stderr silenced. Used for every potentially slow probe
# below; callers treat a non-zero rc / empty output as "unknown".
sec_to() {
  local s="$1"
  shift
  if command_exists timeout; then
    timeout "$s" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# sec_banner (H8) — pre-login banner leak check. Sources, in order of
# authority: the effective 'Banner' directive, then /etc/issue.net, then
# /etc/motd (first line each). A line "leaks" when it names the distro or
# the kernel — exactly what a pre-auth probe wants for fingerprinting.
sec_banner() {
  BH_SEC_BANNER=""
  local b first
  local leak_re='debian|ubuntu|centos|rocky|alma|fedora|kernel|linux release'
  b="$(sec_sshd_opt banner "")"
  case "$b" in none|no) b="" ;; esac
  if [ -n "$b" ]; then
    first="$(head -n 1 "$b" 2>/dev/null)"
    first="${first:0:80}"
    if [ -n "$first" ]; then
      if printf '%s\n' "$first" | grep -qiE "$leak_re"; then
        BH_SEC_BANNER="leaks OS info (Banner $b: '$first')"
      else
        BH_SEC_BANNER="custom"
      fi
      return
    fi
    BH_SEC_BANNER="none"    # Banner set but the file is empty/unreadable
    return
  fi
  first="$(head -n 1 /etc/issue.net 2>/dev/null)"
  first="${first:0:80}"
  if [ -n "$first" ] && printf '%s\n' "$first" | grep -qiE "$leak_re"; then
    BH_SEC_BANNER="leaks OS info (/etc/issue.net: '$first')"
    return
  fi
  first="$(head -n 1 /etc/motd 2>/dev/null)"
  first="${first:0:80}"
  if [ -n "$first" ] && printf '%s\n' "$first" | grep -qiE "$leak_re"; then
    BH_SEC_BANNER="leaks OS info (/etc/motd: '$first')"
    return
  fi
  BH_SEC_BANNER="none"
}

# sec_pam_pw (H4) — which password-quality module does the PAM password
# stage use? Checked files: common-password (Debian) and system-auth /
# password-auth (RHEL-style). minlen comes from /etc/security/pwquality.conf.
# Result: "pwquality (minlen N)" | "pwquality" | "cracklib" | "passwdqc" |
# "none" | "unknown" (no readable PAM password config at all).
sec_pam_pw() {
  BH_SEC_PAM_PW=""
  local f all="" n=0 minlen
  for f in /etc/pam.d/common-password /etc/pam.d/system-auth /etc/pam.d/password-auth; do
    [ -r "$f" ] || continue
    n=$((n + 1))
    grep -qs 'pam_pwquality\.so' "$f" && all="$all pwquality"
    grep -qs 'pam_cracklib\.so' "$f" && all="$all cracklib"
    grep -qs 'pam_passwdqc\.so' "$f" && all="$all passwdqc"
  done
  case "$all" in
    *pwquality*)
      minlen="$(sed -n 's/^[[:space:]]*minlen[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' /etc/security/pwquality.conf 2>/dev/null | head -n 1)"
      if [ -n "$minlen" ]; then BH_SEC_PAM_PW="pwquality (minlen $minlen)"; else BH_SEC_PAM_PW="pwquality"; fi
      ;;
    *cracklib*) BH_SEC_PAM_PW="cracklib" ;;
    *passwdqc*) BH_SEC_PAM_PW="passwdqc" ;;
  esac
  if [ -z "$BH_SEC_PAM_PW" ]; then
    if [ "$n" -gt 0 ]; then BH_SEC_PAM_PW="none"; else BH_SEC_PAM_PW="unknown"; fi
  fi
}

# sec_aging (H5) — password aging: PASS_MAX_DAYS from /etc/login.defs, plus
# the root account's password expiry via `chage -l root` — run directly when
# root, else through passwordless `sudo -n` when that works.
sec_aging() {
  BH_SEC_PASS_MAX_DAYS=""
  BH_SEC_ROOT_EXPIRE=""
  local v out
  v="$(awk '$1=="PASS_MAX_DAYS" && $2 ~ /^[0-9]+$/ {print $2; exit}' /etc/login.defs 2>/dev/null)"
  case "$v" in
    '')    : ;;
    99999) BH_SEC_PASS_MAX_DAYS="no expiry" ;;
    *)     BH_SEC_PASS_MAX_DAYS="$v" ;;
  esac
  if command_exists chage &&
     { [ "$(id -u 2>/dev/null)" = "0" ] || { command_exists sudo && sudo -n true >/dev/null 2>&1; }; }; then
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
      out="$(sec_to 3 chage -l root | sed -n 's/^[[:space:]]*Password expires[[:space:]]*:[[:space:]]*//p' | head -n 1)"
    else
      out="$(sec_to 3 sudo -n chage -l root | sed -n 's/^[[:space:]]*Password expires[[:space:]]*:[[:space:]]*//p' | head -n 1)"
    fi
    case "$out" in
      never) BH_SEC_ROOT_EXPIRE="never" ;;
      '')    : ;;
      *)     BH_SEC_ROOT_EXPIRE="$(sec_to 2 date -d "$out" +%Y-%m-%d)"
             [ -n "$BH_SEC_ROOT_EXPIRE" ] || BH_SEC_ROOT_EXPIRE="$out" ;;
    esac
  fi
}

# sec_auditd (H6) — is the kernel audit daemon installed / running?
sec_auditd() {
  BH_SEC_AUDITD="unknown"
  if command_exists auditd || [ -x /usr/sbin/auditd ] || [ -x /sbin/auditd ] || [ -x /usr/local/sbin/auditd ]; then
    if { command_exists pgrep && pgrep -x auditd >/dev/null 2>&1; } || \
       sec_to 2 systemctl is-active auditd >/dev/null 2>&1; then
      BH_SEC_AUDITD="running"
    else
      BH_SEC_AUDITD="installed-not-running"
    fi
  else
    BH_SEC_AUDITD="not-installed"
  fi
}

# sec_ntp (H7) — clock synchronisation status. Primary: timedatectl's
# NTPSynchronized property (2s timeout). Fallbacks: chronyc tracking rc,
# the systemd-timesyncd "synchronized" marker, then chrony/timesyncd
# presence (installed but not tracking -> "not-synced").
sec_ntp() {
  BH_SEC_NTP="unknown"
  local v=""
  if command_exists timedatectl; then
    v="$(sec_to 2 timedatectl show -p NTPSynchronized --value)"
  fi
  case "$v" in
    yes)
      if sec_to 2 chronyc tracking >/dev/null 2>&1; then
        BH_SEC_NTP="synced (chronyd)"
      elif { command_exists pgrep && pgrep -x chronyd >/dev/null 2>&1; } || \
           [ -f /etc/chrony.conf ] || [ -f /etc/chrony/chrony.conf ]; then
        BH_SEC_NTP="synced (chronyd)"
      else
        BH_SEC_NTP="synced (timesyncd)"
      fi
      ;;
    no)
      BH_SEC_NTP="not-synced"
      ;;
    *)
      # timedatectl unusable (systemd absent / property unsupported)
      if [ -f /run/systemd/timesync/synchronized ]; then
        BH_SEC_NTP="synced (timesyncd)"
      elif sec_to 2 chronyc tracking >/dev/null 2>&1; then
        BH_SEC_NTP="synced (chronyd)"
      elif sec_to 2 systemctl is-active systemd-timesyncd >/dev/null 2>&1; then
        BH_SEC_NTP="synced (timesyncd)"
      elif { command_exists pgrep && pgrep -x chronyd >/dev/null 2>&1; } || \
           [ -f /etc/chrony.conf ] || [ -f /etc/chrony/chrony.conf ]; then
        BH_SEC_NTP="not-synced"   # chrony installed but tracking failed
      else
        BH_SEC_NTP="unknown"
      fi
      ;;
  esac
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

# =====================================================================
# v5.0 deep-scan additions (C10) — helpers + checks called from sec_audit.
# All checks are passive local reads, timeout-wrapped, degrade to silence,
# and print through sec_line so the posture counters stay correct.
# =====================================================================

# bhv5c10_to_err SECS CMD... — timeout wrapper that KEEPS stderr (sshd -t/-V
# report there); stdin is closed so nothing can block on a tty.
bhv5c10_to_err() {
  local s="$1"; shift
  if command_exists timeout; then
    timeout "$s" "$@" 2>&1 </dev/null
  else
    "$@" 2>&1 </dev/null
  fi
}

# bhv5c10_sanitize TEXT — one short single-line printable message safe for
# report sinks: control bytes and tabs flattened, capped at 140 chars. With
# BH_REDACT=1 home-directory paths (which embed usernames) are masked too.
bhv5c10_sanitize() {
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\015\016-\037' | tr '\011' ' ')"
  if [ "${BH_REDACT:-0}" = "1" ]; then
    s="$(printf '%s' "$s" | sed 's#/home/[^/[:space:]]*#/home/<redacted>#g')"
  fi
  printf '%s' "${s:0:140}"
}

# bhv5c10_norm VALUE — lowercase, strip quotes, normalize root-login synonyms
# so both sides of the declared/effective diff compare equal ("without-password"
# is a legacy synonym sshd -T always prints as "prohibit-password").
bhv5c10_norm() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '"')"
  case "$v" in without-password) v="prohibit-password" ;; esac
  printf '%s' "$v"
}

# bhv5c10_decl KEY — first match of KEY in the raw declared stream (Match
# blocks skipped, inline comments stripped, value lowercased); mirrors the
# raw-config branch of sec_sshd_opt.
bhv5c10_decl() {
  [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null || return 0
  printf '%s\n' "${BH_SSH_CFG_LINES[@]}" | awk -v k="$1" '
    { sub(/#.*/, "") }
    tolower($1)=="match" { inmatch=1; next }
    inmatch { next }
    tolower($1)==tolower(k){ $1=""; sub(/^[ \t]+/, ""); print tolower($0); exit }'
}

# bhv5c10_decl_ports — every Port value in the raw declared stream (Port is
# cumulative in sshd, unlike the single-value directives).
bhv5c10_decl_ports() {
  [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null || return 0
  printf '%s\n' "${BH_SSH_CFG_LINES[@]}" | awk '
    { sub(/#.*/, "") }
    tolower($1)=="match" { inmatch=1; next }
    inmatch { next }
    tolower($1)=="port" { print tolower($2) }'
}

# bhv5c10_rsa_bits BLOB — RSA modulus bit count via base64+od+awk (SSH wire
# format: 4-byte BE len(type) + type + 4-byte BE len(mpint) + mpint; the
# leading zero bits of the first modulus byte are subtracted — a sign-marker
# 0x00 byte counts as exactly 8). Prints nothing when the blob is unusable.
# Fallback only for systems without ssh-keygen; never prints key material.
bhv5c10_rsa_bits() {
  local dec
  dec="$(printf '%s' "$1" | base64 -d 2>/dev/null | od -An -v -tu1 | tr -s ' \n' ' ')"
  [ -n "$dec" ] || return 0
  printf '%s\n' "$dec" | awk '
    { for (i = 1; i <= NF; i++) b[i] = $i }
    END {
      if (NF < 16) exit
      n1 = b[1]*16777216 + b[2]*65536 + b[3]*256 + b[4]
      if (n1 < 1 || n1 > 100) exit
      p = 4 + n1
      if (NF < p + 5) exit
      n2 = b[p+1]*16777216 + b[p+2]*65536 + b[p+3]*256 + b[p+4]
      if (n2 < 1 || n2 > 1024) exit
      lz = 0
      for (i = 7; i >= 0; i--) { if (int(b[p+5] / (2 ^ i)) % 2 == 1) break; lz++ }
      print n2 * 8 - lz
    }'
}

# (C1) sshd config syntax gate — `sshd -t` is a test-mode read (parses the
# config, loads nothing, starts nothing). A config that fails -t means the
# NEXT restart breaks SSH: [BAD]. Non-root: skip silently (host keys unread).
# Also records the daemon version (cheap, unprivileged) in BH_SSHD_VER.
bhv5c10_sshd_cfg_valid() {
  BH_SSHD_CFG_VALID="n/a"; BH_SSHD_VER=""
  [ -n "$BH_SSHD_BIN" ] || return 0
  local vout
  vout="$(bhv5c10_to_err 2 "$BH_SSHD_BIN" -V | head -n 1)"
  BH_SSHD_VER="$(printf '%s\n' "$vout" | sed -n 's/.*\(OpenSSH_[0-9][0-9.p]*\).*/\1/p')"
  if [ -z "$BH_SSHD_VER" ]; then
    vout="$(bhv5c10_to_err 2 "$BH_SSHD_BIN" -h | head -n 1)"
    BH_SSHD_VER="$(printf '%s\n' "$vout" | sed -n 's/.*\(OpenSSH_[0-9][0-9.p]*\).*/\1/p')"
  fi
  [ "$(id -u 2>/dev/null)" = "0" ] || { BH_SSHD_CFG_VALID="skipped (non-root)"; return 0; }
  local err rc msg
  err="$(bhv5c10_to_err 3 "$BH_SSHD_BIN" -t)"
  rc=$?
  if [ "$rc" = "0" ]; then
    BH_SSHD_CFG_VALID="ok"
    sec_line ok "sshd config syntax valid (sshd -t)"
  else
    BH_SSHD_CFG_VALID="invalid"
    msg="$(bhv5c10_sanitize "$(printf '%s\n' "$err" | head -n 1)")"
    if [ -n "$msg" ] && [ "${BH_REDACT:-0}" != "1" ]; then
      sec_line bad "sshd config INVALID — next restart will fail ssh: $msg"
    else
      sec_line bad "sshd config INVALID — next restart will fail ssh (no error detail)"
    fi
  fi
}

# (C2) declared vs effective config — when sshd -T worked, diff the raw
# (declared) first-match values against the effective ones: a difference
# means a Match block or drop-in overrode the global setting -> WARN.
bhv5c10_eff_decl() {
  BH_SSH_EFF_DECL="n/a"
  [ "$BH_SSH_T_OK" = "1" ] || return 0
  if [ "${#BH_SSH_CFG_LINES[@]}" -eq 0 ] 2>/dev/null; then
    # v4 only builds the raw line stream when sshd -T fails; build it here so
    # both views exist (sec_sshd_read is the same Include-aware reader).
    BH_SSH_CFG_LINES=()
    [ -r /etc/ssh/sshd_config ] && sec_sshd_read /etc/ssh/sshd_config 0
  fi
  [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null || return 0
  local n=0 key d e dps eps
  for key in passwordauthentication permitrootlogin pubkeyauthentication \
             x11forwarding kbdinteractiveauthentication maxauthtries; do
    d="$(bhv5c10_norm "$(bhv5c10_decl "$key")")"
    e="$(bhv5c10_norm "$(sec_sshd_opt "$key" "")")"
    if [ -z "$d" ] || [ -z "$e" ]; then continue; fi
    if [ "$d" != "$e" ]; then
      n=$((n + 1))
      sec_line warn "declared '$key $d' overridden to '$e' (Match/drop-in)"
    fi
  done
  # Port is cumulative (may repeat) — compare the sorted unique port SETS
  dps="$(bhv5c10_decl_ports | sed '/^$/d' | sort -n | uniq | paste -sd ',' -)"
  eps="$(sec_sshd_all port | tr ',' '\n' | sed '/^$/d' | sort -n | uniq | paste -sd ',' -)"
  if [ -n "$dps" ] && [ -n "$eps" ] && [ "$dps" != "$eps" ]; then
    n=$((n + 1))
    sec_line warn "declared 'Port $dps' overridden to '$eps' (Match/drop-in)"
  fi
  if [ "$n" -gt 0 ]; then
    BH_SSH_EFF_DECL="overrides:$n"
  else
    BH_SSH_EFF_DECL="declared=effective"
    sec_line ok "sshd declared config matches effective config (raw lines cross-checked with sshd -T)"
  fi
  return 0
}

# (C3) socket-activation false-positive guard — Ubuntu 24.04 / Debian 12 ship
# ssh.socket, so no daemon process exists until the first connection. When the
# socket units are active, flip the earlier "NOT detected" warn verdict to OK.
bhv5c10_socket_fp() {
  BH_SSH_SOCKET_FP=0
  [ "$BH_SSH_RUNNING" = "0" ] || return 0
  [ "$BH_SSH_FOUND" = "1" ] || return 0
  [ -d /run/systemd/system ] || return 0
  local u act=0 i flipped=0
  for u in ssh.socket sshd.socket; do
    if sec_to 3 systemctl is-active "$u" >/dev/null 2>&1; then act=1; break; fi
  done
  [ "$act" = "1" ] || return 0
  if [ "${#BH_SEC_LINES[@]}" -gt 0 ] 2>/dev/null; then
    for i in "${!BH_SEC_LINES[@]}"; do
      case "${BH_SEC_LINES[i]}" in
        *"sshd process: NOT detected"*)
          BH_SEC_LINES[i]="  [OK]  sshd via systemd socket-activation (no daemon process — normal on Ubuntu 24.04/Debian 12)"
          BH_SEC_WARN=$((BH_SEC_WARN - 1))
          BH_SEC_PASS=$((BH_SEC_PASS + 1))
          flipped=1
          ;;
      esac
    done
  fi
  BH_SSH_SOCKET_FP=1
  [ "$flipped" = "1" ] || sec_line ok "sshd via systemd socket-activation (no daemon process — normal on Ubuntu 24.04/Debian 12)"
  return 0
}

# (C4) authorized_keys deep scan behind sec_auth_keys: DSA key detection
# (removed in OpenSSH 9.8+), comment CLASS counting (never the comment
# content), key-file rotation age (>730 days), and an RSA bit-count fallback
# via od/awk when ssh-keygen is unavailable. Counts only — no key material,
# no usernames, no comment text ever reaches the report.
bhv5c10_ak_deep() {
  BH_AK_DSA=0; BH_AK_STALE=0; BH_AK_RSA_FB=0; BH_AK_DEEP_KEYS=0
  BH_AK_CMT_EMAIL=0; BH_AK_CMT_HOST=0; BH_AK_CMT_NONE=0; BH_AK_CMT_OTHER=0
  local have_kg=0 have_b64=0
  command_exists ssh-keygen && have_kg=1
  command_exists base64 && have_b64=1
  local d kf owner tok path now cutoff mt kt cls bits f_dsa seen=""
  local homes="/root"
  for d in /home/*; do [ -d "$d" ] && homes="$homes $d"; done
  now="$(date +%s 2>/dev/null)"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  cutoff=$(( now - 730 * 86400 ))
  for d in $homes; do
    owner="$(stat -c %U "$d" 2>/dev/null)"
    [ -n "$owner" ] || owner="${d##*/}"
    for tok in ${BH_SEC_AUTHKEYS_PATH:-".ssh/authorized_keys"}; do
      path="$tok"
      case "$path" in *%h*) path="${path//%h/$d}" ;; esac
      case "$path" in *%u*) path="${path//%u/$owner}" ;; esac
      case "$path" in
        /*) : ;;
        *)  path="$d/$path" ;;
      esac
      # dedup like sec_auth_keys: absolute (%u-free) paths repeat per home
      case ",$seen," in *",${path},"*) continue ;; esac
      seen="$seen,$path"
      kf="$path"
      if [ ! -f "$kf" ] || [ ! -r "$kf" ]; then continue; fi
      f_dsa=0
      # one awk pass per file: key type + comment CLASS per key line
      # (IFS=" " — with IFS= unset-field-splitting would put the whole line in $kt)
      while IFS=" " read -r kt cls; do
        [ -n "$kt" ] || continue
        BH_AK_DEEP_KEYS=$((BH_AK_DEEP_KEYS + 1))
        case "$kt" in
          ssh-dss*)
            f_dsa=1
            BH_AK_DSA=$((BH_AK_DSA + 1))
            # ssh-keygen -lf already counted DSA (1024 bits) as weak in v4;
            # only add here when that path is unavailable (no double count)
            [ "$have_kg" = "1" ] || BH_AK_WEAK=$((BH_AK_WEAK + 1))
            ;;
        esac
        case "$cls" in
          email) BH_AK_CMT_EMAIL=$((BH_AK_CMT_EMAIL + 1)) ;;
          host)  BH_AK_CMT_HOST=$((BH_AK_CMT_HOST + 1)) ;;
          other) BH_AK_CMT_OTHER=$((BH_AK_CMT_OTHER + 1)) ;;
          *)     BH_AK_CMT_NONE=$((BH_AK_CMT_NONE + 1)) ;;
        esac
      done < <(awk '
        {
          t = ""
          for (i = 1; i <= 6 && i <= NF; i++) {
            if ($i ~ /^(ssh-dss|ssh-rsa|ecdsa-sha2-|ssh-ed25519|sk-)/ && $i !~ /[",=]/) { t = $i; break }
          }
          if (t == "" || i + 1 > NF) next
          cls = "none"
          if (i + 2 <= NF) {
            c = $(i + 2)
            if (c ~ /@/) cls = "email"
            else if (c ~ /^[A-Za-z0-9._:-]+$/ && (c ~ /\./ || c ~ /^[0-9]+$/)) cls = "host"
            else cls = "other"
          }
          print t, cls
        }' "$kf")
      [ "$f_dsa" = "1" ] && sec_line warn "DSA key present (removed in OpenSSH 9.8+)"
      # RSA bit-count fallback when v4's ssh-keygen -lf path is unavailable
      if [ "$have_kg" = "0" ] && [ "$have_b64" = "1" ]; then
        while IFS= read -r bits; do
          [ -n "$bits" ] || continue
          BH_AK_RSA_FB=$((BH_AK_RSA_FB + 1))
          bits="$(bhv5c10_rsa_bits "$bits")"
          case "$bits" in
            ''|*[!0-9]*) : ;;
            *) [ "$bits" -lt 2048 ] && BH_AK_WEAK=$((BH_AK_WEAK + 1)) ;;
          esac
        done < <(awk '{ for (i = 1; i <= 6 && i <= NF; i++) if ($i == "ssh-rsa") { if (i + 1 <= NF) print $(i + 1); break } }' "$kf")
      fi
      mt="$(stat -c %Y "$kf" 2>/dev/null)"
      case "$mt" in
        ''|*[!0-9]*) : ;;
        *) [ "$now" -gt 0 ] && [ "$mt" -lt "$cutoff" ] && BH_AK_STALE=$((BH_AK_STALE + 1)) ;;
      esac
    done
  done
  if [ "$BH_AK_STALE" -gt 0 ]; then
    sec_line info "authorized_keys not rotated in >2y: $BH_AK_STALE file(s)"
  fi
  if [ "$BH_AK_DEEP_KEYS" -gt 0 ]; then
    local cmt_other=""
    [ "$BH_AK_CMT_OTHER" -gt 0 ] && cmt_other=" other:$BH_AK_CMT_OTHER"
    sec_line info "key comment classes: email:$BH_AK_CMT_EMAIL host:$BH_AK_CMT_HOST none:$BH_AK_CMT_NONE${cmt_other} (content never printed)"
  fi
  return 0
}

# (C5) host key audit — /etc/ssh/ssh_host_*_key.pub is world-readable by
# design: DSA -> deprecated warn, RSA < 2048 -> BAD, RSA 2048 -> prefer
# 3072+/ed25519 note, all keys sharing one mtime second -> image-clone note.
# Fingerprints print to 16 chars only. ssh-keygen -lf on a .pub is a pure read.
bhv5c10_hostkey_audit() {
  BH_HOSTKEY_AUDIT=""
  local f n=0 dsa=0 small=0 mid=0 first_mt="" same=1 out bits tp fp fps mt
  for f in /etc/ssh/ssh_host_*_key.pub; do
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then continue; fi
    n=$((n + 1))
    if command_exists ssh-keygen; then
      out="$(sec_to 2 ssh-keygen -lf "$f" | head -n 1)"
      bits="${out%%[[:space:]]*}"
      tp="$(printf '%s\n' "$out" | sed -n 's/.*(\([A-Za-z0-9-]*\)).*/\1/p')"
      fp="$(printf '%s\n' "$out" | awk '{print $2}')"
      fps=""
      [ -n "$fp" ] && fps=" (fp ${fp:0:16})"
      case "$tp" in
        DSA)
          dsa=$((dsa + 1))
          sec_line warn "host key type DSA deprecated${fps} — regenerate with ed25519"
          ;;
        RSA)
          case "$bits" in
            ''|*[!0-9]*) : ;;
            *)
              if [ "$bits" -lt 2048 ]; then
                small=$((small + 1))
                sec_line bad "host key RSA too small: $bits bits${fps} — regenerate with 3072+ bits or ed25519"
              elif [ "$bits" -eq 2048 ]; then
                mid=$((mid + 1))
                sec_line info "host key RSA 2048 bits${fps} — prefer 3072+ or ed25519"
              fi
              ;;
          esac
          ;;
      esac
    fi
    mt="$(stat -c %Y "$f" 2>/dev/null)"
    case "$mt" in
      ''|*[!0-9]*) : ;;
      *)
        if [ -z "$first_mt" ]; then first_mt="$mt"
        elif [ "$mt" != "$first_mt" ]; then same=0
        fi
        ;;
    esac
  done
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -gt 1 ] && [ "$same" = "1" ] && [ -n "$first_mt" ]; then
    sec_line info "host keys copied from image (all public keys share one mtime second)"
  fi
  BH_HOSTKEY_AUDIT="keys:$n dsa:$dsa rsa_lt2048:$small rsa_2048:$mid"
  return 0
}

# (C6) certificate auth posture: TrustedUserCAKeys / AuthorizedKeysCommand /
# RevokedKeys / CASignatureAlgorithms from the effective (or declared) config.
bhv5c10_cert_auth() {
  BH_SSH_CA="none"
  [ "$BH_SSH_FOUND" = "1" ] || return 0
  local ca cmd rev casig
  ca="$(sec_sshd_opt trustedusercakeys "")"
  cmd="$(sec_sshd_opt authorizedkeyscommand "")"
  rev="$(sec_sshd_opt revokedkeys "")"
  casig="$(sec_sshd_opt casignaturealgorithms "")"
  case "$(bhv5c10_norm "$ca")" in ''|none) ca="" ;; esac
  case "$(bhv5c10_norm "$cmd")" in ''|none|internal) cmd="" ;; esac
  case "$(bhv5c10_norm "$rev")" in ''|none) rev="" ;; esac
  BH_SSH_CA=""
  [ -n "$ca" ] && BH_SSH_CA="ca"
  [ -n "$cmd" ] && BH_SSH_CA="${BH_SSH_CA:+$BH_SSH_CA+}command"
  [ -n "$BH_SSH_CA" ] || BH_SSH_CA="none"
  if [ -n "$ca" ]; then
    sec_line ok "certificate-based auth available (TrustedUserCAKeys configured${casig:+, CASignatureAlgorithms set})"
    if [ -z "$rev" ]; then
      sec_line info "certificate CA configured but no RevokedKeys — consider 'RevokedKeys /etc/ssh/revoked_keys'"
    fi
  fi
  [ -n "$cmd" ] && sec_line info "AuthorizedKeysCommand: external key source configured"
  return 0
}

# (C7) Match-block scan over the raw config stream: sftp-only chroot blocks
# (ForceCommand internal-sftp + ChrootDirectory) are counted, any external
# ForceCommand is flagged, and a missing Subsystem sftp is noted.
bhv5c10_match_sftp() {
  BH_SSH_MATCH_SFTP=""
  [ "$BH_SSH_FOUND" = "1" ] || return 0
  local res sftp_n=0 ext_n=0 has_sftp=""
  if [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null; then
    # one "block" = everything up to the next Match line (a global ForceCommand
    # before any Match counts as the first block); BEGIN{seen=1} seeds it
    res="$(printf '%s\n' "${BH_SSH_CFG_LINES[@]}" | awk '
      BEGIN { seen = 1 }
      { sub(/#.*/, "") }
      tolower($1)=="match" {
        if (seen) { if (ch && sfc) sftp++; else if (efc) other++ }
        seen=1; sfc=0; efc=0; ch=0; next
      }
      tolower($1)=="forcecommand" {
        if (tolower($2) ~ /^internal-sftp/) sfc=1; else efc=1; next
      }
      tolower($1)=="chrootdirectory" { ch=1; next }
      END {
        if (seen) { if (ch && sfc) sftp++; else if (efc) other++ }
        print sftp + 0, other + 0
      }')"
  fi
  sftp_n="${res%% *}"; ext_n="${res#* }"
  case "$sftp_n" in ''|*[!0-9]*) sftp_n=0 ;; esac
  case "$ext_n" in ''|*[!0-9]*) ext_n=0 ;; esac
  if [ "$sftp_n" -gt 0 ]; then
    BH_SSH_MATCH_SFTP="$sftp_n block(s)"
    sec_line info "sftp-only chroot accounts: $sftp_n Match block(s) (ForceCommand internal-sftp + ChrootDirectory)"
  fi
  if [ "$ext_n" -gt 0 ]; then
    sec_line warn "ForceCommand runs an external command in $ext_n block(s) — review what it executes"
  fi
  if [ "${#BH_SSH_CFG_LINES[@]}" -gt 0 ] 2>/dev/null; then
    has_sftp="$(printf '%s\n' "${BH_SSH_CFG_LINES[@]}" | awk '{ sub(/#.*/, "") } tolower($1)=="subsystem" && tolower($2)=="sftp" { f=1 } END { print f + 0 }')"
  elif [ "$BH_SSH_T_OK" = "1" ] && [ -n "$BH_SSH_T_OUT" ]; then
    has_sftp="$(printf '%s\n' "$BH_SSH_T_OUT" | awk 'tolower($1)=="subsystem" && tolower($2)=="sftp" { f=1 } END { print f + 0 }')"
  fi
  [ "$has_sftp" = "0" ] && sec_line info "Subsystem sftp: not configured (SFTP file transfers unavailable)"
  return 0
}

# (C8) forwarding sweep: TCP/agent forwarding plus permissive root login is a
# pivot surface on multi-user boxes; PerSourcePenalties no (OpenSSH 9.8+)
# disables the per-source brute-force penalties.
bhv5c10_fwd_sweep() {
  BH_SSH_FWD=""
  [ "$BH_SSH_FOUND" = "1" ] || return 0
  local tcp agent tunnel gw pen lu multi=0 fwd_on=0
  tcp="$(sec_sshd_opt allowtcpforwarding "")"
  agent="$(sec_sshd_opt allowagentforwarding "")"
  tunnel="$(sec_sshd_opt permittunnel "")"
  gw="$(sec_sshd_opt gatewayports "")"
  pen="$(sec_sshd_opt persourcepenalties "")"
  BH_SSH_FWD="tcp:${tcp:-unset} agent:${agent:-unset} tunnel:${tunnel:-unset} gatewayports:${gw:-unset} penalties:${pen:-unset}"
  case "$(bhv5c10_norm "$tcp")" in yes|local|remote) fwd_on=1 ;; esac
  [ "$(bhv5c10_norm "$agent")" = "yes" ] && fwd_on=1
  lu="$(awk -F: '$7 ~ /(bash|zsh|ksh|sh)$/{n++} END{print n+0}' /etc/passwd 2>/dev/null)"
  [ "$lu" -gt 1 ] 2>/dev/null && multi=1
  if [ "$fwd_on" = "1" ] && [ "$BH_SSH_ROOTLOGIN" = "permissive" ] && [ "$multi" = "1" ]; then
    sec_line info "forwarding enabled (pivot surface): AllowTcpForwarding/AllowAgentForwarding on with PermitRootLogin permissive on a multi-user box"
  fi
  case "$(bhv5c10_norm "$pen")" in
    no) sec_line warn "PerSourcePenalties: no — per-source brute-force penalties disabled (OpenSSH 9.8+)" ;;
  esac
  return 0
}

# (C9) topology cross-check: listeners that are NOT in the configured Port
# set, the sshd master process count (sshd-session children excluded via
# PPid), and wildcard binds from the ss listener table.
bhv5c10_topology() {
  BH_SSH_TOPO=""
  [ "$BH_SSH_RUNNING" = "1" ] || return 0
  local p unconf="" masters="" kids=0 total=0 bind_wild=0 ssout line la
  if [ -n "$BH_SSH_LISTENING" ]; then
    for p in $(printf '%s\n' "$BH_SSH_LISTENING" | tr ',' ' '); do
      case ",$BH_SSH_PORTS," in *",${p},"*) : ;; *) unconf="${unconf:+$unconf,}$p" ;; esac
    done
    [ -n "$unconf" ] && sec_line warn "unconfigured sshd listener: port(s) $unconf — not in the sshd_config Port set"
  fi
  if command_exists pgrep; then
    local pids all pid ppid
    pids="$(pgrep -x sshd 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      total="$(printf '%s\n' "$pids" | grep -c . || true)"
      all=" $(printf '%s\n' "$pids" | tr '\n' ' ')"
      for pid in $pids; do
        ppid="$(awk '/^PPid/{print $2}' "/proc/$pid/status" 2>/dev/null)"
        case "$all" in *" $ppid "*) kids=$((kids + 1)) ;; esac
      done
      masters=$(( total - kids ))
      [ "$masters" -lt 0 ] 2>/dev/null && masters=0
      if [ "$masters" -gt 1 ]; then
        sec_line warn "multiple sshd master processes detected ($masters) — one daemon should own the port(s)"
      fi
    fi
  fi
  if command_exists ss; then
    ssout="$(sec_to 3 ss -tlnpH || true)"
    [ -n "$ssout" ] || ssout="$(sec_to 3 ss -tlnH || true)"
    if [ -n "$ssout" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086  # fixed-column split of an ss line
        set -- $line
        la="$4"
        case "$la" in ''|LISTEN) continue ;; esac
        case "$line" in
          *sshd*) : ;;
          *) case ",$BH_SSH_LISTENING," in *",${la##*:},"*) : ;; *) continue ;; esac ;;
        esac
        la="${la%:*}"
        case "$la" in
          0.0.0.0|\*|::|\[::\]) bind_wild=1 ;;
        esac
      done < <(printf '%s\n' "$ssout")
    fi
  fi
  BH_SSH_TOPO="cfg:${BH_SSH_PORTS:-?} listen:${BH_SSH_LISTENING:-none} masters:${masters:-n/a}${unconf:+ unconf:$unconf}"
  if [ "$bind_wild" = "1" ]; then
    BH_SSH_TOPO="$BH_SSH_TOPO bind:wildcard"
    sec_line info "sshd binds all interfaces (0.0.0.0/[::]) — confirm the firewall limits exposure"
  fi
  return 0
}

# (C10) auth-log deep view behind sec_failed_logins: accepted PASSWORD logins
# (proof password auth is live), distinct invalid-user names, btmp/lastb
# volume, fail2ban banned count. Counts only — no usernames, IPs or hosts.
bhv5c10_auth_log_deep() {
  BH_AUTH_PW_LOGIN=0; BH_AUTH_INVALID_USERS=0; BH_LASTB_N=0; BH_F2B_BANNED=-1
  BH_AUTH_LOG_SUM=""
  local pw=0 inv=0 src="" n=0 jout fb
  local jerr="$BH_RUNDIR/journal.err"
  # same journal gate as sec_failed_logins (journalctl "succeeds" with no files)
  if command_exists journalctl && journalctl -n 1 >/dev/null 2>&1; then
    if command_exists timeout; then
      jout="$(timeout 5 journalctl -u ssh -u sshd --since '-24 hours' --no-pager 2>"$jerr" || true)"
    else
      jout="$(journalctl -u ssh -u sshd --since '-24 hours' --no-pager 2>"$jerr" || true)"
    fi
    if [ -n "$jout" ] && ! grep -qi 'no journal files' "$jerr" 2>/dev/null; then
      src="journalctl"
      pw="$(printf '%s\n' "$jout" | grep -c 'Accepted password' || true)"
      inv="$(printf '%s\n' "$jout" | awk '/Invalid user/{print $8}' | sort -u | grep -c . || true)"
    fi
  fi
  if [ -z "$src" ] && [ -r /var/log/auth.log ]; then
    src="auth.log"
    pw="$(grep -hc 'Accepted password' /var/log/auth.log 2>/dev/null || true)"
    inv="$(grep -h 'Invalid user' /var/log/auth.log 2>/dev/null | awk '{print $8}' | sort -u | grep -c . || true)"
  fi
  case "$pw" in ''|*[!0-9]*) pw=0 ;; esac
  case "$inv" in ''|*[!0-9]*) inv=0 ;; esac
  BH_AUTH_PW_LOGIN="$pw"; BH_AUTH_INVALID_USERS="$inv"
  if [ -r /var/log/btmp ] && command_exists lastb; then
    n="$(sec_to 3 lastb -n 20 | awk 'NF && $0 !~ /btmp begins/ {n++} END{print n+0}')"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    BH_LASTB_N="$n"
    [ "$n" -gt 0 ] && sec_line info "lastb: $n failed-login entr(ies) in /var/log/btmp (showing up to 20)"
  fi
  if command_exists fail2ban-client; then
    fb="$(sec_to 3 fail2ban-client status sshd | sed -n 's/.*Currently banned:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    case "$fb" in ''|*[!0-9]*) fb="" ;; esac
    if [ -n "$fb" ]; then
      BH_F2B_BANNED="$fb"
      [ "$fb" -gt 0 ] 2>/dev/null && sec_line info "fail2ban sshd jail: $fb IP(s) currently banned"
    fi
  fi
  if [ "$pw" -gt 0 ]; then
    sec_line warn "password logins observed in logs (live use): $pw accepted password login(s) in $src"
  fi
  if [ "$inv" -gt 0 ]; then
    sec_line info "invalid-user probes: $inv distinct name(s) — brute-force background noise (count only)"
  fi
  if [ -n "$src" ] || [ "$BH_LASTB_N" -gt 0 ] || [ "$BH_F2B_BANNED" -ge 0 ] 2>/dev/null; then
    local fl="$BH_SSH_FAILS_N"
    [ "$fl" -ge 0 ] 2>/dev/null || fl="n/a"
    BH_AUTH_LOG_SUM="fail:$fl invalid-users:$BH_AUTH_INVALID_USERS pw-accepted:$BH_AUTH_PW_LOGIN"
  fi
  return 0
}

# (C11) MFA posture: AuthenticationMethods plus a 2FA PAM stack; UsePAM no
# also means account policies (expiry/lockout) are bypassed for SSH logins.
bhv5c10_mfa() {
  BH_SSH_MFA=""
  [ "$BH_SSH_FOUND" = "1" ] || return 0
  local am up pam2fa=0
  am="$(sec_sshd_opt authenticationmethods "")"
  up="$(sec_sshd_opt usepam "")"
  if [ -r /etc/pam.d/sshd ] && grep -qsE 'pam_google_authenticator|pam_u2f|pam_oath|pam_duo' /etc/pam.d/sshd; then
    pam2fa=1
  fi
  case "$(bhv5c10_norm "$am")" in ''|any|none) am="" ;; esac
  if [ -n "$am" ] && [ "$pam2fa" = "1" ]; then
    BH_SSH_MFA="enforced"
    sec_line ok "MFA enforced (AuthenticationMethods: $am + 2FA PAM module in /etc/pam.d/sshd)"
  elif [ "$(bhv5c10_norm "$up")" = "no" ]; then
    BH_SSH_MFA="usepam-no"
    sec_line warn "UsePAM no — account policies (expiry/lockout/2FA hooks) bypassed for SSH"
  elif [ -n "$am" ]; then
    BH_SSH_MFA="methods-only"
    sec_line info "AuthenticationMethods: $am but no 2FA PAM module found in /etc/pam.d/sshd"
  else
    BH_SSH_MFA="none"
    sec_line info "MFA: not configured (single-factor SSH)"
  fi
  return 0
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
    BH_SSH_PERMPTY="$(sec_sshd_opt permitemptypasswords "")"
    BH_SSH_LOGINGRACE="$(sec_sshd_opt logingracetime "")"
    BH_SSH_X11="$(sec_sshd_opt x11forwarding "")"
    BH_SSH_KBDINT="$(sec_sshd_opt kbdinteractiveauthentication "")"
    BH_SSH_ALLOWUSERS="$(sec_sshd_opt allowusers "")"
    local ag
    ag="$(sec_sshd_opt allowgroups "")"
    [ -n "$ag" ] && BH_SSH_ALLOWUSERS="${BH_SSH_ALLOWUSERS:+$BH_SSH_ALLOWUSERS,}$ag"

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

    case "$BH_SSH_PERMPTY" in
      yes) sec_line bad "PermitEmptyPasswords: yes — accounts with empty passwords could log in" ;;
      no)  sec_line ok  "PermitEmptyPasswords: no" ;;
      *)   sec_line ok  "PermitEmptyPasswords: ${BH_SSH_PERMPTY:-no (default)}" ;;
    esac
    if [ -z "$BH_SSH_LOGINGRACE" ]; then
      sec_line info "LoginGraceTime: not set (OpenSSH default: 120s)"
    else
      local lgt_s
      lgt_s="$(sec_grace_secs "$BH_SSH_LOGINGRACE")"
      case "$lgt_s" in
        ''|*[!0-9]*) sec_line info "LoginGraceTime: $BH_SSH_LOGINGRACE (unrecognized value)" ;;
        0)           sec_line warn "LoginGraceTime: 0 (unlimited) — no deadline for authentication" ;;
        *)
          if [ "$lgt_s" -gt 120 ]; then
            sec_line warn "LoginGraceTime: ${lgt_s}s — long pre-auth window (default 120s)"
          else
            sec_line ok "LoginGraceTime: ${lgt_s}s"
          fi
          ;;
      esac
    fi
    case "$BH_SSH_X11" in
      yes) sec_line warn "X11Forwarding: yes — extra attack surface; disable unless X11 is really needed" ;;
      no)  sec_line ok   "X11Forwarding: no" ;;
      *)   sec_line ok   "X11Forwarding: ${BH_SSH_X11:-no (default)}" ;;
    esac
    if [ "$BH_SSH_KBDINT" = "yes" ]; then
      case "$BH_SSH_PWDAUTH" in
        yes) sec_line warn "KbdInteractiveAuthentication: yes + PasswordAuthentication: yes — keyboard-interactive + password auth both on" ;;
        *)   sec_line info "KbdInteractiveAuthentication: yes (PasswordAuthentication: ${BH_SSH_PWDAUTH:-not set})" ;;
      esac
    else
      sec_line info "KbdInteractiveAuthentication: ${BH_SSH_KBDINT:-yes (default)}"
    fi
    if [ -n "$BH_SSH_ALLOWUSERS" ]; then
      sec_line ok "SSH access restricted to: $BH_SSH_ALLOWUSERS (AllowUsers/AllowGroups)"
    else
      sec_line info "AllowUsers/AllowGroups: not set — every account may attempt SSH login"
    fi

    # ---- AuthorizedKeysFile (H3): effective paths feed the key inventory ----
    BH_SEC_AUTHKEYS_PATH="$(sec_sshd_opt authorizedkeysfile "")"
    [ -n "$BH_SEC_AUTHKEYS_PATH" ] || BH_SEC_AUTHKEYS_PATH=".ssh/authorized_keys"
    case "$BH_SEC_AUTHKEYS_PATH" in
      ".ssh/authorized_keys")
        sec_line info "AuthorizedKeysFile: .ssh/authorized_keys (default)" ;;
      *)
        sec_line info "AuthorizedKeysFile: $BH_SEC_AUTHKEYS_PATH (non-default — key inventory scans these paths too, %u/%h expanded)" ;;
    esac

    # ---- crypto hygiene (H1): weak Ciphers/MACs/KexAlgorithms ----
    local eff_cs eff_ms eff_kx
    eff_cs="$(sec_sshd_opt ciphers "")"
    eff_ms="$(sec_sshd_opt macs "")"
    eff_kx="$(sec_sshd_opt kexalgorithms "")"
    BH_SEC_WEAK_CRYPTO="$(sec_weak_tokens "$eff_cs,$eff_ms,$eff_kx")"
    BH_SEC_CIPHERS="$(sec_trunc "$eff_cs")"
    BH_SEC_KEX="$(sec_trunc "$eff_kx")"
    if [ -n "$BH_SEC_WEAK_CRYPTO" ]; then
      sec_line warn "Weak crypto algorithms enabled: $BH_SEC_WEAK_CRYPTO"
    elif [ -n "$eff_cs$eff_ms$eff_kx" ]; then
      sec_line ok "Weak crypto: none — Ciphers/MACs/KexAlgorithms contain no known-weak algorithms"
    else
      sec_line info "Weak crypto: none detected — Ciphers/MACs/KexAlgorithms not set (distro defaults apply)"
    fi
    [ -n "$BH_SEC_CIPHERS" ] && sec_line info "Effective Ciphers: $BH_SEC_CIPHERS"
    [ -n "$BH_SEC_KEX" ] && sec_line info "Effective KexAlgorithms: $BH_SEC_KEX"

    # ---- connection hygiene (H2) ----
    BH_SEC_MAXSTARTUPS="$(sec_sshd_opt maxstartups "")"
    [ -n "$BH_SEC_MAXSTARTUPS" ] || BH_SEC_MAXSTARTUPS="10:30:100 default"
    sec_line info "MaxStartups: $BH_SEC_MAXSTARTUPS (unauthenticated connection throttling)"
    local cai cacm
    cai="$(sec_sshd_opt clientaliveinterval "")"
    cacm="$(sec_sshd_opt clientalivecountmax "")"
    if [ -z "$cai" ] || [ "$cai" = "0" ]; then
      BH_SEC_ALIVE="disabled (default)"
    elif [ -n "$cacm" ]; then
      BH_SEC_ALIVE="ClientAliveInterval ${cai}s x ClientAliveCountMax ${cacm}"
    else
      BH_SEC_ALIVE="ClientAliveInterval ${cai}s x ClientAliveCountMax 3 (default)"
    fi
    sec_line info "Client keepalive: $BH_SEC_ALIVE (dead-session reaping)"

    # ---- pre-login banner leak (H8) ----
    sec_banner
    case "$BH_SEC_BANNER" in
      leaks*) sec_line warn "Pre-login banner: $BH_SEC_BANNER — reveals OS details to anyone probing the SSH port; set 'Banner none'" ;;
      custom) sec_line info "Pre-login banner: custom (no OS info detected)" ;;
      *)      sec_line info "Pre-login banner: none" ;;
    esac

    # ---- v5 deep checks (C10): syntax gate, declared-vs-effective diff, ----
    # ---- certificate auth, Match/SFTP scan, forwarding sweep, MFA      ----
    bhv5c10_sshd_cfg_valid
    bhv5c10_eff_decl
    bhv5c10_cert_auth
    bhv5c10_match_sftp
    bhv5c10_fwd_sweep
    bhv5c10_mfa
  else
    BH_SSH_PORTS=""
    sec_line info "sshd: not found on this machine (no SSH server installed)"
  fi

  # ---- OpenSSH version ('sshd -V' is not portable; 'ssh -V' prints to stderr) ----
  if command_exists ssh; then
    BH_SSH_VERSION="$(ssh -V 2>&1 | sed -n 's/^\(OpenSSH_[0-9.p]*\).*/\1/p' | head -n 1)"
  fi
  if [ -n "$BH_SSH_VERSION" ]; then
    sec_line info "OpenSSH version: $BH_SSH_VERSION"
  else
    sec_line info "OpenSSH version: n/a (ssh client not found)"
  fi
  # daemon and client versions can drift after partial upgrades — report the
  # daemon binary when it adds information beyond the client line above
  if [ -n "$BH_SSHD_VER" ] && [ "$BH_SSHD_VER" != "$BH_SSH_VERSION" ]; then
    if [ -n "$BH_SSH_VERSION" ]; then
      sec_line info "sshd daemon version: $BH_SSHD_VER (ssh client: $BH_SSH_VERSION — client/daemon differ)"
    else
      sec_line info "sshd daemon version: $BH_SSHD_VER (no ssh client for comparison)"
    fi
  fi

  # ---- sshd runtime state ----
  sec_sshd_runtime
  if [ "$BH_SSH_RUNNING" = "1" ]; then
    if [ -n "$BH_SSH_LISTENING" ]; then
      sec_line info "sshd process: running; listening on port(s): $BH_SSH_LISTENING"
    else
      sec_line info "sshd process: running; listening ports unknown (ss unavailable or no match)"
    fi
  elif [ "$BH_SSH_FOUND" = "1" ]; then
    sec_line warn "sshd process: NOT detected, but sshd config exists — SSH server may be down or disabled"
  else
    sec_line info "sshd process: not detected (no SSH server installed)"
  fi

  # ---- v5 (C3/C9): socket-activation false-positive guard + listener topology ----
  bhv5c10_socket_fp
  bhv5c10_topology

  # ---- authorized keys ----
  sec_auth_keys
  bhv5c10_ak_deep
  if [ "$BH_AK_TOTAL" -gt 0 ]; then
    local weaktxt=""
    [ "$BH_AK_WEAK" -gt 0 ] && weaktxt=" — $BH_AK_WEAK WEAK (<2048-bit)"
    sec_line ok "authorized_keys: $BH_AK_TOTAL key(s): ${BH_AK_TYPES:-unknown types}$weaktxt"
  else
    sec_line info "authorized_keys: none found (root + /home/*)"
  fi

  # ---- v5 (C5): host key audit (type/size/mtime; fingerprints truncated) ----
  bhv5c10_hostkey_audit

  # ---- failed logins ----
  sec_failed_logins
  if [ "$BH_SSH_FAILS_N" -ge 50 ] 2>/dev/null; then
    sec_line warn "Failed SSH logins: $BH_SSH_FAILS — looks like active brute-force; consider fail2ban + key-only auth"
  elif [ "$BH_SSH_FAILS_N" -ge 1 ] 2>/dev/null; then
    sec_line info "Failed SSH logins: $BH_SSH_FAILS"
  else
    sec_line info "Failed SSH logins: $BH_SSH_FAILS"
  fi
  bhv5c10_auth_log_deep

  # ---- firewall / fail2ban ----
  sec_firewall
  case "$BH_FW" in
    *INACTIVE*|"no firewall detected") sec_line warn "Firewall: $BH_FW — enable ufw/nftables and only open needed ports" ;;
    *) sec_line ok "Firewall: $BH_FW" ;;
  esac
  # ---- brute-force protection (fail2ban / sshguard / crowdsec) ----
  BH_F2B=0; BH_F2B_ACTIVE=0; BH_SSHGUARD=0; BH_CROWDSEC=0
  if command_exists fail2ban-client || [ -d /etc/fail2ban ]; then
    BH_F2B=1
    # "active" = systemd unit running OR the fail2ban-server process is alive
    if systemctl is-active fail2ban >/dev/null 2>&1 || pgrep -x fail2ban-server >/dev/null 2>&1; then
      BH_F2B_ACTIVE=1
      if command_exists fail2ban-client && fail2ban-client status sshd 2>/dev/null | grep -q "Jail"; then
        sec_line ok "fail2ban: active with sshd jail"
      else
        sec_line ok "fail2ban: active (sshd jail not confirmed — needs fail2ban-client read rights)"
      fi
    else
      sec_line warn "fail2ban: installed but NOT running — 'systemctl enable --now fail2ban'"
    fi
  fi
  if systemctl is-active sshguard >/dev/null 2>&1 || pgrep -x sshguard >/dev/null 2>&1 || [ -f /etc/sshguard.conf ]; then
    BH_SSHGUARD=1
    sec_line ok "sshguard: present (brute-force protection)"
  fi
  if systemctl is-active crowdsec >/dev/null 2>&1 || pgrep -x crowdsec >/dev/null 2>&1 || [ -d /etc/crowdsec ] || command_exists cscli; then
    BH_CROWDSEC=1
    sec_line ok "crowdsec: present (collaborative brute-force protection)"
  fi
  if [ "$BH_F2B" = "0" ] && [ "$BH_SSHGUARD" = "0" ] && [ "$BH_CROWDSEC" = "0" ]; then
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

  # ---- password/account hygiene (H4/H5) ----
  sec_pam_pw
  case "$BH_SEC_PAM_PW" in
    pwquality*|cracklib|passwdqc) sec_line ok "PAM password quality: $BH_SEC_PAM_PW" ;;
    none) sec_line info "PAM password quality: none — no pwquality/cracklib module in the PAM password stack" ;;
    *)    sec_line info "PAM password quality: unknown (PAM password config not readable)" ;;
  esac
  sec_aging
  if [ -n "$BH_SEC_PASS_MAX_DAYS" ]; then
    sec_line info "Password aging: PASS_MAX_DAYS=$BH_SEC_PASS_MAX_DAYS${BH_SEC_ROOT_EXPIRE:+ | root password expires: $BH_SEC_ROOT_EXPIRE}"
  else
    sec_line info "Password aging: n/a (/etc/login.defs not readable)"
  fi

  # ---- auditd / time sync (H6/H7) ----
  sec_auditd
  case "$BH_SEC_AUDITD" in
    running)               sec_line ok "auditd: running (kernel audit rules active)" ;;
    installed-not-running) sec_line warn "auditd: installed but NOT running — 'systemctl enable --now auditd'" ;;
    not-installed)         sec_line info "auditd: not installed (kernel audit framework)" ;;
    *)                     sec_line info "auditd: unknown" ;;
  esac
  sec_ntp
  case "$BH_SEC_NTP" in
    synced*)    sec_line ok "Time sync: $BH_SEC_NTP" ;;
    not-synced) sec_line warn "Time sync: not-synced — clock drift breaks TLS, logs and cron" ;;
    *)          sec_line info "Time sync: unknown (no systemd/chrony time source detected)" ;;
  esac

  # ---- hardening extras (lib/85-hardening.sh, optional module) ----
  # Guarded so this file still works when sourced standalone (tests do that).
  if command -v sec_hardening >/dev/null 2>&1; then
    sec_hardening
  fi

  # ---- v5 companion modules (86/87, another coder owns them) ----
  declare -F sec_system_sec >/dev/null 2>&1 && sec_system_sec
  declare -F sec_malware_hunt >/dev/null 2>&1 && sec_malware_hunt

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
