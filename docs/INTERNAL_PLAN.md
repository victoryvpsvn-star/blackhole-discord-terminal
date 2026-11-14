# INTERNAL PLAN — blackhole-vps-bench v5.0.0

> Tài liệu nội bộ: quy trình build v5 bằng pipeline AI agent, quyết định thiết kế,
> danh mục module và ràng buộc kỹ thuật. Update lần: v5.0.0.

## 1. Quy trình đa-agent (10 → 5 → 15)

```
10 IDEA AGENT (mỗi con 1 góc domain, đọc code v4, đề xuất 8-12 ý)
   └─ IA-01 VMM fingerprint  IA-02 cloud/region  IA-03 hardware
      IA-04 storage          IA-05 network       IA-06 security
      IA-07 SSH              IA-08 container/k8s IA-09 bench science
      IA-10 report UX
        ⇒ ~140 ý thô (đã tự loại trùng với v4)

5 REVIEW AGENT (mỗi con 1 lens, chấm + chọn)
   └─ RA-01 feasibility/correctness   RA-02 safety/CI-budget
      RA-03 user value/wow            RA-04 integration/architecture
      RA-05 portfolio balance/dedupe
        ⇒ 26 cụm trùng gộp lại, 10 ý cắt, chốt ~45 ý

15 CODER AGENT (song song, mỗi con sở hữu file riêng, không đụng chéo)
   └─ C01 05-noise      C02 12-cloud + 13-region    C03 10-detect
      C04 24-speccheck  C05 16-hw-deep              C06 20-info
      C07 55-storage-map C08 56-storage-health + 57-mount-audit
      C09 85 + 86-system-sec + 87-malware-hunt      C10 80-ssh
      C11 25-env + 26-container                     C12 30-cpu + 40-mem + 35-bench-extra
      C13 45-disk-dur + 60-net + 62-net-extra       C14 63-tips + 70-report
      C15 64-history + 99-main (wiring, flags, selftest)
```

Kết quả: 14/15 coder PASS ngay; C09 (security) hết lượt agent trước khi báo cáo
nhưng code đã hoàn chỉnh — được integrator kiểm chứng bằng bash -n + shellcheck +
smoke test. Integrator vá 5 lỗi tích hợp nhỏ: gọi sai tên `_bhv5c12_cgstat`,
redirect bash `< file 2>/dev/null` sai thứ tự (55), tips match sai key PSI
(`mem s=` vs `memory s=`), DNS verdict "clean" bị gắn chip WARN, và mở test
version chấp nhận v5.

## 2. Kiến trúc module v5 (load-order = số tiền tố, glob alphabet)

| File | Trạng thái | Nội dung chính |
|---|---|---|
| `00-core.sh` | mở rộng | env v5 (`BH_QUIET/TIMING_OUT/BADGE_OUT/SVG_OUT/HISTORY`), `bh_timed`, `bh_timing_table`, `bh_psi` |
| `05-noise.sh` | MỚI | `bh_median3` (median-of-3 + spread%) — kỷ luật noise cho micro-bench |
| `10-detect.sh` | mở rộng | TCG-vs-KVM accel, NIC driver census, PCI vendor census, module census, dmesg, ACPI OEM, DT (ARM), cmdline (Firecracker), DMI-spoof detector, Xen version |
| `12-cloud.sh` | mở rộng | meta probes Vultr/Scaleway/UpCloud/OpenStack/Hetzner + AZ fill big-3 + hints resolv/NTP/MAC/IPv6-prefix |
| `13-region.sh` | MỚI | cloud-init offline region (0ms, chạy cả detect mode) |
| `16-hw-deep.sh` | MỚI | NUMA, cpufreq/turbo, thermal, throttle counters, MCE/EDAC, DIMM (root) |
| `20-info.sh` | mở rộng | cache matrix (L1/L2/L3), block queue deep (4Kn/512e/wc) |
| `24-speccheck.sh` | MỚI | bảng spec nhúng 27 plan × provider → ✓/⚠/✗ advertised-vs-measured + burst tag |
| `25-env.sh` | mở rộng | uid_map (rootless truth), seccomp mode+count, PSI |
| `26-container.sh` | MỚI | runtime pinpoint (cgroup v1+v2 mountinfo fallback), k8s ns/SA/pod-uid/projected-volumes/ns-inode |
| `30-cpu.sh` | mở rộng | cgroup throttle % (cpu.stat v1/v2), A/B noisy-neighbor |
| `35-bench-extra.sh` | mở rộng | pipe ping-pong µs, sqlite insert/s (time-box), stat syscall rate, urandom rate |
| `40-mem.sh` | mở rộng | memory latency (pointer-chase), page-fault rate |
| `45-disk-dur.sh` | MỚI | fsync durability per-IO: p50/p99 ms + fsyncs/s (deadline 6s/3s) |
| `55-storage-map.sh` | mở rộng | queue matrix, mdraid degraded, zfs pool, btrfs errs, lvm thin |
| `56-storage-health.sh` | MỚI | SMART (root), NVMe wear/temp, cgroup io.stat rate |
| `57-mount-audit.sh` | MỚI | mount flags matrix, inode pressure, fstrim timer crosscheck |
| `60-net.sh` | mở rộng | clock-skew HTTPS, egress proxy/tunnel, PTR class, PMTU, DNS census+hijack test, TCP jitter, conntrack, sockstat, IPv6 speed |
| `62-net-extra.sh` | MỚI | TLS handshake ms (5 parallel) |
| `63-tips.sh` | MỚI | tips engine data-driven (13 rules, severity sort, top-3) |
| `64-history.sh` | MỚI | run history TSV (TTY-only, cap 512, chmod 600) + sparkline + trend |
| `70-report.sh` | mở rộng | render mọi global mới, JSON/MD/Prom sinks, badge + SVG builders, truth strip, fingerprint, redact mở rộng |
| `80-ssh.sh` | mở rộng | sshd -t, declared-vs-effective, socket-activation FP fix, AK deep scan (DSA/RSA-bits fallback), host key audit, cert auth, Match/SFTP, fwd sweep, topology, auth-log deep, MFA |
| `85-hardening.sh` | mở rộng | sysctl stage2, lockdown+taint, /etc world-writable |
| `86-system-sec.sh` | MỚI | PAM 2FA/lockout, EDR census, cron pipe-to-shell triage, reboot-required, journald volatility, auto-update timer truth |
| `87-malware-hunt.sh` | MỚI | /proc exe scan: deleted binary, world-writable dir exec |
| `99-main.sh` | mở rộng | wiring mọi module mới vào 4 mode, `--timing/--badge/--svg`, progress hints, `--quiet`, footer wall-time + repro hint, selftest +12 assertion |

## 3. Ràng buộc kỹ thuật (bắt buộc mọi module)

1. **mawk-safe**: không `systime()`, không `printf %d` cho số >2^31 (bug bão hoà
   INT32 — đã ghi trong 00-core). Thời gian qua `now_ms`/`now_us` (EPOCHREALTIME).
2. **Read-only tuyệt đối** ngoài `$BH_RUNDIR`/`$BH_DISK_DIR`; cấm `smartctl -t`,
   cấm fstrim thật, cấm ghi sysfs. Token/secret chỉ tồn tại check (`[ -s ]`).
3. **Guard mọi thứ**: file `[ -r ]`, lệnh `command_exists`, external `timeout N`;
   thiếu → `""`/`n/a` sạch, không warn ồn.
4. **Budget**: detect+info <10s; bench additions fast <4s / full <10s; net waves
   ≤4s (song song); sec <2s.
5. **shellcheck v0.10** sạch trên dist bundle (exempt: SC2034/SC2016/SC2317/SC2329).
6. **Redact**: `BH_REDACT=1` → không in IP/serial/instance-id/hostname; id container
   chỉ 8 ký tự đầu.
7. **Evidence-only**: tells mới không được override verdict `BH_KIND` — chỉ thêm
   bằng chứng vào `BH_VMM_TELLS`.

## 4. Sinks & CI

- Output: terminal màu (mặc định) + `--json/--markdown/--output/--prom/--badge/--svg/--timing`.
- GitHub Actions: `vps-bench-selftest.yml` (shellcheck pinned v0.10 + bundle
  freshness + selftest + smoke trên ubuntu/arm + containers) và
  `vps-bench-remote.yml` (bench VPS thật qua SSH, trigger thủ công).
- Exit gates giữ nguyên: 0 ok | 1 no-data | 2 usage | 3 `--min-score` | 4 `--fail-on`.
- Discord webhook: KHÔNG dùng làm kênh chính (theo yêu cầu chủ repo) — kết quả in
  thẳng terminal; `--webhook` chỉ là tuỳ chọn legacy không kích hoạt mặc định.

## 5. Việc còn lại (wave-2 reserve)

- Ý đã review nhưng chưa làm: stat-syscall mở rộng, module census nâng cao,
  overlay upperdir size, geo cross-check, colour-blind palette.
- Benchmark BASH_SCORE weight cho fsync p99 (hiện info-only, không vào score).
- arm64 CI job bổ sung assertions cho DT/device-tree tells.
