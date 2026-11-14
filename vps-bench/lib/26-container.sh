# =====================================================================
# blackhole-vps-bench · 26-container.sh — container / orchestrator deep-dive
# =====================================================================
# shellcheck shell=bash
#
# Module 26 (v5): WHEN we run inside a container, identify the runtime and
# every Kubernetes identity signal reachable from /proc and /etc — without
# ever touching a secret. Loads after 25-env.sh (uses nothing from it).
#
#   C1 runtime + orchestrator (/proc/1/cgroup, /proc/self/cgroup,
#      /proc/self/mountinfo v2 upperdir fallback, sentinel files)
#   C2 k8s namespace + cluster domain (/etc/resolv.conf "search X.svc.Y",
#      corroborated by options ndots:5 and the pod-style hostname)
#   C3 serviceaccount identity (namespace VALUE is safe; the token is only
#      existence-checked with [ -s ] — its content is NEVER read/printed)
#   C4 pod UID (kubepods cgroup pod<uid>, uuid-validated; v2 _ -> -)
#   C5 k8s env keys (/proc/1/environ fallback self: SERVICE_HOST/PORT values
#      are IPs/ports = safe; other *_SERVICE_HOST counted by NAME only)
#   C6 projected/configmap/secret volumes (mountinfo; count + <=3 paths)
#   C7 namespace fingerprint (ns inode tuple + pid-ns vs pid1 comparison)
#
# Contract: defines gather_container() ONLY — no top-level side effects, so
# this file may be sourced even when the module is disabled. All helpers are
# private (bhv5c11_*). Sets BH_* globals inside gather_container; never
# prints to stdout; read-only; no network; every external command guarded
# (command_exists + `timeout 2`); bash-3.2 compatible; mawk-safe (zero awk).
# Never fails: unreadable input => ""/"unknown"/"id-unavailable".
# Budget: pure procfs text scanning + ~6 readlink forks => well under 0.5s.

# bhv5c11_uuid_ok STRING — return 0 when STRING is a 36-char canonical
# uuid (8-4-4-4-12 hex, case-insensitive). Pure bash ERE, no forks.
bhv5c11_uuid_ok() {
  local re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  [[ "$1" =~ $re ]]
}

# bhv5c11_cg_scan CGROUP_PATH — inspect one cgroup path string and update the
# private scratch state (bhv5c11_rt / bhv5c11_cid / bhv5c11_orch /
# bhv5c11_poduid; all initialised by gather_container). First specific match
# wins for the runtime; orchestrator/pod-uid keep scanning. Regexes are kept
# in variables so `[[ =~ $re ]]` stays portable back to bash 3.2.
bhv5c11_cg_scan() {
  local p="$1" re id
  # ---- orchestrator: kubepods slice at any depth (v1 and v2 layouts,
  #      including -burst / -besteffort / kubepods.slice/pod<uid>) ----
  case "$p" in
    *kubepods*)
      if [ -z "$bhv5c11_orch" ]; then bhv5c11_orch="kubernetes"; fi
      if [ -z "$bhv5c11_poduid" ]; then
        re='pod([0-9a-fA-F_-]{36})'
        if [[ "$p" =~ $re ]]; then
          id="${BASH_REMATCH[1]}"
          id="${id//_/-}"                     # v2 escapes '-' as '_' in slices
          if bhv5c11_uuid_ok "$id"; then bhv5c11_poduid="$id"; fi
        fi
      fi
      ;;
  esac
  # ---- docker-compose slice (independent of runtime match order) ----
  case "$p" in
    *docker.slice*)
      if [ -z "$bhv5c11_orch" ]; then bhv5c11_orch="docker-compose"; fi
      if [ -z "$bhv5c11_rt" ]; then bhv5c11_rt="docker"; fi
      ;;
  esac
  [ -n "$bhv5c11_rt" ] && return 0            # runtime already pinned
  # ---- runtimes with a container id in the scope name ----
  re='docker-([0-9a-f]{32,64})\.scope'
  if [[ "$p" =~ $re ]]; then
    bhv5c11_rt="docker"; bhv5c11_cid="${BASH_REMATCH[1]}"; return 0
  fi
  re='crio-([0-9a-f]{32,64})\.scope'
  if [[ "$p" =~ $re ]]; then
    bhv5c11_rt="cri-o"; bhv5c11_cid="${BASH_REMATCH[1]}"; return 0
  fi
  re='cri-containerd-([0-9a-f]{32,64})\.scope'
  if [[ "$p" =~ $re ]]; then
    bhv5c11_rt="containerd"; bhv5c11_cid="${BASH_REMATCH[1]}"; return 0
  fi
  re='libpod-([0-9a-f]{32,64})\.scope'
  if [[ "$p" =~ $re ]]; then
    bhv5c11_rt="podman"; bhv5c11_cid="${BASH_REMATCH[1]}"; return 0
  fi
  # legacy v1 layout: .../docker/<64hex> (id from path)
  re='/docker/([0-9a-f]{32,64})($|/)'
  if [[ "$p" =~ $re ]]; then
    bhv5c11_rt="docker"; bhv5c11_cid="${BASH_REMATCH[1]}"; return 0
  fi
  case "$p" in
    *libpod*|*podman*) bhv5c11_rt="podman" ;;
  esac
  return 0
}

# bhv5c11_ns_inode NSPATH — print the decimal inode of a /proc/*/ns/* symlink
# ("" when unavailable). readlink is guarded (command_exists + timeout 2).
bhv5c11_ns_inode() {
  local p="$1" out=""
  if command_exists readlink; then
    if command_exists timeout; then
      out="$(timeout 2 readlink "$p" 2>/dev/null)" || out=""
    else
      out="$(readlink "$p" 2>/dev/null)" || out=""
    fi
  fi
  case "$out" in
    *:*) out="${out##*:}" ;;            # "pid:[4026532249]" -> "[4026532249]"
  esac
  case "$out" in
    '['*) out="${out#?}" ;;             # strip leading bracket
  esac
  case "$out" in
    *']') out="${out%?}" ;;             # strip trailing bracket
  esac
  case "$out" in
    ''|*[!0-9]*) printf '' ;;
    *)           printf '%s' "$out" ;;
  esac
  return 0
}

gather_container() {
  # ---- defaults (function-local init: no top-level side effects here) ----
  BH_RT_NAME=""         # docker | cri-o | containerd | podman | lxc |
                        # systemd-nspawn | "" (unknown / not a container)
  BH_RT_CTR_ID=""       # >=32 hex container id | id-unavailable
  BH_ORCH=""            # kubernetes | docker-compose | ""
  BH_K8S_NS=""          # namespace from resolv.conf search / SA namespace
  BH_K8S_CTX=""         # "ns=<ns> domain=<domain>" | "" (no k8s context)
  BH_SA_TXT=""          # "ns=<ns> token=present|absent ca=present|absent"
  BH_POD_UID=""         # 36-char pod uuid | ""
  BH_K8S_ENV_KEYS=""    # "KUBERNETES_SERVICE_HOST=ip KUBERNETES_SERVICE_PORT=n
                        #  svc_host_keys=N" (other keys counted by NAME only)
  BH_PROJ_VOL=""        # "count=N paths=<up to 3 mountpoints>"
  BH_NS_FP=""           # "pid=.. mnt=.. net=.. uts=.. ipc=.. (pid-ns ...)"
  local bhv5c11_rt="" bhv5c11_cid="" bhv5c11_orch="" bhv5c11_poduid=""
  local iscont=0

  # ---- fast path: honor the authoritative verdict from 10-detect ----
  case "${BH_KIND:-}" in
    container)  iscont=1 ;;
    bare-metal) return 0 ;;            # nothing container-shaped to report
  esac
  # independent sentinels (also cover runs where detect_virt did not execute)
  if [ "$iscont" -eq 0 ]; then
    [ -e /.dockerenv ] && iscont=1
    [ -e /run/.containerenv ] && iscont=1
    [ -r /run/systemd/container ] && iscont=1
  fi

  # ---- C1a: cgroup paths (pid1 first, then self; first specific hit wins) ----
  local cgf _cgh _cgi cgpath
  for cgf in /proc/1/cgroup /proc/self/cgroup; do
    [ -r "$cgf" ] || continue
    while IFS=: read -r _cgh _cgi cgpath || [ -n "${cgpath:-}" ]; do
      [ -n "$cgpath" ] || continue
      bhv5c11_cg_scan "$cgpath"
    done < "$cgf"
  done

  # ---- C1b/C6: mountinfo — v2 runtime fallback + projected volumes ----
  local mi_f1 mi_root mi_mp mi_rest
  local pv_total=0 pv_shown=0 pv_paths="" pv_fb=""
  if [ -r /proc/self/mountinfo ]; then
    while read -r mi_f1 _ _ mi_root mi_mp mi_rest \
      || [ -n "${mi_f1:-}" ]; do
      case "$mi_mp" in /*) : ;; *) continue ;; esac
      # C1b: cgroup-v2 leaves "0::/" in cgroup files — the overlay upperdir /
      # lowerdir paths are the reliable runtime marker instead
      if [ -z "$bhv5c11_rt" ]; then
        case "$mi_root $mi_rest" in
          *docker/overlay2*)              bhv5c11_rt="docker" ;;
          *io.containerd.snapshotter.v1*) bhv5c11_rt="containerd" ;;
          *containers/storage/overlay*)   bhv5c11_rt="podman" ;;
        esac
      fi
      # C6: kubelet puts kubernetes.io~* in the mount root/source fields
      case "$mi_root $mi_rest" in
        *kubernetes.io~projected*|*kubernetes.io~configmap*|\
*kubernetes.io~secret*|*kubernetes.io~serviceaccount*)
          pv_total=$(( pv_total + 1 ))
          case "|$pv_paths|" in
            *"|$mi_mp|"*) : ;;                       # dedupe
            *)
              if [ "$pv_shown" -lt 3 ]; then
                pv_paths="${pv_paths:+$pv_paths }$mi_mp"
                pv_shown=$(( pv_shown + 1 ))
              fi
              ;;
          esac
          ;;
      esac
      # C6 fallback: SA bind mount without a kubernetes.io~ marker
      if [ -z "$pv_fb" ]; then
        case "$mi_mp" in
          /var/run/secrets/kubernetes.io/serviceaccount|\
/var/run/secrets/kubernetes.io/serviceaccount/*|\
/run/secrets/kubernetes.io/serviceaccount|\
/run/secrets/kubernetes.io/serviceaccount/*)
            pv_fb="$mi_mp" ;;
        esac
      fi
    done < /proc/self/mountinfo
  fi

  # container-ness may also follow from the parse itself
  if [ "$iscont" -eq 0 ]; then
    if [ -n "$bhv5c11_rt" ] || [ -n "$bhv5c11_orch" ] || [ "$pv_total" -gt 0 ]; then
      iscont=1
    fi
  fi
  [ "$iscont" -eq 1 ] || return 0

  # ---- C1c: sentinel / systemd-container fallbacks (specific markers win) ----
  if [ -z "$bhv5c11_rt" ] && [ -r /run/systemd/container ]; then
    local sc=""
    read -r sc < /run/systemd/container 2>/dev/null || sc=""
    sc="${sc//[[:space:]]/}"
    case "$sc" in
      docker)         bhv5c11_rt="docker" ;;
      containerd)     bhv5c11_rt="containerd" ;;
      crio)           bhv5c11_rt="cri-o" ;;
      podman)         bhv5c11_rt="podman" ;;
      lxc)            bhv5c11_rt="lxc" ;;
      systemd-nspawn) bhv5c11_rt="systemd-nspawn" ;;
    esac
  fi
  if [ -z "$bhv5c11_rt" ]; then
    [ -e /.dockerenv ] && bhv5c11_rt="docker"
    if [ -z "$bhv5c11_rt" ] && [ -e /run/.containerenv ]; then
      bhv5c11_rt="podman"
    fi
  fi

  BH_RT_NAME="$bhv5c11_rt"
  if [ -n "$bhv5c11_cid" ]; then
    BH_RT_CTR_ID="$bhv5c11_cid"
  else
    BH_RT_CTR_ID="id-unavailable"
  fi
  BH_POD_UID="$bhv5c11_poduid"

  # ---- C2: k8s namespace + cluster domain from /etc/resolv.conf ----
  # "search default.svc.cluster.local" -> ns=default domain=cluster.local;
  # corroborated by "options ndots:5" and the <name>-<5char> pod hostname.
  local rkw rt1 rt2 rt3 rt4 tok ns="" domain="" ndots=0 hpod=0 hn=""
  if [ -r /etc/resolv.conf ]; then
    while read -r rkw rt1 rt2 rt3 rt4 _ || [ -n "${rkw:-}" ]; do
      case "$rkw" in
        search)
          for tok in "$rt1" "$rt2" "$rt3" "$rt4"; do
            [ -n "$tok" ] || continue
            case "$tok" in
              *.svc.*)
                if [ -z "$ns" ]; then
                  ns="${tok%%.svc.*}"
                  domain="${tok#*.svc.}"
                fi
                ;;
            esac
          done
          ;;
        options)
          case " $rt1 $rt2 $rt3 $rt4 " in
            *" ndots:5 "*) ndots=1 ;;
          esac
          ;;
      esac
    done < /etc/resolv.conf
  fi
  # pod-style hostname (Deployment/RS suffix) corroborates the k8s context
  if [ -r /proc/sys/kernel/hostname ]; then
    read -r hn < /proc/sys/kernel/hostname 2>/dev/null || hn=""
  fi
  [ -n "$hn" ] || hn="${HOSTNAME:-}"
  local hre='^[a-z0-9]([-a-z0-9]*[a-z0-9])?-[a-z0-9]{5}$'
  if [[ "$hn" =~ $hre ]]; then hpod=1; fi

  # ---- C3: serviceaccount identity (token existence-check ONLY) ----
  local sadir="" sans="" tok_p="absent" ca_p="absent"
  if [ -d /var/run/secrets/kubernetes.io/serviceaccount ]; then
    sadir="/var/run/secrets/kubernetes.io/serviceaccount"
  elif [ -d /run/secrets/kubernetes.io/serviceaccount ]; then
    sadir="/run/secrets/kubernetes.io/serviceaccount"
  fi
  if [ -n "$sadir" ]; then
    if [ -r "$sadir/namespace" ]; then
      read -r sans < "$sadir/namespace" 2>/dev/null || sans=""
      sans="${sans%%[[:space:]]*}"          # trim trailing whitespace only
    fi
    [ -s "$sadir/token" ] && tok_p="present"    # NEVER read the token body
    [ -s "$sadir/ca.crt" ] && ca_p="present"
    BH_SA_TXT="ns=${sans:-unknown} token=$tok_p ca=$ca_p"
  fi

  # resolv.conf silent but the SA namespace file speaks: it is authoritative
  if [ -z "$ns" ] && [ -n "$sans" ]; then ns="$sans"; fi

  BH_K8S_NS="$ns"
  local kctx=""
  [ -n "$ns" ] && kctx="ns=$ns"
  [ -n "$domain" ] && kctx="${kctx:+$kctx }domain=$domain"
  BH_K8S_CTX="$kctx"

  # ---- C5: k8s service env keys (values are IP/port = safe to report) ----
  local envf="" kv ekey eval_ nsvc=0 khost="" kport="" envparts=""
  if [ -r /proc/1/environ ]; then
    envf="/proc/1/environ"
  elif [ -r /proc/self/environ ]; then
    envf="/proc/self/environ"
  fi
  if [ -n "$envf" ]; then
    while IFS= read -r -d '' kv || [ -n "$kv" ]; do
      case "$kv" in
        *=*) ekey="${kv%%=*}"; eval_="${kv#*=}" ;;
        *)   continue ;;
      esac
      case "$ekey" in
        KUBERNETES_SERVICE_HOST)
          case "$eval_" in
            ''|*[!0-9A-Fa-f.:]*) : ;;             # keep IPs only, never leak
            *) [ "${#eval_}" -le 45 ] && khost="$eval_" ;;
          esac
          ;;
        KUBERNETES_SERVICE_PORT)
          case "$eval_" in
            ''|*[!0-9]*) : ;;
            *) [ "${#eval_}" -le 5 ] && kport="$eval_" ;;
          esac
          ;;
        *_SERVICE_HOST)
          nsvc=$(( nsvc + 1 ))                    # key NAME count only
          ;;
      esac
    done < "$envf"
  fi
  [ -n "$khost" ] && envparts="KUBERNETES_SERVICE_HOST=$khost"
  [ -n "$kport" ] && envparts="${envparts:+$envparts }KUBERNETES_SERVICE_PORT=$kport"
  [ "$nsvc" -gt 0 ] && envparts="${envparts:+$envparts }svc_host_keys=$nsvc"
  BH_K8S_ENV_KEYS="$envparts"

  # ---- orchestrator corroboration from C2/C3/C5 evidence ----
  # ndots:5 + pod-style hostname together is weak-but-consistent k8s evidence
  # (the "boost" the resolv.conf/hostname probes exist for)
  if [ -z "$bhv5c11_orch" ]; then
    if [ -n "$sadir" ] || [ -n "$khost" ] || [ "$nsvc" -gt 0 ] || [ -n "$ns" ]; then
      bhv5c11_orch="kubernetes"
    elif [ "$ndots" -eq 1 ] && [ "$hpod" -eq 1 ]; then
      bhv5c11_orch="kubernetes"
    fi
  fi
  BH_ORCH="$bhv5c11_orch"

  # ---- C6 compose ----
  if [ "$pv_total" -gt 0 ]; then
    BH_PROJ_VOL="count=$pv_total paths=$pv_paths"
  elif [ -n "$pv_fb" ]; then
    BH_PROJ_VOL="count=1 paths=$pv_fb"
  fi

  # ---- C7: namespace fingerprint + pid-ns vs pid1 ----
  local n_pid n_mnt n_net n_uts n_ipc p1 pidns
  n_pid="$(bhv5c11_ns_inode /proc/self/ns/pid)"
  n_mnt="$(bhv5c11_ns_inode /proc/self/ns/mnt)"
  n_net="$(bhv5c11_ns_inode /proc/self/ns/net)"
  n_uts="$(bhv5c11_ns_inode /proc/self/ns/uts)"
  n_ipc="$(bhv5c11_ns_inode /proc/self/ns/ipc)"
  p1="$(bhv5c11_ns_inode /proc/1/ns/pid)"
  pidns="unknown"
  if [ -n "$n_pid" ] && [ -n "$p1" ]; then
    if [ "$n_pid" = "$p1" ]; then
      pidns="pid-ns shared with pid1"
    else
      pidns="nested pid-ns"
    fi
  fi
  if [ -n "$n_pid$n_mnt$n_net$n_uts$n_ipc" ]; then
    BH_NS_FP="pid=${n_pid:-?} mnt=${n_mnt:-?} net=${n_net:-?} uts=${n_uts:-?} ipc=${n_ipc:-?} ($pidns)"
  else
    BH_NS_FP="unknown"
  fi

  return 0
}
