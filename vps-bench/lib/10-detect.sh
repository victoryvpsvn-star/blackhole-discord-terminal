# =====================================================================
# blackhole-vps-bench · 10-detect.sh — virtualization / environment detection
# Answers: KVM? Docker? OpenVZ? LXC? Xen? Hyper-V? VMware? bare metal?
# Every verdict carries evidence lines so the user can verify the reasoning.
# =====================================================================
# shellcheck shell=bash

BH_KIND="unknown"      # bare-metal | vm | container
BH_TYPE="unknown"      # kvm, docker, openvz, lxc, xen-hvm, aws-metal, chroot, ...
BH_PRODUCT="Unknown"
BH_HOST_TYPE=""        # host VM type when running inside a container
BH_HOST_PRODUCT=""
BH_CLOUD=""
BH_CLOUD_DETAIL=""
BH_CLOUD_METHOD=""     # how BH_CLOUD was determined: dmi | metadata
BH_AWS_GEN=""          # AWS EC2 generation: xen | nitro
BH_EVIDENCE=""
BH_DMI_VENDOR=""; BH_DMI_PRODUCT=""; BH_DMI_FAMILY=""; BH_DMI_BOARD=""; BH_DMI_BIOS=""
BH_DMI_BIOS_VERSION=""; BH_DMI_ASSET_TAG=""
BH_CHASSIS_TYPE=""; BH_CHASSIS_CLASS=""   # SMBIOS chassis type + vm|physical|"" class
BH_CHASSIS_WEAK=0      # 1 when chassis is 1/Other or 2/Unknown (weak VM evidence only)
BH_WSL_GEN=""          # WSL generation: 1 | 2 ("" when not WSL)
BH_IS_CHROOT=0         # 1 when / differs from /proc/1/root/. (chroot jail)

# ---- R3-approved deep-scan verdicts (optional: ""/0 when undetermined) ----
BH_VIRT_NESTED=""      # C4: exposed | masked | native | ""  (nested-virt tri-state)
BH_CONF_COMPUTING=""   # C1: amd-sev|amd-sev-es|amd-sev-snp|intel-tdx|arm-cca|""
BH_IRQ_VMM=""          # C7: comma list of VMM handler names from /proc/interrupts
BH_VIRTIO_DEVS=""      # C8: comma list of virtio driver names (virtio_blk,virtio_net)
BH_IRQ_VMM_RE='kvm[a-z-]*|xen[a-z-]*|hv_[a-z]+|vmbus|dragonball[.a-z0-9]*|virtio[0-9]*|vfio|firecracker|cloud-hypervisor'

dmi_read() {
  local f="/sys/class/dmi/id/$1" v=""
  if [ -r "$f" ]; then v="$(tr -d '\n' < "$f" 2>/dev/null)"; fi
  printf '%s' "$v"
}

read_all_dmi() {
  BH_DMI_VENDOR="$(dmi_read sys_vendor)"
  BH_DMI_PRODUCT="$(dmi_read product_name)"
  BH_DMI_FAMILY="$(dmi_read product_family)"
  BH_DMI_BOARD="$(dmi_read board_vendor)"
  BH_DMI_BIOS="$(dmi_read bios_vendor)"
  BH_DMI_BIOS_VERSION="$(dmi_read bios_version)"
  BH_DMI_ASSET_TAG="$(dmi_read chassis_asset_tag)"
}

append_ev() { BH_EVIDENCE="${BH_EVIDENCE:+$BH_EVIDENCE
}• $1"; }

# x86: "hypervisor" sits in the flags line; aarch64: the same token appears in
# the "Features" line (Graviton/Ampere KVM guests) — whole-file grep covers
# both. ARM has no vmx/svm; this is the only CPU-level hypervisor tell there.
has_hv_flag() { grep -qw hypervisor /proc/cpuinfo 2>/dev/null; }

cpu_brand() { awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null; }

# systemd-detect-virt guarded by command_exists + timeout 3 (contract).
sdv_vmm() {
  command_exists systemd-detect-virt || return 0
  if command_exists timeout; then
    timeout 3 systemd-detect-virt --vm 2>/dev/null || true
  else
    systemd-detect-virt --vm 2>/dev/null || true
  fi
}
sdv_any() {
  command_exists systemd-detect-virt || return 0
  if command_exists timeout; then
    timeout 3 systemd-detect-virt 2>/dev/null || true
  else
    systemd-detect-virt 2>/dev/null || true
  fi
}

# grep with an optional 3s timeout — used for the larger /proc scans below;
# plain greps on tiny files (cpuinfo, cgroups) follow the existing file style.
bh_grep_to() {
  if command_exists timeout; then timeout 3 grep "$@"; else grep "$@"; fi
}

# sort + dedupe whitespace-separated words into a comma list (bash-3.2 safe)
bh_join_commas() {
  [ -n "${1:-}" ] || return 0
  local out
  out="$(printf '%s\n' "$1" | sort -u | tr '\n' ',')"
  printf '%s' "${out%,}"
}

# ---- chassis ----
# SMBIOS chassis_type: 1 (Other) / 2 (Unknown) is what most VMs report;
# 3..36 are concrete physical enclosures (desktop, tower, rack, blade, ...).
detect_chassis() {
  local v
  v="$(dmi_read chassis_type)"
  case "$v" in
    ''|*[!0-9]*) return 0 ;;   # file missing or not a plain integer
  esac
  BH_CHASSIS_TYPE="$v"
  case "$v" in
    1|2)
      BH_CHASSIS_CLASS="vm"
      BH_CHASSIS_WEAK=1   # softened: 1/Other and 2/Unknown are also common on physical OEM boards
      ;;
    *)
      if [ "$v" -ge 3 ] && [ "$v" -le 36 ]; then
        BH_CHASSIS_CLASS="physical"
      else
        BH_CHASSIS_CLASS=""
      fi
      ;;
  esac
  case "$BH_CHASSIS_CLASS" in
    vm)
      if [ "$BH_CHASSIS_WEAK" = "1" ]; then
        append_ev "DMI chassis_type=$v => VM-typical (weak: 1/Other also common on physical OEM boards)"
      else
        append_ev "DMI chassis_type=$v => VM-typical"
      fi
      ;;
    physical) append_ev "DMI chassis_type=$v => physical chassis" ;;
  esac
}

# ---- chroot ----
# Our "/" is not the root PID 1 sees. Purely informational here — detect_virt
# only promotes it to a verdict when no container/VM signal exists at all.
detect_chroot() {
  BH_IS_CHROOT=0
  [ -d /proc/1/root/. ] || return 0
  local a b
  a="$(stat -c %d:%i / 2>/dev/null)"
  b="$(stat -c %d:%i /proc/1/root/. 2>/dev/null)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
    BH_IS_CHROOT=1
    append_ev "/ and /proc/1/root/. differ (device:inode) => chroot"
  fi
}

# Map DMI vendor/product (optional: bios_vendor, chassis asset tag) to a
# friendly VM product name. Prints "" when unknown.
map_vm_product() {
  local vendor="$1" product="${2:-}" bios="${3:-}" tag="${4:-}" p2=""
  case "$vendor" in
    QEMU)                    printf 'KVM/QEMU' ;;
    "Amazon EC2")            printf 'AWS EC2 (Nitro/KVM)' ;;
    "Microsoft Corporation") printf 'Hyper-V' ;;
    VMware*)                 printf 'VMware ESXi' ;;
    "innotek GmbH")          printf 'VirtualBox' ;;
    Xen)                     printf 'Xen HVM' ;;
    Bochs)                   printf 'Bochs' ;;
    "Parallels Software International Inc.") printf 'Parallels' ;;
    Google)                  printf 'Google Compute Engine (KVM)' ;;
    DigitalOcean)            printf 'DigitalOcean (KVM)' ;;
    Hetzner)                 printf 'Hetzner Cloud (KVM)' ;;
    Scaleway)                printf 'Scaleway (KVM)' ;;
    "Oracle Corporation")
      # Oracle Corporation covers both on-prem Oracle VM and OCI guests;
      # only the OracleCloud.com chassis asset tag means OCI.
      if [ "$tag" = "OracleCloud.com" ]; then
        printf 'Oracle Cloud (OCI)'
      else
        printf 'Oracle VM'
      fi
      ;;
    Alibaba*)                printf 'Alibaba Cloud (KVM)' ;;
    Tencent*)                printf 'Tencent Cloud (KVM)' ;;
    OpenStack*|Mirantis*)    printf 'OpenStack (KVM)' ;;
    "FreeBSD bhyve"|bhyve)   printf 'bhyve' ;;
    *)
      case "$product" in
        *"Virtual Machine"*)      p2='KVM/QEMU' ;;
        *VMware*)                 p2='VMware' ;;
        *VirtualBox*)             p2='VirtualBox' ;;
        *"HVM domU"*)             p2='Xen HVM' ;;
        *BHYVE*|*bhyve*)          p2='bhyve' ;;
        *"Standard PC"*|*"QEMU"*) p2='KVM/QEMU' ;;
        *"Alibaba Cloud ECS"*)    p2='Alibaba Cloud ECS (KVM)' ;;
        *OpenStack*)              p2='OpenStack (KVM)' ;;
        *)                        p2='' ;;
      esac
      # Linode exposes no sys_vendor/product signature — only bios_vendor says "Linode"
      if [ -z "$p2" ] && [ "$bios" = "Linode" ]; then p2='Linode (KVM)'; fi
      printf '%s' "$p2"
      ;;
  esac
}

# Map DMI data (vendor, product, bios_vendor, chassis asset tag) to a cloud
# provider. Prints "" when the platform carries no cloud identity.
# NOTE: "Microsoft Corporation" alone is plain Hyper-V — Azure requires the
# well-known chassis asset tag 7783-7084-3265-9085-8269-3286-77.
map_vm_cloud() {
  local vendor="$1" product="${2:-}" bios="${3:-}" tag="${4:-}"
  case "$vendor" in
    "Amazon EC2")  printf 'AWS EC2' ;;
    "Microsoft Corporation")
      if [ "$tag" = "7783-7084-3265-9085-8269-3286-77" ]; then
        printf 'Microsoft Azure'
      fi
      ;;
    Google)        printf 'Google Cloud' ;;
    DigitalOcean)  printf 'DigitalOcean' ;;
    Alibaba*)      printf 'Alibaba Cloud' ;;
    Tencent*)      printf 'Tencent Cloud' ;;
    OpenStack*)    printf 'OpenStack cloud' ;;
    "Oracle Corporation")
      if [ "$tag" = "OracleCloud.com" ]; then
        printf 'Oracle Cloud (OCI)'
      fi
      ;;
    Hetzner)       printf 'Hetzner Cloud' ;;
    Scaleway)      printf 'Scaleway' ;;
    *)
      # Linode: no sys_vendor, only bios_vendor
      if [ "$bios" = "Linode" ]; then
        printf 'Linode (Akamai)'
      else
        case "$product" in
          *OpenStack*) printf 'OpenStack cloud' ;;
        esac
      fi
      ;;
  esac
}

# Pure helper (tests call this directly): cloud identity from DMI globals.
cloud_from_dmi() {
  map_vm_cloud "$BH_DMI_VENDOR" "$BH_DMI_PRODUCT" "$BH_DMI_BIOS" "$BH_DMI_ASSET_TAG"
}

# AWS bios_version looks like "4.2.amazon" — evidence-only corroboration.
bh_aws_bios_ev() {
  case "$BH_DMI_BIOS_VERSION" in
    *amazon*) append_ev "DMI bios_version='$BH_DMI_BIOS_VERSION' (Amazon build)" ;;
  esac
}

# AWS EC2 generation split from the DMI signature:
#   product contains ".metal"  -> bare metal instance (Nitro)
#   product contains "HVM domU" -> Xen generation
#   otherwise                  -> Nitro (KVM), with /sys/hypervisor/type as tiebreak
classify_aws() {
  local hv=""
  [ -r /sys/hypervisor/type ] && hv="$(tr -d '\n' < /sys/hypervisor/type 2>/dev/null)"
  case "$BH_DMI_PRODUCT" in
    *.metal*)
      BH_AWS_GEN="nitro"
      BH_KIND="bare-metal"
      BH_TYPE="aws-metal"
      BH_PRODUCT="AWS EC2 bare metal (Nitro)"
      append_ev "AWS DMI product '$BH_DMI_PRODUCT' contains .metal => bare metal instance (Nitro)"
      ;;
    *"HVM domU"*)
      BH_AWS_GEN="xen"
      BH_PRODUCT="AWS EC2 (Xen HVM domU)"
      append_ev "AWS DMI product 'HVM domU' => Xen generation"
      ;;
    *)
      if [ "$hv" = "xen" ]; then
        BH_AWS_GEN="xen"
        BH_PRODUCT="AWS EC2 (Xen)"
        append_ev "/sys/hypervisor/type = xen => AWS Xen generation"
      else
        BH_AWS_GEN="nitro"
        BH_PRODUCT="AWS EC2 (Nitro/KVM)"
        append_ev "AWS DMI without 'HVM domU'/xen hypervisor => Nitro generation"
      fi
      ;;
  esac
  bh_aws_bios_ev
}

map_container_product() {
  case "$1" in
    docker)         printf 'Docker' ;;
    podman)         printf 'Podman' ;;
    kubernetes)     printf 'Kubernetes (CRI)' ;;
    lxc)            printf 'LXC / LXD' ;;
    systemd-nspawn) printf 'systemd-nspawn' ;;
    openvz)         printf 'OpenVZ / Virtuozzo' ;;
    containerd)     printf 'containerd' ;;
    chroot)         printf 'chroot environment' ;;
    *)              printf 'Container (%s)' "$1" ;;
  esac
}

map_sdv_product() {
  case "$1" in
    kvm)       printf 'KVM' ;;
    qemu)      printf 'QEMU' ;;
    vmware)    printf 'VMware' ;;
    microsoft) printf 'Hyper-V' ;;
    oracle)    printf 'VirtualBox' ;;
    xen)       printf 'Xen' ;;
    bochs)     printf 'Bochs' ;;
    parallels) printf 'Parallels' ;;
    bhyve)     printf 'bhyve' ;;
    "")       printf '' ;;
    *)         printf 'hypervisor (%s)' "$1" ;;
  esac
}

# Detect the hypervisor hosting the container we run in (best effort).
detect_host_virt() {
  local t p
  t="$(sdv_vmm)"
  p="$(map_vm_product "$BH_DMI_VENDOR" "$BH_DMI_PRODUCT" "$BH_DMI_BIOS" "$BH_DMI_ASSET_TAG")"
  if [ -n "$p" ]; then
    BH_HOST_TYPE="${t:-$BH_HOST_TYPE}"
    BH_HOST_PRODUCT="$p"
    append_ev "host DMI: vendor='$BH_DMI_VENDOR' product='$BH_DMI_PRODUCT'"
  elif [ -n "$t" ]; then
    BH_HOST_TYPE="$t"
    p="$(map_sdv_product "$t")"
    BH_HOST_PRODUCT="${p:-$t}"
    append_ev "systemd-detect-virt --vm = $t"
  fi
}

detect_virt_core() {
  read_all_dmi
  detect_chassis
  detect_chroot
  local ctype=""

  # ---- container signals ----
  # G8 fix: evaluated BEFORE any WSL early-return — Docker can run inside WSL2,
  # and that box must report kind=container/type=docker with the WSL1-vs-WSL2
  # distinction kept as the HOST label (see the WSL block below).
  if [ -e /.dockerenv ]; then
    ctype="docker"
    append_ev "/.dockerenv present"
  fi
  if [ -e /run/.containerenv ]; then
    ctype="${ctype:-podman}"
    append_ev "/run/.containerenv present (Podman)"
  fi
  if [ -r /run/systemd/container ]; then
    local sc
    sc="$(tr -d '\n' < /run/systemd/container 2>/dev/null)"
    if [ -n "$sc" ]; then
      ctype="${ctype:-$sc}"
      append_ev "/run/systemd/container = $sc"
    fi
  fi
  local cg
  for cg in /proc/1/cgroup /proc/self/cgroup /proc/self/mountinfo; do
    [ -r "$cg" ] || continue
    if grep -aq kubepods "$cg" 2>/dev/null; then
      ctype="kubernetes"; append_ev "$cg mentions kubepods"
    fi
    if grep -aqE '/docker[/-]|docker\.slice' "$cg" 2>/dev/null; then
      ctype="${ctype:-docker}"; append_ev "$cg references docker"
    fi
    if grep -aqE 'libpod|podman' "$cg" 2>/dev/null; then
      ctype="${ctype:-podman}"; append_ev "$cg references podman/libpod"
    fi
    if grep -aqE '(^|[:/])lxc' "$cg" 2>/dev/null; then
      ctype="${ctype:-lxc}"; append_ev "$cg references lxc"
    fi
    if grep -aqE 'machine.slice|systemd-nspawn' "$cg" 2>/dev/null; then
      ctype="${ctype:-systemd-nspawn}"; append_ev "$cg references systemd-nspawn/machine.slice"
    fi
    if grep -aq 'vzcid\|/vz/' "$cg" 2>/dev/null; then
      ctype="openvz"; append_ev "$cg references openvz"
    fi
  done
  if [ -e /var/run/secrets/kubernetes.io/serviceaccount ] || [ -e /run/secrets/kubernetes.io/serviceaccount ]; then
    ctype="kubernetes"
    append_ev "Kubernetes serviceaccount present"
  fi
  if [ -r /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container=lxc'; then
    ctype="lxc"; append_ev "/proc/1/environ container=lxc"
  fi
  # Kubernetes injects KUBERNETES_SERVICE_HOST into PID 1's environment
  if [ -r /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^KUBERNETES_SERVICE_HOST='; then
    ctype="kubernetes"
    append_ev "/proc/1/environ sets KUBERNETES_SERVICE_HOST"
  fi

  # ---- OpenVZ / Virtuozzo (container tech, may sit above other signals) ----
  # Virtuozzo 7 dropped /proc/user_beancounters; envID/VxID in status is the marker
  if grep -qE '^(envID|VxID):' /proc/self/status 2>/dev/null; then
    ctype="openvz"
    append_ev "/proc/self/status has envID/VxID (OpenVZ / Virtuozzo 7)"
  fi
  if [ -e /proc/vz ] && [ ! -e /proc/bc ]; then
    ctype="openvz"
    append_ev "/proc/vz present without /proc/bc"
  elif [ -e /proc/user_beancounters ]; then
    ctype="openvz"
    append_ev "/proc/user_beancounters present"
  fi

  # ---- WSL (1 = syscall translation layer, 2 = real VM with custom kernel) ----
  # G8: runs AFTER the container signals so a container on WSL keeps its own
  # verdict and the WSL generation becomes the host VM label instead.
  if grep -qi microsoft /proc/version 2>/dev/null; then
    local krel wslprod
    krel="$(uname -r 2>/dev/null)"
    case "$krel" in
      *microsoft-standard*)
        BH_WSL_GEN=2
        wslprod="WSL2 (Windows Subsystem for Linux 2, real Linux kernel)"
        ;;
      *)
        BH_WSL_GEN=1
        wslprod="WSL1 (Windows Subsystem for Linux 1, syscall translation)"
        ;;
    esac
    if [ -n "$ctype" ]; then
      # container verdict wins; WSL1-vs-WSL2 distinction moves to the host label
      BH_KIND="container"
      BH_TYPE="$ctype"
      BH_PRODUCT="$(map_container_product "$ctype")"
      BH_HOST_TYPE="wsl$BH_WSL_GEN"
      BH_HOST_PRODUCT="$wslprod"
      append_ev "/proc/version mentions Microsoft (kernel $krel -> WSL$BH_WSL_GEN) => container on WSL$BH_WSL_GEN host"
      return
    fi
    BH_KIND="vm"; BH_TYPE="wsl"
    BH_PRODUCT="$wslprod"
    append_ev "/proc/version mentions Microsoft (kernel $krel -> WSL$BH_WSL_GEN)"
    detect_host_virt
    return
  fi

  if [ -n "$ctype" ]; then
    BH_KIND="container"
    BH_TYPE="$ctype"
    BH_PRODUCT="$(map_container_product "$ctype")"
    detect_host_virt
    return
  fi

  # ---- Xen paravirtualized (no DMI in PV guests) ----
  if [ -r /sys/hypervisor/type ] && [ "$(tr -d '\n' < /sys/hypervisor/type 2>/dev/null)" = "xen" ]; then
    if [ "$BH_DMI_VENDOR" = "Amazon EC2" ]; then
      # EC2 Xen guests DO expose DMI ("HVM domU") — report AWS, not generic Xen
      BH_KIND="vm"; BH_TYPE="xen-hvm"; BH_AWS_GEN="xen"
      BH_PRODUCT="AWS EC2 (Xen HVM domU)"
      append_ev "/sys/hypervisor/type = xen"
      append_ev "DMI: vendor='Amazon EC2' product='$BH_DMI_PRODUCT' => AWS Xen generation"
      bh_aws_bios_ev
      BH_CLOUD="AWS EC2"
      BH_CLOUD_METHOD="dmi"
      return
    fi
    BH_KIND="vm"; BH_TYPE="xen-pv"; BH_PRODUCT="Xen PV"
    append_ev "/sys/hypervisor/type = xen"
    if [ -r /proc/xen/capabilities ] && grep -q control_d /proc/xen/capabilities 2>/dev/null; then
      BH_PRODUCT="Xen dom0 (host)"
      append_ev "/proc/xen/capabilities has control_d (dom0)"
    fi
    return
  fi

  # ---- full VMs ----
  local t p
  t="$(sdv_vmm)"
  p="$(map_vm_product "$BH_DMI_VENDOR" "$BH_DMI_PRODUCT" "$BH_DMI_BIOS" "$BH_DMI_ASSET_TAG")"
  if [ -n "$p" ]; then
    BH_KIND="vm"
    BH_TYPE="${t:-unknown}"
    BH_PRODUCT="$p"
    append_ev "DMI: vendor='$BH_DMI_VENDOR' product='$BH_DMI_PRODUCT' board='$BH_DMI_BOARD'"
    [ -n "$t" ] && append_ev "systemd-detect-virt --vm = $t"
    # AWS needs a generation split (Nitro vs Xen) and a .metal bare-metal override
    case "$BH_DMI_VENDOR" in
      "Amazon EC2") classify_aws ;;
    esac
  elif [ -n "$t" ]; then
    BH_KIND="vm"
    BH_TYPE="$t"
    BH_PRODUCT="Virtual machine ($t)"
    append_ev "systemd-detect-virt --vm = $t"
  elif has_hv_flag; then
    BH_KIND="vm"
    BH_TYPE="unknown"
    BH_PRODUCT="Virtual machine (hypervisor bit set, vendor unknown)"
    append_ev "/proc/cpuinfo has 'hypervisor' flag"
  else
    BH_KIND="bare-metal"
    BH_TYPE="none"
    BH_PRODUCT="Bare metal (dedicated server)"
    append_ev "no hypervisor flag, no container markers, no VM DMI signature"
    [ -n "$BH_DMI_VENDOR" ] && append_ev "DMI: vendor='$BH_DMI_VENDOR' product='$BH_DMI_PRODUCT'"
    case "$BH_CHASSIS_CLASS" in
      physical) append_ev "chassis_type=$BH_CHASSIS_TYPE corroborates bare metal" ;;
      vm)       append_ev "chassis_type=$BH_CHASSIS_TYPE suggests VM (weak: chassis 1/Other is common on physical boards too)" ;;
    esac
    # chroot is the weakest container signal: only claim it when nothing else matched
    if [ "$BH_IS_CHROOT" = "1" ]; then
      BH_KIND="container"
      BH_TYPE="chroot"
      BH_PRODUCT="$(map_container_product chroot)"
      append_ev "everything else unknown + / differs from /proc/1/root => chroot"
    fi
  fi

  # (nested-virtualization note moved to detect_nested_virt — C4 tri-state,
  #  now runs for every kind: vm, container, bare-metal and WSL)

  # clocksource corroboration
  local cs
  cs="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null)"
  case "$cs" in
    kvm-clock) append_ev "clocksource = kvm-clock (KVM signature)" ;;
    tsc)       : ;;
    xen)       append_ev "clocksource = xen" ;;
    *)         : ;;
  esac

  # cloud vendor from DMI (metadata probes live in 12-cloud.sh)
  BH_CLOUD="$(cloud_from_dmi)"
  # Scaleway images also drop a runtime marker when DMI is hidden/overridden
  if [ -z "$BH_CLOUD" ] && [ -e /var/run/scaleway ]; then
    BH_CLOUD="Scaleway"
    append_ev "/var/run/scaleway marker present"
  fi
  [ -n "$BH_CLOUD" ] && BH_CLOUD_METHOD="dmi"
}

# =====================================================================
# R3-approved deep-scan detectors — pure local reads, no network, no
# stdout; each only SETs its global + appends evidence lines.
# =====================================================================

# ---- C4: nested virtualization tri-state ----
# BH_VIRT_NESTED = "exposed" | "masked" | "native" | "" (no CPU signal)
#   exposed: vmx/svm visible AND hypervisor flag -> guest may run its own VMs
#   native : vmx/svm visible without hypervisor flag -> bare-metal CPU
#   masked : hypervisor flag without vmx/svm -> CPUID-filtered by the host
# ARM (aarch64) has no vmx/svm; the "hypervisor" token in the Features line
# plays the hypervisor role (Graviton/Ampere), so ARM guests land on "masked".
detect_nested_virt() {
  BH_VIRT_NESTED=""
  local vmx=0 hv=0 is_arm=0
  bh_grep_to -qwE 'vmx|svm' /proc/cpuinfo 2>/dev/null && vmx=1
  has_hv_flag && hv=1
  bh_grep_to -q '^Features' /proc/cpuinfo 2>/dev/null && is_arm=1  # aarch64 cpuinfo format
  if [ "$vmx" = "1" ] && [ "$hv" = "1" ]; then
    BH_VIRT_NESTED="exposed"
    append_ev "nested virtualization exposed (vmx/svm in CPU flags) => guest may run its own VMs"
  elif [ "$vmx" = "1" ]; then
    BH_VIRT_NESTED="native"
    append_ev "vmx/svm in CPU flags without hypervisor flag => native (bare-metal CPU)"
  elif [ "$hv" = "1" ]; then
    BH_VIRT_NESTED="masked"
    if [ "$is_arm" = "1" ]; then
      append_ev "hypervisor bit in cpuinfo Features (no vmx/svm on ARM) => masked (virt features not exposed to guests)"
    else
      append_ev "hypervisor flag without vmx/svm => masked (CPUID-filtered by host)"
    fi
  fi
  # A container shares the host kernel: /proc/cpuinfo is the host's view,
  # never the container's own — never claim the guest owns the flags.
  if [ -n "$BH_VIRT_NESTED" ] && [ "$BH_KIND" = "container" ]; then
    append_ev "caveat: cpu flags are host cpu flags (container view)"
  fi
}

# ---- C1: confidential computing ----
# BH_CONF_COMPUTING = amd-sev | amd-sev-es | amd-sev-snp | intel-tdx | arm-cca | ""
# Sources ONLY (no dmesg inference): (a) /proc/cpuinfo flags sev/sev_es/
# sev_snp/tdx_guest, (b) existence of /dev/sev-guest, (c) directory
# /sys/kernel/security/tdx_guest. Highest wins: snp > sev-es > sev; tdx
# standalone. arm-cca is a reserved value — no (a)/(b)/(c) source exists for
# it yet, so it stays unset until an approved marker is defined.
detect_conf_computing() {
  BH_CONF_COMPUTING=""
  local src=""
  if bh_grep_to -qw 'sev_snp' /proc/cpuinfo 2>/dev/null; then
    BH_CONF_COMPUTING="amd-sev-snp"; src="cpuinfo flag sev_snp"
  elif bh_grep_to -qw 'sev_es' /proc/cpuinfo 2>/dev/null; then
    BH_CONF_COMPUTING="amd-sev-es"; src="cpuinfo flag sev_es"
  elif bh_grep_to -qw 'sev' /proc/cpuinfo 2>/dev/null; then
    BH_CONF_COMPUTING="amd-sev"; src="cpuinfo flag sev"
  elif bh_grep_to -qw 'tdx_guest' /proc/cpuinfo 2>/dev/null; then
    BH_CONF_COMPUTING="intel-tdx"; src="cpuinfo flag tdx_guest"
  fi
  if [ -z "$BH_CONF_COMPUTING" ] && [ -e /dev/sev-guest ]; then
    BH_CONF_COMPUTING="amd-sev"; src="/dev/sev-guest present"
  fi
  if [ -z "$BH_CONF_COMPUTING" ] && [ -d /sys/kernel/security/tdx_guest ]; then
    BH_CONF_COMPUTING="intel-tdx"; src="/sys/kernel/security/tdx_guest present"
  fi
  if [ -n "$BH_CONF_COMPUTING" ]; then
    append_ev "confidential computing: $BH_CONF_COMPUTING ($src)"
  else
    append_ev "confidential computing: none detected"
  fi
}

# ---- C7: VMM handler fingerprint from /proc/interrupts ----
# Interrupt handler names leak the hosting VMM (regex in BH_IRQ_VMM_RE).
# GUARD (R3): inside a container /proc/interrupts is the HOST's table, so the
# scan only runs when the header CPU-column count matches our visible NCPU;
# otherwise BH_IRQ_VMM stays "" (host view would be misattributed).
detect_irq_vmm() {
  BH_IRQ_VMM=""
  if [ ! -r /proc/interrupts ]; then
    append_ev "VMM fingerprint: /proc/interrupts unreadable"
    return 0
  fi
  local cols
  cols="$(awk 'NR==1{print NF; exit}' /proc/interrupts 2>/dev/null)"
  if [ "$BH_KIND" = "container" ]; then
    if [ -z "$cols" ] || [ "$cols" -ne "$NCPU" ] 2>/dev/null; then
      append_ev "VMM fingerprint skipped: /proc/interrupts shows $cols CPU columns vs NCPU=$NCPU (container sees host table)"
      return 0
    fi
  fi
  local raw
  raw="$(bh_grep_to -oE "$BH_IRQ_VMM_RE" /proc/interrupts 2>/dev/null | sort -u | tr '\n' ',')"
  raw="${raw%,}"
  BH_IRQ_VMM="$raw"
  if [ -n "$BH_IRQ_VMM" ]; then
    append_ev "VMM handlers in /proc/interrupts: $BH_IRQ_VMM"
  else
    append_ev "no VMM handler names in /proc/interrupts"
  fi
}

# ---- C8: virtio device inventory ----
# Driver basenames behind /sys/bus/virtio/devices/*/driver, e.g. virtio_blk.
detect_virtio_devs() {
  BH_VIRTIO_DEVS=""
  if [ ! -d /sys/bus/virtio/devices ]; then
    append_ev "virtio inventory: /sys/bus/virtio absent"
    return 0
  fi
  local d name names="" n=0
  for d in /sys/bus/virtio/devices/*; do
    [ -e "$d" ] || continue          # glob unmatched -> literal pattern
    [ -e "$d/driver" ] || continue   # virtio device not bound to a driver
    name="$(readlink "$d/driver" 2>/dev/null)"
    name="${name##*/}"               # basename without an external command
    [ -n "$name" ] || continue
    names="$names $name"
    n=$((n + 1))
  done
  if [ -n "$names" ]; then
    BH_VIRTIO_DEVS="$(bh_join_commas "$names")"
    append_ev "virtio devices: $BH_VIRTIO_DEVS ($n device(s))"
  else
    append_ev "no virtio devices bound"
  fi
}

# =====================================================================
# Entry point — 99-main.sh calls detect_virt(). Classic verdict first,
# then the cross-cutting deep-scan detectors (they need BH_KIND set for
# the container guards, hence they run after the verdict is known).
# =====================================================================
detect_virt() {
  detect_virt_core
  detect_nested_virt      # C4
  detect_conf_computing   # C1
  detect_irq_vmm          # C7
  detect_virtio_devs      # C8
}
