# blackhole-vps-bench

Tool kiểm tra VPS của bạn thực chất đang chạy trên gì — KVM, QEMU, Docker, Podman, Kubernetes, LXC/LXD, OpenVZ, Xen, Hyper-V, VMware, VirtualBox, bhyve, WSL hay máy chủ dedicated — rồi benchmark đúng **cấu hình thực** (đọc cgroup limit chứ không báo nhầm RAM/CPU của host), **audit SSH & bảo mật ngay trên máy** (password hay key auth, root login, firewall, fail2ban, brute-force log...), đo **tốc độ mạng down/up + latency/jitter**. Thuần bash, một file duy nhất, chạy được cả trong container Alpine, có GitHub Actions selftest, và **kết quả in thẳng ra terminal** — Discord chỉ là tuỳ chọn.

- Phiên bản: **v3.0.0**
- Repo: `victoryvpsvn-star/blackhole-discord-terminal`
- Yêu cầu: Linux + bash, `curl` (bắt buộc cho phần network), còn lại mọi thứ đều tự động hóa qua `dd`/`sha256sum`/`openssl`/`fio`/`ss` nếu có. Không cần root (có root thì audit sâu hơn).

> **Có gì mới ở v2?** Mode `sec` audit SSH/bảo mật độc lập · badge màu [OK]/[WARN]/[BAD] ngay terminal · ICMP latency + jitter · deep-scan (DNS, TCP congestion control, entropy, TUN/FUSE/PPP, load, tiến trình, timezone) · JSON/Markdown có thêm `security` + `net_env` · container job trong CI bị giới hạn cứng 2 CPU / 2 GB để chứng minh bench tự scale theo quota.
>
> **Có gì mới ở v3?** Fingerprint cloud đầy đủ: **AWS Nitro vs Xen, Azure (asset-tag chuẩn), GCE, OCI, Alibaba, Tencent, DigitalOcean, Hetzner, Linode, Scaleway, OpenStack** (DMI + metadata IMDSv2) · chassis_type (VM vs máy vật lý) · phân biệt **WSL1/WSL2** + phát hiện chroot + Virtuozzo 7 (`envID`) · **CPU steal %** (báo động hàng xóm ồn ào) · multi-thread efficiency % · **4K IOPS** tự tính + phân loại ổ **NVMe/SSD/HDD** + scheduler · tier label cho mọi metric (entry-NVMe, gigabit-class…) · grade **S→F** cho BH-SCORE · **sửa bug endpoint** (Cloudflare chặn >50 MB, cachefly thành stub → best-of-N: Cloudflare 50 MB + OVH + Hetzner + Thinkbroadband, chọn số nhanh nhất) · audit SSH sâu hơn: **PermitEmptyPasswords, LoginGraceTime, X11Forwarding, KbdInteractive, AllowUsers, file permission của authorized_keys (StrictModes), fail2ban có ĐANG CHẠY + sshd jail, sshguard, crowdsec, sshd version, sshd process/listening** · module hardening mới: **SELinux/AppArmor, pending updates, port nguy hiểm expose (redis/mysql/mongo/memcached…), scan cryptominer, docker.sock, sysctl (kptr/dmesg/BPF/yama), /tmp noexec, cron/timers**.

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

Bốn lệnh hay dùng nhất:

```sh
blackhole-vps-bench detect                # KVM hay Docker? (offline, vài giây)
blackhole-vps-bench all --fast            # detect + bench nhanh + audit bảo mật
blackhole-vps-bench sec                   # chỉ audit SSH & bảo mật (không bench)
blackhole-vps-bench all --webhook 'https://discord.com/api/webhooks/ID/TOKEN'   # nếu MUỐN đẩy Discord
```

Kết quả luôn in ngay terminal: verdict có bằng chứng (evidence), benchmark có màu, audit SSH có badge `[OK]`/`[WARN]`/`[BAD]`, cuối là BH-SCORE. Không cần webhook gì hết.

---

## 2. Chế độ và tuỳ chọn

Đúng theo `blackhole-vps-bench help`.

| Chế độ | Ý nghĩa |
|---|---|
| `all` | detect + info + benchmark đầy đủ + security audit (mặc định) |
| `detect` | chỉ nhận diện ảo hóa, nhanh, chạy được offline |
| `info` | system info + security audit, không benchmark |
| `bench` | chỉ benchmark (vẫn in verdict để biết ngữ cảnh) |
| `sec` | chỉ audit SSH & bảo mật — không benchmark, không tạo traffic |
| `help` | in trợ giúp |

| Tuỳ chọn | Ý nghĩa |
|---|---|
| `--fast` | profile nhanh (payload nhỏ hơn) |
| `--no-net` | bỏ qua test mạng (không tạo traffic ra ngoài) |
| `--no-sec` | bỏ qua audit SSH/bảo mật |
| `--webhook URL` | gửi báo cáo Discord embed (env: `BH_WEBHOOK`) — **tuỳ chọn** |
| `--json PATH` | ghi báo cáo JSON ra PATH (`-` = stdout) |
| `--markdown PATH` | ghi báo cáo Markdown ra PATH (`-` = stdout) |
| `--output PATH` | ghi báo cáo plain-text ra PATH |
| `--disk-dir DIR` | thư mục chứa file test disk (mặc định: `/tmp`) |
| `--no-color` | tắt màu ANSI |
| `--version` | in phiên bản |
| `-h`, `help` | in trợ giúp |

Biến môi trường: `BH_WEBHOOK`, `BH_FAST=1`, `BH_NO_NET=1`, `BH_NO_SEC=1`, `BH_DISK_DIR`, `BH_NO_COLOR=1`.

Exit codes: `0` ok | `1` benchmark không sinh được dữ liệu | `2` sai cú pháp lệnh.

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
| WSL | `/proc/version` nhắc Microsoft; **v3 phân biệt WSL1/WSL2** qua `microsoft-standard` trong kernel version |
| Chroot | `/` khác inode với `/proc/1/root/.` (chỉ kết luận khi không có signal nào khác) |
| KVM / QEMU | DMI vendor `QEMU` / product "Virtual Machine"; `systemd-detect-virt --vm` = `kvm`; clocksource `kvm-clock` |
| AWS EC2 (Nitro/KVM), GCE, DigitalOcean, Alibaba, Tencent, OpenStack | map từ DMI vendor/product; **v3 tách AWS Xen-gen (product `HVM domU`) vs Nitro, và instance `.metal` → bare metal** |
| **v3**: Oracle Cloud (OCI), Hetzner, Linode, Scaleway | OCI qua chassis asset-tag `OracleCloud.com`; Hetzner/Linode/Scaleway qua DMI vendor/bios + metadata probe |
| Xen PV | `/sys/hypervisor/type` = `xen`; nếu có `control_d` thì là dom0 |
| Xen HVM | DMI vendor `Xen` hoặc product "HVM domU" |
| Hyper-V | DMI vendor "Microsoft Corporation" + product "Virtual Machine"; **chỉ dán nhãn Azure khi chassis asset-tag khớp `7783-7084-…-77`** — Hyper-V on-prem không bị gọi nhầm Azure nữa (v3 fix) |
| VMware ESXi | DMI vendor `VMware*` |
| VirtualBox | DMI vendor "innotek GmbH" |
| bhyve | DMI vendor "FreeBSD bhyve" |
| Bare metal | không có hypervisor flag, không container marker, không DMI của VM |

Ví dụ output (rút gọn):

```
[1] VIRTUALIZATION VERDICT
  Kind    : container
  Type    : docker
  Product : Docker
  Host VM : KVM
  Verdict : Container (Docker) on host: KVM
  Evidence:
  • /.dockerenv present
  • systemd-detect-virt --vm = kvm
```

---

## 4. Audit SSH & bảo mật (v2) — "hacker checklist" cho chính máy bạn

Section `[5] SSH & SECURITY AUDIT` chỉ đọc cấu hình **trên chính máy này** — không scan/đánh máy ai. Mỗi dòng có badge màu khi in ra terminal:

| Badge | Ý nghĩa |
|---|---|
| `[OK]` (xanh lá) | cấu hình tốt |
| `[WARN]` (vàng) | nên sửa (ví dụ bật password auth, firewall inactive) |
| `[BAD]` (đỏ) | rủi ro nghiêm trọng (PermitRootLogin yes, mật khẩu trống, tài khoản UID-0 lạ) |
| `[INFO]` | thông tin tham khảo |

Các check thực hiện:

- **sshd effective config**: `sshd -T` khi có quyền; không thì parse `/etc/ssh/sshd_config` + drop-in `/etc/ssh/sshd_config.d/*.conf` đúng semantics *first-match-wins* của OpenSSH (drop-in thường thắng vì Include nằm đầu file). In rõ nguồn cấu hình đã dùng.
- **PasswordAuthentication** — `no` = chỉ cho đăng nhập bằng key (khuyến nghị); `yes`/mặc định = cảnh báo brute-force surface.
- **PubkeyAuthentication** — tắt sẽ bị cảnh báo.
- **PermitRootLogin** — `yes` là `[BAD]`; `prohibit-password` (mặc định) kèm gợi ý.
- **SSH port(s)** + `MaxAuthTries` (hỗ trợ multi-Port).
- **(v3) PermitEmptyPasswords** — `yes` là `[BAD]` · **LoginGraceTime** > 120s → `[WARN]` · **X11Forwarding** bật → `[WARN]` · **KbdInteractiveAuthentication** + password auth cùng bật → `[WARN]` · **AllowUsers/AllowGroups** → ghi nhận whitelist.
- **(v3) sshd runtime**: binary probe `/usr/sbin/sshd` → version qua `ssh -V`, process đang chạy hay không (`pgrep`), đang listen trên port nào (`ss -tlnp`).
- **(v3) File permission**: `authorized_keys`/`~/.ssh`/home dir ghi quyền group/world-writable → `[WARN]` (sshd `StrictModes` sẽ TỪ CHỐI key nếu home ghi được bởi group/others).
- **authorized_keys**: đếm key của `root` + mọi `/home/*`, phân loại `ed25519`/`RSA`/`ECDSA`, và dùng `ssh-keygen -lf` (nếu có) để bắt key yếu < 2048 bit.
- **Failed SSH logins**: đếm qua `journalctl` (24h gần nhất) hoặc `/var/log/auth.log`; ≥ 50 lần/24h → cảnh báo đang bị brute-force.
- **Firewall**: ufw active / nftables / iptables rules / firewalld; không thấy gì → `[WARN]`.
- **fail2ban** — v3 kiểm tra cả trạng thái **ĐANG CHẠY** (`systemctl is-active` / `pgrep fail2ban-server`) + sshd jail qua `fail2ban-client status sshd`; cài mà không chạy → `[WARN]`. Nhận diện thêm **sshguard** và **crowdsec**.
- **(v3) Hardening scan** (module mới `85-hardening.sh`): **SELinux/AppArmor** · **pending package updates** (apt/dnf/yum/apk/pacman, >50 gói → `[WARN]`) · **port nguy hiểm bind wildcard** — redis/mongo/memcached/telnet expose là `[BAD]`, mysql/postgres/rdp/vnc/ftp/smb là `[WARN]` · **scan cryptominer** (`xmrig`, `kdevtmpfsi`, `kinsing`, `stratum+tcp`…) · **docker.sock** world-accessible là `[BAD]` (tương đương root) · **sysctl kernel**: `kptr_restrict`, `dmesg_restrict`, `unprivileged_bpf_disabled`, `yama ptrace_scope` · **/tmp** có `noexec,nosuid` không · đếm **cron + systemd timers**.
- **sudo NOPASSWD**, **tài khoản UID-0** (ngoài root là `[BAD]`), **mật khẩu trống** trong `/etc/shadow` (cần root), **ASLR**, **auto security updates** (unattended-upgrades / dnf-automatic), **listening TCP ports**.
- Kết: **Posture** `GOOD` / `FAIR` / `WEAK` kèm đếm pass/warn/bad.

Chạy riêng nhanh:

```sh
blackhole-vps-bench sec            # chỉ audit, vài giây
blackhole-vps-bench sec --json sec.json
```

> Tool này là audit **một chiều trên máy mình** (kiểu Lynis thu nhỏ). Nó không brute-force, không scan mạng ai cả.

---

## 5. Cách đo benchmark

| Hạng mục | Cách đo |
|---|---|
| CPU single | bơm 256 MB (fast: 96 MB) qua `sha256sum`, tính MB/s; có warmup 8 MB không tính điểm |
| CPU multi | cùng bài trên, chạy song song `effective cores` job (số core thực theo cgroup), tính tổng MB/s |
| CPU cross-check | `openssl speed -seconds 2 -evp sha256` (k/s, chỉ để đối chiếu) |
| Memory | vòng lặp memcpy-style viết bằng C, biên dịch lúc chạy (cc/gcc/clang), lấy best của 3 passes, GB/s |
| Memory fallback | không có compiler thì dùng proxy `dd` — kết quả luôn ghi kèm `[method]` để bạn biết số nào thật |
| Disk seq/4K | `dd` ghi rồi đọc: seq block 1M, 4K block 4k; ghi có fsync; có `fio` thì thêm 4K random IOPS (randrw 8s, direct, bỏ qua khi `--fast`). **v3: tự tính 4K IOPS baseline từ dd + nhận diện ổ NVMe/SSD/HDD + I/O scheduler** |
| Network | **v3 (fix bug)**: Cloudflare chặn payload > 50 MB (HTTP 403) và cachefly đã thành stub 25 byte → tool dùng **best-of-N endpoint đã verify**: Cloudflare 50 MB → OVH → Thinkbroadband (fast: CF 10 MB → OVH), thử endpoint kế khi transfer kết thúc < 2s hoặc fail, **lấy số lớn nhất**; in rõ endpoint thắng + bảng attempts. Upload POST lên `speed.cloudflare.com/__up` (25 MB, fast: 10 MB), latency = TCP connect time |
| ICMP latency + jitter (v2) | `ping -c 4` tới 1.1.1.1 (fallback 8.8.8.8): avg + mdev (jitter). Container không có CAP_NET_RAW thì tự bỏ qua, giữ số TCP connect |
| Địa lý | IPv4/IPv6 qua ipify; geo/ISP/ASN qua ip-api.com |

Deep-scan (v2, in trong section `[2] SYSTEM / REAL CONFIG`): TCP congestion control đang dùng + các thuật toán available (thấy `bbr` là VPS tốt cho proxy/VPN), entropy pool, DNS resolvers, TUN/TAP + FUSE + PPP (đủ để chạy VPN hay không), load average, số tiến trình, timezone.

Deep-scan v3: **CPU steal %** — lấy mẫu `/proc/stat` 2 lần (0.7s): steal > 5% in kèm `noisy neighbor!` (VPS oversell là đây) · CPU freq hiện tại · cpuset cores count · **THP + hugepages** · **swap** total/free · MTU · multi-thread efficiency (`multi ÷ (single × jobs) × 100` — ~100% là scale tuyến tính).

Mọi metric benchmark đều có **tier label** ngay dòng số liệu: CPU (`standard`/`high-perf`/`server-grade`…), RAM (GB/s), disk (`HDD-class`/`SATA-SSD-class`/`entry-NVMe`/`premium-NVMe`), IOPS (`cloud-standard`/`fast-SSD`/`NVMe-class`), net (`slow`/`standard`/`fast`/`gigabit-class`/`10G-class`) — đọc một phát biết ngay VPS mình nằm đẳng cấp nào.

Vì sao số có thể khác các tool/label khác:

- **Shared vCPU**: nhà cung cấp oversell; CPU quota cgroup (ví dụ `200000/100000` = 2 core) mới là phần thật của bạn. Tool đọc quota trước rồi mới đo.
- **Overlayfs**: filesystem của container thường từ chối `O_DIRECT`. Tool probe trước với file 1 MB — được thì đo mode `direct+fsync`, không được thì tự hạ xuống `fsync (buffered)` và ghi rõ mode vào báo cáo. Số disk giữa hai mode không so sánh trực tiếp được.
- **Page cache**: nếu cả direct read cũng không dùng được, số đọc có thể bị "tốt ảo" do dữ liệu còn trong cache. Báo cáo ghi mode kèm `+direct-read` khi đọc qua direct I/O; nếu không thấy, hãy nghi ngờ số read.
- **Payload nhỏ trên disk bé**: kích thước test tự thu nhỏ còn tối đa ~20% dung lượng trống để không phá disk nhỏ.

---

## 6. BH-SCORE

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

**v3 thêm grade letter** theo tỷ lệ điểm/tối đa: `S ≥ 630` · `A ≥ 525` · `B ≥ 420` · `C ≥ 315` · `D ≥ 210` · `F` dưới — in ngay cạnh TOTAL và trong JSON (`score.grade`).

---

## 7. Cgroup limits — vì sao tool này báo đúng RAM/CPU của container

Vào một Docker container, nhiều tool "system info" báo RAM 256 GB và 128 core — đó là của **host**, không phải của bạn. Tool này đọc trực tiếp cấu hình cgroup:

- cgroup v2: `/sys/fs/cgroup/cpu.max`, `memory.max`, `cpuset.cpus.effective`
- cgroup v1: `cpu.cfs_quota_us`/`cpu.cfs_period_us`, `memory.limit_in_bytes`, `cpuset.cpus`

Từ đó tính ra:

- **CPU quota** (số core thực, ví dụ `2.00`) và **effective cores** = min(quota, số core thấy được)
- **Container limit** cho RAM (lấy min giữa limit cgroup và MemTotal)
- **cpuset** nếu bị giới hạn ràng buộc vào core cụ thể

Số job benchmark multi-core cũng chạy theo effective cores, nên điểm multi phản ánh đúng phần CPU được cấp, không phải toàn host. CI còn có job chạy container bị giới hạn cứng `--cpus 2 --memory 2g` và assert báo cáo phải nhắc "cgroup quota" — chứng minh tính năng này thật, không phải lời nói.

```
  CPU     : Intel(R) Xeon(R) ...
            8 logical / 4 physical cores
            effective: 2 core(s), cgroup quota 2.00 cores, cpuset [0-7]
  RAM     : total 1024 MB, avail 512 MB, swap 0 MB | container limit 1024 MB
```

---

## 8. Gửi báo cáo Discord (tuỳ chọn — không bắt buộc)

Mặc định mọi thứ in ngay terminal. Chỉ khi bạn **muốn** đẩy kết quả đi đâu đó:

```sh
blackhole-vps-bench all --webhook 'https://discord.com/api/webhooks/ID/TOKEN'
# hoặc: export BH_WEBHOOK='https://discord.com/api/webhooks/ID/TOKEN'
```

Tool POST một embed (màu theo verdict: container xanh dương, VM tím, bare metal xanh lá) gồm: Verdict, BH-SCORE, CPU, Memory, Disk, Network, **SSH auth + Security posture (v2)**, Location. Gửi thành công khi Discord trả HTTP 204/200; thất bại chỉ cảnh báo, không làm tool thoát lỗi.

---

## 9. GitHub Actions

Hai workflow có sẵn trong `.github/workflows/`.

### 9.1. `vps-bench selftest` — tool tự test bản thân

Chạy khi push lên `main` (thư mục `vps-bench/**`), khi pull_request thay đổi `vps-bench/**`, chạy tay qua `workflow_dispatch`, và định kỳ cron `0 3 * * 1` (mỗi thứ Hai 03:00 UTC). Bốn job:

1. **shellcheck** — build bundle rồi lint `dist/blackhole-vps-bench`, `install.sh`, `run-tests.sh` (`shellcheck -x -e SC2034,SC2016,SC2317,SC2329`), kèm kiểm tra bundle trong `dist/` không bị stale so với source.
2. **smoke** — `tests/run-tests.sh` (bao gồm test mode `sec` + `--no-sec` + schema JSON có `security`) + chạy full bench `all --fast` trên matrix `ubuntu-24.04` và `ubuntu-22.04`, upload artifact `report-<os>` (JSON/Markdown/text).
3. **containers** — chạy trong Docker image `alpine:3.20`, `debian:12` (full bench `--no-net`), **`ubuntu:24.04` bị giới hạn `--cpus 2 --memory 2g --shm-size 1g` (full bench + assert "cgroup quota" xuất hiện trong báo cáo — chứng minh bench tự scale theo quota)**, và `rockylinux:9`, `fedora:41` (chỉ `detect`).
4. **discord notify** — tổng hợp kết quả 3 job trên, gửi embed PASS/FAIL tới secret `DISCORD_WEBHOOK` (nếu chưa set thì bỏ qua, không fail).

### 9.2. `vps-bench remote` — bench VPS thật qua SSH

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

---

## 10. Output JSON

`--json report.json` sinh một object với các nhóm key chính (v2 thêm `net_env` và `security`; **v3 thêm**: `virtualization.chassis_type/chassis_class/wsl_gen/is_chroot/aws_gen/cloud_method`, `system.steal_pct`, `cpu.freq_mhz/efficiency_pct`, `memory.swap`, `limits.cpuset_cores`, disk `class/scheduler/rotational/iops_4k_*`, network `endpoint/attempts`, security `sshd_version/sshd_running/permit_empty_passwords/login_grace_time/x11_forwarding/allow_users/auth_key_perm_issues/mac/updates/risky_ports/miners/docker_sock/sysctl/tmp_opts/sshguard/crowdsec`, `score.grade`):

```json
{
  "tool": "blackhole-vps-bench", "version": "3.0.0", "mode": "all",
  "virtualization": { "kind": "container", "type": "docker", "product": "Docker",
                      "host_type": "kvm", "host_product": "KVM/QEMU",
                      "cloud": "", "evidence": ["..."] },
  "system": { "os": "...", "kernel": "...", "arch": "x86_64",
              "cpu": { "model": "...", "logical_cores": 8, "effective_cores": 2 },
              "memory": { "total_mb": 1024, "available_mb": 512, "swap_mb": 0 } },
  "limits": { "cgroup_version": 2, "cpu_quota_cores": "2.00",
              "memory_limit_mb": 1024, "cpuset": "0-7" },
  "net_env": { "tcp_cc": "bbr", "dns": "1.1.1.1,8.8.8.8", "entropy": 256,
               "tun": 0, "fuse": 0, "ppp": 0, "load": "0.10 0.08 0.09", "processes": 87 },
  "bench": { "cpu": { "sha256_1c_mbps": 498.2, "sha256_mc_mbps": 995.4, "threads": 2 },
             "memory": { "gbps": 11.4, "method": "c-loop" },
             "disk": { "mode": "direct+fsync +direct-read", "seq_write_mbps": 210.5,
                       "k4_write_mbps": 55.1, "k4_read_mbps": 260.0,
                       "fio_randread_iops": "", "fio_randwrite_iops": "" },
             "network": { "download_mbps": 940.1, "upload_mbps": 380.2, "connect_ms": 1.9,
                          "icmp_latency_ms": "", "icmp_jitter_ms": "" } },
  "security": { "sshd_found": 1, "password_auth": "no", "pubkey_auth": "yes",
                "root_login": "prohibit-password", "ports": "22",
                "authorized_keys": 2, "key_types": "ed25519x2", "weak_keys": 0,
                "failed_logins": "0 in last 24h (journalctl)",
                "firewall": "ufw active", "fail2ban": 1, "uid0_accounts": "root",
                "empty_passwords": "0", "sudo_nopasswd": "no", "aslr": "2",
                "auto_updates": "enabled (unattended-upgrades)",
                "listening_ports": "22,80,443", "pass": 7, "warn": 1, "bad": 0,
                "posture": "GOOD" },
  "score": { "cpu_1c": 100, "cpu_multi": 50, "memory": 91, "disk_seq": 21,
             "disk_4k": 79, "net_down": 47, "net_up": 19, "total": 407, "max": 700 }
}
```

Các hạng mục chưa đo được (ví dụ chạy `detect`/`info`, hoặc `fio` không có mặt) sẽ là chuỗi rỗng `""` thay vì số 0 cứng, giúp phân biệt "chưa chạy" với "chạy mà bằng 0".

---

## 11. FAQ

**Multi-core thấp hơn core × single?** Bình thường. Hyper-Threading/SMT chia sẻ execution unit, cache và băng thông bộ nhớ; container còn bị chặn bởi CPU quota. Điểm multi phản ánh throughput thật khi chạy đồng thời, không phải phép nhân lý thuyết.

**Disk read cao bất thường?** Page cache. Khi filesystem không cho `O_DIRECT` (khá phổ biến trong container/overlayfs), phần đọc được tính nhanh vì dữ liệu còn trong RAM. Kiểm tra dòng mode trong báo cáo: không thấy `+direct-read` nghĩa là số read có thể bị "tốt ảo".

**Có cần root không?** Không. Tool chỉ đọc `/proc`, `/sys`, ghi một file test tạm vào `--disk-dir` (mặc định `/tmp`) rồi xoá. Có root thì audit sâu hơn (`sshd -T`, `/etc/shadow`, `journalctl`, đếm failed logins chính xác). Thiếu gì tự giản lược và ghi rõ `n/a`.

**Audit SSH có đụng tới máy khác không?** Không. Toàn bộ section `[5]` chỉ đọc cấu hình và log của chính máy đang chạy tool — giống Lynis thu nhỏ. Không brute-force, không scan mạng.

**Chạy trong Alpine/busybox được không?** Được — pipeline CI chính là chạy trong `alpine:3.20`. Cần `bash` và `curl` (cài `coreutils`/`openssl` cho đủ tính năng).

---

## English quick reference

`blackhole-vps-bench` is a single-file pure-bash Linux tool that (1) detects the virtualization environment — KVM/QEMU, Docker, Podman, Kubernetes, LXC/LXD, systemd-nspawn, OpenVZ/Virtuozzo 7, Xen PV/HVM, Hyper-V, VMware, VirtualBox, Parallels, bhyve, WSL1/WSL2, chroot, or bare metal — plus cloud fingerprinting (AWS Nitro vs Xen, Azure via chassis asset tag, GCE, Oracle Cloud, Alibaba, Tencent, DigitalOcean, Hetzner, Linode, Scaleway, OpenStack) with verifiable evidence lines for every verdict; (2) benchmarks the real cgroup-limited configuration: CPU sha256 throughput (single and effective-core parallel, with multi-thread efficiency %), memory bandwidth (compiled C memcpy loop with a labeled dd fallback), disk sequential and 4K dd throughput with derived 4K IOPS, NVMe/SSD/HDD classification and scheduler detection, automatic O_DIRECT probing plus optional fio random IOPS, and network download via verified best-of-N endpoints (Cloudflare 50 MB, OVH, Thinkbroadband) with upload via Cloudflare, TCP connect latency plus ICMP latency/jitter when ping is permitted; (3) audits the local SSH & security posture (password vs pubkey auth, root login, PermitEmptyPasswords, LoginGraceTime, X11, AllowUsers, authorized_keys inventory with weak-key and permission checks, sshd runtime/version, fail2ban jail state, sshguard, crowdsec, failed login counts, firewall, SELinux/AppArmor, pending updates, exposed services, cryptominer scan, docker.sock, kernel sysctls, UID-0 accounts, empty passwords, sudo NOPASSWD, ASLR, auto updates) summarized as GOOD/FAIR/WEAK — local machine only, no remote scanning; and (4) reports everything to the terminal with colored OK/WARN/BAD badges and per-metric tier labels, plus optional JSON, Markdown, and Discord webhook outputs. Each of 7 score components (cpu1c = sha1c/5, cpumc = shanc/20, mem = GBps*8, dseq = seqw/10, d4k = (4kw+4kr)/4, ndown = down/20, nup = up/20) is capped at 100 for a BH-SCORE of at most 700 with a letter grade S/A/B/C/D/F.

| Flag | Effect |
|---|---|
| `all` / `detect` / `info` / `bench` / `sec` / `help` | modes (default `all`) |
| `--fast` | smaller test payloads |
| `--no-net` | skip network tests |
| `--no-sec` | skip the SSH/security audit |
| `--webhook URL` | POST Discord embed (env `BH_WEBHOOK`) — optional |
| `--json PATH` | JSON report (`-` = stdout) |
| `--markdown PATH` | Markdown report (`-` = stdout) |
| `--output PATH` | plain-text report |
| `--disk-dir DIR` | disk test directory (default `/tmp`) |
| `--no-color` | disable ANSI colors |
| `--version` | print version |

```sh
curl -fsSL https://raw.githubusercontent.com/victoryvpsvn-star/blackhole-discord-terminal/main/vps-bench/install.sh | sh
blackhole-vps-bench all --fast
blackhole-vps-bench sec
```

Exit codes: 0 ok, 1 no benchmark data, 2 usage error. No root required.
