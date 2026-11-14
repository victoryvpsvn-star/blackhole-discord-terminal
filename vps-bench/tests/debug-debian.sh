#!/bin/bash
# debug-debian.sh — capture timing/awk/dd behaviour inside CI containers
echo "== bash =="
bash --version | head -n1
echo "EPOCHREALTIME=[$EPOCHREALTIME]"
echo "== binaries =="
command -v dd sha256sum awk sleep
dd --version 2>&1 | head -n1
(readlink -f "$(command -v awk)" 2>/dev/null || true)
awk -W version 2>&1 | head -n1 || awk --version 2>&1 | head -n1
echo "== clock sources =="
cat /proc/uptime
sleep 1
cat /proc/uptime
echo "== now_ms emulation (3 samples, 1s apart) =="
for i in 1 2 3; do
  awk -v t="$EPOCHREALTIME" 'BEGIN{n=split(t,a,"."); printf "sample=%d ms=%d a1=%s a2=%s\n", '"$i"', a[1]*1000+int(substr((a[2]"000"),1,3)), a[1], a[2]}'
  sleep 1
done
echo "== raw dd timed =="
t0=$EPOCHREALTIME
dd if=/dev/zero bs=1M count=256 2>/tmp/dderr | sha256sum >/dev/null
rc=$?
t1=$EPOCHREALTIME
echo "rc=$rc"
echo "t0=[$t0] t1=[$t1]"
awk -v a="$t0" -v b="$t1" 'BEGIN{printf "delta_ms=%d\n", (b-a)*1000}'
echo "dd stderr:"; cat /tmp/dderr
echo "== dd to null timed =="
t0=$EPOCHREALTIME
dd if=/dev/zero of=/dev/null bs=1M count=1024 2>&1 | tail -n1
t1=$EPOCHREALTIME
awk -v a="$t0" -v b="$t1" 'BEGIN{printf "delta_ms=%d\n", (b-a)*1000}'
echo "== tool now_ms (sourced) =="
. /work/vps-bench/lib/00-core.sh
x1=$(now_ms); sleep 1; x2=$(now_ms)
echo "x1=[$x1] x2=[$x2] delta=$((x2 - x1))"
