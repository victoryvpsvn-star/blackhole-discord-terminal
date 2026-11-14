#!/usr/bin/env bash
# run-tests.sh — smoke tests for blackhole-vps-bench
# shellcheck disable=SC2015  # 'cmd && pass || flunk' is safe here: pass/flunk never fail
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
pass() { echo "PASS: $1"; }
flunk() { echo "FAIL: $1"; fail=1; }

echo "== 1. help =="
./bin/blackhole-vps-bench help >/dev/null 2>&1 && pass "help" || flunk "help"

echo "== 2. version =="
v="$(./bin/blackhole-vps-bench --version 2>/dev/null)"
case "$v" in *"blackhole-vps-bench v1."*) pass "version ($v)" ;; *) flunk "version ($v)" ;; esac

echo "== 3. detect mode =="
out="$(./bin/blackhole-vps-bench detect 2>/dev/null)"
printf '%s\n' "$out" | grep -q "Kind    :" && pass "detect kind" || flunk "detect kind"
printf '%s\n' "$out" | grep -q "Verdict :" && pass "detect verdict" || flunk "detect verdict"

echo "== 4. fast bench, no net, outputs =="
./bin/blackhole-vps-bench all --fast --no-net --json /tmp/bhvps_t.json --markdown /tmp/bhvps_t.md --output /tmp/bhvps_t.txt >/dev/null 2>&1 \
  && pass "bench exit 0" || flunk "bench exit 0"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; d=json.load(open("/tmp/bhvps_t.json")); assert d["virtualization"]["kind"]; assert d["score"]["max"]==700' \
    && pass "json schema" || flunk "json schema"
else
  grep -q '"virtualization"' /tmp/bhvps_t.json && pass "json looks present" || flunk "json"
fi
grep -q "BH-SCORE" /tmp/bhvps_t.txt && pass "text report" || flunk "text report"
grep -q "## Verdict" /tmp/bhvps_t.md && pass "markdown report" || flunk "markdown report"

echo "== 5. bundle build + smoke =="
./build.sh >/dev/null 2>&1 && pass "build.sh" || flunk "build.sh"
if [ -x dist/blackhole-vps-bench ]; then
  ./dist/blackhole-vps-bench detect >/dev/null 2>&1 && pass "bundle detect" || flunk "bundle detect"
  ./dist/blackhole-vps-bench --version >/dev/null 2>&1 && pass "bundle version" || flunk "bundle version"
else
  flunk "bundle missing"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED"
  exit 1
fi
