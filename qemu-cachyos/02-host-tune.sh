#!/usr/bin/env bash
# 02-host-tune.sh — kernel parameters, hugepages, KVM module tuning, storage.
#
# Everything here is written to dedicated drop-in files or clearly-marked
# config blocks, and 99-uninstall.sh reverts all of it.
#
# Environment knobs:
#   VM_RAM_GB=32          how much guest RAM to reserve as 1 GiB hugepages
#   KIT_ENABLE_AVIC=1     trade nested virtualisation for lower interrupt latency
#   KIT_MITIGATIONS_OFF=1 disable CPU speculation mitigations (read the warning)
#   KIT_ASSUME_YES=1      no prompts

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

need_root "$@"
require_cachyos
init_state

vendor=$(cpu_vendor)
params=()

hr
printf '%sHost tuning%s\n' "$c_bld" "$c_reset"
hr

# ---------------------------------------------------------------------------
# 1. IOMMU
#
# Without this the kernel never builds IOMMU groups and vfio-pci has nothing
# to bind to. iommu=pt ("passthrough") skips DMA translation for host devices,
# which removes the IOMMU from the host's own I/O path — you get passthrough
# capability without paying for it on host devices.
# ---------------------------------------------------------------------------
info "IOMMU"
if [[ -d /sys/kernel/iommu_groups ]] && [[ -n $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; then
  ok "IOMMU already active ($(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d | wc -l) groups)"
  cmdline_has iommu=pt || params+=("iommu=pt")
else
  case $vendor in
    amd)   params+=("iommu=pt" "amd_iommu=on") ;;
    intel) params+=("intel_iommu=on" "iommu=pt") ;;
    *)     warn "Unknown CPU vendor; add IOMMU parameters manually." ;;
  esac
  note "IOMMU parameters queued. If groups still do not appear after reboot,"
  note "the setting is off in firmware — look for 'IOMMU' or 'SVM' in your UEFI."
fi

# ---------------------------------------------------------------------------
# 2. Hugepages
#
# The guest's entire RAM is backed by 1 GiB pages instead of 4 KiB ones. That
# shrinks the page tables the CPU walks on every TLB miss by ~262144x for that
# region, and with VFIO the memory is pinned anyway so there is no downside in
# flexibility that you were not already paying.
#
# For MATLAB — large matrices, poor locality, constant TLB pressure — this is
# the second-biggest win after the passthrough GPU itself.
# ---------------------------------------------------------------------------
info "Hugepages"
mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
default_vm_ram=$(( mem_gb / 2 ))
(( default_vm_ram > 32 )) && default_vm_ram=32
(( default_vm_ram < 8 )) && default_vm_ram=8
VM_RAM_GB=${VM_RAM_GB:-$default_vm_ram}

if (( VM_RAM_GB >= mem_gb - 6 )); then
  die "VM_RAM_GB=$VM_RAM_GB leaves under 6 GiB for the host on a ${mem_gb} GiB machine."
fi

note "host RAM        : ${mem_gb} GiB"
note "reserving       : ${VM_RAM_GB} GiB as 1 GiB hugepages"
note "left for host   : $(( mem_gb - VM_RAM_GB )) GiB"
warn "Reserved hugepages are removed from general-purpose RAM at boot,"
warn "whether or not the VM is running. Re-run with VM_RAM_GB=<n> to change."
if confirm "Reserve ${VM_RAM_GB} GiB of 1 GiB hugepages?"; then
  params+=("default_hugepagesz=1G" "hugepagesz=1G" "hugepages=${VM_RAM_GB}")
  record "hugepages:${VM_RAM_GB}"
  ok "queued ${VM_RAM_GB} x 1 GiB hugepages"
else
  note "Skipped. The VM will use transparent hugepages instead — still fine,"
  note "just less deterministic. Remove <hugepages/> from the domain XML."
fi

# ---------------------------------------------------------------------------
# 3. KVM module options
# ---------------------------------------------------------------------------
info "KVM module options"
kvm_opts=()
# Windows and some ISV licensing/telemetry code probes model-specific registers
# that KVM does not implement. Ignoring them beats a guest crash, and silencing
# the report keeps dmesg readable.
kvm_opts+=("options kvm ignore_msrs=1 report_ignored_msrs=0")

if [[ $vendor == amd ]]; then
  if [[ ${KIT_ENABLE_AVIC:-0} == 1 ]]; then
    # AVIC handles guest interrupts in hardware instead of trapping to the
    # hypervisor. Lower latency, but KVM refuses to enable it alongside
    # nested SVM — and Windows 11's VBS/HVCI needs nesting. Opt-in only.
    kvm_opts+=("options kvm_amd npt=1 avic=1 nested=0")
    warn "AVIC enabled: nested virtualisation is now OFF."
    warn "You must disable Memory Integrity / VBS inside Windows or it will"
    warn "boot slowly or fail. See docs/guest-tuning.md."
  else
    kvm_opts+=("options kvm_amd npt=1 nested=1")
    note "Nested virtualisation ON (Windows 11 VBS-compatible)."
    note "For lower interrupt latency, re-run with KIT_ENABLE_AVIC=1."
  fi
elif [[ $vendor == intel ]]; then
  kvm_opts+=("options kvm_intel nested=1 ept=1 enable_apicv=1")
fi

printf '%s\n' \
  "# CachyOS QEMU/VFIO kit — KVM tuning. Delete this file to revert." \
  "${kvm_opts[@]}" | own_file /etc/modprobe.d/99-kvm-tuning.conf

# ---------------------------------------------------------------------------
# 4. Memory lock limits
#
# VFIO pins the guest's whole address space. Without a raised memlock ceiling
# the VM refuses to start with a distinctly unhelpful "Cannot allocate memory".
# ---------------------------------------------------------------------------
info "Memory lock limits"
printf '%s\n' \
  "# CachyOS QEMU/VFIO kit — VFIO pins all guest memory, so raise memlock." \
  "@kvm     soft memlock unlimited" \
  "@kvm     hard memlock unlimited" \
  "@libvirt soft memlock unlimited" \
  "@libvirt hard memlock unlimited" | own_file /etc/security/limits.d/99-kvm-memlock.conf

# ---------------------------------------------------------------------------
# 5. Storage for VM images
# ---------------------------------------------------------------------------
info "VM image storage"
img_dir=/var/lib/libvirt/images
install -d -m 0711 "$img_dir"
fstype=$(findmnt -no FSTYPE --target "$img_dir" 2>/dev/null || echo unknown)
note "filesystem: $fstype"
case $fstype in
  btrfs)
    # Copy-on-write turns every guest random write into read-modify-write plus
    # metadata churn, and fragments the image into tens of thousands of extents.
    # +C only affects newly created files, so it must be set before the image.
    if chattr +C "$img_dir" 2>/dev/null; then
      ok "disabled CoW on $img_dir (applies to newly created images)"
      record "chattr:$img_dir"
    else
      warn "Could not set +C. Create the image on a nodatacow subvolume instead."
    fi
    note "Also exclude this directory from snapshots, or every snapshot pins"
    note "the whole disk image and CoW comes back through the side door."
    ;;
  zfs)
    note "On ZFS use a zvol with volblocksize=64k, or a dataset with"
    note "recordsize=64k, primarycache=metadata, logbias=throughput."
    ;;
  ext4|xfs)
    ok "$fstype needs no special treatment — use a preallocated raw image"
    ;;
esac

# ---------------------------------------------------------------------------
# 6. Optional: speculation mitigations
# ---------------------------------------------------------------------------
if [[ ${KIT_MITIGATIONS_OFF:-0} == 1 ]]; then
  hr
  warn "KIT_MITIGATIONS_OFF=1 requested."
  warn "This disables Spectre/Meltdown/MDS/Retbleed mitigations HOST-WIDE."
  warn "Everything on this machine — browser, the VM, other guests — loses"
  warn "protection against cross-domain speculative side channels."
  warn "Realistic gain for SolidWorks/MATLAB: low single-digit percent."
  if confirm "Really disable CPU security mitigations?"; then
    params+=("mitigations=off")
    ok "queued mitigations=off"
  else
    note "Skipped — good call."
  fi
fi

# ---------------------------------------------------------------------------
# 7. Apply
# ---------------------------------------------------------------------------
hr
if [[ ${#params[@]} -gt 0 ]]; then
  info "Kernel parameters to add"
  printf '    %s\n' "${params[*]}"
  if confirm "Write these to your bootloader config?"; then
    cmdline_add "${params[*]}"
    regen_boot
    mark_reboot
  else
    note "Skipped. Add them yourself; nothing else here depends on them at build time."
  fi
else
  ok "No kernel parameter changes needed"
fi

info "Reloading module configuration"
regen_initramfs
mark_reboot

hr
printf '%sHost tuning done.%s Next: sudo ./03-vfio-bind.sh\n' "${c_grn}${c_bld}" "$c_reset"
note "03 needs the IOMMU groups that only exist after a reboot, so if IOMMU"
note "was not already active, reboot first."
reboot_notice
