# vps-bench v5.1 — Internal design & agent pipeline record

> Internal update ("update nội bộ") — how v5.1 was designed, reviewed and implemented.
> Date: 2026-11-15 · Tool version: 5.1.0 · Authors: agent pipeline + integrator.

## 1. Pipeline

| Phase | Agents | Output |
|---|---|---|
| Ideas | 10 idea agents (virt detect, containers, cloud, CPU, RAM, disk, network, security, SSH, bench design) | 100 candidate probes, each verified live against /proc + /sys |
| Review | 5 review agents (portability, bench integrity, security/privacy, UX value, CI feasibility) | scored 11 deduped candidates (G1–G11), value/risk/effort |
| Code | 3 coder agents (A: lib module, B: CI workflow, C: tests) | 27-probes.sh, selftest.yml verdict digest, run-tests.sh sections 19–20 |
| Integrate | 1 integrator | 99-main wiring, 70-report rendering, JSON keys, version bump, dist rebuild, lint, full suite |

Dedup against the existing 30-module codebase removed ideas the tool already had
(PSI, steal, NUMA, THP, entropy, lockdown, conntrack, TRIM, sshd -T, weak crypto, ...).
Full gap list: `docs/vps-bench-v5.1-gaps.md`.

## 2. Review verdicts (value/risk/effort, consensus)

| ID | Candidate | Verdict |
|---|---|---|
| G1 | SMT topology + hotplug delta | IMPLEMENT — guards: masked topology files => "unknown", never assert "SMT off" blindly |
| G2 | Overcommit mode/ratio + Committed_AS vs CommitLimit | IMPLEMENT — phrase as headroom, not alarm |
| G3 | TCP knobs (syncookies/fastopen/rmem/wmem/rp_filter) | IMPLEMENT — one compact line, /proc-only |
| G4 | Default-iface qdisc + BBR/fq note | IMPLEMENT — command_exists guard (no tc on minimal images) |
| G5 | Sandbox runtime class (kata/gVisor/Firecracker) | IMPLEMENT — merge into verdict rows; kata needs any-signal, others via /proc/version |
| G6 | max_user_namespaces | IMPLEMENT — one guarded read |
| G7 | Guest-agent census | IMPLEMENT (narrowed by security review): presence-only, no args, no configs, no /var/lib/cloud contents; found-only rendering |
| G8 | drop_caches before disk read | REJECT — tool already negotiates `iflag=direct`; drop_caches evicts HOST-wide page cache (shared-kernel side effect) |
| G9 | speedtest-cli / iperf3 backends | DEFER — flaky, no-install policy; keep Cloudflare default |
| G10 | Discord notify verdict digest | IMPLEMENT — artifacts (verdict-*) + download-artifact merge; `branches: ain]` was a sandbox display artifact (on-disk bytes are `[main]`) |
| G11 | CPU steal check | REJECT — already shipped in v4 (idle steal + steal-under-load + JSON steal_pct) |

## 3. Implementation map

| File | Change |
|---|---|
| `vps-bench/lib/27-probes.sh` (NEW) | `gather_probes()`: 17 globals (BH_SMT_THREADS, BH_CPU_HOTPLUG, BH_OOM_MODE/RATIO/COMMIT_PCT, BH_TCP_*, BH_RP_FILTER, BH_QDISC(+IFACE/NOTE), BH_SANDBOX(+TXT), BH_USERNS_MAX, BH_GUEST_AGENTS); read-only, silent, idempotent, busybox-safe |
| `vps-bench/lib/99-main.sh` | `probes` module wired in `bhv5c15_v5_gathers` (double-guarded, `--only/--skip probes` works) |
| `vps-bench/lib/70-report.sh` | verdict row `Sandbox :`; CPU rows `SMT:` + `hotplug:`; `[ENV]` rows `OverCmt/TCP/Qdisc/Userns/Managed`; JSON `system.{smt_threads,cpu_hotplug,oom_mode,oom_commit_pct,tcp_syncookies,tcp_fastopen,rp_filter,qdisc,sandbox,userns_max,guest_agents}` |
| `vps-bench/lib/00-core.sh` | BH_VERSION 5.0.0 → 5.1.0 |
| `vps-bench/tests/run-tests.sh` | section 19 (globals contract incl. stdout-silence + no-path-leak in BH_GUEST_AGENTS) + section 20 (idempotency + degraded-PATH tolerance) + JSON soft-key guard |
| `.github/workflows/vps-bench-selftest.yml` | verdict digest: smoke/containers write `verdict-*` artifacts (if: always(), if-no-files-found: ignore); notify downloads + appends to the Discord embed (3500-char cap, never fails when missing) |
| `vps-bench/README.md` | v5.1 changelog block |

## 4. Verification performed

- `build.sh` bundle: 642093 bytes, `bash -n` OK, pinned shellcheck v0.10.0 CLEAN (repo exclusion set).
- Full `tests/run-tests.sh`: ALL TESTS PASSED (incl. new probe sections).
- Live run on this sandbox (kata container on Alibaba dragonball/KVM): `Sandbox : kata microVM sandbox (signals: mountinfo + env)`, `SMT: 1 hardware thread(s)/core`, `OverCmt : mode 0`, `TCP : syncookies 1 · fastopen 1 · rp_filter 0/0 · rmem max 909K · wmem max 909K`, `Qdisc : pfifo on eth0`, `Userns : max_user_namespaces 462`, `Managed` line correctly absent (no agents installed).
- JSON: all 11 new keys present and typed.

## 5. Deferred (next batch candidates)

- G9 opt-in `--net-backend speedtest|iperf3` with strict timeouts and method-tagged numbers.
- G7 expansion: systemd unit *states* (installed≠running) behind the same privacy guardrails.
- cc-autotune context for rmem/wmem (avoid over-interpreting buffer ceilings).
