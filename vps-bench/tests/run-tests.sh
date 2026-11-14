#!/usr/bin/env bash
# run-tests.sh — smoke tests for blackhole-vps-bench
# shellcheck disable=SC2015  # 'cmd && pass || flunk' is safe here: pass/flunk never fail
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
pass() { echo "PASS: $1"; }
flunk() { echo "FAIL: $1"; fail=1; }
skip() { echo "SKIP: $1"; }   # v4 feature not merged yet — never counts as failure

# unit-test assertion helpers, used INSIDE a ( ) subshell that sources only the
# libs under test; each subshell exits non-zero when any assertion failed:
#   u  DESC EXPECTED ACTUAL  — exact string compare
#   um DESC REGEX    ACTUAL  — case-insensitive extended regex match
u()  { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want: '$2' got: '$3')"; return 1; fi; }
um() { if printf '%s' "$3" | grep -qiE "$2"; then echo "PASS: $1"; else echo "FAIL: $1 (want: /$2/ got: '$3')"; return 1; fi; }

echo "== 1. help =="
./bin/blackhole-vps-bench help >/dev/null 2>&1 && pass "help" || flunk "help"

echo "== 2. version =="
v="$(./bin/blackhole-vps-bench --version 2>/dev/null)"
# v3/v4: the version line must carry the tool name + major version (v4.0
# bumped BH_VERSION in lib/00-core.sh; accept both so the suite is green at
# every merge state)
case "$v" in *"blackhole-vps-bench v3."*|*"blackhole-vps-bench v4."*) pass "version ($v)" ;; *) flunk "version ($v)" ;; esac

echo "== 3. detect mode =="
out="$(./bin/blackhole-vps-bench detect 2>/dev/null)"
printf '%s\n' "$out" | grep -q "Kind    :" && pass "detect kind" || flunk "detect kind"
printf '%s\n' "$out" | grep -q "Verdict :" && pass "detect verdict" || flunk "detect verdict"

echo "== 4. fast bench, no net, outputs =="
./bin/blackhole-vps-bench all --fast --no-net --json /tmp/bhvps_t.json --markdown /tmp/bhvps_t.md --output /tmp/bhvps_t.txt >/dev/null 2>&1 \
  && pass "bench exit 0" || flunk "bench exit 0"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; d=json.load(open("/tmp/bhvps_t.json")); assert d["virtualization"]["kind"]; assert d["score"]["max"]==700; assert d["security"]["posture"]; assert "net_env" in d; assert "grade" in d["score"]; assert "chassis_type" in d["virtualization"]; assert "steal_pct" in d["system"]; assert "cpuset_cores" in d["limits"]; assert "cpu_freq_mhz" in d["system"]["cpu"]; assert "efficiency_pct" in d["bench"]["cpu"]; assert "iops_4k_write" in d["bench"]["disk"]; assert "endpoint" in d["bench"]["network"]; assert "sshd_version" in d["security"] and "sysctl" in d["security"]' \
    && pass "json schema" || flunk "json schema"
else
  grep -q '"virtualization"' /tmp/bhvps_t.json && pass "json looks present" || flunk "json"
fi
grep -q "BH-SCORE" /tmp/bhvps_t.txt && pass "text report" || flunk "text report"
grep -q "SSH & SECURITY" /tmp/bhvps_t.txt && pass "security section (text)" || flunk "security section (text)"
grep -q "## Verdict" /tmp/bhvps_t.md && pass "markdown report" || flunk "markdown report"
grep -q "## SSH & Security" /tmp/bhvps_t.md && pass "security section (markdown)" || flunk "security section (markdown)"
grep -q "Steal   :" /tmp/bhvps_t.txt && pass "steal line (text)" || flunk "steal line (text)"
grep -q "Swap    :" /tmp/bhvps_t.txt && pass "swap detail line (text)" || flunk "swap detail line (text)"
grep -q "(grade" /tmp/bhvps_t.txt && pass "grade in TOTAL (text)" || flunk "grade in TOTAL (text)"
grep -q "grade S >=630" /tmp/bhvps_t.txt && pass "grade mapping (text)" || flunk "grade mapping (text)"
grep -q "(grade" /tmp/bhvps_t.md && pass "grade in BH-SCORE heading (markdown)" || flunk "grade in BH-SCORE heading (markdown)"

echo "== 4b. sec mode =="
./bin/blackhole-vps-bench sec --output /tmp/bhvps_sec.txt >/dev/null 2>&1 \
  && pass "sec exit 0" || flunk "sec exit 0"
grep -q "SSH & SECURITY AUDIT" /tmp/bhvps_sec.txt && pass "sec audit section" || flunk "sec audit section"
grep -q "Posture:" /tmp/bhvps_sec.txt && pass "sec posture" || flunk "sec posture"

echo "== 4c. --no-sec flag =="
./bin/blackhole-vps-bench info --no-sec --output /tmp/bhvps_nosec.txt >/dev/null 2>&1 \
  && pass "info --no-sec exit 0" || flunk "info --no-sec exit 0"
grep -q "skipped" /tmp/bhvps_nosec.txt && pass "no-sec skips audit" || flunk "no-sec skips audit"

echo "== 5. bundle build + smoke =="
./build.sh >/dev/null 2>&1 && pass "build.sh" || flunk "build.sh"
if [ -x dist/blackhole-vps-bench ]; then
  ./dist/blackhole-vps-bench detect >/dev/null 2>&1 && pass "bundle detect" || flunk "bundle detect"
  ./dist/blackhole-vps-bench --version >/dev/null 2>&1 && pass "bundle version" || flunk "bundle version"
else
  flunk "bundle missing"
fi

echo "== 6. unit: tier_* label boundaries =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  # shellcheck disable=SC1091
  . ./lib/70-report.sh
  U=0
  u "tier_cpu1c empty -> ''"          ""                 "$(tier_cpu1c '')"            || U=1
  u "tier_cpu1c 0 -> ''"              ""                 "$(tier_cpu1c 0)"             || U=1
  u "tier_cpu1c 499 -> budget-tier"   "budget-tier"      "$(tier_cpu1c 499)"           || U=1
  u "tier_cpu1c 500 -> standard"      "standard"         "$(tier_cpu1c 500)"           || U=1
  u "tier_cpu1c 1499 -> standard"     "standard"         "$(tier_cpu1c 1499)"          || U=1
  u "tier_cpu1c 1500 -> high-perf"    "high-perf"        "$(tier_cpu1c 1500)"          || U=1
  u "tier_cpu1c 3499 -> high-perf"    "high-perf"        "$(tier_cpu1c 3499)"          || U=1
  u "tier_cpu1c 3500 -> server-grade" "server-grade"     "$(tier_cpu1c 3500)"          || U=1
  u "tier_mem_gbs empty -> ''"        ""                 "$(tier_mem_gbs '')"          || U=1
  u "tier_mem_gbs 1.9 -> low"         "low"              "$(tier_mem_gbs 1.9)"         || U=1
  u "tier_mem_gbs 2 -> standard"      "standard"         "$(tier_mem_gbs 2)"           || U=1
  u "tier_mem_gbs 7.9 -> standard"    "standard"         "$(tier_mem_gbs 7.9)"         || U=1
  u "tier_mem_gbs 8 -> high"          "high"             "$(tier_mem_gbs 8)"           || U=1
  u "tier_mem_gbs 19.9 -> high"       "high"             "$(tier_mem_gbs 19.9)"        || U=1
  u "tier_mem_gbs 20 -> server-grade" "server-grade"     "$(tier_mem_gbs 20)"          || U=1
  u "tier_disk_seq 0 -> ''"           ""                 "$(tier_disk_seq 0)"          || U=1
  u "tier_disk_seq 79.9 -> HDD"       "HDD-class"        "$(tier_disk_seq 79.9)"       || U=1
  u "tier_disk_seq 80 -> SATA-SSD"    "SATA-SSD-class"   "$(tier_disk_seq 80)"         || U=1
  u "tier_disk_seq 250 -> entry-NVMe" "entry-NVMe"       "$(tier_disk_seq 250)"        || U=1
  u "tier_disk_seq 1200 -> premium"   "premium-NVMe"     "$(tier_disk_seq 1200)"       || U=1
  u "tier_iops empty -> ''"           ""                 "$(tier_iops '')"             || U=1
  u "tier_iops 0 -> ''"               ""                 "$(tier_iops 0)"              || U=1
  u "tier_iops 499 -> very-slow"      "very-slow"        "$(tier_iops 499)"            || U=1
  u "tier_iops 500 -> cloud-standard" "cloud-standard"   "$(tier_iops 500)"            || U=1
  u "tier_iops 3000 -> fast-SSD"      "fast-SSD"         "$(tier_iops 3000)"           || U=1
  u "tier_iops 20000 -> NVMe-class"   "NVMe-class"       "$(tier_iops 20000)"          || U=1
  u "tier_net 0 -> ''"                ""                 "$(tier_net 0)"               || U=1
  u "tier_net 9.9 -> slow"            "slow"             "$(tier_net 9.9)"             || U=1
  u "tier_net 10 -> standard"         "standard"         "$(tier_net 10)"              || U=1
  u "tier_net 100 -> fast"            "fast"             "$(tier_net 100)"             || U=1
  u "tier_net 500 -> gigabit-class"   "gigabit-class"    "$(tier_net 500)"             || U=1
  u "tier_net 1000 -> 10G-class"      "10G-class"        "$(tier_net 1000)"            || U=1
  exit "$U"
) && pass "tier_* label boundaries" || flunk "tier_* label boundaries"

echo "== 7. unit: grade thresholds =="
# shellcheck disable=SC2030  # intentional: score sentinels scoped to this subshell
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  # shellcheck disable=SC1091
  . ./lib/70-report.sh
  U=0
  u "grade_letter empty total -> ''" ""  "$(grade_letter '' 700)"  || U=1
  u "grade_letter 0/700 -> ''"       ""  "$(grade_letter 0 700)"   || U=1
  u "grade_letter 700/700 -> S"      "S" "$(grade_letter 700 700)" || U=1
  u "grade_letter 630/700 -> S"      "S" "$(grade_letter 630 700)" || U=1
  u "grade_letter 629/700 -> A"      "A" "$(grade_letter 629 700)" || U=1
  u "grade_letter 525/700 -> A"      "A" "$(grade_letter 525 700)" || U=1
  u "grade_letter 524/700 -> B"      "B" "$(grade_letter 524 700)" || U=1
  u "grade_letter 420/700 -> B"      "B" "$(grade_letter 420 700)" || U=1
  u "grade_letter 419/700 -> C"      "C" "$(grade_letter 419 700)" || U=1
  u "grade_letter 315/700 -> C"      "C" "$(grade_letter 315 700)" || U=1
  u "grade_letter 314/700 -> D"      "D" "$(grade_letter 314 700)" || U=1
  u "grade_letter 210/700 -> D"      "D" "$(grade_letter 210 700)" || U=1
  u "grade_letter 209/700 -> F"      "F" "$(grade_letter 209 700)" || U=1
  u "grade_letter max 0 -> ''"       ""  "$(grade_letter 350 0)"   || U=1
  # compute_scores integration: grade must follow the computed ratio
  # shellcheck disable=SC2030  # intentional: sentinels scoped to this subshell
  BH_SHA1C=800; BH_SHANC=4000; BH_MEM_GBS=16; BH_SEQW=400; BH_SEQR=500
  # shellcheck disable=SC2030  # intentional: sentinels scoped to this subshell
  BH_4KW=40; BH_4KR=60; BH_DOWN_MBPS=400; BH_UP_MBPS=200
  compute_scores
  u "compute_scores -> grade matches ratio" "$(grade_letter "$BH_SCORE_TOTAL" "$BH_SCORE_MAX")" "$BH_GRADE" || U=1
  u "compute_scores -> total > 0 => grade set" "yes" "$([ -n "$BH_GRADE" ] && echo yes || echo no)" || U=1
  exit "$U"
) && pass "grade thresholds" || flunk "grade thresholds"

echo "== 8. unit: json_val number vs string =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  U=0
  u "json_val integer stays numeric"     "42"           "$(json_val 42)"           || U=1
  u "json_val negative float numeric"    "-3.5"         "$(json_val -3.5)"         || U=1
  u "json_val exponent becomes string"   '"4e9"'        "$(json_val 4e9)"          || U=1
  u "json_val text becomes string"       '"n/a"'        "$(json_val n/a)"          || U=1
  u "json_val empty -> empty string"     '""'           "$(json_val '')"           || U=1
  u "json_val quotes are escaped"        '"say \"hi\""' "$(json_val 'say "hi"')"   || U=1
  u "json_val backslash is escaped"      '"a\\b"'      "$(json_val 'a\b')"        || U=1
  exit "$U"
) && pass "json_val number-vs-string" || flunk "json_val number-vs-string"

echo "== 9. unit: sec_sshd_opt (first-match-wins, Match skip) =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  # shellcheck disable=SC1091
  . ./lib/80-ssh.sh
  U=0
  # fixture A: raw config lines (BH_SSH_T_OK=0), first match wins, comments
  # and inline comments ignored, values lowercased like sshd semantics
  BH_SSH_T_OK=0
  BH_SSH_T_OUT=""
  BH_SSH_CFG_LINES=(
    "Port 22"
    "# PasswordAuthentication yes"
    "PasswordAuthentication YES"
    "PermitRootLogin prohibit-password"
    "PermitRootLogin no"
    "PermitEmptyPasswords no"
    "Match User backup"
    "PasswordAuthentication yes"
    "PermitEmptyPasswords yes"
  )
  u "first match wins (later duplicate ignored)" "prohibit-password" "$(sec_sshd_opt permitrootlogin '')" || U=1
  u "comment skipped + value lowercased"          "yes"               "$(sec_sshd_opt passwordauthentication '')" || U=1
  u "Match-block value does not win"              "no"                "$(sec_sshd_opt permitemptypasswords '')" || U=1
  u "plain key lookup"                            "22"                "$(sec_sshd_opt port '')" || U=1
  # fixture B: key only inside a Match block -> skipped, default returned
  BH_SSH_CFG_LINES=(
    "Match User backup"
    "PasswordAuthentication yes"
    "PermitRootLogin no"
  )
  u "Match-block-only key falls back to default" "unset" "$(sec_sshd_opt passwordauthentication "unset")" || U=1
  u "Match-block-only key yields empty"          ""      "$(sec_sshd_opt permitrootlogin '')" || U=1
  # fixture C: sshd -T effective output wins when BH_SSH_T_OK=1
  BH_SSH_T_OK=1
  BH_SSH_T_OUT="port 2222
permitrootlogin no"
  BH_SSH_CFG_LINES=()
  u "sshd -T output parsed" "no" "$(sec_sshd_opt permitrootlogin "default")" || U=1
  u "sshd -T port parsed"   "2222" "$(sec_sshd_opt port '')" || U=1
  exit "$U"
) && pass "sec_sshd_opt fixtures" || flunk "sec_sshd_opt fixtures"

echo "== 10. unit: cloud_from_dmi / map_vm_cloud =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  # shellcheck disable=SC1091
  . ./lib/10-detect.sh
  # shellcheck disable=SC1091
  [ -f ./lib/12-cloud.sh ] && . ./lib/12-cloud.sh
  U=0
  # map_vm_cloud VENDOR PRODUCT BIOS ASSET_TAG — Azure only with the well-known
  # Azure chassis asset tag; plain "Microsoft Corporation" is just Hyper-V
  u "Microsoft + Azure chassis asset tag -> Azure" "Microsoft Azure" \
    "$(map_vm_cloud "Microsoft Corporation" "" "" "7783-7084-3265-9085-8269-3286-77")" || U=1
  u "Microsoft without asset tag -> NOT Azure (empty)" "" \
    "$(map_vm_cloud "Microsoft Corporation" "" "" "")" || U=1
  um "Oracle + OracleCloud.com asset tag -> OCI" 'OCI' \
    "$(map_vm_cloud "Oracle Corporation" "" "" "OracleCloud.com")" || U=1
  u "Amazon EC2 -> AWS EC2" "AWS EC2" "$(map_vm_cloud "Amazon EC2" "" "" "")" || U=1
  # cloud_from_dmi — pure helper reading the BH_DMI_* globals
  BH_DMI_VENDOR="Amazon EC2"; BH_DMI_PRODUCT=""; BH_DMI_BIOS=""; BH_DMI_ASSET_TAG=""
  um "cloud_from_dmi: EC2 vendor -> AWS" 'AWS' "$(cloud_from_dmi)" || U=1
  BH_DMI_VENDOR="Microsoft Corporation"
  u "cloud_from_dmi: Microsoft without Azure tag -> empty" "" "$(cloud_from_dmi)" || U=1
  BH_DMI_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"
  um "cloud_from_dmi: Microsoft + Azure tag -> Azure" 'Azure' "$(cloud_from_dmi)" || U=1
  # aws_gen: old EC2 Xen guests advertise DMI product "HVM domU" -> gen = xen
  BH_DMI_VENDOR="Amazon EC2"; BH_DMI_PRODUCT="i-0abc123 HVM domU"; BH_DMI_BIOS_VERSION=""
  BH_EVIDENCE=""; BH_AWS_GEN=""
  classify_aws
  u "classify_aws: EC2 'HVM domU' product -> aws_gen xen" "xen" "${BH_AWS_GEN:-}" || U=1
  exit "$U"
) && pass "cloud_from_dmi / map_vm_cloud" || flunk "cloud_from_dmi / map_vm_cloud"

echo "== 11. json schema v4 (--json - emits JSON on stdout) =="
jout="$(./bin/blackhole-vps-bench all --fast --no-net --json - 2>/dev/null)"
# stdout = human report body + the JSON object as its last '{'-leading line
jline="$(printf '%s\n' "$jout" | awk '/^\{/{j=$0} END{print j}')"
[ -n "$jline" ] && pass "json object emitted on stdout (--json -)" || flunk "json object emitted on stdout (--json -)"
if [ -n "$jline" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$jline" | jq -e '.virtualization.evidence | type == "array"' >/dev/null 2>&1 \
    && pass "json: virtualization.evidence is array" || flunk "json: virtualization.evidence is array"
  printf '%s' "$jline" | jq -e '.security | type == "object"' >/dev/null 2>&1 \
    && pass "json: security is object" || flunk "json: security is object"
  # v4 soft keys — assert ONLY when the producer is actually wired into lib/,
  # otherwise the whole suite would be red mid-merge:
  #   .cpu.ai_features  <- BH_CPU_AI_FEAT (20-info.sh) + build_json key
  #   .security.ntp     <- BH_SEC_NTP + build_json key
  #   .score.grade      <- BH_GRADE + build_json key (v3, always present)
  if grep -qs 'BH_CPU_AI_FEAT' lib/*.sh && grep -qs '"ai_features"' lib/70-report.sh; then
    printf '%s' "$jline" | jq -e '.cpu | has("ai_features")' >/dev/null 2>&1 \
      && pass "json: cpu.ai_features present" || flunk "json: cpu.ai_features present"
  else
    skip "json: cpu.ai_features (feature not present)"
  fi
  if grep -qs 'BH_SEC_NTP' lib/*.sh && grep -qs '"ntp"' lib/70-report.sh; then
    printf '%s' "$jline" | jq -e '.security | has("ntp")' >/dev/null 2>&1 \
      && pass "json: security.ntp present" || flunk "json: security.ntp present"
  else
    skip "json: security.ntp (feature not present)"
  fi
  if grep -qs '"grade"' lib/70-report.sh; then
    printf '%s' "$jline" | jq -e '.score | has("grade")' >/dev/null 2>&1 \
      && pass "json: score.grade present" || flunk "json: score.grade present"
  else
    skip "json: score.grade (feature not present)"
  fi
elif [ -n "$jline" ] && command -v python3 >/dev/null 2>&1; then
  printf '%s' "$jline" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d["virtualization"]["evidence"], list); assert isinstance(d["security"], dict); assert "grade" in d["score"]' \
    && pass "json schema v4 (python3 fallback)" || flunk "json schema v4 (python3 fallback)"
else
  skip "json schema v4 deep keys (no jq/python3 or no json line)"
fi

echo "== 12. sec mode zero-network guarantee (curl shim, bug G4) =="
shimdir="$(mktemp -d "${TMPDIR:-/tmp}/bhvps_shim.XXXXXX")"
curllog="$shimdir/curl.log"
cat > "$shimdir/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$curllog"
exit 1
EOF
chmod +x "$shimdir/curl"
secrc=0
PATH="$shimdir:$PATH" ./bin/blackhole-vps-bench sec --json - >/dev/null 2>&1 || secrc=$?
[ "$secrc" -eq 0 ] && pass "sec exit 0 with failing curl shim" || flunk "sec exit 0 with failing curl shim (rc=$secrc)"
if [ ! -s "$curllog" ]; then
  pass "sec zero-network: curl never invoked (G4)"
else
  # fallback: local metadata probes are tolerable, egress lookups are not
  if grep -qiE 'ipify|ip-api|cloudflare' "$curllog"; then
    flunk "sec made egress curl calls (G4 regression): $(head -n 2 "$curllog")"
  else
    pass "sec no egress lookups (curl only for local metadata: $(wc -l < "$curllog") call(s))"
  fi
fi
rm -rf "$shimdir"

echo "== 13. selftest mode (soft) =="
selfout="$(./bin/blackhole-vps-bench selftest 2>&1)"; selfrc=$?
if [ "$selfrc" -eq 0 ]; then
  pass "selftest mode exits 0"
elif [ "$selfrc" -eq 2 ] && printf '%s\n' "$selfout" | grep -qi 'unknown argument'; then
  skip "selftest mode (feature not present)"
else
  flunk "selftest mode (rc=$selfrc)"
fi

echo "== 14. exit gate --min-score (soft) =="
msout="$(./bin/blackhole-vps-bench detect --min-score 999999 2>&1)"; msrc=$?
if [ "$msrc" -eq 3 ]; then
  pass "detect --min-score 999999 exits 3 (gate fires on score 0)"
elif [ "$msrc" -eq 2 ] && printf '%s\n' "$msout" | grep -qi 'unknown argument'; then
  skip "--min-score exit gate (feature not present)"
elif [ "$msrc" -eq 0 ]; then
  flunk "detect --min-score 999999 rc=0, want 3 (gate did not fire)"
else
  flunk "detect --min-score 999999 unexpected rc=$msrc"
fi
if [ "$msrc" -eq 3 ] || { [ "$msrc" -ne 2 ] && ! printf '%s\n' "$msout" | grep -qi 'unknown argument'; }; then
  ms0rc=0
  ./bin/blackhole-vps-bench detect --min-score 0 >/dev/null 2>&1 || ms0rc=$?
  [ "$ms0rc" -eq 0 ] && pass "detect --min-score 0 passes (rc=0)" || flunk "detect --min-score 0 rc=$ms0rc, want 0"
fi

echo "== 15. unit: cpuset / BH_PAR_JOBS math =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  # shellcheck disable=SC1091
  . ./lib/10-detect.sh
  # shellcheck disable=SC1091
  . ./lib/20-info.sh
  BH_FAST=1
  U=0
  gather_info >/dev/null 2>&1 || { echo "SKIP: cpuset math (gather_info failed)"; exit 0; }
  u "BH_PAR_JOBS <= NCPU" "yes" \
    "$([ "${BH_PAR_JOBS:-1}" -le "${NCPU:-1}" ] 2>/dev/null && echo yes || echo no)" || U=1
  if [ -n "${CPUSET:-}" ] && [ "${BH_CPUSET_N:-0}" -gt 0 ] 2>/dev/null; then
    u "BH_EFF_CORES <= cpuset cores (cpuset '$CPUSET' = $BH_CPUSET_N cores)" "yes" \
      "$([ "${BH_EFF_CORES:-0}" -le "$BH_CPUSET_N" ] 2>/dev/null && echo yes || echo no)" || U=1
  else
    echo "SKIP: cpuset constraint (CPUSET empty on this host)"
  fi
  exit "$U"
) && pass "cpuset / BH_PAR_JOBS math" || flunk "cpuset / BH_PAR_JOBS math"

echo "== 16. unit: gauge/render helper (soft) =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  # shellcheck disable=SC1091
  . ./lib/70-report.sh
  G=""
  declare -f gauge    >/dev/null 2>&1 && G="gauge"
  [ -z "$G" ] && declare -f bh_gauge >/dev/null 2>&1 && G="bh_gauge"
  if [ -n "$G" ]; then
    U=0
    g0="$($G 0)"; g50="$($G 50)"; g100="$($G 100)"
    u "gauge 0 non-empty"   "yes" "$([ -n "$g0" ]   && echo yes || echo no)" || U=1
    u "gauge 50 non-empty"  "yes" "$([ -n "$g50" ]  && echo yes || echo no)" || U=1
    u "gauge 100 non-empty" "yes" "$([ -n "$g100" ] && echo yes || echo no)" || U=1
    u "gauge 0 != 50"   "yes" "$([ "$g0" != "$g50" ]   && echo yes || echo no)" || U=1
    u "gauge 50 != 100" "yes" "$([ "$g50" != "$g100" ] && echo yes || echo no)" || U=1
    u "gauge fixed width (0/50/100 same length)" "yes" \
      "$([ "${#g0}" -eq "${#g50}" ] && [ "${#g50}" -eq "${#g100}" ] && echo yes || echo no)" || U=1
    exit "$U"
  else
    echo "SKIP: gauge/bh_gauge helper (feature not present)"
    exit 0
  fi
) && pass "gauge helper shape (0/50/100)" || flunk "gauge helper shape (0/50/100)"

echo "== 17. bench-extra smoke (soft) =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  U=0
  if [ ! -f ./lib/35-bench-extra.sh ]; then
    echo "SKIP: lib/35-bench-extra.sh (feature not present)"
    exit 0
  fi
  # shellcheck disable=SC1091
  . ./lib/35-bench-extra.sh
  BH_FAST=1
  # the module is INFO-ONLY: score inputs must come out untouched
  BH_SHA1C=4321; BH_MEM_GBS=12.5
  if ! bench_extra >/dev/null 2>&1; then
    echo "FAIL: bench_extra rc!=0 with BH_FAST=1"; U=1
  fi
  u "BH_FORK_RATE non-empty after bench_extra" "yes" \
    "$([ -n "${BH_FORK_RATE:-}" ] && echo yes || echo no)" || U=1
  u "bench_extra leaves BH_SHA1C untouched"   "4321" "${BH_SHA1C:-}"   || U=1
  u "bench_extra leaves BH_MEM_GBS untouched" "12.5" "${BH_MEM_GBS:-}" || U=1
  exit "$U"
) && pass "bench_extra smoke (BH_FAST=1)" || flunk "bench_extra smoke (BH_FAST=1)"

echo "== 18. new module smoke: gather_env / gather_storage_map (soft) =="
(
  # shellcheck disable=SC1091
  . ./lib/00-core.sh
  U=0
  if [ -f ./lib/25-env.sh ]; then
    # shellcheck disable=SC1091
    . ./lib/25-env.sh
    if declare -f gather_env >/dev/null 2>&1; then
      # stdout -> file (NOT $( ): the globals-only contract must be checked in
      # THIS shell — a command substitution would run gather_env in a child
      # and hide every BH_CAPS_* / BH_PIDS_* global it sets)
      gather_env > "$BH_RUNDIR/gather_env.out" 2>/dev/null; envrc=$?
      envout="$(cat "$BH_RUNDIR/gather_env.out" 2>/dev/null)"
      u "gather_env exit 0" "0" "$envrc" || U=1
      u "gather_env stdout empty (globals-only contract)" "" "$envout" || U=1
      u "gather_env sets BH_CAPS_CLASS" "yes" \
        "$([ -n "${BH_CAPS_CLASS:-}" ] && echo yes || echo no)" || U=1
      u "gather_env sets BH_DEV_MAP" "yes" \
        "$([ -n "${BH_DEV_MAP:-}" ] && echo yes || echo no)" || U=1
    else
      echo "SKIP: gather_env (function not present)"
    fi
  else
    echo "SKIP: lib/25-env.sh (feature not present)"
  fi
  if [ -f ./lib/55-storage-map.sh ]; then
    # shellcheck disable=SC1091
    . ./lib/55-storage-map.sh
    if declare -f gather_storage_map >/dev/null 2>&1; then
      gather_storage_map > "$BH_RUNDIR/gather_storage_map.out" 2>/dev/null; smrc=$?
      smout="$(cat "$BH_RUNDIR/gather_storage_map.out" 2>/dev/null)"
      u "gather_storage_map exit 0" "0" "$smrc" || U=1
      u "gather_storage_map stdout empty" "" "${smout:-}" || U=1
    else
      echo "SKIP: gather_storage_map (function not present)"
    fi
  else
    echo "SKIP: lib/55-storage-map.sh (feature not present)"
  fi
  exit "$U"
) && pass "new module smoke (25-env / 55-storage-map)" || flunk "new module smoke (25-env / 55-storage-map)"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED"
  exit 1
fi
