# vps-bench v5.1 — Enhancement gap list (from 10 idea agents, 100 ideas, deduped vs existing coverage)

Existing tool already covers: virt detection chain, DMI, cgroups v1/v2, container markers, cloud DMI+metadata,
PSI (00-core bh_psi), CPU vulnerabilities, NUMA, cpufreq/governor, THP, hugepages, entropy, lockdown, LSM,
CapEff, OOM score, conntrack, congestion control, TRIM, schedulers, sector sizes, mdstat, nvme, sshd -T,
Include parsing, weak crypto, fail2ban, authorized_keys census, tainted, WSL, OpenVZ beancounters, gvisor hint.

GAPS proposed for v5.1 (each = candidate module work):

G1. SMT / topology truth — thread_siblings_list per cpu0: "2 threads/core (SMT on)" or "1 (SMT off)"; also
    siblings vs cpu cores cross-check, online vs possible cores (hotplug). Files: /sys/devices/system/cpu/cpu0/topology/*,
    /sys/devices/system/cpu/{online,possible,present}.
G2. Overcommit policy — /proc/sys/vm/overcommit_memory (0 heuristic/1 always/2 strict) + overcommit_ratio +
    CommitLimit vs Committed_AS headroom from /proc/meminfo; warn when Committed_AS > CommitLimit (mode 2 OOM risk).
G3. TCP stack knobs — /proc/sys/net/ipv4/{tcp_fastopen,tcp_syncookies,tcp_rmem,tcp_wmem}, conf/{all,default}/rp_filter,
    tcp_notsent_lowat. Classify: fastopen mode meaning, syncookies on=good, rmem/wmem max for throughput ceiling.
G4. Queue discipline of default iface — tc qdisc show dev <def-iface> (works unprivileged); report qdisc name
    (fq/fq_codel/pfifo/mq) + relevance to BBR (fq recommended).
G5. Sandbox runtime class — kata-containers: /proc/self/mountinfo contains kata-containers, env KATA_CONTAINER,
    FC_CONTAINER_ID, /run/kata-containers, /opt/kata; gVisor: /proc/version "gVisor"; firecracker /proc/version
    "Firecracker"; label "sandbox: kata|gvisor|firecracker|none" + nested-viz note (this matters on modern clouds).
G6. User namespaces budget — /proc/sys/user/max_user_namespaces (+ current user ns count via /proc/self/ns/user
    vs init), cgroup v1/v2 already known; warn 0 = userns disabled (hardening) / huge = attack surface.
G7. Guest-agent & provisioning census — qemu-guest-agent, vmtoolsd (open-vm-tools), waagent (Azure Linux agent),
    google-guest-agent, amazon-ssm-agent, exoscale/cloudstack agent, cloud-init (status per /var/lib/cloud +
    cloud-init status), ignition. Detection via command -v, pgrep, systemd unit files list (systemctl list-unit-files
    unprivileged), /etc default files. Adds "who is managing this box" visibility.
G8. Disk-read cache honesty — before the dd read benchmark in 50-disk: if root, sync + echo 3 > drop_caches
    (best effort), label result UNCACHED vs CACHED; never mix medians. Improves accuracy of the headline number.
G9. Extra speedtest backends — if speedtest-cli binary exists use it (full mode only), if iperf3 + public server
    arg given use it; keep cloudflare curl as default; report which method was used.
G10. Discord notify upgrade (CI) — notify job downloads verdict artifacts (Verdict/share/Posture lines) from the
    matrix jobs and includes them in the embed; fix malformed workflow trigger `branches: ain]` -> [main].
G11. CPU steal & hypervisor shed check — quick 200ms /proc/stat delta: steal time % (st) visible in guests;
    high steal = noisy neighbor. Cheap, high value for VPS users.

Non-goals (rejected before review): installing packages on user machines, metadata sweep without opt-in flag
(already opt-in in 12-cloud), running fsck/mount changes, touching sshd config.
