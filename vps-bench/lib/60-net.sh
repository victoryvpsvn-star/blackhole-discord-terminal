# =====================================================================
# blackhole-vps-bench · 60-net.sh — network benchmark (multi-endpoint)
# =====================================================================
# v3: download (best-of-N over verified endpoints) + upload + TCP connect
#     latency + optional ICMP latency/jitter. Skippable with --no-net.
# v4.0 (W3-J):
#   - This module OWNS egress identity: BH_IPV4 / BH_IPV6 / BH_IP_GEO /
#     BH_IP_ASN (moved out of 20-info.sh — bug G4: sec / --no-net mode must
#     stay 100% offline; everything below hard-skips when BH_NO_NET=1).
#   - Geo via ONE Cloudflare trace fetch (shared by all consumers):
#     ip / loc (country) / colo (datacenter airport code) ->
#     BH_GEO_LOC / BH_GEO_CLO / BH_NET_CLO (R5: report compares the claimed
#     geo vs the real exit colo).
#   - ASN via ipwho.is (grep/sed parsing, NO jq assumption):
#     BH_IP_ASN "AS16509 Amazon" style.
#   - N1 region TCP-connect latency matrix, 5 targets fully parallel:
#     BH_LAT_MATRIX="US:12 EU:145 Asia:230 AU:310 CF:2" ("--" when missing).
#   - N2 NAT/CGNAT verdict: BH_NAT_MODE (+ BH_NAT_IFACE / BH_NAT_SRC detail).
#   - N3 egress port reachability: BH_PORT_25/465/587/1194/51820 —
#     reachability labels ONLY (open/filtered/untestable), never claims like
#     "provider blocks". Gated by BH_PORT_PROBE (main sets 0 for --fast).
#   - N4 DNS speed: BH_DNS_MS (avg of 5 getent lookups, parallel) + BH_DNS_TAG.
#   - N5 NIC honesty: BH_NIC_DRIVER / BH_NIC_QUEUES / BH_NIC_OFFLOADS.
#   - N7 packet loss: BH_PACKET_LOSS (needs CAP_NET_RAW; else "n/a (no icmp)").
#   - N8 IPv6 grade: BH_IPV6_GRADE = native | address-only | none.
#   Runtime: all probes launch as ONE parallel background wave, so the added
#   wall time stays ~<=4 s on top of the classic download/upload bench.
# =====================================================================
# shellcheck shell=bash

# ------- classic bench globals (v3, unchanged) -------
BH_DOWN_MBPS=""; BH_UP_MBPS=""; BH_LAT_MS=""; BH_NET_METHOD=""
# winning endpoint label + compact per-attempt summary (v2.1)
BH_NET_ENDPOINT=""; BH_NET_TRIES=""
# ICMP latency + jitter (v2) — empty when ping is unavailable/blocked
BH_LAT_ICMP=""; BH_LAT_JITTER=""; BH_LAT_TARGET=""

# ------- v4.0 globals (this module owns them; "" = not measured) -------
# egress identity (was 20-info's; bug G4 ownership move)
BH_IPV4=""; BH_IPV6=""; BH_IP_GEO=""; BH_IP_ASN=""
# Cloudflare trace: country + exit colo (geo AND region-truth share one fetch)
BH_GEO_LOC=""; BH_GEO_CLO=""; BH_NET_CLO=""
# N1: region TCP-connect latency matrix (ms ints, "--" = missing)
BH_LAT_MATRIX=""
# N2: NAT/CGNAT verdict + raw detail for the report layer
BH_NAT_MODE=""; BH_NAT_IFACE=""; BH_NAT_SRC=""
# N3: egress port reachability
BH_PORT_25=""; BH_PORT_465=""; BH_PORT_587=""; BH_PORT_1194=""; BH_PORT_51820=""
# N4: DNS resolver speed (avg ms) + tag ("stub" for loopback resolvers)
BH_DNS_MS=""; BH_DNS_TAG=""
# N5: NIC honesty
BH_NIC_DRIVER=""; BH_NIC_QUEUES=""; BH_NIC_OFFLOADS=""
# N7: packet loss (ICMP)
BH_PACKET_LOSS=""
# N8: IPv6 grade
BH_IPV6_GRADE=""

# bh_dl_try URL MAXTIME — one download attempt; prints the curl -w triple
# "speed size http_code" (speed in bytes/s, size in bytes). Empty on hard fail.
bh_dl_try() {
  curl -sL -o /dev/null --max-time "$2" -w '%{speed_download} %{size_download} %{http_code}' "$1" 2>/dev/null
}

# bh_tcp_probe HOST PORT [TIMEOUT_S] — rc 0 when a TCP connection was
# established within TIMEOUT seconds. Hard no-op-fail when BH_NO_NET=1.
# Uses timeout(1) when present, else a self-kill watchdog (busybox-safe).
bh_tcp_probe() {
  [ "${BH_NO_NET:-0}" = "1" ] && return 1
  local h="$1" p="$2" t="${3:-2}" pid wd rc
  if command_exists timeout; then
    timeout "$t" bash -c "exec 3<>/dev/tcp/$h/$p" >/dev/null 2>&1
    return $?
  fi
  bash -c "exec 3<>/dev/tcp/$h/$p" >/dev/null 2>&1 &
  pid="$!"
  ( sleep "$t" 2>/dev/null; kill -9 "$pid" 2>/dev/null ) &
  wd="$!"
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  return "$rc"
}

# bh_ip4_scope IP — classify an IPv4: 10 | 172 | 192 (RFC1918), cgnat
# (100.64/10, RFC6598), public, invalid. Pure awk, no subprocess pid cost.
bh_ip4_scope() {
  awk -v ip="$1" 'BEGIN{
    n = split(ip, o, ".")
    if (n != 4) { print "invalid"; exit }
    for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || o[i]+0 > 255) { print "invalid"; exit }
    v = (o[1]+0)*16777216 + (o[2]+0)*65536 + (o[3]+0)*256 + (o[4]+0)
    if      (v >= 167772160  && v <= 184549375)  print "10"      # 10.0.0.0/8
    else if (v >= 2886729728 && v <= 2887778303) print "172"     # 172.16/12
    else if (v >= 3232235520 && v <= 3232301055) print "192"     # 192.168/16
    else if (v >= 1681915904 && v <= 1686110207) print "cgnat"   # 100.64/10
    else print "public"
  }'
}

# bh_default_iface — resolve the default-route interface + its source IP.
# Prints "<iface> <src>" (either may be empty). Skips overlay/virtual ifaces.
bh_default_iface() {
  local rl dev src d
  dev=""; src=""
  if command_exists ip; then
    rl="$(ip -4 route get 1.1.1.1 2>/dev/null)"
    dev="$(printf '%s\n' "$rl" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
    src="$(printf '%s\n' "$rl" | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  fi
  if [ -z "$dev" ] || [ -z "$src" ]; then
    # fallback: first sane iface + first hostname -I address
    if [ -z "$dev" ]; then
      for d in /sys/class/net/*; do
        [ -d "$d" ] || continue
        d="${d##*/}"
        case "$d" in
          lo|veth*|cni*|br-*|tailscale*|cali*|docker*) continue ;;
        esac
        dev="$d"; break
      done
    fi
    [ -n "$src" ] || src="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s %s' "${dev:-}" "${src:-}"
}

# bh_v6_global_addr — true when /proc/net/if_inet6 has a global-scope
# (scope 00) address on a non-lo interface. Pure local read, no network.
bh_v6_global_addr() {
  local d ifc idx
  for d in /sys/class/net/*; do
    [ -d "$d" ] || continue
    ifc="${d##*/}"
    [ "$ifc" = "lo" ] && continue
    idx="$(cat "$d/ifindex" 2>/dev/null)"
    [ -n "$idx" ] || continue
    if awk -v idx="$idx" '$2 == idx && $4 == "00" { f = 1 } END { exit !f }' /proc/net/if_inet6 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# bh_who_str FIELD JSON — extract a JSON string field with grep/sed ONLY
# (no jq assumption). Tolerates both pretty-printed ("field": "x") and
# compact ("field":"x") JSON. Empty when the field is absent or null.
bh_who_str() {
  printf '%s' "$2" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n 1 \
    | sed "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//;s/\"$//"
}

bench_net() {
  if [ "$BH_NO_NET" = "1" ]; then
    log "NET bench skipped (--no-net)"
    return 0
  fi
  if ! command_exists curl; then
    warn "curl not found — network bench skipped"
    return 0
  fi

  # ================================================================
  # v4.0 PARALLEL PROBE WAVE — every probe below is a background job
  # writing into $BH_RUNDIR; one `wait`, then parse. This keeps the
  # added wall time at ~max(per-probe timeout), not the sum.
  # ================================================================
  log "NET bench: identity/geo probes + region matrix (parallel wave)..."

  # --- A. TCP connect latency (v3 behaviour, unchanged semantics) ---
  (
    lat="$(curl -s -o /dev/null --max-time 8 -w '%{time_connect}' 'https://speed.cloudflare.com/__down?bytes=0' 2>/dev/null)"
    if [ -z "$lat" ] || [ "$lat" = "0.000000" ]; then
      lat="$(curl -s -o /dev/null --max-time 8 -w '%{time_starttransfer}' 'https://speed.cloudflare.com/__down?bytes=1' 2>/dev/null)"
    fi
    printf '%s' "$lat" > "$BH_RUNDIR/net_lat" 2>/dev/null
  ) &

  # --- B. ICMP latency + jitter (v3 behaviour; needs CAP_NET_RAW) ---
  (
    : > "$BH_RUNDIR/net_ping" 2>/dev/null
    for tgt in 1.1.1.1 8.8.8.8; do
      if ping -c 4 -W 2 -q "$tgt" > "$BH_RUNDIR/net_ping" 2>/dev/null \
         && grep -qE 'rtt|round-trip' "$BH_RUNDIR/net_ping" 2>/dev/null; then
        printf '%s' "$tgt" > "$BH_RUNDIR/net_ping_tgt" 2>/dev/null
        break
      fi
    done
  ) &

  # --- C. N7 packet loss (skipped on --fast; preflight = CAP_NET_RAW test) ---
  if [ "$BH_FAST" != "1" ] && command_exists ping; then
    (
      if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
        ping -c 5 -i 0.2 -W 1 1.1.1.1 > "$BH_RUNDIR/net_loss" 2>/dev/null
      fi
    ) &
  fi

  # --- D-G. egress identity: ipv4 / ipv6 / CF trace (ONE fetch) / ipwho.is ---
  curl -sL --max-time 3 'https://api.ipify.org' > "$BH_RUNDIR/net_geo4" 2>/dev/null &
  curl -6 -sL --max-time 2 'https://api64.ipify.org' > "$BH_RUNDIR/net_geo6" 2>/dev/null &
  curl -sL --max-time 3 'https://www.cloudflare.com/cdn-cgi/trace' > "$BH_RUNDIR/net_trace" 2>/dev/null &
  curl -sL --max-time 3 'https://ipwho.is/' > "$BH_RUNDIR/net_who" 2>/dev/null &

  # --- H-L. N1 region TCP-connect latency matrix (skip on --fast) ---
  # 404/redirect bodies are fine: only %{time_connect} (TCP) matters.
  if [ "$BH_FAST" != "1" ]; then
    (
      curl -o /dev/null -s -m 2 -w '%{time_connect}' 'https://download.thinkbroadband.com/' > "$BH_RUNDIR/m.US" 2>/dev/null
    ) &
    (
      curl -o /dev/null -s -m 2 -w '%{time_connect}' 'https://nbg1-speed.hetzner.com/' > "$BH_RUNDIR/m.EU" 2>/dev/null
    ) &
    (
      curl -o /dev/null -s -m 2 -w '%{time_connect}' 'https://ftp.jaist.ac.jp/' > "$BH_RUNDIR/m.Asia" 2>/dev/null
    ) &
    (
      curl -o /dev/null -s -m 2 -w '%{time_connect}' 'https://mirror.aarnet.edu.au/' > "$BH_RUNDIR/m.AU" 2>/dev/null
    ) &
    (
      curl -o /dev/null -s -m 2 -w '%{time_connect}' 'https://1.1.1.1/' > "$BH_RUNDIR/m.CF" 2>/dev/null
    ) &
  fi

  # --- M. N4 DNS speed: 5 lookups in parallel (skips itself w/o getent) ---
  (
    ns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)"
    [ -n "$ns" ] || exit 0
    printf '%s' "$ns" > "$BH_RUNDIR/dns_ns" 2>/dev/null
    command_exists getent || exit 0
    i=0
    for h in google.com cloudflare.com github.com wikipedia.org archive.org; do
      i=$((i + 1))
      (
        t0=$(now_ms)
        timeout 2 getent hosts "$h" >/dev/null 2>&1
        rc=$?
        t1=$(now_ms)
        printf '%s %s\n' "$rc" "$((t1 - t0))" > "$BH_RUNDIR/dns.$i" 2>/dev/null
      ) &
    done
    wait
  ) &

  # --- N. N3 egress port reachability (control probe gates the rest) ---
  # Reachability ONLY: "open" = TCP connect ok, "filtered" = no connect
  # within 2 s, "untestable" = the control probe itself failed. Never
  # claim intent ("provider blocks") — a DROP and a REJECT look the same.
  if [ "${BH_PORT_PROBE:-1}" = "1" ]; then
    (
      if bh_tcp_probe 1.1.1.1 443 2; then
        for spec in "smtp.gmail.com 25 p25" "smtp.gmail.com 465 p465" \
                    "smtp.gmail.com 587 p587" "portquiz.net 1194 p1194" \
                    "portquiz.net 51820 p51820"; do
          # shellcheck disable=SC2086  # fixed 3-field spec, word-split on purpose
          set -- $spec
          (
            if bh_tcp_probe "$1" "$2" 2; then printf 'open\n'
            else printf 'filtered\n'; fi
          ) > "$BH_RUNDIR/$3" 2>/dev/null &
        done
        wait
      else
        for n in p25 p465 p587 p1194 p51820; do
          printf 'untestable\n' > "$BH_RUNDIR/$n" 2>/dev/null
        done
      fi
    ) &
  fi

  wait   # ------- end of parallel wave -------

  # ================================================================
  # PARSE WAVE RESULTS (all local, instant)
  # ================================================================

  # ---- A. TCP connect latency ----
  local lat
  lat="$(cat "$BH_RUNDIR/net_lat" 2>/dev/null)"
  [ -n "$lat" ] && [ "$lat" != "0.000000" ] && \
    BH_LAT_MS="$(awk -v t="$lat" 'BEGIN{ if (t+0>0) printf "%.1f", t*1000; else print 0 }')"

  # ---- B. ICMP latency + jitter ----
  if [ -s "$BH_RUNDIR/net_ping_tgt" ]; then
    local pout
    pout="$(cat "$BH_RUNDIR/net_ping" 2>/dev/null)"
    # stats line is "rtt min/avg/max/mdev = a/b/c/d ms" (iputils, 4 values)
    # or "round-trip min/avg/max = a/b/c ms" (busybox, 3 values, no mdev).
    BH_LAT_ICMP="$(printf '%s\n' "$pout" | awk '/rtt|round-trip/{ if (match($0, /[0-9.]+\/[0-9.]+\/[0-9.]+/)) { split(substr($0, RSTART, RLENGTH), a, "/"); printf "%.1f", a[2] } exit }')"
    BH_LAT_JITTER="$(printf '%s\n' "$pout" | awk '/rtt|round-trip/{ if (match($0, /[0-9.]+\/[0-9.]+\/[0-9.]+\/[0-9.]+/)) { split(substr($0, RSTART, RLENGTH), a, "/"); printf "%.1f", a[4] } exit }')"
    BH_LAT_TARGET="$(cat "$BH_RUNDIR/net_ping_tgt" 2>/dev/null)"
  fi

  # ---- C. packet loss ----
  if [ -s "$BH_RUNDIR/net_loss" ]; then
    local ploss
    ploss="$(sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p' "$BH_RUNDIR/net_loss" 2>/dev/null | tail -n 1)"
    [ -n "$ploss" ] && BH_PACKET_LOSS="${ploss}%"
  fi
  [ -z "$BH_PACKET_LOSS" ] && BH_PACKET_LOSS="n/a (no icmp)"

  # ---- D-G. geo / identity ----
  # CF trace (ONE fetch, shared by geo + region-truth):
  #   ip=1.2.3.4 / colo=IAD / loc=US
  local tr tline tr_ip="" tr_loc="" tr_colo="" who_cc="" who_city="" \
          who_asn="" who_isp="" who_org="" short="" g=""
  # cat(1) with 2>/dev/null (NOT a bare '<' redirect): a missing file must
  # stay silent — bash would print a redirect error to stderr otherwise.
  tr="$(tr -d '\r' < "$BH_RUNDIR/net_trace" 2>/dev/null)"
  while IFS= read -r tline; do
    case "$tline" in
      ip=*)   tr_ip="${tline#ip=}" ;;
      loc=*)  tr_loc="${tline#loc=}" ;;
      colo=*) tr_colo="${tline#colo=}" ;;
    esac
  done <<EOF
$tr
EOF
  case "$tr_ip" in ''|*[!0-9.]*) tr_ip="" ;; esac          # v4-only field
  case "$tr_loc" in ''|*[!A-Za-z]*) tr_loc="" ;; esac
  case "$tr_colo" in ''|*[!A-Za-z0-9]*) tr_colo="" ;; esac

  # ipwho.is (grep/sed — no jq): country_code / city / connection.asn+isp
  # NOTE: the service pretty-prints ("asn": 45102) so patterns must allow
  # optional whitespace between ':' and the value.
  local w
  w="$(cat "$BH_RUNDIR/net_who" 2>/dev/null)"
  if [ -n "$w" ]; then
    who_cc="$(bh_who_str country_code "$w")"
    who_city="$(bh_who_str city "$w")"
    who_asn="$(printf '%s' "$w" | grep -o '"asn"[[:space:]]*:[[:space:]]*[0-9][0-9]*' | head -n 1 | tr -dc '0-9')"
    who_isp="$(bh_who_str isp "$w")"
    who_org="$(bh_who_str org "$w")"
  fi

  # BH_IPV4: ipify primary, CF-trace ip as fallback (shared fetch)
  local v4 v6
  v4="$(tr -d ' \t\n\r' < "$BH_RUNDIR/net_geo4" 2>/dev/null)"
  case "$v4" in *[!0-9.]*) v4="" ;; esac
  [ -z "$v4" ] && v4="$tr_ip"
  [ -n "$v4" ] && BH_IPV4="$v4"

  # BH_IPV6: ipify over -6 only; empty when the box has no v6 egress
  v6="$(tr -d ' \t\n\r' < "$BH_RUNDIR/net_geo6" 2>/dev/null)"
  case "$v6" in *:*) case "$v6" in *[!0-9a-fA-F:.]*) v6="" ;; esac ;; *) v6="" ;; esac
  [ -n "$v6" ] && BH_IPV6="$v6"

  # BH_GEO_* + BH_NET_CLO (R5): same trace fetch feeds both
  [ -n "$tr_colo" ] && { BH_GEO_CLO="$tr_colo"; BH_NET_CLO="$tr_colo"; }
  [ -n "$tr_loc" ]  && BH_GEO_LOC="$tr_loc"

  # BH_IP_ASN "AS16509 Amazon" style — short ISP = first word of isp/org
  short="$who_isp"
  if [ -z "$short" ] && [ -n "$who_org" ]; then
    case "$who_org" in
      AS[0-9]*" "*) short="${who_org#* }" ;;
      *)            short="$who_org" ;;
    esac
  fi
  short="${short%% *}"; short="${short%%.*}"; short="${short%%,*}"
  if [ -n "$who_asn" ]; then
    BH_IP_ASN="AS$who_asn${short:+ $short}"
  fi

  # BH_IP_GEO human string: "US / Ashburn (colo IAD)"
  g="$BH_GEO_LOC"
  [ -z "$g" ] && g="$who_cc"
  [ -n "$g" ] && [ -n "$who_city" ] && g="$g / $who_city"
  [ -n "$BH_GEO_CLO" ] && g="$g (colo $BH_GEO_CLO)"
  BH_IP_GEO="$g"

  # ---- N1: latency matrix ----
  if [ "$BH_FAST" != "1" ]; then
    local mk mv mout mx=""
    for mk in US EU Asia AU CF; do
      mout="--"
      mv="$(cat "$BH_RUNDIR/m.$mk" 2>/dev/null)"
      if [ -n "$mv" ] && [ "$mv" != "0.000000" ]; then
        case "$mv" in
          *[!0-9.]*) mv="" ;;
          *)         mout="$(awk -v t="$mv" 'BEGIN{ printf "%.0f", t*1000 }')" ;;
        esac
      fi
      mx="$mx $mk:$mout"
    done
    BH_LAT_MATRIX="${mx# }"
  fi

  # ---- N4: DNS speed + tag ----
  local dns_ns line drc dms dsum=0 dn=0 dok=0 di
  dns_ns="$(cat "$BH_RUNDIR/dns_ns" 2>/dev/null)"
  if [ -n "$dns_ns" ]; then
    case "$dns_ns" in
      127.*|::1) BH_DNS_TAG="stub" ;;
      *)         BH_DNS_TAG="resolver" ;;
    esac
    for di in 1 2 3 4 5; do
      line="$(cat "$BH_RUNDIR/dns.$di" 2>/dev/null)"
      [ -n "$line" ] || continue
      drc="${line%% *}"; dms="${line##* }"
      case "$dms" in ''|*[!0-9]*) continue ;; esac
      dsum=$((dsum + dms)); dn=$((dn + 1))
      [ "$drc" = "0" ] && dok=$((dok + 1))
    done
    # avg over all attempts (a timing-out lookup IS the resolver's real
    # behaviour); meaningless when every lookup failed -> ""
    if [ "$dn" -gt 0 ] && [ "$dok" -gt 0 ]; then BH_DNS_MS=$((dsum / dn)); fi
  fi

  # ---- N2: NAT / CGNAT verdict (needs BH_IPV4, fetched above) ----
  local di_dev di_src dcls
  # shellcheck disable=SC2046  # intentional split: "<dev> <src>"
  set -- $(bh_default_iface)
  di_dev="${1:-}"; di_src="${2:-}"
  BH_NAT_IFACE="$di_dev"; BH_NAT_SRC="$di_src"
  case "$di_dev" in
    ""|lo|veth*|cni*|br-*|tailscale*|cali*|docker*)
      BH_NAT_MODE="unknown" ;;
    *)
      if [ -z "$di_src" ] || [ -z "$BH_IPV4" ]; then
        BH_NAT_MODE="unknown"
      elif [ "$di_src" = "$BH_IPV4" ]; then
        BH_NAT_MODE="public-ip"
      else
        dcls="$(bh_ip4_scope "$di_src")"
        case "$dcls" in
          # 100.64/10 on the iface = carrier-grade NAT (definitive)
          cgnat) BH_NAT_MODE="cgnat (rfc1918 iface, distinct egress)" ;;
          # anything else on the iface (RFC1918 or a second public IP)
          # that differs from the real egress = NAT'd, show the values
          *) BH_NAT_MODE="nat (iface $di_src ≠ egress $BH_IPV4)" ;;
        esac
      fi ;;
  esac

  # ---- N5: NIC honesty (same default iface as the NAT verdict) ----
  if [ -n "$di_dev" ]; then
    local drv off
    drv="$(readlink "/sys/class/net/$di_dev/device/driver" 2>/dev/null)"
    BH_NIC_DRIVER="${drv##*/}"
    [ -z "$BH_NIC_DRIVER" ] && BH_NIC_DRIVER="unknown"
    local qn=0 q
    for q in /sys/class/net/"$di_dev"/queues/rx-*; do
      [ -d "$q" ] || continue
      qn=$((qn + 1))
    done
    BH_NIC_QUEUES="$qn"
    if command_exists ethtool; then
      off="$(ethtool -k "$di_dev" 2>/dev/null)"
      if [ -n "$off" ]; then
        BH_NIC_OFFLOADS="$(printf '%s\n' "$off" | awk '
          /^tcp-segmentation-offload:/     { t = $NF }
          /^generic-segmentation-offload:/ { s = $NF }
          /^generic-receive-offload:/      { r = $NF }
          END {
            o = ""
            if (t != "") o = "tso:" t
            if (s != "") o = o (o != "" ? " " : "") "gso:" s
            if (r != "") o = o (o != "" ? " " : "") "gro:" r
            print o
          }')"
      fi
    fi
    [ -z "$BH_NIC_OFFLOADS" ] && BH_NIC_OFFLOADS="unknown"
  else
    BH_NIC_DRIVER="unknown"; BH_NIC_QUEUES=""; BH_NIC_OFFLOADS="unknown"
  fi

  # ---- N8: IPv6 grade (global addr in if_inet6 + real v6 egress) ----
  if bh_v6_global_addr; then
    if [ -n "$BH_IPV6" ]; then BH_IPV6_GRADE="native"
    else BH_IPV6_GRADE="address-only"; fi
  else
    BH_IPV6_GRADE="none"
  fi

  # ---- N3: read port-probe results (files exist only when probed) ----
  local pfile pval pf
  for pfile in "25:p25" "465:p465" "587:p587" "1194:p1194" "51820:p51820"; do
    pf="${pfile#*:}"
    pval=""
    [ -r "$BH_RUNDIR/$pf" ] && \
      pval="$(tr -d ' \t\n\r' < "$BH_RUNDIR/$pf" 2>/dev/null)"
    case "$pval" in
      open|filtered|untestable) : ;;
      *) pval="" ;;
    esac
    case "${pfile%%:*}" in
      25)    BH_PORT_25="$pval" ;;
      465)   BH_PORT_465="$pval" ;;
      587)   BH_PORT_587="$pval" ;;
      1194)  BH_PORT_1194="$pval" ;;
      51820) BH_PORT_51820="$pval" ;;
    esac
  done

  # ================================================================
  # CLASSIC BENCH (v3, unchanged): download best-of-N + upload
  # ================================================================

  # ------- download: best-of-N over verified endpoints -------
  # Cloudflare now REJECTS __down?bytes>50MB with HTTP 403 and cachefly's
  # 100mb.test shrank to a 25-byte stub, so measure several known-good
  # files and keep the fastest. An attempt only counts with http_code
  # 200/206 and speed > 0. The first (biggest) payload is trusted once it
  # took >= 2.0 s to transfer; a faster finish (or any failure) means the
  # link outran the file, so the whole fallback chain runs and the max wins.
  local dl_chain dl_label dl_url dl_maxtime
  local d_out d_speed d_size d_code d_mbps d_secs
  local best_mbps="" tries="" n_tries=0 early_stop=1
  if [ "$BH_FAST" = "1" ]; then
    dl_chain="cloudflare-10MB|https://speed.cloudflare.com/__down?bytes=10485760|20
ovh|https://proof.ovh.net/files/100Mb.dat|15"
    log "NET bench: download (fast profile: cloudflare 10 MB, then ovh)..."
  else
    dl_chain="cloudflare-50MB|https://speed.cloudflare.com/__down?bytes=52428800|45
ovh|https://proof.ovh.net/files/100Mb.dat|30
hetzner-nbg1|https://nbg1-speed.hetzner.com/100MB.bin|30
thinkbroadband|http://ipv4.download.thinkbroadband.com/100MB.zip|30"
    log "NET bench: download (best-of-4 verified endpoints)..."
  fi
  while IFS='|' read -r dl_label dl_url dl_maxtime; do
    [ -n "$dl_label" ] || continue
    n_tries=$((n_tries + 1))
    d_mbps=""
    d_out="$(bh_dl_try "$dl_url" "$dl_maxtime")"
    d_speed=""; d_size=""; d_code=""
    # shellcheck disable=SC2086  # word-split on purpose: "speed size code"
    set -- $d_out
    d_speed="${1:-}"; d_size="${2:-}"; d_code="${3:-}"
    case "$d_code" in
      200|206)
        if [ -n "$d_speed" ] && [ -n "$d_size" ] && awk -v s="$d_speed" 'BEGIN{exit !(s+0>0)}'; then
          d_mbps="$(awk -v s="$d_speed" 'BEGIN{printf "%.1f", s*8/1000000}')"
        fi
        ;;
    esac
    if [ -n "$d_mbps" ]; then
      d_secs="$(awk -v s="$d_speed" -v z="$d_size" 'BEGIN{ if (s+0>0) printf "%.2f", z/s; else print 0 }')"
      tries="$tries $dl_label:${d_mbps}Mbps"
      if [ -z "$best_mbps" ] || awk -v b="$best_mbps" -v v="$d_mbps" 'BEGIN{exit !(v+0>b+0)}'; then
        best_mbps="$d_mbps"
        BH_NET_ENDPOINT="$dl_label"
        BH_NET_METHOD="$dl_label"
      fi
      # only the FIRST attempt may short-circuit the chain (payload took
      # >= 2.0 s); otherwise every remaining endpoint runs, max wins
      if [ "$early_stop" = "1" ] && [ "$n_tries" = "1" ] && awk -v t="$d_secs" 'BEGIN{exit !(t+0>=2.0)}'; then
        break
      fi
    else
      tries="$tries $dl_label:fail"
    fi
  done <<EOF
$dl_chain
EOF
  [ "$n_tries" -le 1 ] && tries=""   # single attempt = nothing to compare
  BH_NET_TRIES="${tries# }"
  BH_DOWN_MBPS="$best_mbps"
  [ -z "$BH_NET_METHOD" ] && BH_NET_METHOD="none"

  # ------- upload: Cloudflare __up (verified working) -------
  # Stage the payload on disk instead of piping from head — the pipe form
  # is not busybox-safe and can stall on tiny busyboxes.
  # Early-stop applies to BOTH profiles: the first attempt short-circuits the
  # chain only when its payload took >= 2.0 s (link not faster than the file);
  # a faster finish (or any failure) runs the whole chain and the max wins.
  # This bounds the fast profile to ~35 s of download worst case.
  local ubytes=26214400 ul_max=60
  [ "$BH_FAST" = "1" ] && { ubytes=10485760; ul_max=30; }
  log "NET bench: upload ($((ubytes / 1048576)) MB to cloudflare)..."
  local upfile="$BH_RUNDIR/up.bin"
  dd if=/dev/zero of="$upfile" bs=1M count=$((ubytes / 1048576)) 2>/dev/null
  local u
  u="$(curl -s -o /dev/null --max-time "$ul_max" -w '%{speed_upload}' -X POST --data-binary @"$upfile" 'https://speed.cloudflare.com/__up' 2>/dev/null)"
  rm -f "$upfile" 2>/dev/null
  [ -n "$u" ] && [ "$u" != "0" ] && BH_UP_MBPS="$(awk -v s="$u" 'BEGIN{printf "%.1f", s*8/1000000}')"

  return 0
}
