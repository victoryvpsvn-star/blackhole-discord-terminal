# =====================================================================
# blackhole-vps-bench · 62-net-extra.sh — TLS handshake latency (v5)
# =====================================================================
# BH_TLS_MS: the TLS-over-TCP overhead a visitor pays per connection.
# 5 PARALLEL curl runs to speed.cloudflare.com (each capped at 2 s);
# per-run TLS = time_appconnect - time_connect. Runs with
# appconnect == 0 (TLS never completed) are discarded; "" when fewer
# than 2 valid runs remain. BH_NO_NET=1 -> skipped entirely.
# shellcheck shell=bash

BH_TLS_MS=""    # mean TLS handshake ms (1 decimal float); "" = not measured

bench_net_extra() {
  BH_TLS_MS=""
  [ "${BH_NO_NET:-0}" = "1" ] && return 0
  command_exists curl || return 0
  local d="$BH_RUNDIR" i
  mkdir -p "$d" 2>/dev/null || return 0
  i=0
  while [ "$i" -lt 5 ]; do
    i=$((i + 1))
    (
      curl -s -o /dev/null --max-time 2 -w '%{time_connect} %{time_appconnect}\n' \
        'https://speed.cloudflare.com/__down?bytes=0' > "$d/c13_tls.$i" 2>/dev/null
    ) &
  done
  wait
  BH_TLS_MS="$(cat "$d"/c13_tls.[1-5] 2>/dev/null | awk '
    NF == 2 && $1 + 0 > 0 && $2 + 0 > $1 + 0 {
      s += ($2 - $1) * 1000; n++
    }
    END {
      if (n >= 2) printf "%.1f", s / n
    }')"
  return 0
}
