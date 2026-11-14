# =====================================================================
# blackhole-vps-bench · 15-gpu.sh — GPU / accelerator inventory (passive)
# =====================================================================
#
# v4.0 (W3-N): answers "is there a GPU here and can we actually use it?"
# sysfs-first — NO lspci dependency, ZERO network, zero writes:
#   D1 device nodes      /dev/dri/card* renderD* + /dev/nvidia* -> BH_GPU_NODES
#                        /proc/driver/nvidia/version            -> BH_NVIDIA_DRIVER
#   D2 PCI enumeration   /sys/bus/pci/devices class 0x03xx      -> BH_GPU_PCI
#   D3 nvidia-smi query  name/mem/gen/width/driver              -> BH_GPU_NVIDIA
#   D4 MIG / vGPU        nvidia-smi -L (MIG only)               -> BH_GPU_MIG / BH_GPU_VGPU
#   D5 AMD/Intel VRAM    drm sysfs mem_info_vram_total          -> BH_GPU_VRAM_SYSFS
#   D6 libs-vs-devices   ldconfig vs /dev + PCI NVIDIA          -> BH_GPU_LIBS
#   D7 passthrough       driver of the first 0x03 device        -> BH_GPU_PASSTHROUGH
#   D8 one-line verdict                                         -> BH_GPU_SUMMARY
#
# Contract: sets BH_* globals only (never prints to stdout); every potentially
# hanging external command is guarded (command_exists + `timeout 3` via
# bh_gpu_t3 — nvidia-smi is ALWAYS timeout-wrapped: a driver-less container is
# the classic hang); NO network access; no `set -e`; bash-3.2 compatible (no
# assoc arrays / mapfile / ${var,,}); never fails: on a GPU-less box every
# global stays "" (BH_GPU_LIBS becomes "none" per D6) and gather_gpu returns 0
# in well under a second. The /sys/bus/pci/devices walk is capped at 64
# devices so huge hosts stay cheap.
# shellcheck shell=bash

# ------- globals (empty / neutral defaults — the no-GPU shape) -------
BH_GPU_NODES=""        # "dri:2(card1+render1) nvidia:0" | "" = no GPU device nodes
BH_NVIDIA_DRIVER=""    # kernel module version "535.104.05" | "" = not loaded/absent
BH_GPU_PCI=""          # "1x NVIDIA 10de:2684 (3D, driver nvidia) + 1x ASPEED 1a03:2000 (VGA)" | ""
BH_GPU_NVIDIA=""       # "A100-SXM4-40GB, 40960 MiB, PCIe4 x16, driver 535.104" | ""
BH_GPU_MIG=""          # "MIG: 4 slices" | ""
BH_GPU_VGPU=""         # reserved — the `-q` vGPU probe is intentionally skipped (cheap module)
BH_GPU_VRAM_SYSFS=""   # "65536 MiB (amdgpu)" — largest card exposing sysfs VRAM | ""
BH_GPU_LIBS=""         # "cuda-libs-without-devices (broken GPU container)" | "none" | ""
BH_GPU_PASSTHROUGH=""  # "vfio (passed into VM)" | "native driver" | "driver ast" | ""
BH_GPU_SUMMARY=""      # one-line verdict, always non-empty after gather_gpu

# bh_gpu_t3 CMD... — run a possibly-hanging external command under `timeout 3`
# when available (same pattern as bh_t2 in 55-storage-map.sh / 85-hardening.sh).
bh_gpu_t3() {
  if command_exists timeout; then
    timeout 3 "$@" 2>/dev/null </dev/null
  else
    "$@" 2>/dev/null </dev/null
  fi
}

# bh_gpu_trim S — strip leading/trailing whitespace (sysfs label files are
# space-padded); pure parameter expansion, no external tool, no subshell cost.
bh_gpu_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

gather_gpu() {
  # ================= D1: device nodes =================
  local n_card=0 n_render=0 n_nv=0 p dri_part
  for p in /dev/dri/card*;    do [ -e "$p" ] || continue; n_card=$(( n_card + 1 ));   done
  for p in /dev/dri/renderD*; do [ -e "$p" ] || continue; n_render=$(( n_render + 1 )); done
  # literal /dev/nvidia* per spec — nvidiactl / nvidia-uvm control nodes count
  # too: this is device EXPOSURE, not a GPU count (nvidia-smi owns the count).
  for p in /dev/nvidia*;      do [ -e "$p" ] || continue; n_nv=$(( n_nv + 1 ));       done

  if [ $(( n_card + n_render )) -gt 0 ]; then
    dri_part="dri:$(( n_card + n_render ))(card${n_card}+render${n_render})"
  else
    dri_part="dri:0"
  fi
  if [ $(( n_card + n_render + n_nv )) -gt 0 ]; then
    BH_GPU_NODES="${dri_part} nvidia:${n_nv}"
  fi

  # kernel module version: first version-like token ("NVRM version: ... 535.104.05 ...")
  if [ -r /proc/driver/nvidia/version ]; then
    BH_NVIDIA_DRIVER="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+)+$/) { print $i; exit } }' /proc/driver/nvidia/version 2>/dev/null)"
  fi

  # ================= D2: PCI enumeration via sysfs (no lspci) =================
  # Walk /sys/bus/pci/devices, keep only display-class (0x03xxxx) functions.
  # Pure-bash reads of the single-token sysfs files (no subshell per file);
  # the whole walk is capped at 64 devices.
  local scanned=0 i found fmt
  local -a g_fmts=() g_counts=()
  local nvidia_pci=0 first03=0 f03_driver=""
  # headline slots for the D8 summary: NVIDIA > AMD > Intel > first-of-any
  local pci_nv_m="" pci_nv_t=""        # 10de model/class
  local pci_amd_m="" pci_amd_t=""      # 1002
  local pci_itl_m=""                   # 8086
  local pci_gen_vn="" pci_gen_m="" pci_gen_t=""   # first 0x03 device, generic
  local cls ctype vend devid vname model drvname

  for p in /sys/bus/pci/devices/*; do
    [ -d "$p" ] || continue                    # unmatched glob / hotplug race
    scanned=$(( scanned + 1 ))
    [ "$scanned" -gt 64 ] && break

    cls=""
    read -r cls < "$p/class" 2>/dev/null || true
    cls="${cls#0x}"
    case "$cls" in
      030000) ctype="VGA"  ;;
      030200) ctype="3D"   ;;
      03*)    ctype="Disp" ;;
      *)      continue     ;;
    esac

    vend=""; devid=""
    read -r vend  < "$p/vendor" 2>/dev/null || true
    read -r devid < "$p/device"  2>/dev/null || true
    vend="${vend#0x}"; devid="${devid#0x}"
    case "$vend" in ''|*[!0-9a-fA-F]*) continue ;; esac
    case "$devid" in ''|*[!0-9a-fA-F]*) devid="0000" ;; esac

    case "$vend" in
      10de) vname="NVIDIA"     ;;
      1002) vname="AMD/ATI"    ;;
      8086) vname="Intel"      ;;
      1a03) vname="ASPEED"     ;;
      15ad) vname="VMware"     ;;
      1b36) vname="QXL/RedHat" ;;
      1013) vname="Cirrus"     ;;
      *)    vname="PCI"        ;;
    esac
    [ "$vend" = "10de" ] && nvidia_pci=1

    model=""
    read -r model < "$p/label" 2>/dev/null || true
    model="$(bh_gpu_trim "$model")"
    [ -n "$model" ] || model="${vend}:${devid}"

    drvname=""
    if command_exists readlink; then
      drvname="$(readlink "$p/driver" 2>/dev/null)"
      drvname="${drvname##*/}"
    fi
    if [ -n "$drvname" ]; then
      fmt="${vname} ${model} (${ctype}, driver ${drvname})"
    else
      fmt="${vname} ${model} (${ctype})"
    fi

    # dedup identical (model, class, driver) combos, keep first-seen order
    found=-1; i=0
    while [ "$i" -lt "${#g_fmts[@]}" ]; do
      [ "${g_fmts[$i]}" = "$fmt" ] && { found=$i; break; }
      i=$(( i + 1 ))
    done
    if [ "$found" -ge 0 ]; then
      local gc=${g_counts[$found]}
      g_counts[found]=$(( gc + 1 ))
    else
      g_fmts[${#g_fmts[@]}]="$fmt"
      g_counts[${#g_counts[@]}]=1
    fi

    # D7 input: first 0x03 device in sysfs order, raw driver ("" when unbound)
    if [ "$first03" -eq 0 ]; then
      first03=1
      f03_driver="$drvname"
    fi
    # D8 headline slots
    case "$vend" in
      10de) [ -z "$pci_nv_m" ]  && { pci_nv_m="$model";  pci_nv_t="$ctype"; } ;;
      1002) [ -z "$pci_amd_m" ] && { pci_amd_m="$model"; pci_amd_t="$ctype"; } ;;
      8086) [ -z "$pci_itl_m" ] && { pci_itl_m="$model"; } ;;
    esac
    [ -z "$pci_gen_m" ] && { pci_gen_vn="$vname"; pci_gen_m="$model"; pci_gen_t="$ctype"; }
  done

  if [ "${#g_fmts[@]}" -gt 0 ]; then
    i=0
    while [ "$i" -lt "${#g_fmts[@]}" ]; do
      BH_GPU_PCI="${BH_GPU_PCI:+${BH_GPU_PCI} + }${g_counts[$i]}x ${g_fmts[$i]}"
      i=$(( i + 1 ))
    done
  fi

  # ================= D3: nvidia-smi (ALWAYS timeout-wrapped) =================
  # A driver-less container (CUDA image without devices) is the classic hang —
  # never call nvidia-smi outside bh_gpu_t3.
  local nout="" nline="" parsed="" ngpu=0 qrc=0
  local nv_name="" nv_mem="" nv_drv="" nv_gen="" nv_w=""
  if command_exists nvidia-smi; then
    nout="$(bh_gpu_t3 nvidia-smi --query-gpu=name,memory.total,driver_version,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits)"
    qrc=$?
    if [ -n "$nout" ]; then
      ngpu="$(printf '%s\n' "$nout" | awk 'NF { n++ } END { print n + 0 }')"
      nline="$(printf '%s\n' "$nout" | awk 'NF { print; exit }')"
      # "|" separator: GPU names never contain one, and unlike whitespace/tabs
      # a non-whitespace IFS keeps EMPTY csv fields aligned for `read`.
      parsed="$(printf '%s\n' "$nline" | awk -F', ' '{ printf "%s|%s|%s|%s|%s", $1, $2, $3, $4, $5 }')"
      IFS="|" read -r nv_name nv_mem nv_drv nv_gen nv_w _ <<<"$parsed" || true
      nv_name="$(bh_gpu_trim "$nv_name")"
      case "$nv_name" in ""|"N/A"|"ERR!"|"[N/A]"|"[Not Supported]"|"[Insufficient Permissions]") nv_name="" ;; esac
      nv_mem="$(bh_gpu_trim "$nv_mem")"; case "$nv_mem" in ''|*[!0-9]*) nv_mem="" ;; esac
      nv_drv="$(bh_gpu_trim "$nv_drv")"; case "$nv_drv" in ''|*[!0-9.]*) nv_drv="" ;; esac
      nv_gen="$(bh_gpu_trim "$nv_gen")"; case "$nv_gen" in ''|*[!0-9]*) nv_gen="" ;; esac
      nv_w="$(bh_gpu_trim "$nv_w")";     case "$nv_w"   in ''|*[!0-9]*) nv_w=""   ;; esac

      if [ -n "$nv_name" ]; then
        BH_GPU_NVIDIA="$nv_name"
        [ -n "$nv_mem" ] && BH_GPU_NVIDIA="${BH_GPU_NVIDIA}, ${nv_mem} MiB"
        if [ -n "$nv_gen" ] && [ "$nv_gen" -gt 0 ] 2>/dev/null && \
           [ -n "$nv_w" ]   && [ "$nv_w"   -gt 0 ] 2>/dev/null; then
          BH_GPU_NVIDIA="${BH_GPU_NVIDIA}, PCIe${nv_gen} x${nv_w}"
        fi
        # "535.104.05" -> "535.104" (%.* drops the last dot-component)
        [ -n "$nv_drv" ] && BH_GPU_NVIDIA="${BH_GPU_NVIDIA}, driver ${nv_drv%.*}"
        [ "$ngpu" -gt 1 ] 2>/dev/null && BH_GPU_NVIDIA="${BH_GPU_NVIDIA}, x ${ngpu} GPUs"
      fi
    fi
  fi

  # ================= D4: MIG / vGPU =================
  BH_GPU_VGPU=""    # the `-q` vGPU probe is intentionally skipped — keep it cheap
  # qrc=124 means the query probe was killed by `timeout 3` — the driver env is
  # hung, so a second nvidia-smi (-L) would just burn another 3s. Old drivers
  # that merely DON'T SUPPORT --query-gpu fail fast (rc!=124) and still get the
  # -L probe here.
  if command_exists nvidia-smi && [ "$qrc" -ne 124 ]; then
    local migout="" mign=0
    migout="$(bh_gpu_t3 nvidia-smi -L)"
    if [ -n "$migout" ]; then
      mign="$(printf '%s\n' "$migout" | awk '$1 == "MIG" { n++ } END { print n + 0 }')"
      [ "$mign" -gt 0 ] 2>/dev/null && BH_GPU_MIG="MIG: ${mign} slices"
    fi
  fi

  # ================= D5: AMD/Intel VRAM via sysfs =================
  # amdgpu (and the new xe driver) expose mem_info_vram_total in bytes,
  # world-readable — the only VRAM source that needs no privileged tool.
  local vcf vb=0 vbest=0 vdir vdrv=""
  for vcf in /sys/class/drm/card*/device/mem_info_vram_total; do
    [ -r "$vcf" ] || continue
    vb="$(tr -d ' \t\n\r' < "$vcf" 2>/dev/null)"
    case "$vb" in ''|*[!0-9]*) continue ;; esac
    [ "$vb" -gt 0 ] || continue
    if [ "$vb" -gt "$vbest" ]; then
      vbest="$vb"
      vdir="${vcf%/mem_info_vram_total}"           # .../cardN/device
      vdrv=""
      if command_exists readlink; then
        vdrv="$(readlink "${vdir}/driver" 2>/dev/null)"
        vdrv="${vdrv##*/}"
      fi
      [ -n "$vdrv" ] || vdrv="amdgpu"
    fi
  done
  [ "$vbest" -gt 0 ] && BH_GPU_VRAM_SYSFS="$(( vbest / 1048576 )) MiB (${vdrv})"

  # ================= D6: CUDA libs without devices =================
  # CUDA runtime libs present but zero NVIDIA devices/PCI: the broken-GPU-
  # container signature (workspace "GPU" plans on nvme-only VPSes).
  local cudalibs=0 ldp=""
  if command_exists ldconfig; then
    ldp="$(bh_gpu_t3 ldconfig -p)"
    case "$ldp" in *libcuda.so*|*libnvidia-ml.so*) cudalibs=1 ;; esac
  fi
  if [ "$n_nv" -eq 0 ] && [ "$nvidia_pci" -eq 0 ]; then
    if [ "$cudalibs" -eq 1 ]; then
      BH_GPU_LIBS="cuda-libs-without-devices (broken GPU container)"
    else
      BH_GPU_LIBS="none"
    fi
  fi

  # ================= D7: passthrough state of the first 0x03 device ========
  if [ "$first03" -eq 1 ]; then
    case "$f03_driver" in
      vfio-pci)              BH_GPU_PASSTHROUGH="vfio (passed into VM)" ;;
      nvidia|amdgpu|i915|xe) BH_GPU_PASSTHROUGH="native driver" ;;
      "")                    : ;;                                # unbound -> ""
      *)                     BH_GPU_PASSTHROUGH="driver ${f03_driver}" ;;
    esac
  fi

  # ================= D8: one-line verdict =================
  local gb=""
  if [ -n "$BH_GPU_NVIDIA" ]; then
    BH_GPU_SUMMARY="$nv_name"
    if [ -n "$nv_mem" ]; then
      gb="$(awk -v m="$nv_mem" 'BEGIN{ printf "%d", m / 1024 + 0.5 }')"   # MiB -> GB, rounded
      [ -n "$gb" ] && BH_GPU_SUMMARY="${BH_GPU_SUMMARY} ${gb}GB"
    fi
    [ -n "$nv_drv" ] && BH_GPU_SUMMARY="${BH_GPU_SUMMARY} (driver ${nv_drv%.*})"
    [ "$ngpu" -gt 1 ] 2>/dev/null && BH_GPU_SUMMARY="${BH_GPU_SUMMARY}, x ${ngpu} GPUs"
  elif [ -n "$pci_nv_m" ]; then
    BH_GPU_SUMMARY="NVIDIA ${pci_nv_m} (${pci_nv_t})"
  elif [ -n "$pci_amd_m" ]; then
    BH_GPU_SUMMARY="AMD/ATI ${pci_amd_m} (${pci_amd_t})"
  elif [ -n "$pci_itl_m" ]; then
    BH_GPU_SUMMARY="Intel iGPU (${pci_itl_m})"
  elif [ -n "$pci_gen_m" ]; then
    BH_GPU_SUMMARY="${pci_gen_vn} ${pci_gen_m} (${pci_gen_t})"
  elif [ -n "$BH_GPU_VRAM_SYSFS" ]; then
    BH_GPU_SUMMARY="GPU ${BH_GPU_VRAM_SYSFS}"
  elif [ -n "$BH_GPU_NODES" ]; then
    BH_GPU_SUMMARY="GPU device nodes (${BH_GPU_NODES}, no PCI view)"
  elif [ -n "$BH_GPU_MIG" ]; then
    BH_GPU_SUMMARY="${BH_GPU_MIG}"
  else
    BH_GPU_SUMMARY="no GPU detected (vCPU-only plan)"
  fi

  return 0
}
