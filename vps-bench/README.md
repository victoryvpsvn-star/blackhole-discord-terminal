# blackhole-vps-bench

Tool kiểm tra VPS của bạn thực chất đang chạy trên gì — KVM, QEMU, Docker, Podman, Kubernetes, LXC/LXD, OpenVZ, Xen, Hyper-V, VMware, VirtualBox, bhyve, WSL hay máy chủ dedicated — rồi benchmark đúng **cấu hình thực** (đọc cgroup limit chứ không báo nhầm RAM/CPU của host), **chứng minh nhà cung cấp có oversell hay không** (steal-under-load, KSM, diskstats live, model ổ host), **chỉ ra region thật** (colo Cloudflare), **chốt VPS chạy mail/VPN được không** (NAT/CGNAT + port 25/465/587/1194/51820), kiểm kê **GPU/AI accelerator**, **audit SSH & bảo mật ngay trên máy**. Thuần bash, một file duy nhất, chạy được cả trong container Alpine lẫn runner ARM, có GitHub Actions selftest, và **kết quả in thẳng ra terminal** — Discord chỉ là tuỳ chọn.

- Phiên bản: **v5.1.0**
- Repo: `victoryvpsvn-star/blackhole-discord-terminal`
- Yêu cầu: Linux + bash, `curl` (bắt buộc cho phần network), còn lại mọi thứ đều tự động hóa qua `dd`/`sha256sum`/`openssl`/`fio`/`ss` nếu có. Không cần root (có root thì audit sâu hơn).

> **Có gì mới ở v4?** Câu hỏi lớn của v4: **"nhà cung cấp có đang nói dối mình không?"** — và mỗi câu trả lời đều kèm bằng chứng đo được, không phải lời đồn:
> - **Oversell proof**: steal % lấy mẫu **đúng lúc đang bench** (noisy neighbor bị bắt tại trận), KSM đang gộp trang (clue RAM oversell), **/proc/diskstats live** cho đúng device trong lúc bench (IOPS/MBps/busy%), **model ổ của host** (QEMU_HARDDISK hay SSD thật?) — chốt bằng verdict `Oversell: LIKELY / POSSIBLE / no evidence`.
> - **Region truth**: colo Cloudflare thật (IAD? SGN? FRA?) so với geo nhà cung cấp quảng cáo + **latency matrix** US/EU/Asia/AU đo song song.
> - **Mail/VPN viability**: verdict NAT/CGNAT + kiểm tra ra được port 25/465/587 (SMTP), 1194 (OpenVPN), 51820 (WireGuard) hay không.
> - **GPU-for-AI card**: có GPU thật không, VRAM bao nhiêu, MIG chia slice, và cảnh báo **cuda-libs-without-devices** (image CUDA nhưng không có device — container GPU "phượt" trên VPS thường).
> - **Confidential computing badge**: AMD SEV / SEV-ES / SEV-SNP, Intel TDX.
> - **NIC honesty**: driver `e1000` (emulated, chậm 2-5x) hay `virtio_net`?
> - **vs-last-run trend**: `--compare` so điểm với JSON run trước, mũi tên ▲/▼.
> - **Share card**: một dòng tóm tắt cuối report, copy đi đâu cũng được (`share: container/docker · 2c/4G · entry-NVMe · C (384/700)`).
>
> Và **7 bug có thật của v3 được sửa** (changelog trung thực, không tô hồng):
> 1. **"4K read" cũ là đọc tuần tự** — v4 đọc random-offset 4K thật, kèm p50/p90/p99 latency.
> 2. **Membench tính gấp đôi băng thông thật** (over-credit 2x) — v4 đếm đúng 16 B/pt: 8 đọc + 8 ghi, nhãn `c-copy (r+w)`.
> 3. **CPU bench hash `/dev/zero`** dính zero fast-path của sha-ni → v4 hash payload urandom, mọi job dùng chung một file.
> 4. **Mode sec vẫn rò gói tin ra mạng** (ipify/ip-api nằm nhầm module info) → v4 sec/detect là zero-traffic, có test CI dùng curl shim chứng minh.
> 5. **Parser sshd đọc drop-in thắng main config vô điều kiện** — v4 expand Include đúng vị trí, giữ semantics *first-match-wins* của OpenSSH.
> 6. **`aws_gen` bị ép gán từ IMDSv2** (Xen-gen cũng trả lời IMDSv2 mà) — v4 chỉ suy generation từ DMI/instance-type, không đè verdict của detect.
> 7. **cpuset bị bỏ qua khi bench** (chỉ để hiển thị) — v4 số job song song = min(cgroup quota, nproc, số core trong cpuset).

> **Có gì mới ở v5.1?** Đợt nâng cấp "dò được nhiều thứ trên máy hơn" do pipeline 10 idea agent → 5 review agent → 3 coder agent đề xuất/chấm điểm/triển khai (chi tiết: `docs/vps-bench-v5.1-design.md`):
> - **Sandbox class**: nhận diện **kata-containers / gVisor / Firecracker** — microVM sandbox bọc ngoài container của bạn (dòng `Sandbox :` trong verdict, kèm danh sách signal đã bắn).
> - **SMT truth**: `SMT: N hardware thread(s)/core` + hotplug delta (`N offline`) — đối chiếu "N vCPU" quảng cáo với topology thật.
> - **Overcommit posture**: mode 0/1/2 + `Committed_AS` vs `CommitLimit` (mode 2 breach = OOM risk thật).
> - **TCP kernel knobs**: syncookies, fastopen, rp_filter (all/default), rmem/wmem max — một dòng `[ENV]` gọn.
> - **Qdisc of default iface**: pfifo/fq/fq_codel + cảnh báo `fq recommended with BBR` khi đang chạy BBR mà qdisc không phải fq.
> - **Userns budget**: `max_user_namespaces` — hardening surface một dòng.
> - **Guest-agent census** (found-only, presence-only — KHÔNG đọc config, KHÔNG đụng /var/lib/cloud contents): cloud-init, qemu-ga, vmtoolsd, waagent, google-guest-agent, amazon-ssm-agent → dòng `Managed :` trả lời "thằng nào đang quản máy này".
> - **JSON**: 11 key mới trong `system` (`smt_threads`, `oom_mode`, `sandbox`, `qdisc`, `guest_agents`, ...).
> - **CI Discord notify bản nâng cấp**: embed giờ kèm **verdict digest thật** (Verdict/share/Posture/Oversell) từ từng job host + từng container, không chỉ PASS/FAIL.
>
> Đề xuất bị review agent loại có chủ đích: `drop_caches` trước disk-read (vì `iflag=direct` đã có sẵn và drop_caches đập cache CẢ HOST — nguy hiểm shared kernel), speedtest-cli/iperf3 tự động (flaky, vi phạm no-install), CPU steal (đã ship từ v4).

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

Năm lệnh hay dùng nhất:

```sh
blackhole-vps-bench detect                # KVM hay Docker? (offline, vài giây)
blackhole-vps-bench all --fast            # detect + bench nhanh + audit bảo mật
blackhole-vps-bench sec                   # chỉ audit SSH & bảo mật (không benchmark, không traffic)
blackhole-vps-bench selftest              # bộ assert nội bộ của tool (không stress, không mạng)
blackhole-vps-bench all --webhook 'https://discord.com/api/webhooks/ID/TOKEN'   # nếu MUỐN đẩy Discord
```

Kết quả luôn in ngay terminal: verdict có bằng chứng (evidence), benchmark có màu, audit SSH có badge `[OK]`/`[WARN]`/`[BAD]`, cuối là BH-SCORE kèm bar gauge + oversell verdict + share card. Không cần webhook gì hết.

---

## 2. Chế độ và tuỳ chọn

Đúng theo `blackhole-vps-bench help`.

| Chế độ | Ý nghĩa |
|---|---|
| `all` | detect + info + GPU/env/storage + benchmark đầy đủ + security audit (mặc định) |
| `detect` | chỉ nhận diện ảo hóa — nhanh, **offline 100%** (tự ép no-net + tắt port probe) |
| `info` | system info + security audit, không benchmark |
| `bench` | chỉ benchmark (vẫn in verdict để biết ngữ cảnh) |
| `sec` | chỉ audit SSH & bảo mật — không benchmark, **không tạo một gói tin nào ra mạng** (fix G4) |
| `selftest` | chạy bộ assert nội bộ (helper thuần: JSON, grade, tier, gauge, cpuset math) — không stress, không mạng |
| `help` | in trợ giúp |

| Tuỳ chọn | Ý nghĩa |
|---|---|
| `--fast` | profile nhanh (payload nhỏ hơn, tắt region matrix + port probe) |
| `--no-net` | bỏ qua test mạng (không tạo traffic ra ngoài) |
| `--no-sec` | bỏ qua audit SSH/bảo mật |
| `--no-port-probe` | bỏ kiểm tra khả năng ra port 25/465/587/1194/51820 |
| `--redact` | che IP/username/instance-id trong **mọi** output (text, markdown, JSON, Discord, Prometheus) |
| `--only LIST` | chỉ chạy các module này: `cpu,mem,disk,extra,net,sec,env,gpu,storage,info` |
| `--skip LIST` | bỏ qua các module (cùng bộ tên) |
| `--min-score N` | CI gate: exit 3 khi BH-SCORE total < N |
| `--fail-on warn\|bad` | CI gate: exit 4 khi security posture có warn (hay bad) |
| `--prom PATH` | xuất Prometheus textfile (atomic tmp + mv, kiểu node_exporter) |
| `--compare PATH` | so kết quả với JSON của run trước (trend ▲/▼ cho 7 thành phần + total + grade) |
| `--webhook URL` | gửi báo cáo Discord embed (env: `BH_WEBHOOK`) — **tuỳ chọn** |
| `--json PATH` | ghi báo cáo JSON ra PATH (`-` = stdout) |
| `--markdown PATH` | ghi báo cáo Markdown ra PATH (`-` = stdout) |
| `--output PATH` | ghi báo cáo plain-text ra PATH |
| `--disk-dir DIR` | thư mục chứa file test disk (mặc định: `/tmp`) |
| `--no-color` | tắt màu ANSI |
| `--version` | in phiên bản |
| `-h`, `help` | in trợ giúp |

Biến môi trường: `BH_WEBHOOK`, `BH_FAST=1`, `BH_NO_NET=1`, `BH_NO_SEC=1`, `BH_REDACT=1`, `BH_PORT_PROBE=0`, `BH_GAUGE_ASCII=1` (bar `#---` thay vì `▰▱`), `BH_DISK_DIR`, `BH_NO_COLOR=1`.

Exit codes: `0` ok | `1` benchmark không sinh được dữ liệu | `2` sai cú pháp lệnh | `3` BH-SCORE dưới `--min-score` | `4` security posture dính `--fail-on`.

---

## 3. "KVM hay Docker?" — verdict, Evidence và deep-scan ảo hóa

Mọi kết luận đều kèm **Evidence**: các dòng bằng chứng in ngay dưới verdict để bạn tự kiểm chứng lại. Tool không đoán suông — mỗi dấu hiệu ghi rõ nguồn (file nào, nội dung gì). Nếu đang chạy trong container, tool dò xem host bên trên là VM loại gì (`Host VM : ...`), và ngược lại gắn nhãn cloud (AWS EC2, Azure, Google Cloud, DigitalOcean, Alibaba, Tencent, OpenStack, OCI, Hetzner, Linode, Scaleway) dựa trên DMI + metadata IMDSv2.

| Loại nhận diện | Dấu hiệu chính (evidence) |
|---|---|
| Docker / Podman / Kubernetes / LXC-LXD / systemd-nspawn / OpenVZ-Virtuozzo 7 / containerd | marker files + cgroup path + serviceaccount + `envID` (như v3) |
| WSL1 / WSL2 | `/proc/version` nhắc Microsoft; `microsoft-standard` trong kernel = WSL2. **v4 fix G8**: container signals đánh giá TRƯỚC WSL — Docker trong WSL2 giờ báo `container/docker` với host label `WSL2`, không bị nuốt verdict |
| Chroot | `/` khác inode với `/proc/1/root/.` (chỉ kết luận khi không có signal nào khác) |
| KVM/QEMU, Xen PV/HVM, Hyper-V (Azure cần asset-tag chuẩn), VMware, VirtualBox, bhyve, AWS Xen-gen vs Nitro + `.metal` | map DMI vendor/product/bios + `systemd-detect-virt` + clocksource (như v3) |
| **v4: Nested virt (tri-state)** | `Nested : exposed` (vmx/svm + hypervisor flag → guest tự chạy VM được) · `masked` (hypervisor flag không có vmx/svm → host lọc CPUID; ARM rơi vào đây vì không có vmx/svm) · `native` (vmx/svm không hypervisor flag → CPU bare-metal) |
| **v4: Confidential computing** | `amd-sev` / `amd-sev-es` / `amd-sev-snp` / `intel-tdx` từ cpuinfo flags (`sev`, `sev_es`, `sev_snp`, `tdx_guest`), `/dev/sev-guest`, `/sys/kernel/security/tdx_guest` — chỉ dùng nguồn công bố, không suy từ dmesg |
| **v4: VMM irq fingerprint** | tên interrupt handler trong `/proc/interrupts` (`kvm*`, `xen*`, `hv_*`, `vmbus`, `dragonball`, `virtio*`, `vfio`, `firecracker`...) leak đúng VMM đang host. Trong container, bảng interrupts là của host — tool chỉ scan khi số cột CPU khớp NCPU nhìn được, không khớp thì tự bỏ qua |
| **v4: Virtio inventory** | liệt kê driver của `/sys/bus/virtio/devices/*` (`virtio_blk,virtio_net,...`) — biết ngay disk/net có paravirtual hóa không |

Ví dụ output thật (rút gọn, chạy trong container):

```
[1] VIRTUALIZATION VERDICT
  Kind    : container
  Type    : docker
  Product : Docker
  Host VM : KVM
  Nested  : masked
  VMM irq : dragonball.0,virtio0,virtio1,virtio2,virtio3,virtio4,virtio5
  Virtio  : virtio_blk,virtio_mem,virtio_net,virtio_pmem,virtiofs,...
  Verdict : Container (Docker) on host: KVM
  Evidence:
  • /.dockerenv present
  • hypervisor flag without vmx/svm => masked (CPUID-filtered by host)
  • caveat: cpu flags are host cpu flags (container view)
```

---

## 4. Audit SSH & bảo mật (v4) — "hacker checklist" cho chính máy bạn

Section `[5] SSH & SECURITY AUDIT` chỉ đọc cấu hình **trên chính máy này** — không scan/đánh máy ai. Mỗi dòng có badge `[OK]`/`[WARN]`/`[BAD]`/`[INFO]`, kết bằng **Posture** `GOOD / FAIR / WEAK` kèm đếm pass/warn/bad.

Toàn bộ check v3 giữ nguyên (password/pubkey/root login, PermitEmptyPasswords, LoginGraceTime, X11, AllowUsers, StrictModes, authorized_keys + key yếu, failed logins, firewall, fail2ban/sshguard/crowdsec, sshd version/runtime, UID-0, mật khẩu trống, sudo NOPASSWD, ASLR, auto updates, listening ports, SELinux/AppArmor, pending updates, port nguy hiểm, cryptominer, docker.sock, sysctl kernel, /tmp noexec, cron/timers). **v4 thêm (H1-H8):**

- **Include đúng semantics (fix G5)**: config đọc tuần tự, Include expand **đúng vị trí** trong stream, directive đặt TRƯỚC Include vẫn thắng drop-in — đúng luật *first obtained value wins* của OpenSSH. Depth-cap 8 chống cycle.
- **Weak crypto trong effective config**: quét `Ciphers`/`MACs`/`KexAlgorithms`, bắt token yếu (`arcfour`, `3des-cbc`, `aes*-cbc`, `hmac-sha1`, `diffie-hellman-group1`...).
- **MaxStartups + ClientAliveInterval/CountMax**: connection hygiene, hiển thị cả khi đang default.
- **AuthorizedKeysFile phi mặc định**: `%u`/`%h` được expand, mọi path effective đều được quét key (không chỉ `.ssh/authorized_keys`).
- **PAM password quality**: `pam_pwquality` (kèm minlen) / `cracklib` / `passwdqc` / none.
- **Password aging**: `PASS_MAX_DAYS` từ login.defs (`99999` → "no expiry") + hạn mật khẩu root qua `chage`.
- **auditd** (running / installed-not-running / not-installed) và **time sync** (chronyd/timesyncd có đang sync).
- **Pre-login banner leak**: `Banner`, `/etc/issue.net`, `/etc/motd` có tiết lộ OS version không.
- **Hardening X1-X8 (passive)**: PATH dir world-writable · SUID/SGID inventory + basename lạ ngoài whitelist · core dumps (`suid_dumpable`, ulimit, pattern) · sysctl `fs.protected_*` (`!` = đang TẮT — symlink/hardlink/TOCTOU race) · legacy daemons (nis/rsh/telnet/talk/xinetd/tftp) · version sudo/pkexec (chỉ INFO — CVE fix là của distro, tuổi version không phải verdict) · umask cấu hình ở đâu · forensics toolkit (rkhunter/chkrootkit/clamav/aide).

Ví dụ thật (rút gọn):

```
  [INFO]  PAM password quality: none — no pwquality/cracklib module in the PAM password stack
  [INFO]  Password aging: PASS_MAX_DAYS=no expiry
  [INFO]  auditd: not installed (kernel audit framework)
  [WARN]  SUID/SGID: 12 file(s), non-standard: unix_chkpwd — review each one
  [OK]  core dumps: dumpable=0 ulimit=0 pattern=core
  [OK]  legacy network daemons (nis/rsh/telnet/talk/xinetd/tftp): none installed
  [INFO]  sudo version: Sudo version 1.9.16p2 (info only — ...)
  [POST]  Posture: FAIR (8 pass / 5 warn / 0 bad) — scope: this machine only
```

Chạy riêng nhanh:

```sh
blackhole-vps-bench sec            # chỉ audit, vài giây, zero-traffic
blackhole-vps-bench sec --json sec.json
```

> Tool này là audit **một chiều trên máy mình** (kiểu Lynis thu nhỏ). Nó không brute-force, không scan mạng ai cả — mode `sec` bị chặn mạng ngay từ `main()` trước khi module nào kịp gọi.

---

## 5. Cách đo benchmark

| Hạng mục | Cách đo |
|---|---|
| CPU single | bơm **payload RANDOM** sinh một lần mỗi run (urandom, 256 MB — fast 96 MB) qua `sha256sum`, tính MB/s; adaptive lặp tới khi ≥ 300 ms; warmup 8 MB + kéo payload vào page cache (fix G3: hash `/dev/zero` là dính zero fast-path, số đẹp ảo) |
| CPU multi | cùng bài, `effective cores` job song song (min giữa cgroup quota, nproc, cpuset — v4 fix G7), **mỗi job hash cùng một file** để efficiency % công bằng |
| Steal-under-load (v4) | `/proc/stat` lấy mẫu steal ngay TRƯỚC và SAU cửa sổ multi-core — noisy neighbor bị bắt khi máy đang tải, khác với steal idle của info |
| CPU cross-check | `openssl speed -seconds 2 -evp sha256` — parser v4 chịu cả OpenSSL 3.x (`SHA2-256`) lẫn 1.x (`sha256`), lấy cột số cuối; thêm ops/s `bash` vs `awk` (B6) |
| Memory | C stream-copy `dst[i]=src[i]` biên dịch lúc chạy, đếm đúng **16 B/phần tử (8 đọc + 8 ghi)** — fix lỗi over-credit 2x của v3; buffer = 256 MB (fast 64) nhưng không quá 1/8 RAM khả dụng; best of 3; barrier + rotating checksum chống dead-store elimination |
| Memory fallback | không compiler thì `dd` ghi /dev/null — v4 **relabel thành `cpu-proxy (dd)`**: đó là throughput CPU/zero-page, KHÔNG phải băng thông RAM, đừng đem so |
| Disk seq | `dd` ghi rồi đọc tuần tự, direct-first negotiation như v3 (`direct+fsync` → `fsync (buffered)` → cảnh báo `plain (cache-inflated!)`); 4K write chạy trên **file riêng**, adaptive x4 |
| Disk 4K random read | **v4 fix G1**: N lần đọc 1 block 4K tại offset pseudo-random (payload urandom, không còn là stream tuần tự), mỗi IO tính µs bằng `$EPOCHREALTIME`, một pass `sort` → **p50/p90/p99 latency** + MB/s thật; IOPS tự tính chỉ cấp khi đi đường `direct` (đường cached thì không nói dối) |
| Live proof (v4) | `/proc/diskstats` lấy mẫu quanh toàn bộ bench, lọc đúng major:minor của device thật (decode `stat -c %d`, verify qua `/sys/dev/block`) → **IOPS / MBps / busy% đo trong lúc bench**; anonymous dev (tmpfs/overlay) thì bỏ qua hoàn toàn, không đoán mò |
| Guards + TRIM (v4) | bench dir tmpfs/ramfs bị gắn cờ "numbers not disk" · payload tự cap ≤ 20% free space · từ chối bench khi free < 3x payload (không wedge disk gần đầy) · TRIM matrix passive từ sysfs (`discard_granularity`/`discard_max_*`) + option `discard` trong /proc/mounts — KHÔNG BAO GIỜ chạy fstrim |
| fio | khi có fio: 4k randrw 8s direct, JSON parse (premium, gate thời gian + space) |
| Network | như v3: download best-of-N (Cloudflare 50 MB → OVH → Hetzner → Thinkbroadband, max thắng, early-stop chỉ khi payload ≥ 2s) + upload Cloudflare; **v4: mọi probe identity chạy MỘT wave song song** nên thêm wall time ≤ ~4s |
| ICMP latency + jitter | `ping -c 4` tới 1.1.1.1 (fallback 8.8.8.8); packet loss v4: 5 probe ICMP (cần CAP_NET_RAW, không có thì ghi `n/a (no icmp)`) |
| Địa lý | **v4**: Cloudflare `/cdn-cgi/trace` MỘT fetch cho cả geo + colo (`US / Ashburn (colo IAD)`); ASN/ISP qua ipwho.is (không còn ip-api) |

Deep-scan giữ nguyên từ v2/v3 (TCP cc, entropy, DNS, TUN/FUSE/PPP, load, TZ, THP, hugepages, swap, MTU, multi-thread efficiency %) và **v4 thêm vào [2] SYSTEM**: CPU vulnerability matrix (`/sys/devices/system/cpu/vulnerabilities/*`, đếm các mục `Vulnerable`, ghi rõ scope — trong container đó là **host kernel**) · ISA inventory AI (`avx512_vnni`, `amx_*`, `bf16`...) + crypto (`vaes`, `sha_ni`, `gfni`...) — hoạt động cả trên ARM qua dòng `Features` · microcode + stepping · **KSM** (`on/off` + pages_sharing — gộp trang đang chạy là clue oversell RAM).

Mọi metric vẫn có **tier label** ngay dòng số liệu (`standard`, `high-perf`, `entry-NVMe`, `premium-NVMe`, `gigabit-class`...) — đọc một phát biết đẳng cấp.

---

## 6. Các section mới: [GPU], [ENV], [STORAGE], [BENCH-EXTRA]

V4 tách 4 module mới; tất cả đều **passive** (đọc /sys, /proc — zero network, zero write; riêng BENCH-EXTRA là micro-bench info-only), bash-3.2 safe, mọi lệnh ngoài đều bọc `timeout` nên không bao giờ treo.

**[GPU] GRAPHICS / ACCELERATORS** — sysfs-first, không cần lspci:
- Device nodes: đếm `/dev/dri/card*`, `renderD*`, `/dev/nvidia*` (device EXPOSURE, không phải số GPU) + driver version từ `/proc/driver/nvidia/version`; PCI enumeration qua `/sys/bus/pci/devices` (class `0x03*`, cap 64 device): NVIDIA/AMD/Intel/ASPEED/QXL/Cirrus kèm driver đang bind.
- `nvidia-smi` **luôn bọc timeout 3s** (container có CUDA image nhưng không device là chỗ treo kinh điển): tên, VRAM, PCIe gen x width, driver; `nvidia-smi -L` đếm **MIG slices**; VRAM AMD/Intel qua `mem_info_vram_total` (drm sysfs, world-readable).
- **`cuda-libs-without-devices`**: ldconfig thấy `libcuda.so`/`libnvidia-ml.so` nhưng 0 NVIDIA device/PCI → container GPU hỏng, báo thẳng. **vfio passthrough**: driver `vfio-pci` trên device đầu tiên = card đã pass vào VM.
- One-line verdict, GPU-less box thì in `no GPU detected (vCPU-only plan)`.

**[ENV] capabilities & limits** — "cái box này được PHÉP làm gì":
- Decode CapEff/CapBnd bằng pure-bash bit math (40 caps) → class `privileged` / `semi-privileged` / `unprivileged` (unprivileged → ghi rõ "cannot mount/load-kernel"); phân biệt cap bị **dropped** vs **bounded-out**; cross-check với `capsh` khi có.
- `pids.max/current` (cgroup v1 lẫn v2) · NoNewPrivs + Securebits · **PID 1 identity** (LSM label + cmdline preview) · rlimits (nofile/nproc/stack/memlock/core) · device map `kvm:tun:dri:fuse:ppp:shm` (kvm:yes → "can run KVM VMs", tun:yes → "VPN server possible") · OOM adj/score · cgroup controllers.

**[STORAGE] topology (passive map)** — "mình đang nằm trên storage gì": FS tree từ /proc/mounts (fstype có `*` = COW/overlay stack — container "disk" không phải disk) · **root backing stack walk**: `overlay (container root) -> vda (virtio)` hay `dm-0 -> LVM lv_root -> sda+sdb`, kèm hardware class (virtio/nvme/scsi/xen/pmem/loop) · stacking `md:`/`lvm:`/`zfs:`/`btrfs:` · **zram** (kèm compression ratio) · **zswap** · **swap kind** (zram hay disk) · NVMe controller + **PCIe gen** · **model string ổ host** (`SAMSUNG MZQL296H...` — "NVMe premium" mà model là QEMU_HARDDISK thì hiểu rồi).

**[BENCH-EXTRA] info-only micro-benchmarks** — không ảnh hưởng BH-SCORE (score engine đọc đúng 8 biến cũ, chặt chẽ):
- **Crypto**: AES-256-GCM + ChaCha20-poly1305 (`openssl speed -bytes 16384`, fallback AES-256-CBC cho openssl < 1.1.1) — biết CPU có AES acceleration ngon hay không.
- **Compress**: gzip (fallback `xz -0`) + zstd -1.
- **Fork/exec rate** (N lần `/bin/true`), **pipe IPC** GB/s (256k + 4k), **small-file create rate** (files/s, adaptive cửa sổ, ghi rõ fs type).

Ví dụ thật (rút gọn):

```
[3] BENCHMARK
  CPU     : sha256 801.7 MB/s (1 core) | 1.21 GB/s (2 threads) [standard]
            steal under load: 22.1% ← noisy neighbor WHILE benching!
  Memory  : 13.03 GB/s  [c-copy (r+w)]
  Disk    : seq w 1.21 GB/s | seq r 1.14 GB/s | 4k w 28.9 MB/s | 4k r 3.9 MB/s  [premium-NVMe] | ...
            4k rand latency p50/p90/p99: 0.93/1.02/1.71 ms [direct]
[BENCH-EXTRA] info-only micro-benchmarks
  Crypto  : AES-256-GCM 12163.7 MB/s | ChaCha20 3639.6 MB/s  [gcm+chacha]
  Compress: gzip 103.3 MB/s  [gzip]
  Forkexec: 1754 exec/s
  Pipe IPC: 2.4 GB/s
  Smallfile: 19753 files/s (fs: overlayfs)
[STORAGE] topology (passive map)
  Summary : root=overlay/virtio stack=none zram=no
  Root    : overlay (container root) -> vda (virtio) + pmem0 (pmem) (class: overlay/virtio)
[ENV] capabilities & limits
  Caps    : unprivileged — dropped:net_raw bounded-out:net_admin,sys_admin,... → cannot mount/load-kernel
  Devs    : kvm:no tun:no dri:no fuse:no ppp:no shm:64M
```

---

## 7. Network deep-dive (v4) — region truth, NAT, mail/VPN ports

Section `[4] LOCATION / NETWORK IDENTITY` v4 trả lời những câu mà v3 né: **VPS này nằm ở đâu THẬT? có host mail/VPN được không?**

- **Cloudflare colo geo truth**: một fetch `/cdn-cgi/trace` trả `loc` (country) + `colo` (mã sân bay datacenter — IAD, FRA, SGN...). Nhà cung cấp nói "Singapore" mà colo là SJC thì đây là bằng chứng. Geo line: `US / Ashburn (colo IAD)`.
- **Region latency matrix** (bỏ khi `--fast`): TCP-connect time tới 5 target (US thinkbroadband, EU Hetzner nbg1, Asia JAIST, AU aarnet, CF 1.1.1.1) chạy **đầy song song** → `region matrix: US:12 EU:145 Asia:230 AU:310 CF:2`.
- **NAT/CGNAT verdict**: so IP source của default route với egress IP. `public-ip` (IP thật, có inbound) · `nat (iface 10.0.0.5 ≠ egress 203.0.113.7)` · `cgnat` (RFC6598 `100.64/10`) — NAT/CGNAT kèm cảnh báo "no inbound ports, mail/web cần port-forward".
- **Outbound port viability**: thử TCP connect ra `25 / 465 / 587` (SMTP), `1194` (OpenVPN), `51820` (WireGuard). Kết quả chỉ là **reachability** — `open` / `filtered` / `untestable`, KHÔNG kết luận "provider chặn" (DROP và REJECT nhìn giống nhau). Có control probe (1.1.1.1:443): control fail thì mọi port trả `untestable` thay vì dối là `filtered`. Tự tắt khi `--fast` / `--no-net` / `--no-port-probe`.
- **DNS speed**: trung bình 5 lookup `getent` song song + tag `stub` (resolver loopback) hay `resolver`.
- **NIC honesty**: driver của default iface — `e1000`/`rtl8139`/`pcnet` gắn cờ "emulated NIC, 2-5x slower than virtio"; kèm số RX queues + offloads (tso/gso/gro qua ethtool nếu có).
- **Packet loss** (5 ICMP, cần CAP_NET_RAW) và **IPv6 grade**: `native` (có global addr + egress v6 thật) / `address-only` (có addr không ra được) / `none`.

Ví dụ format (rút gọn):

```
[4] LOCATION / NETWORK IDENTITY
  IPv4    : 203.0.113.7
  Geo/ISP : US / Ashburn (colo IAD)
  ASN     : AS16509 Amazon
  egress: US · CF colo: IAD · region matrix: US:12 EU:145 Asia:230 AU:310 CF:2
  NAT     : nat (iface 10.0.0.5 ≠ egress 203.0.113.7) → no inbound ports (mail/web hosting needs port-forward)
  Ports   : outbound 25:filtered 465:open 587:open 1194:open 51820:open
  DNS     : 3 ms (resolver)
  NIC     : driver virtio_net, queues 4, offloads: tso:on gso:on gro:on
  Loss    : 0.0% packet loss
  IPv6    : grade native
```

---

## 8. Oversell verdict, bar gauges, share card, --compare

Đây là phần "chốt đơn" của v4 — sau BH-SCORE, tool kết luận luôn:

- **Oversell verdict** tổng hợp 4 tín hiệu: steal-under-load > 5% hoặc steal idle > 5% (mạnh) · KSM `pages_sharing` > 0 (nhẹ) · disk busy% live > 85% trong lúc bench (nhẹ). ≥1 tín hiệu mạnh → `[BAD] Oversell: LIKELY (...)`; chỉ tín hiệu nhẹ → `[WARN] POSSIBLE (...)`; sạch → `[OK] no evidence`.
- **Bar gauges**: 7 thành phần điểm in kèm bar `▰▰▰▰▱▱▱▱▱▱` 10 ô (ASCII `#---` khi set `BH_GAUGE_ASCII=1` hoặc terminal không UTF-8).
- **Share card**: một dòng cuối report, tổng hợp cloud · kind/type · cores/RAM · disk tier · down/up · grade — dán Discord/tweet được ngay.
- **`--compare last.json`**: bảng trend `old → new ▲/▼ delta` cho cả 7 thành phần + total + grade (cần jq hoặc python3; thiếu thì in note, không lỗi).
- **`--redact`**: pass privacy chạy ở ĐẦU mỗi sink (text/markdown/JSON/Discord/Prom) — IP → `<redacted-ip>`, geo chỉ giữ country, AllowUsers → `(N users)` (đếm, không lộ tên), AWS instance-id thậm chí không được fetch khi redact bật.

```
[6] BH-SCORE
  CPU 1c     100/100 ▰▰▰▰▰▰▰▰▰▰
  Disk 4k      8/100 ▰▱▱▱▱▱▱▱▱▱
  TOTAL: 384 / 700 (grade C)
  [BAD]  Oversell: LIKELY (steal 22.7% under load)
generated 2026-11-14 19:56:54 UTC by blackhole-vps-bench v4.0.0
  share: container/docker · 2c/4G · entry-NVMe · C (384/700)
```

Output phụ: `--prom metrics.prom` ghi Prometheus textfile (# HELP/# TYPE + gauges `bh_score_total`, `bh_score_component`, `bh_security_bad`, các gauge throughput chính) qua **atomic tmp+mv** đúng convention của node_exporter textfile collector. Khi chạy trong GitHub Actions và có `--markdown`, report tự append vào **job summary** ($GITHUB_STEP_SUMMARY) — zero config.

---

## 9. BH-SCORE

Không đổi so với v3: 7 thành phần, mỗi thành phần chặn tối đa 100 điểm, tổng tối đa **700**:

| Thành phần | Công thức từ số đo |
|---|---|
| CPU 1-core | `sha256 1-core (MB/s) / 5` |
| CPU multi | `sha256 multi (MB/s) / 20` |
| Memory | `băng thông (GB/s) × 8` |
| Disk seq | `seq write (MB/s) / 10` |
| Disk 4K | `(4k write + 4k read) (MB/s) / 4` |
| Net down | `download (Mbps) / 20` |
| Net up | `upload (Mbps) / 20` |

Grade letter theo tỷ lệ điểm/tối đa: `S ≥ 630` · `A ≥ 525` · `B ≥ 420` · `C ≥ 315` · `D ≥ 210` · `F` dưới. Thành phần thiếu dữ liệu tính 0, không bù điểm.

**Tầm quan trọng v4**: toàn bộ metric mới (GPU, crypto/compress/fork/pipe/smallfile, region matrix, NAT, DNS, NIC, vuln matrix, ISA, microcode, KSM, TRIM, storage map, env) là **info-only, chủ động KHÔNG đưa vào điểm số** — score giữ đúng 7 bài đo cũ nên điểm v4 vẫn so ngang hàng với lịch sử, và các metric mới không thể "farm điểm". Lưu ý công bằng: 2 fix (membench đếm đúng 16 B/pt, CPU hash payload random) làm số mem/CPU của v4 **thấp hơn v3 một cách trung thực** — đó là ý của chuyện này.

---

## 10. Cgroup limits — vì sao tool này báo đúng RAM/CPU của container

Vào một Docker container, nhiều tool "system info" báo RAM 256 GB và 128 core — đó là của **host**, không phải của bạn. Tool này đọc trực tiếp cấu hình cgroup (v2: `cpu.max`, `memory.max`, `cpuset.cpus.effective`; v1: `cpu.cfs_quota_us`/`period`, `memory.limit_in_bytes`, `cpuset.cpus`) rồi tính ra CPU quota, container RAM limit và cpuset.

**v4 fix G7 — cpuset giờ được ENFORCE**: số job benchmark multi-core = `min(cgroup quota, số core nhìn thấy, số core trong cpuset)` (cap 64). Trước đây cpuset chỉ để hiển thị — container bị pin `[0-1]` vẫn chạy 8 job, oversubscribe làm điểm multi và efficiency % méo. Buffer membench cũng tự clamp theo RAM khả dụng (clamp bởi cgroup limit khi nhỏ hơn), và disk bench trên tmpfs tôn trọng cả memory limit.

```
  CPU     : Intel(R) Xeon(R) ...
            2 logical / 2 physical cores
            effective: 2 core(s), cpuset [0-1]
  RAM     : total 4041 MB, avail 3525 MB, swap 0 MB | container limit 4096 MB
```

CI có job chạy container bị giới hạn cứng `--cpus 2 --memory 2g --shm-size 1g` và assert báo cáo phải nhắc "cgroup quota" — chứng minh tính năng thật, không phải lời nói.

---

## 11. Gửi báo cáo Discord (tuỳ chọn — không bắt buộc)

Mặc định mọi thứ in ngay terminal. Chỉ khi bạn **muốn** đẩy kết quả đi đâu đó:

```sh
blackhole-vps-bench all --webhook 'https://discord.com/api/webhooks/ID/TOKEN'
# hoặc: export BH_WEBHOOK='https://discord.com/api/webhooks/ID/TOKEN'
```

Tool POST một embed (màu theo verdict) gồm Verdict, BH-SCORE, CPU, Memory, Disk, Network, SSH auth + Security posture, Oversell, Location. Gửi thành công khi Discord trả HTTP 204/200; thất bại chỉ cảnh báo. **Mode `sec` bỏ qua webhook hoàn toàn** — giữ đúng cam kết zero-traffic.

---

## 12. GitHub Actions

Workflow `vps-bench selftest` (`.github/workflows/vps-bench-selftest.yml`) chạy khi push/PR đổi `vps-bench/**`, chạy tay qua `workflow_dispatch`, và cron `0 3 * * 1` (thứ Hai 03:00 UTC). Bốn job:

1. **shellcheck** — build bundle rồi lint `dist/`, `install.sh`, `run-tests.sh`, kèm kiểm tra bundle không stale so với source.
2. **smoke** — `tests/run-tests.sh` (**18 nhóm test**, gồm sec-mode zero-network guarantee bằng curl shim) trên matrix **`ubuntu-24.04`, `ubuntu-22.04`, `ubuntu-24.04-arm`** (runner ARM ép các code path aarch64: flags từ dòng `Features`, không có vmx/svm) + `selftest` mode + **exit gate** (`--min-score 999999` phải thoát mã 3) + full bench `all --fast` với `--json --markdown --output --prom`, upload artifact cả 4 file (JSON/MD/text/**.prom**).
3. **containers** — `alpine:3.20`, `debian:12` (full bench `--no-net`), `ubuntu:24.04` bị giới hạn `--cpus 2 --memory 2g --shm-size 1g` (assert "cgroup quota"), `rockylinux:9`, `fedora:41` (detect). Container job cũng chạy `selftest` và assert section `[ENV]` + share card có mặt trong report.
4. **discord notify** — tổng hợp kết quả 3 job, gửi embed PASS/FAIL tới secret `DISCORD_WEBHOOK` (chưa set thì bỏ qua, không fail).

Workflow `vps-bench remote` giữ như v3: chạy tay qua `workflow_dispatch` (inputs `fast`, `extra_args`), scp bundle lên VPS, bench trên VPS thật, kéo report về làm artifact. Secrets: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_PORT` (tuỳ chọn), `DISCORD_WEBHOOK` (tuỳ chọn).

---

## 13. Output JSON

`--json report.json` sinh một object. **v4 thêm các nhóm key**: `virtualization.nested/conf_computing/irq_vmm/virtio_devices/chassis_weak` · `system.vuln_worst/vuln_scope` · `system.cpu.ai_features/crypto_features/microcode/stepping/bash_ops/awk_ops/steal_under_load/input_src` · `memory.ksm` · `limits.cpuset_cores` · object `gpu` (summary/pci/nvidia/mig/vram_sysfs/libs/passthrough/nodes) · object `network` deep (geo_loc/geo_clo/net_clo/nat_mode/lat_matrix/port_25..51820/dns_ms/nic_driver/nic_queues/nic_offloads/packet_loss/ipv6_grade) · object `env` (caps_class/caps_eff/caps_missing/pids_max/pids_cur/nnp/pid1_lsm/pid1_cmd/rl_nofile/rl_nproc/dev_map/shm_mb/oom_adj/cg_controllers) · `bench.disk.lat_p50/p90/p99_ms/lat_label/live_iops/live_mbps/live_busy_pct/live_dev/trim_support/discard_mount/bench_fs` · `bench.extra` (aes_gcm/chacha/gzip/zstd/fork_rate/pipe/pipe4k/smallfile) · `security` mở rộng (weak_crypto/ciphers/kex/maxstartups/alive/authkeys_path/pam_pw/pass_max_days/root_expire/auditd/ntp/banner/path_world_writable/suid_count/suid_odd/core_dumps/protected_sysctl/legacy_pkgs/sudo_ver/pkexec_ver/umask/forensics) · `score.oversell` · `score.share_card`.

```json
{
  "tool": "blackhole-vps-bench", "version": "4.0.0", "mode": "all",
  "virtualization": { "kind": "container", "type": "docker",
                      "host_type": "kvm", "cloud": "",
                      "nested": "masked", "conf_computing": "",
                      "irq_vmm": "dragonball.0,virtio0", "virtio_devices": "virtio_blk,virtio_net" },
  "system": { "os": "...", "kernel": "...", "arch": "x86_64",
              "steal_pct": "0.0", "vuln_worst": "spectre_v2", "vuln_scope": "host-kernel",
              "cpu": { "model": "...", "logical_cores": 2, "effective_cores": 2,
                       "ai_features": "avx512f,amx_bf16", "crypto_features": "vaes,sha_ni",
                       "microcode": "0x1", "stepping": "1", "steal_under_load": "22.1" },
              "memory": { "total_mb": 4041, "available_mb": 3525, "ksm": "off" } },
  "limits": { "cgroup_version": 1, "cpu_quota_cores": "", "memory_limit_mb": 4096,
              "cpuset": "0-1", "cpuset_cores": 2 },
  "gpu": { "summary": "no GPU detected (vCPU-only plan)", "libs": "none" },
  "network": { "geo_loc": "US", "geo_clo": "IAD", "nat_mode": "public-ip",
               "lat_matrix": "US:12 EU:145 Asia:230 AU:310 CF:2",
               "port_25": "filtered", "port_587": "open", "dns_ms": 3,
               "nic_driver": "virtio_net", "ipv6_grade": "native" },
  "env": { "caps_class": "unprivileged", "caps_missing": "dropped:net_raw bounded-out:net_admin",
           "pids_max": "unlimited", "dev_map": "kvm:no tun:no dri:no fuse:no ppp:no shm:64M" },
  "bench": { "cpu": { "sha256_1c_mbps": 498.2, "sha256_mc_mbps": 995.4, "efficiency_pct": "99.9" },
             "memory": { "gbps": 13.03, "method": "c-copy (r+w)" },
             "disk": { "mode": "direct+fsync +direct-read", "seq_write_mbps": 1239.5,
                       "k4_write_mbps": 28.9, "k4_read_mbps": 3.9,
                       "lat_p50_ms": "0.93", "lat_p90_ms": "1.02", "lat_p99_ms": "1.71", "lat_label": "direct",
                       "live_iops": "7393", "live_busy_pct": "24.0", "trim_support": "unknown" },
             "extra": { "aes_gcm_mbps": "12163.7", "gzip_mbps": "103.3", "fork_rate": "1754" },
             "network": { "download_mbps": 940.1, "upload_mbps": 380.2, "endpoint": "cloudflare-50MB" } },
  "security": { "password_auth": "no", "root_login": "prohibit-password",
                "weak_crypto": "", "maxstartups": "10:30:100 default",
                "pam_pw": "none", "auditd": "not-installed", "banner": "none",
                "path_world_writable": "0", "suid_odd": "unix_chkpwd",
                "pass": 8, "warn": 5, "bad": 0, "posture": "FAIR" },
  "score": { "cpu_1c": 100, "cpu_multi": 50, "memory": 104, "disk_seq": 100, "disk_4k": 8,
             "net_down": 47, "net_up": 19, "total": 384, "max": 700, "grade": "C",
             "oversell": "LIKELY (steal 22.7% under load)",
             "share_card": "container/docker · 2c/4G · entry-NVMe · C (384/700)" }
}
```

Các hạng mục chưa đo được là chuỗi rỗng `""` thay vì số 0 cứng — phân biệt "chưa chạy" với "chạy mà bằng 0". Object `gpu`/`network`/`env` chỉ xuất khi module tương ứng đã chạy.

---

## 14. FAQ

**Multi-core thấp hơn core × single?** Bình thường. SMT chia sẻ execution unit/cache/băng thông; container còn bị chặn bởi quota VÀ (từ v4) cpuset. Efficiency % phản ánh scale thật.

**Disk read cao bất thường?** Page cache. Kiểm tra dòng mode: không thấy `+direct-read` nghĩa là số read có thể "tốt ảo". Random 4K read v4 đi ladder direct → nocache → cached và ghi nhãn `[direct]`/`[cached]` ngay cạnh latency.

**Vì sao đo steal-under-load mà không chỉ steal idle?** Steal idle thấp không có nghĩa là gì — hàng xóm chỉ ồn vào giờ cao điểm. Lấy mẫu steal ngay trước/sau cửa sổ multi-core bắt đúng khoảnh khắc bạn đang CẦN CPU. Steal > 5% trong lúc bench là bằng chứng oversell mạnh nhất tool có, và nó được cấp verdict riêng (LIKELY) chứ không giấu ở dòng phụ.

**Port probe có an toàn không, tắt được không?** An toàn: chỉ là 5 TCP connect ra service công cộng (smtp.gmail.com, portquiz.net) có control probe, không brute-force, không gửi payload. Muốn không probe: `--no-port-probe`, hoặc `--no-net` (tắt cả cụ), hoặc `--fast` (tự tắt). Kết quả chỉ là open/filtered/untestable — tool không kết luận ý đồ của ai.

**`--redact` che những gì?** Mọi IP (IPv4/IPv6 → `<redacted-ip>`/`<redacted-ip6>`, kể cả IP nhúng trong verdict NAT), geo rút còn country, AllowUsers/AllowGroups → đếm `(N users)`, instance-id AWS không được fetch ngay từ đầu. Áp cho cả text, markdown, JSON, Discord lẫn Prometheus — pass chạy ở đầu mỗi sink nên không đường nào lọt.

**Có cần root không?** Không. Chỉ đọc `/proc`, `/sys`, ghi file test tạm vào `--disk-dir` rồi xoá. Có root thì audit sâu hơn (`sshd -T`, `/etc/shadow`, `journalctl`, `chage`). Thiếu gì tự giản lược và ghi rõ `n/a`.

**Audit SSH có đụng tới máy khác không?** Không. Section `[5]` chỉ đọc cấu hình/log của chính máy — Lynis thu nhỏ. Mode `sec` còn bị chặn mạng ở tầng main, có test CI dùng curl shim fail ngay nếu mode sec kêu curl.

**Chạy trong Alpine/busybox được không?** Được — CI chạy cả `alpine:3.20` lẫn runner `ubuntu-24.04-arm`. Cần `bash` và `curl`; cài `coreutils`/`openssl` cho đủ tính năng. Mọi lệnh ngoài trong module mới đều bọc `timeout` nên không treo trên busybox.

---

## English quick reference

`blackhole-vps-bench` is a single-file pure-bash Linux tool that (1) detects the virtualization environment — KVM/QEMU, Docker, Podman, Kubernetes, LXC/LXD, systemd-nspawn, OpenVZ/Virtuozzo 7, Xen PV/HVM, Hyper-V, VMware, VirtualBox, bhyve, WSL1/WSL2 (containers-on-WSL keep their own verdict, v4 fix), chroot, or bare metal — plus cloud fingerprinting (AWS Nitro vs Xen vs `.metal`, Azure via chassis asset tag, GCE, OCI, Alibaba, Tencent, DigitalOcean, Hetzner, Linode, Scaleway, OpenStack), a nested-virtualization tri-state (exposed/masked/native), a confidential-computing badge (AMD SEV/SEV-ES/SEV-SNP, Intel TDX), a VMM fingerprint from `/proc/interrupts` handler names, and a virtio device inventory, each verdict backed by verifiable evidence lines and full ARM/aarch64 support; (2) proves (or disproves) provider overselling with steal-under-load sampling around the multi-core bench window, KSM page-sharing state, live `/proc/diskstats` IOPS/MBps/busy% attributed to the real backing device, and host disk model strings, rendered as an `Oversell: LIKELY/POSSIBLE/no evidence` verdict; (3) benchmarks the real cgroup-limited configuration — sha256 over a random shared payload (never `/dev/zero`'s fast path, v4 fix), a C stream-copy memory kernel counted honestly at 16 bytes/element (`c-copy (r+w)`, fixes the old 2x over-credit; dd fallback relabeled `cpu-proxy`), sequential dd disk throughput, TRUE random-offset 4K reads with p50/p90/p99 latency (fixes the old sequential masquerade), live device proof, a passive TRIM matrix, tmpfs and free-space guards, info-only extras (AES-256-GCM/ChaCha20, gzip/zstd, fork/exec rate, pipe IPC, small-file rate), and network best-of-4 download + Cloudflare upload in one parallel probe wave that also yields Cloudflare-colo geo truth, a US/EU/Asia/AU region latency matrix, a NAT/CGNAT verdict, outbound port viability (25/465/587/1194/51820, opt-out), DNS speed, NIC honesty (emulated e1000 vs virtio), packet loss, and an IPv6 grade; (4) audits the local SSH & security posture with correct OpenSSH Include first-match semantics (v4 fix), weak ciphers/MACs/kex, MaxStartups/ClientAlive, non-default AuthorizedKeysFile paths, PAM pwquality, password aging, auditd, NTP sync, banner leaks, PATH world-writables, SUID/SGID inventory, core dumps, fs.protected_* sysctls, legacy daemons, sudo/pkexec versions, umask, and a forensics-toolkit check, summarized as GOOD/FAIR/WEAK with OK/WARN/BAD badges — local machine only, zero network traffic in `sec` mode (CI-enforced); and (5) reports with bar gauges, a one-line share card, a `--compare` run-to-run trend, optional JSON/Markdown/Prometheus textfile/Discord sinks, `--redact` identity masking applied to every sink, and CI exit gates (`--min-score`, `--fail-on`). BH-SCORE stays 7×100 (cpu1c = sha1c/5, cpumc = shanc/20, mem = GBps*8, dseq = seqw/10, d4k = (4kw+4kr)/4, ndown = down/20, nup = up/20) capped at 700 with grade S/A/B/C/D/F; all v4 metrics are deliberately informational and never scored.

| Flag | Effect |
|---|---|
| `all` / `detect` / `info` / `bench` / `sec` / `selftest` / `help` | modes (default `all`; `sec` and `detect` are zero-traffic) |
| `--fast` | smaller payloads, no region matrix / port probes |
| `--no-net` | skip all network tests |
| `--no-sec` | skip the SSH/security audit |
| `--no-port-probe` | skip outbound port checks (25/465/587/1194/51820) |
| `--redact` | mask IPs / usernames / instance ids in every sink |
| `--only LIST` / `--skip LIST` | run only / skip modules: cpu,mem,disk,extra,net,sec,env,gpu,storage,info |
| `--min-score N` | exit 3 when BH-SCORE < N (CI gate) |
| `--fail-on warn\|bad` | exit 4 when the security posture matches (CI gate) |
| `--prom PATH` | Prometheus textfile export (atomic rename) |
| `--compare PATH` | diff against a previous JSON report (trend arrows) |
| `--webhook URL` | POST Discord embed (env `BH_WEBHOOK`) — optional |
| `--json PATH` / `--markdown PATH` / `--output PATH` | JSON / Markdown / plain-text report (`-` = stdout) |
| `--disk-dir DIR` | disk test directory (default `/tmp`) |
| `--no-color` | disable ANSI colors (env `BH_NO_COLOR=1`, `BH_GAUGE_ASCII=1` for ASCII bars) |
| `--version` | print version |

```sh
curl -fsSL https://raw.githubusercontent.com/victoryvpsvn-star/blackhole-discord-terminal/main/vps-bench/install.sh | sh
blackhole-vps-bench all --fast
blackhole-vps-bench sec
blackhole-vps-bench bench --compare last.json --min-score 400 --prom metrics.prom
```

Exit codes: 0 ok, 1 no benchmark data, 2 usage error, 3 score below `--min-score`, 4 security posture hit `--fail-on`. No root required.
