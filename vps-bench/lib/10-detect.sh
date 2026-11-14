# =====================================================================
# blackhole-vps-bench · 10-detect.sh — virtualization / environment detection
# Answers: KVM? Docker? OpenVZ? LXC? Xen? Hyper-V? VMware? bare metal?
# Every verdict carries evidence lines so the user can verify the reasoning.
# =====================================================================
# shellcheck shell=bash

BH_KIND="unknown"      # bare-metal | vm | container
BH_TYPE="unknown"      # kvm, docker, openvz, lxc, xen-hvm, ...
BH_PRODUCT="Unknown"
BH_HOST_TYPE=""        # host VM type when running inside a container
BH_HOST_PRODUCT=""
BH_CLOUD=""
BH_CLOUD_DETAIL=""
BH_EVIDENCE=""
BH_DMI_VENDOR=""; BH_DMI_PRODUCT=""; BH_DMI_FAMILY=""; BH_DMI_BOARD=""; BH_DMI_BIOS=""

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
}

append_ev() { BH_EVIDENCE="${BH_EVIDENCE:+$BH_EVIDENCE
}• $1"; }

has_hv_flag() { grep -qw hypervisor /proc/cpuinfo 2>/dev/null; }

cpu_brand() { awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null; }

sdv_vmm() {
  if command_exists systemd-detect-virt; then
    systemd-detect-virt --vm 2>/dev/null || true
  fi
}
sdv_any() {
  if command_exists systemd-detect-virt; then
    systemd-detect-virt 2>/dev/null || true
  fi
}

# Map DMI vendor/product to a friendly VM product name. Prints "" when unknown.
map_vm_product() {
  local vendor="$1" product="$2"
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
    "Oracle Corporation")    printf 'Oracle VM' ;;
    Alibaba*)                printf 'Alibaba Cloud (KVM)' ;;
    Tencent*)                printf 'Tencent Cloud (KVM)' ;;
    OpenStack*|Mirantis*)    printf 'OpenStack (KVM)' ;;
    "FreeBSD bhyve"|bhyve)   printf 'bhyve' ;;
    *)
      case "$product" in
        *"Virtual Machine"*)      printf 'KVM/QEMU' ;;
        *VMware*)                 printf 'VMware' ;;
        *VirtualBox*)             printf 'VirtualBox' ;;
        *"HVM domU"*)             printf 'Xen HVM' ;;
        *BHYVE*|*bhyve*)          printf 'bhyve' ;;
        *"Standard PC"*|*"QEMU"*) printf 'KVM/QEMU' ;;
        *) printf '' ;;
      esac
      ;;
  esac
}

map_vm_cloud() {
  local vendor="$1"
  case "$vendor" in
    "Amazon EC2")            printf 'AWS EC2' ;;
    "Microsoft Corporation") printf 'Microsoft Azure' ;;
    Google)                  printf 'Google Cloud' ;;
    DigitalOcean)            printf 'DigitalOcean' ;;
    Alibaba*)                printf 'Alibaba Cloud' ;;
    Tencent*)                printf 'Tencent Cloud' ;;
    OpenStack*)              printf 'OpenStack cloud' ;;
    *) printf '' ;;
  esac
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
  p="$(map_vm_product "$BH_DMI_VENDOR" "$BH_DMI_PRODUCT")"
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

detect_virt() {
  read_all_dmi
  local ctype=""

  # ---- WSL ----
  if grep -qi microsoft /proc/version 2>/dev/null; then
    BH_KIND="vm"; BH_TYPE="wsl"; BH_PRODUCT="WSL (Windows Subsystem for Linux)"
    append_ev "/proc/version mentions Microsoft"
    detect_host_virt
    return
  fi

  # ---- container signals ----
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

  # ---- OpenVZ / Virtuozzo (container tech, may sit above other signals) ----
  if [ -e /proc/vz ] && [ ! -e /proc/bc ]; then
    ctype="openvz"
    append_ev "/proc/vz present without /proc/bc"
  elif [ -e /proc/user_beancounters ]; then
    ctype="openvz"
    append_ev "/proc/user_beancounters present"
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
  p="$(map_vm_product "$BH_DMI_VENDOR" "$BH_DMI_PRODUCT")"
  if [ -n "$p" ]; then
    BH_KIND="vm"
    BH_TYPE="${t:-unknown}"
    BH_PRODUCT="$p"
    append_ev "DMI: vendor='$BH_DMI_VENDOR' product='$BH_DMI_PRODUCT' board='$BH_DMI_BOARD'"
    [ -n "$t" ] && append_ev "systemd-detect-virt --vm = $t"
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
  fi

  # nested virtualization note
  if [ "$BH_KIND" = "vm" ] && grep -qwE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
    append_ev "nested virtualization exposed (vmx/svm in CPU flags)"
  fi

  # clocksource corroboration
  local cs
  cs="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null)"
  case "$cs" in
    kvm-clock) append_ev "clocksource = kvm-clock (KVM signature)" ;;
    tsc)       : ;;
    xen)       append_ev "clocksource = xen" ;;
    *)         : ;;
  esac

  # cloud vendor from DMI
  BH_CLOUD="$(map_vm_cloud "$BH_DMI_VENDOR")"
}
