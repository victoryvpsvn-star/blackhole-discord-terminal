#!/usr/bin/env bash
# run-tests.sh — smoke tests for blackhole-vps-bench
# shellcheck disable=SC2015  # 'cmd && pass || flunk' is safe here: pass/flunk never fail
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
pass() { echo "PASS: $1"; }
flunk() { echo "FAIL: $1"; fail=1; }

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
case "$v" in *"blackhole-vps-bench v3."*) pass "version ($v)" ;; *) flunk "version ($v)" ;; esac

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
  BH_SHA1C=800; BH_SHANC=4000; BH_MEM_GBS=16; BH_SEQW=400; BH_SEQR=500
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

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED"
  exit 1
fi
