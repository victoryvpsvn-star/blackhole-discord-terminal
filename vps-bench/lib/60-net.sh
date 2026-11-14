# =====================================================================
# blackhole-vps-bench · 60-net.sh — network benchmark (multi-endpoint)
# Download (best-of-N over verified endpoints) + upload + TCP connect
# latency. Skippable with --no-net.
# =====================================================================
# shellcheck shell=bash

BH_DOWN_MBPS=""; BH_UP_MBPS=""; BH_LAT_MS=""; BH_NET_METHOD=""
# winning endpoint label + compact per-attempt summary (v2.1)
BH_NET_ENDPOINT=""; BH_NET_TRIES=""
# ICMP latency + jitter (v2) — empty when ping is unavailable/blocked
BH_LAT_ICMP=""; BH_LAT_JITTER=""; BH_LAT_TARGET=""

# bh_dl_try URL MAXTIME — one download attempt; prints the curl -w triple
# "speed size http_code" (speed in bytes/s, size in bytes). Empty on hard fail.
bh_dl_try() {
  curl -sL -o /dev/null --max-time "$2" -w '%{speed_download} %{size_download} %{http_code}' "$1" 2>/dev/null
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

  # TCP connect latency (TTFB fallback)
  local lat
  lat="$(curl -s -o /dev/null --max-time 8 -w '%{time_connect}' 'https://speed.cloudflare.com/__down?bytes=0' 2>/dev/null)"
  if [ -z "$lat" ] || [ "$lat" = "0.000000" ]; then
    lat="$(curl -s -o /dev/null --max-time 8 -w '%{time_starttransfer}' 'https://speed.cloudflare.com/__down?bytes=1' 2>/dev/null)"
  fi
  [ -n "$lat" ] && BH_LAT_MS="$(awk -v t="$lat" 'BEGIN{ if (t+0>0) printf "%.1f", t*1000; else print 0 }')"

  # ICMP latency + jitter (v2): ping needs CAP_NET_RAW — often absent in
  # containers, so this stays optional and the TCP number above remains.
  if command_exists ping; then
    local tgt out
    for tgt in 1.1.1.1 8.8.8.8; do
      if out="$(ping -c 4 -W 2 -q "$tgt" 2>/dev/null)" && printf '%s\n' "$out" | grep -qE 'rtt|round-trip'; then
        # stats line is "rtt min/avg/max/mdev = a/b/c/d ms" (iputils, 4 values)
        # or "round-trip min/avg/max = a/b/c ms" (busybox, 3 values, no mdev).
        # Parse positionally AFTER '=' — with -F'/' the fixed fields $5/$6 are
        # avg/max on iputils but avg lands in $4 on busybox, and mdev is $7.
        BH_LAT_ICMP="$(printf '%s\n' "$out" | awk '/rtt|round-trip/{ if (match($0, /[0-9.]+\/[0-9.]+\/[0-9.]+/)) { split(substr($0, RSTART, RLENGTH), a, "/"); printf "%.1f", a[2] } exit }')"
        BH_LAT_JITTER="$(printf '%s\n' "$out" | awk '/rtt|round-trip/{ if (match($0, /[0-9.]+\/[0-9.]+\/[0-9.]+\/[0-9.]+/)) { split(substr($0, RSTART, RLENGTH), a, "/"); printf "%.1f", a[4] } exit }')"
        BH_LAT_TARGET="$tgt"
        break
      fi
    done
  fi

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
