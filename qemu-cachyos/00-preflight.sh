#!/usr/bin/env bash
# 00-preflight.sh — read-only survey of the host.
#
# Changes nothing. Run this first and read the output before anything else;
# it tells you whether GPU passthrough is actually viable on this machine and
# which devices/cores the later scripts will work with.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

problems=0
flag() { warn "$*"; problems=$((problems + 1)); }

hr
printf '%sCachyOS QEMU / VFIO preflight%s\n' "$c_bld" "$c_reset"
hr

# --- System ---------------------------------------------------------------
info "System"
# shellcheck disable=SC1091
. /etc/os-release
note "distro   : ${PRETTY_NAME:-unknown}"
if [[ ${ID:-} != cachyos && ${ID:-} != arch && ${ID_LIKE:-} != *arch* ]]; then
  flag "Not an Arch-family distro — the install and tuning scripts will not run here."
fi
for tool in lspci lscpu findmnt; do
  have "$tool" || flag "'$tool' is missing; parts of this survey will be incomplete (install pciutils / util-linux)."
done
note "kernel   : $(uname -r)"
note "bootloader: $(detect_bootloader)"
if [[ $(detect_bootloader) == unknown ]]; then
  flag "Bootloader could not be identified — kernel parameters must be added by hand."
fi

# --- CPU ------------------------------------------------------------------
info "CPU"
vendor=$(cpu_vendor)
note "model    : $(cpu_model)"
note "vendor   : $vendor"
threads=$(nproc)
cores=$(lscpu | sed -n 's/^Core(s) per socket:[[:space:]]*//p')
sockets=$(lscpu | sed -n 's/^Socket(s):[[:space:]]*//p')
tps=$(lscpu | sed -n 's/^Thread(s) per core:[[:space:]]*//p')
note "topology : ${sockets:-?} socket(s) x ${cores:-?} core(s) x ${tps:-?} thread(s) = $threads logical CPUs"

if [[ $vendor == amd ]]; then
  if grep -qm1 ' svm' /proc/cpuinfo; then
    ok "AMD-V (svm) is enabled in firmware"
  else
    flag "AMD-V (svm) not present in /proc/cpuinfo — enable SVM in your BIOS/UEFI."
  fi
elif [[ $vendor == intel ]]; then
  grep -qm1 ' vmx' /proc/cpuinfo && ok "VT-x (vmx) is enabled in firmware" \
    || flag "VT-x (vmx) not present — enable Intel Virtualization Technology in BIOS."
fi

[[ -e /dev/kvm ]] && ok "/dev/kvm exists" || flag "/dev/kvm is missing — KVM is not usable yet."

# --- CCD / cache topology -------------------------------------------------
# On Ryzen and Threadripper, cores that share an L3 slice form a CCX/CCD.
# Pinning a VM inside one L3 domain is the single biggest CPU-side win for
# latency-sensitive, largely single-threaded workloads like SolidWorks.
info "Cache (L3) domains — candidate pinning groups"
if lscpu -e=CPU,CORE,NODE,SOCKET,CACHE >/dev/null 2>&1; then
  lscpu -e=CPU,CORE,NODE,SOCKET,CACHE | awk '
    NR==1 { next }
    { l3=$5; sub(/^.*:/,"",l3); groups[l3] = groups[l3] " " $1; core[l3] = core[l3] " " $2 }
    END {
      for (g in groups) printf "  L3 #%-3s CPUs:%s\n", g, groups[g]
    }' | sort -V
else
  note "lscpu does not expose cache IDs on this kernel; falling back to sysfs"
  for d in /sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list; do
    [[ -r $d ]] || continue
    cat "$d"
  done | sort -u | sed 's/^/  L3 shared by CPUs: /'
fi

numa_nodes=$(lscpu | sed -n 's/^NUMA node(s):[[:space:]]*//p')
note "NUMA nodes: ${numa_nodes:-1}"
if [[ ${numa_nodes:-1} -gt 1 ]]; then
  lscpu | sed -n 's/^NUMA node\([0-9]\+\) CPU(s):[[:space:]]*/  node \1 CPUs: /p'
  note "Multi-node system (Threadripper in NPS>1): keep the VM's vCPUs and its"
  note "hugepages on the SAME node or you will pay for every memory access."
fi

# --- IOMMU ----------------------------------------------------------------
info "IOMMU"
if [[ -d /sys/kernel/iommu_groups ]] && [[ -n $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; then
  ngroups=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d | wc -l)
  ok "IOMMU is active — $ngroups groups"
else
  flag "IOMMU is NOT active. Passthrough is impossible until it is."
  note "Enable IOMMU/SVM in BIOS, then run 02-host-tune.sh which adds the kernel flags."
fi

# --- GPUs -----------------------------------------------------------------
info "Graphics devices"
mapfile -t gpu_lines < <(lspci -D -nn 2>/dev/null \
  | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
if [[ ${#gpu_lines[@]} -eq 0 ]]; then
  flag "No GPU found via lspci (is pciutils installed?)"
else
  for line in "${gpu_lines[@]}"; do
    addr=${line%% *}
    drv=$(lspci -D -k -s "$addr" | sed -n 's/.*Kernel driver in use: //p')
    printf '  %s\n' "$line"
    printf '      driver in use: %s\n' "${drv:-<none>}"
  done
fi
if [[ ${#gpu_lines[@]} -lt 2 ]]; then
  flag "Fewer than 2 GPUs detected. Two-GPU passthrough needs a GPU the host can release."
else
  ok "${#gpu_lines[@]} graphics devices present — two-GPU passthrough is viable"
fi

# --- Display wiring: the muxless trap ------------------------------------
# A discrete GPU with no display connectors of its own is "muxless": its
# output is copied through the integrated GPU's framebuffer by the host
# driver. Once the card belongs to a guest that path no longer exists, so it
# renders to nothing you can see. This is the normal wiring for laptop dGPUs
# and it is the most common reason a carefully built passthrough setup ends
# in a black screen.
info "Display connectors per GPU"
chassis=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 0)
is_laptop=0
case $chassis in 8|9|10|11|14|30|31|32) is_laptop=1 ;; esac
[[ $is_laptop == 1 ]] && note "chassis type $chassis — this looks like a laptop/portable"

for line in "${gpu_lines[@]}"; do
  addr=${line%% *}
  desc=$(sed 's/^[^ ]* //' <<<"$line" | cut -c1-60)
  total=0; connected=0
  for card in /sys/class/drm/card[0-9]*; do
    [[ -e $card/device ]] || continue
    [[ $(readlink -f "$card/device") == */"$addr" ]] || continue
    for conn in "$card"-*; do
      [[ -r $conn/status ]] || continue
      total=$((total + 1))
      [[ $(cat "$conn/status") == connected ]] && connected=$((connected + 1))
    done
  done
  printf '  %s  %s\n' "$addr" "$desc"
  printf '      display outputs: %d (%d with a monitor attached)\n' "$total" "$connected"
  if [[ $total -eq 0 ]]; then
    warn "  $addr exposes no display connectors of its own."
    note "  Either it is muxless (typical laptop wiring), or it is bound to a"
    note "  driver that does not register them. If muxless, passing it through"
    note "  gives a working GPU with nowhere to send the picture — you would"
    note "  need Looking Glass. See docs/nvidia-igpu-notes.md."
  fi
done

if [[ $is_laptop == 1 ]]; then
  flag "Laptop chassis: confirm the discrete GPU has its own display outputs before proceeding."
fi

# --- Which GPU owns the console ------------------------------------------
for d in /sys/bus/pci/devices/*/boot_vga; do
  [[ -r $d ]] || continue
  [[ $(cat "$d") == 1 ]] || continue
  bv=$(basename "$(dirname "$d")")
  note "boot/primary GPU (host console): $bv"
  if [[ $(lspci -D -nn -s "$bv" 2>/dev/null) == *NVIDIA* ]]; then
    warn "The NVIDIA card is currently the primary display adapter."
    note "Set the integrated GPU as primary in UEFI setup before passing the"
    note "NVIDIA card through — look for 'Primary Video Adapter', 'Initiate"
    note "Graphic Adapter' or 'IGFX Multi-Monitor'. Otherwise the host console"
    note "goes away with the card."
  fi
done

# --- IOMMU grouping of the GPUs ------------------------------------------
# A GPU can only be passed through together with everything else in its
# IOMMU group. A clean group (GPU + its own audio function) is what you want.
if [[ -d /sys/kernel/iommu_groups ]]; then
  info "IOMMU group membership for each GPU"
  for line in "${gpu_lines[@]}"; do
    addr=${line%% *}
    grp=$(readlink -f "/sys/bus/pci/devices/$addr/iommu_group" 2>/dev/null | awk -F/ '{print $NF}')
    [[ -n $grp ]] || { note "$addr: no IOMMU group"; continue; }
    printf '  %s is in IOMMU group %s, which contains:\n' "$addr" "$grp"
    members=0
    for dev in /sys/kernel/iommu_groups/"$grp"/devices/*; do
      d=$(basename "$dev")
      printf '      %s\n' "$(lspci -D -nn -s "$d")"
      members=$((members + 1))
    done
    if [[ $members -gt 3 ]]; then
      warn "  group $grp has $members devices — everything listed must be passed through together."
      note "  If unrelated devices (NVMe, USB, network) share it, you need either a"
      note "  different PCIe slot or the ACS override patch (see docs/troubleshooting.md)."
    fi
  done
fi

# --- Memory ---------------------------------------------------------------
info "Memory"
mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
note "installed: ${mem_gb} GiB"
if [[ $mem_gb -lt 16 ]]; then
  flag "Under 16 GiB total. SolidWorks in a VM wants 16 GiB in the guest alone."
elif [[ $mem_gb -lt 32 ]]; then
  warn "With ${mem_gb} GiB total, budget ~half to the VM and skip 1 GiB hugepages."
else
  ok "Plenty of RAM for a 16-32 GiB guest plus host headroom"
fi
hp_total=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
note "hugepages currently reserved: ${hp_total:-0}"

# --- Storage --------------------------------------------------------------
info "Storage for VM images"
img_dir=/var/lib/libvirt/images
fstype=$(findmnt -no FSTYPE --target "$(dirname "$img_dir")" 2>/dev/null || echo unknown)
note "$img_dir will live on: $fstype"
if [[ $fstype == btrfs ]]; then
  warn "Btrfs: copy-on-write murders random-write performance for VM images."
  note "02-host-tune.sh will create the image directory with CoW disabled (chattr +C)."
fi

# --- Existing virt stack --------------------------------------------------
info "Existing virtualisation packages"
for p in qemu-full qemu-desktop libvirt virt-manager edk2-ovmf swtpm virtiofsd; do
  if pacman -Qq "$p" >/dev/null 2>&1; then ok "$p installed"; else note "$p not installed"; fi
done

hr
if [[ $problems -eq 0 ]]; then
  printf '%sPreflight clean — proceed with 01-install-packages.sh%s\n' "${c_grn}${c_bld}" "$c_reset"
else
  printf '%s%d issue(s) flagged above.%s Read them before continuing; some (BIOS settings)\n' \
    "${c_ylw}${c_bld}" "$problems" "$c_reset"
  printf 'must be fixed outside Linux, others are resolved by 02-host-tune.sh.\n'
fi
hr
