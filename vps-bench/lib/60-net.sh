# =====================================================================
# blackhole-vps-bench · 60-net.sh — network benchmark (Cloudflare speed)
# Download + upload + TCP connect latency. Skippable with --no-net.
# =====================================================================
# shellcheck shell=bash

BH_DOWN_MBPS=""; BH_UP_MBPS=""; BH_LAT_MS=""; BH_NET_METHOD=""

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

  # download
  local dbytes=104857600 dmethod="cloudflare"
  [ "$BH_FAST" = "1" ] && dbytes=26214400
  log "NET bench: download ($((dbytes / 1048576)) MB from ${dmethod})..."
  local d
  d="$(curl -s -o /dev/null --max-time 60 -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=$dbytes" 2>/dev/null)"
  if [ -z "$d" ] || [ "$d" = "0" ] || [ "$d" = "0.000" ]; then
    dmethod="cachefly"
    d="$(curl -s -o /dev/null --max-time 60 -w '%{speed_download}' 'http://cachefly.cachefly.net/100mb.test' 2>/dev/null)"
  fi
  [ -n "$d" ] && [ "$d" != "0" ] && BH_DOWN_MBPS="$(awk -v s="$d" 'BEGIN{printf "%.1f", s*8/1000000}')"
  BH_NET_METHOD="$dmethod"

  # upload
  local ubytes=26214400
  [ "$BH_FAST" = "1" ] && ubytes=10485760
  log "NET bench: upload ($((ubytes / 1048576)) MB to cloudflare)..."
  local u
  u="$(head -c "$ubytes" /dev/zero | curl -s -o /dev/null --max-time 60 -w '%{speed_upload}' -X POST --data-binary @- 'https://speed.cloudflare.com/__up' 2>/dev/null)"
  [ -n "$u" ] && [ "$u" != "0" ] && BH_UP_MBPS="$(awk -v s="$u" 'BEGIN{printf "%.1f", s*8/1000000}')"

  return 0
}
