# blackhole-vps-bench

Tool kiểm tra VPS của bạn thực chất đang chạy trên gì — KVM, QEMU, Docker, Podman, Kubernetes, LXC/LXD, OpenVZ, Xen, Hyper-V, VMware, VirtualBox, bhyve, WSL hay máy chủ dedicated — rồi benchmark đúng **cấu hình thực** (đọc cgroup limit chứ không báo nhầm RAM/CPU của host). Thuần bash, một file duy nhất, chạy được cả trong container Alpine, có GitHub Actions selftest và gửi báo cáo về Discord.

- Phiên bản: v1.0.0
- Repo: `victoryvpsvn-star/blackhole-discord-terminal`
- Yêu cầu: Linux + bash, `curl` (bắt buộc cho phần network), còn lại mọi thứ đều tự động hóa qua `dd`/`sha256sum`/`openssl`/`fio` nếu có. Không cần root.

---

## 1. Tải và chạy nhanh

Cài vào hệ thống (mặc định `/usr/local/bin`, dùng curl hoặc wget, không cần root nếu prefix ghi được):

```sh
curl -fsSL https://raw.githubusercontent.com/victoryvpsvn-star/blackhole-discord-terminal/main/vps-bench/install.sh | sh
```

Hoặc chạy luôn không cần cài — tải bundle một file rồi bash:

```sh
curl -fsSL -o bhvps.sh https://raw.githubusercontent.com/victoryvpsvn-star/blackhole-discord-terminal/main/vps-bench/dist/blackhole-vps-bench
bash bhvps.sh detect      # chỉ nhận diện, nhanh, chạy offline được
```

Hoặc chạy từ bản checkout của repo:

```sh
./vps-bench/bin/blackhole-vps-bench all
```

Ba lệnh hay dùng nhất:

```sh
blackhole-vps-bench detect                # KVM hay Docker? (offline, vài giây)
blackhole-vps-bench all --fast            # detect + bench nhanh
blackhole-vps-bench all --webhook 'https://discord.com/api/webhooks/ID/TOKEN'
```

---

## 2. Chế độ và tuỳ chọn

Đúng theo `blackhole-vps-bench help`.

| Chế độ | Ý nghĩa |
|---|---|
| `all` | detect + info + benchmark đầy đủ (mặc định) |
| `detect` | chỉ nhận diện ảo hóa, nhanh, chạy được offline |
| `info` | chỉ in thông tin hệ thống, không benchmark |
| `bench` | chỉ benchmark (vẫn in verdict để biết ngữ cảnh) |
| `help` | in trợ giúp |

| Tuỳ chọn | Ý nghĩa |
|---|---|
| `--fast` | profile nhanh (payload nhỏ hơn) |
| `--no-net` | bỏ qua test mạng (không tạo traffic ra ngoài) |
| `--webhook URL` | gửi báo cáo Discord embed (env: `BH_WEBHOOK`) |
| `--json PATH` | ghi báo cáo JSON ra PATH (`-` = stdout) |
| `--markdown PATH` | ghi báo cáo Markdown ra PATH (`-` = stdout) |
| `--output PATH` | ghi báo cáo plain-text ra PATH |
| `--disk-dir DIR` | thư mục chứa file test disk (mặc định: `/tmp`) |
| `--no-color` | tắt màu ANSI |
| `--version` | in phiên bản |
| `-h`, `help` | in trợ giúp |

Biến môi trường: `BH_WEBHOOK`, `BH_FAST=1`, `BH_NO_NET=1`, `BH_DISK_DIR`, `BH_NO_COLOR=1`.

Exit codes: `0` ok | `1` benchmark không sinh được dữ liệu | `2` sai cú pháp lệnh.

Ví dụ chuẩn:

```sh
blackhole-vps-bench
blackhole-vps-bench detect
blackhole-vps-bench all --fast --webhook https://discord.com/api/webhooks/xxx/yyy
blackhole-vps-bench all --json report.json --markdown report.md
```

---

## 3. "KVM hay Docker?" — verdict và Evidence

Mọi kết luận đều kèm **Evidence**: các dòng bằng chứng in ngay dưới verdict để bạn tự kiểm chứng lại. Tool không đoán suông — mỗi dấu hiệu được ghi rõ nguồn (file nào, nội dung gì). Nếu đang chạy trong container, tool còn dò xem host bên trên là VM loại gì (dòng `Host VM : ...`), và ngược lại có thể gắn nhãn cloud (AWS EC2, Azure, Google Cloud, DigitalOcean, Alibaba, Tencent, OpenStack) dựa trên DMI + metadata.

| Loại nhận diện | Dấu hiệu chính (evidence) |
|---|---|
| Docker | `/.dockerenv` tồn tại; cgroup tham chiếu `docker` |
| Podman | `/run/.containerenv` tồn tại; cgroup tham chiếu `podman`/`libpod` |
| Kubernetes (CRI) | cgroup chứa `kubepods`; có serviceaccount của Kubernetes |
| LXC / LXD | cgroup tham chiếu `lxc`; `/proc/1/environ` có `container=lxc` |
| systemd-nspawn | `/run/systemd/container`; cgroup `machine.slice` |
| OpenVZ / Virtuozzo | `/proc/vz` tồn tại không có `/proc/bc`; `/proc/user_beancounters`; cgroup `vzcid`/`/vz/` |
| WSL | `/proc/version` nhắc Microsoft |
| KVM / QEMU | DMI vendor `QEMU` / product "Virtual Machine"; `systemd-detect-virt --vm` = `kvm`; clocksource `kvm-clock` |
| AWS EC2 (Nitro/KVM), GCE, DigitalOcean, Alibaba, Tencent, OpenStack | map từ DMI vendor/product tương ứng |
| Xen PV | `/sys/hypervisor/type` = `xen`; nếu có `control_d` thì là dom0 |
| Xen HVM | DMI vendor `Xen` hoặc product "HVM domU" |
| Hyper-V | DMI vendor "Microsoft Corporation" |
| VMware ESXi | DMI vendor `VMware*` |
| VirtualBox | DMI vendor "innotek GmbH" |
| bhyve | DMI vendor "FreeBSD bhyve" |
| Bare metal | không có hypervisor flag, không container marker, không DMI của VM |

Thêm nữa: cờ `hypervisor` trong `/proc/cpuinfo` làm bằng chứng dự phòng; ghi chú nested virtualization khi thấy `vmx`/`svm`; và nếu mọi nhận diện đều trống mới kết luận dedicated.

Ví dụ output (rút gọn):

```
[1] VIRTUALIZATION VERDICT
  Kind    : container
  Type    : docker
  Product : Docker
  Host VM : KVM/QEMU
  Verdict : Container (Docker) on host: KVM/QEMU
  Evidence:
  • /.dockerenv present
  • /proc/1/cgroup references docker
  • host DMI: vendor='QEMU' product='Standard PC (Q35 + ICH9, 2009)'
```

---

## 4. Cách đo benchmark

| Hạng mục | Cách đo |
|---|---|
| CPU single | bơm 256 MB (fast: 96 MB) qua `sha256sum`, tính MB/s; có warmup 8 MB không tính điểm |
| CPU multi | cùng bài trên, chạy song song `effective cores` job (số core thực theo cgroup), tính tổng MB/s |
| CPU cross-check | `openssl speed -seconds 2 -evp sha256` (k/s, chỉ để đối chiếu) |
| Memory | vòng lặp memcpy-style viết bằng C, biên dịch lúc chạy (cc/gcc/clang), lấy best của 3 passes, GB/s |
| Memory fallback | không có compiler thì dùng proxy `dd` — kết quả luôn ghi kèm `[method]` để bạn biết số nào thật |
| Disk seq/4K | `dd` ghi rồi đọc: seq block 1M, 4K block 4k; ghi có fsync; có `fio` thì thêm 4K random IOPS (randrw 8s, direct, bỏ qua khi `--fast`) |
| Network | download từ `speed.cloudflare.com/__down` (100 MB, fast: 25 MB; fallback cachefly), upload POST lên `speed.cloudflare.com/__up` (25 MB, fast: 10 MB), latency = TCP connect time |
| Địa lý | IPv4/IPv6 qua ipify; geo/ISP/ASN qua ip-api.com |

Vì sao số có thể khác các tool/label khác:

- **Shared vCPU**: nhà cung cấp oversell; CPU quota cgroup (ví dụ `200000/100000` = 2 core) mới là phần thật của bạn. Tool đọc quota trước rồi mới đo.
- **Overlayfs**: filesystem của container thường từ chối `O_DIRECT`. Tool probe trước với file 1 MB — được thì đo mode `direct+fsync`, không được thì tự hạ xuống `fsync (buffered)` và ghi rõ mode vào báo cáo. Số disk giữa hai mode không so sánh trực tiếp được.
- **Page cache**: nếu cả direct read cũng không dùng được, số đọc có thể bị "tốt ảo" do dữ liệu còn trong cache. Báo cáo ghi mode kèm `+direct-read` khi đọc qua direct I/O; nếu không thấy, hãy nghi ngờ số read.
- **Payload nhỏ trên disk bé**: kích thước test tự thu nhỏ còn tối đa ~20% dung lượng trống để không phá disk nhỏ.

---

## 5. BH-SCORE

7 thành phần, mỗi thành phần chặn tối đa 100 điểm, tổng tối đa **700**:

| Thành phần | Công thức từ số đo |
|---|---|
| CPU 1-core | `sha256 1-core (MB/s) / 5` |
| CPU multi | `sha256 multi (MB/s) / 20` |
| Memory | `băng thông (GB/s) × 8` |
| Disk seq | `seq write (MB/s) / 10` |
| Disk 4K | `(4k write + 4k read) (MB/s) / 4` |
| Net down | `download (Mbps) / 20` |
| Net up | `upload (Mbps) / 20` |

Ví dụ đọc điểm: 1 core đạt ~500 MB/s sha256 → 500/5 = 100 điểm; RAM 12.5 GB/s → 100 điểm; net 2000 Mbps down → 100 điểm. Một thành phần thiếu dữ liệu (ví dụ `--no-net`) tính 0, không bù điểm.

---

## 6. Cgroup limits — vì sao tool này báo đúng RAM/CPU của container

Vào một Docker container, nhiều tool "system info" báo RAM 256 GB và 128 core — đó là của **host**, không phải của bạn. Tool này đọc trực tiếp cấu hình cgroup:

- cgroup v2: `/sys/fs/cgroup/cpu.max`, `memory.max`, `cpuset.cpus.effective`
- cgroup v1: `cpu.cfs_quota_us`/`cpu.cfs_period_us`, `memory.limit_in_bytes`, `cpuset.cpus`

Từ đó tính ra:

- **CPU quota** (số core thực, ví dụ `2.00`) và **effective cores** = min(quota, số core thấy được)
- **Container limit** cho RAM (lấy min giữa limit cgroup và MemTotal)
- **cpuset** nếu bị giới hạn ràng buộc vào core cụ thể

Số job benchmark multi-core cũng chạy theo effective cores, nên điểm multi phản ánh đúng phần CPU được cấp, không phải toàn host. Báo cáo in rõ:

```
  CPU     : Intel(R) Xeon(R) ... 
            8 logical / 4 physical cores
            effective: 2 core(s), cgroup quota 2.00 cores, cpuset [0-7]
  RAM     : total 1024 MB, avail 512 MB, swap 0 MB | container limit 1024 MB
```

---

## 7. Gửi báo cáo Discord

```sh
blackhole-vps-bench all --webhook 'https://discord.com/api/webhooks/ID/TOKEN'
# hoặc: export BH_WEBHOOK='https://discord.com/api/webhooks/ID/TOKEN'
```

Tool POST một embed (màu theo verdict: container xanh dương, VM tím, bare metal xanh lá) gồm:

- **Verdict** (VD: `Container (Docker) on host: KVM/QEMU`)
- **BH-SCORE** tổng / 700
- **CPU sha256** 1 core / multi (kèm số threads)
- **Memory** (GB/s)
- **Disk** seq và 4K
- **Network** down/up (bỏ qua khi `--no-net`)
- **Location** (geo/ISP)

Phần mô tả embed là đoạn cuối của báo cáo text (tối đa 1900 ký tự). Gửi thành công khi Discord trả HTTP 204/200; thất bại chỉ cảnh báo, không làm tool thoát lỗi.

---

## 8. GitHub Actions

Hai workflow có sẵn trong `.github/workflows/`.

### 8.1. `vps-bench selftest` — tool tự test bản thân

Chạy khi push lên `main` (thư mục `vps-bench/**`), khi pull_request thay đổi `vps-bench/**`, chạy tay qua `workflow_dispatch`, và định kỳ cron `0 3 * * 1` (mỗi thứ Hai 03:00 UTC). Bốn job:

1. **shellcheck** — build bundle rồi lint `dist/blackhole-vps-bench`, `install.sh`, `run-tests.sh` (`shellcheck -x -e SC2034,SC2016,SC2317`), kèm kiểm tra bundle trong `dist/` không bị stale so với source.
2. **smoke** — `tests/run-tests.sh` + chạy full bench `all --fast` trên matrix `ubuntu-24.04` và `ubuntu-22.04`, upload artifact `report-<os>` (JSON/Markdown/text).
3. **containers** — chạy trong Docker image `alpine:3.20`, `debian:12` (full bench `--no-net`) và `rockylinux:9`, `fedora:41` (chỉ `detect`).
4. **discord notify** — tổng hợp kết quả 3 job trên, gửi embed PASS/FAIL tới secret `DISCORD_WEBHOOK` (nếu chưa set thì bỏ qua, không fail).

### 8.2. `vps-bench remote` — bench VPS thật qua SSH

Chỉ chạy tay qua `workflow_dispatch` với 2 input: `fast` (mặc định bật) và `extra_args` (VD `--disk-dir /data`). Workflow đóng gói `bin/` + `lib/` thành tarball, scp lên VPS, chạy `blackhole-vps-bench all` ngay trên VPS, scp báo cáo về làm artifact `vps-report` và append `report.md` vào job summary.

### Hướng dẫn set secrets từng bước

1. Tạo SSH key riêng cho CI: `ssh-keygen -t ed25519 -f bh_ci_key`, append `bh_ci_key.pub` vào `/root/.ssh/authorized_keys` trên VPS.
2. Trên GitHub: **Settings → Secrets and variables → Actions → New repository secret**, thêm lần lượt:
   - `VPS_HOST` — IP hoặc hostname của VPS
   - `VPS_USER` — user SSH (thường là `root`)
   - `VPS_SSH_KEY` — **toàn bộ nội dung** file key private `bh_ci_key` (bao gồm cả dòng BEGIN/END)
   - `VPS_PORT` — tuỳ chọn, nếu SSH không dùng cổng 22
   - `DISCORD_WEBHOOK` — tuỳ chọn, để tool gửi report về Discord (dùng chung cho cả hai workflow)
3. Vào tab **Actions → vps-bench remote → Run workflow**, chọn `fast`, điền `extra_args` nếu cần, chạy.
4. Nếu thiếu secrets bắt buộc, workflow không lỗi — nó in notice "Remote bench disabled" và bỏ qua.

Lưu ý: `ssh-keyscan` được dùng để thêm host key của VPS vào known_hosts lúc chạy. Nếu muốn chặt hơn, pin host key trước khi chạy.

---

## 9. Output JSON

`--json report.json` sinh một object với các nhóm key chính:

```json
{
  "tool": "blackhole-vps-bench", "version": "1.0.0", "mode": "all",
  "virtualization": { "kind": "container", "type": "docker", "product": "Docker",
                      "host_type": "kvm", "host_product": "KVM/QEMU",
                      "cloud": "", "evidence": ["..."] },
  "system": { "os": "...", "kernel": "...", "arch": "x86_64",
              "cpu": { "model": "...", "logical_cores": 8, "effective_cores": 2 },
              "memory": { "total_mb": 1024, "available_mb": 512, "swap_mb": 0 } },
  "limits": { "cgroup_version": 2, "cpu_quota_cores": "2.00",
              "memory_limit_mb": 1024, "cpuset": "0-7" },
  "bench": { "cpu": { "sha256_1c_mbps": 498.2, "sha256_mc_mbps": 995.4, "threads": 2 },
             "memory": { "gbps": 11.4, "method": "c-loop" },
             "disk": { "mode": "direct+fsync +direct-read", "seq_write_mbps": 210.5,
                       "k4_write_mbps": 55.1, "k4_read_mbps": 260.0,
                       "fio_randread_iops": "", "fio_randwrite_iops": "" },
             "network": { "download_mbps": 940.1, "upload_mbps": 380.2, "connect_ms": 1.9 } },
  "score": { "cpu_1c": 100, "cpu_multi": 50, "memory": 91, "disk_seq": 21,
             "disk_4k": 79, "net_down": 47, "net_up": 19, "total": 407, "max": 700 }
}
```

Các hạng mục chưa đo được (ví dụ chạy `detect`/`info`, hoặc `fio` không có mặt) sẽ là chuỗi rỗng `""` thay vì số 0 cứng, giúp phân biệt "chưa chạy" với "chạy mà bằng 0".

---

## 10. FAQ

**Multi-core thấp hơn core × single?** Bình thường. Hyper-Threading/SMT chia sẻ Execution unit, cache và băng thông bộ nhớ; container còn bị chặn bởi CPU quota. Điểm multi phản ánh throughput thật khi chạy đồng thời, không phải phép nhân lý thuyết.

**Disk read cao bất thường?** Page cache. Khi filesystem không cho `O_DIRECT` (khá phổ biến trong container/overlayfs), phần đọc được tính nhanh vì dữ liệu còn trong RAM. Kiểm tra dòng mode trong báo cáo: không thấy `+direct-read` nghĩa là số read có thể bị "tốt ảo".

**Có cần root không?** Không. Tool chỉ đọc `/proc`, `/sys`, ghi một file test tạm vào `--disk-dir` (mặc định `/tmp`) rồi xoá. Có `fio` thì thêm số IOPS, có `openssl` thì thêm cross-check — thiếu tự giản lược.

**Chạy trong Alpine/busybox được không?** Được — pipeline CI chính là chạy trong `alpine:3.20`. Cần `bash` và `curl` (cài `coreutils`/`openssl` cho đủ tính năng).

---

## English quick reference

`blackhole-vps-bench` is a single-file pure-bash Linux tool that (1) detects the virtualization environment — KVM/QEMU, Docker, Podman, Kubernetes, LXC/LXD, systemd-nspawn, OpenVZ/Virtuozzo, Xen PV/HVM, Hyper-V, VMware, VirtualBox, bhyve, WSL, or bare metal — printing verifiable evidence lines for every verdict, and (2) benchmarks the real cgroup-limited configuration: CPU sha256 throughput (single and effective-core parallel), memory bandwidth (compiled C memcpy loop with a labeled dd fallback), disk sequential and 4K dd throughput with automatic O_DIRECT detection plus optional fio random IOPS, and network download/upload via Cloudflare speed endpoints with TCP connect latency, plus IP geo/ASN from ip-api.com. Each of 7 score components (cpu1c = sha1c/5, cpumc = shanc/20, mem = GBps*8, dseq = seqw/10, d4k = (4kw+4kr)/4, ndown = down/20, nup = up/20) is capped at 100 for a BH-SCORE of at most 700. Reports go to pretty terminal text, JSON, Markdown, and optionally a Discord embed webhook.

| Flag | Effect |
|---|---|
| `all` / `detect` / `info` / `bench` / `help` | modes (default `all`) |
| `--fast` | smaller test payloads |
| `--no-net` | skip network tests |
| `--webhook URL` | POST Discord embed (env `BH_WEBHOOK`) |
| `--json PATH` | JSON report (`-` = stdout) |
| `--markdown PATH` | Markdown report (`-` = stdout) |
| `--output PATH` | plain-text report |
| `--disk-dir DIR` | disk test directory (default `/tmp`) |
| `--no-color` | disable ANSI colors |
| `--version` | print version |

```sh
curl -fsSL https://raw.githubusercontent.com/victoryvpsvn-star/blackhole-discord-terminal/main/vps-bench/install.sh | sh
blackhole-vps-bench all --fast --webhook https://discord.com/api/webhooks/xxx/yyy
```

Exit codes: 0 ok, 1 no benchmark data, 2 usage error. No root required.
