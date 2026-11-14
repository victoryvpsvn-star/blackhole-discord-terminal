# =====================================================================
# blackhole-vps-bench · 57-mount-audit.sh — mount flags / inode / TRIM
# =====================================================================
# v5.0 (C8): pure /proc/mounts + df reads (runs in every mode, <0.3s).
# Nothing here ever writes or unmounts anything; fstrim is only ever
# QUERIED (systemctl is-enabled / show), never executed.
#   M1  hardening flags of the key mountpoints (/, /tmp, /dev/shm,
#       /var, /home, /run — exact or longest-prefix real mount)
#                     -> BH_MOUNT_FLAGS_TXT
#       "/tmp: nosuid,nodev,noexec | /var: (none) | /: (none)"
#       Sensitive mounts (/tmp, /dev/shm) missing nosuid/nodev/noexec
#       get a "!" entry with the missing reasons, e.g.
#       "!/dev/shm: exec allowed". / itself is NEVER flagged for
#       missing nodev/noexec (normal); "ro" is only recorded for
#       real-fs mounts (not squashfs/iso9660). Targets that are not
#       separate mountpoints (they just inherit /) are not listed.
#   M2  worst inode usage across real filesystems (df -Pi; overlay IS
#       included — containers care; "-" rows (btrfs/xfs dynamic) and
#       itotal < 1000 pseudo-fs rows are skipped)
#                     -> BH_INODE_TXT "inode peak 87% on /var"
#       >=80% gets a "!" prefix.
#   M3  fstrim.timer state (only with systemd present) cross-checked
#       with BH_DISCARD_MOUNT (owned by 50-disk.sh, guarded read)
#                     -> BH_FSTRIM_TXT
#       "TRIM never runs (no discard mount + fstrim.timer disabled)" |
#       "fstrim.timer enabled (last: <ts>)" | "fstrim.timer disabled" |
#       "fstrim.timer absent" ; no systemd -> "".
#
# Globals are initialized inside gather_mount_audit(); sourcing this
# file has zero side effects (function definitions only). Contract:
# sets BH_* globals only (never stdout); every external command runs
# under `timeout` (bhv5c8_to); unreadable/missing input => "" (clean);
# mawk-safe awk only. Budget: <0.3s.
# =====================================================================
# shellcheck shell=bash

# bhv5c8_to SECS CMD... — run CMD under `timeout` when available (same
# helper as in 56-storage-health.sh, kept file-local so either file can
# be sourced standalone).
bhv5c8_to() {
  local s="$1"; shift
  if command_exists timeout; then
    timeout "$s" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# bhv5c8_trim — pure-bash whitespace strip (systemctl output padding).
bhv5c8_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# bhv5c8_mount_flags MOUNTS_TXT — resolve hardening flags for the six
# key targets from a mounts table of "mnt fst opts" lines (the exact
# fields /proc/mounts provides; every field there is whitespace-escaped
# so a literal space never splits fields — space-or-tab IFS is safe).
# Prints the compact " | "-joined string; "" when nothing matches.
# Pure text, unit-testable.
bhv5c8_mount_flags() {
  local mlist="${1:-}" t tmnt tfst topts best_mnt best_fst best_opts
  local flags reasons entry out=""
  [ -n "$mlist" ] || { printf ''; return 0; }
  for t in /tmp /dev/shm /var /home /run /; do
    best_mnt=""; best_fst=""; best_opts=""
    while IFS=$' \t' read -r tmnt tfst topts; do
      [ -n "$tmnt" ] || continue
      case "$t" in
        "$tmnt"|"$tmnt"/*) : ;;    # exact, or this mount covers the target
        *) continue ;;
      esac
      if [ "${#tmnt}" -gt "${#best_mnt}" ]; then
        best_mnt="$tmnt"; best_fst="$tfst"; best_opts="$topts"
      fi
    done <<< "$mlist"
    [ -n "$best_mnt" ] || continue
    if [ "$best_mnt" = "/" ] && [ "$t" != "/" ]; then
      continue        # not a separate mount -> root flags apply, listing = noise
    fi
    flags=""
    case ",${best_opts}," in *",nosuid,"*) flags="nosuid" ;; esac
    case ",${best_opts}," in *",nodev,"*)  flags="${flags:+$flags,}nodev" ;; esac
    case ",${best_opts}," in *",noexec,"*) flags="${flags:+$flags,}noexec" ;; esac
    case ",${best_opts}," in *",ro,"*)
      case "$best_fst" in squashfs|iso9660) : ;; *) flags="${flags:+$flags,}ro" ;; esac
      ;;
    esac
    case "$t" in
      /tmp|/dev/shm)
        reasons=""
        case ",${best_opts}," in *",nosuid,"*) : ;; *) reasons="suid allowed" ;; esac
        case ",${best_opts}," in *",nodev,"*)  : ;; *) reasons="${reasons:+$reasons,}dev allowed" ;; esac
        case ",${best_opts}," in *",noexec,"*) : ;; *) reasons="${reasons:+$reasons,}exec allowed" ;; esac
        if [ -n "$reasons" ]; then
          entry="!$t: $reasons"
        else
          entry="$t: ${flags:-(none)}"
        fi
        ;;
      *)  entry="$t: ${flags:-(none)}" ;;   # / is never flagged (normal)
    esac
    out="${out}${out:+ | }$entry"
  done
  printf '%s' "$out"
}

# bhv5c8_inode_peak DF_TXT — parse `df -Pi` (POSIX inode table): real-fs
# rows with a numeric IUse% (skip "-" used by btrfs/xfs dynamic inodes,
# skip itotal<1000 pseudo/tiny rows, skip tmpfs/devtmpfs/proc/... rows,
# keep overlay). Prints "inode peak N% on MNT" (with "!" prefix when
# N >= 80) or "" when nothing numeric remains. Pure text, testable.
bhv5c8_inode_peak() {
  [ -n "${1:-}" ] || { printf ''; return 0; }
  printf '%s\n' "$1" | awk '
    NR > 1 {
      pct = $5
      if (pct == "" || pct == "-") next
      sub(/%$/, "", pct)
      if (pct !~ /^[0-9]+$/) next
      itot = $2
      if (itot !~ /^[0-9]+$/ || itot + 0 < 1000) next
      if ($1 ~ /^(tmpfs|devtmpfs|ramfs|udev|none|proc|sysfs|devpts|mqueue|securityfs|cgroup2?|pstore|bpf|debugfs|tracefs|configfs|fusectl|hugetlbfs|nsfs|squashfs|iso9660|autofs|binfmt_misc|rpc_pipefs|efivarfs|cgmfs)$/) next
      m = $6
      for (i = 7; i <= NF; i++) m = m " " $i
      if (pct + 0 > max + 0) { max = pct + 0; mm = m }
    }
    END {
      if (max + 0 > 0) printf "%sinode peak %d%% on %s\n", (max >= 80 ? "!" : ""), max, mm
    }' 2>/dev/null
}

gather_mount_audit() {
  BH_MOUNT_FLAGS_TXT=""
  BH_INODE_TXT=""
  BH_FSTRIM_TXT=""

  # ------------- M1: mount flags (single /proc/mounts pass) -------------
  local mlist="" _mdev mnt fst opts
  if [ -r /proc/mounts ]; then
    while read -r _mdev mnt fst opts _mrest; do
      [ -n "$mnt" ] || continue
      mlist="${mlist}${mnt}"$'\t'"${fst}"$'\t'"${opts}"$'\n'
    done < /proc/mounts
  fi
  BH_MOUNT_FLAGS_TXT="$(bhv5c8_mount_flags "$mlist")"

  # ------------- M2: worst inode usage ----------------------------------
  local dfo
  dfo="$(bhv5c8_to 3 df -Pi)"
  BH_INODE_TXT="$(bhv5c8_inode_peak "$dfo")"

  # ------------- M3: fstrim.timer state (read-only queries) -------------
  if [ -d /run/systemd/system ] && command_exists systemctl; then
    local st last
    st="$(bhv5c8_to 2 systemctl is-enabled fstrim.timer)"
    st="$(bhv5c8_trim "$st")"
    case "$st" in
      enabled)
        last="$(bhv5c8_to 2 systemctl show fstrim.timer -p LastTriggerUSec --value)"
        last="$(bhv5c8_trim "$last")"
        case "$last" in ""|n/a|0) last="n/a" ;; esac
        BH_FSTRIM_TXT="fstrim.timer enabled (last: $last)"
        ;;
      disabled)
        if [ "${BH_DISCARD_MOUNT:-}" = "no" ]; then
          BH_FSTRIM_TXT="TRIM never runs (no discard mount + fstrim.timer disabled)"
        else
          BH_FSTRIM_TXT="fstrim.timer disabled"
        fi
        ;;
      not-found)                        BH_FSTRIM_TXT="fstrim.timer absent" ;;
      masked|static|indirect|generated) BH_FSTRIM_TXT="fstrim.timer $st" ;;
      *) : ;;                           # systemctl error/timeout -> "" clean
    esac
  fi

  return 0
}
