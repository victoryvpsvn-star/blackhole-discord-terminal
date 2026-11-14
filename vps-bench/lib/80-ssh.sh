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
