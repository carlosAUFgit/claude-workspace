#!/usr/bin/env bash
# 03-vfio-bind.sh — hand one GPU to vfio-pci so the guest can own it.
#
# Interactive: shows the GPUs, you pick the one the VM gets, it binds that
# card and every function in its IOMMU group. Reversible via 99-uninstall.sh.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

need_root "$@"
require_cachyos
init_state

hr
printf '%sVFIO GPU binding%s\n' "$c_bld" "$c_reset"
hr

[[ -d /sys/kernel/iommu_groups && -n $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]] \
  || die "IOMMU is not active. Run 02-host-tune.sh and reboot first."

# --- Enumerate GPUs -------------------------------------------------------
mapfile -t gpus < <(lspci -D -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
[[ ${#gpus[@]} -ge 2 ]] || die "Need at least 2 GPUs; found ${#gpus[@]}."

boot_vga=""
for d in /sys/bus/pci/devices/*/boot_vga; do
  [[ -r $d ]] || continue
  if [[ $(cat "$d") == 1 ]]; then boot_vga=$(basename "$(dirname "$d")"); fi
done

info "Graphics devices on this system"
for i in "${!gpus[@]}"; do
  addr=${gpus[$i]%% *}
  drv=$(lspci -D -k -s "$addr" | sed -n 's/.*Kernel driver in use: //p')
  tag=""
  [[ $addr == "$boot_vga" ]] && tag=" ${c_ylw}[boot/primary GPU]${c_reset}"
  printf '  %s%d)%s %s%s\n' "$c_bld" "$((i + 1))" "$c_reset" "${gpus[$i]}" "$tag"
  printf '        driver: %s\n' "${drv:-<none>}"
done

if [[ -n $boot_vga ]]; then
  hr
  note "The card marked [boot/primary GPU] is the one your host desktop uses."
  note "Passing THAT one through is single-GPU passthrough and needs extra hooks;"
  note "you said you have two, so pick the other one."
fi

echo
read -r -p "Which GPU should the VM get? [1-${#gpus[@]}] " choice </dev/tty
[[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#gpus[@]} )) \
  || die "Invalid selection."
sel_addr=${gpus[$((choice - 1))]%% *}

if [[ $sel_addr == "$boot_vga" ]]; then
  warn "You selected the primary/boot GPU."
  warn "Your host desktop will lose its display when the VM starts unless you"
  warn "set up single-GPU-passthrough hooks (not covered by this kit)."
  confirm "Continue anyway?" || die "Aborted."
fi

# --- Muxless check --------------------------------------------------------
# If the selected card has no display connectors of its own, its output is
# being routed through another GPU's framebuffer. That path disappears the
# moment a guest owns the card, so the guest renders somewhere you cannot
# see it. Better to stop here than after two reboots and a black screen.
sel_conns=0
for card in /sys/class/drm/card[0-9]*; do
  [[ -e $card/device ]] || continue
  [[ $(readlink -f "$card/device") == */"$sel_addr" ]] || continue
  for conn in "$card"-*; do
    [[ -r $conn/status ]] && sel_conns=$((sel_conns + 1))
  done
done
if [[ $sel_conns -eq 0 ]]; then
  hr
  warn "$sel_addr has no display connectors of its own."
  warn "If this is a laptop dGPU it is almost certainly muxless: the guest will"
  warn "get a working GPU that renders to nothing you can see on a monitor."
  note "Workable only with Looking Glass, or if you genuinely only need the card"
  note "for compute (CUDA/MATLAB) rather than a display."
  note "Full explanation: docs/nvidia-igpu-notes.md"
  hr
  confirm "Bind it anyway?" || die "Aborted — see docs/nvidia-igpu-notes.md."
else
  ok "$sel_addr has $sel_conns display connector(s) — not muxless"
fi

# --- Collect the whole IOMMU group ---------------------------------------
# A GPU is never alone: at minimum it has an HDMI audio function, and some
# cards add a USB-C controller. The IOMMU cannot split a group, so every
# device in it goes to the guest together.
group=$(readlink -f "/sys/bus/pci/devices/$sel_addr/iommu_group" | awk -F/ '{print $NF}')
info "Selected $sel_addr — IOMMU group $group"

group_devs=()
group_ids=()
for dev in /sys/kernel/iommu_groups/"$group"/devices/*; do
  d=$(basename "$dev")
  # PCI bridges are not passed through and have no driver to unbind.
  class=$(cat "/sys/bus/pci/devices/$d/class")
  if [[ $class == 0x0604* ]]; then
    note "skipping bridge $d"
    continue
  fi
  ids=$(lspci -D -n -s "$d" | awk '{print $3}')
  printf '  will pass through: %s\n' "$(lspci -D -nn -s "$d")"
  group_devs+=("$d")
  group_ids+=("$ids")
done

[[ ${#group_devs[@]} -gt 0 ]] || die "No passable devices found in group $group."

if [[ ${#group_devs[@]} -gt 3 ]]; then
  warn "This group has ${#group_devs[@]} devices. If any of them is something the"
  warn "host needs (NVMe, USB, NIC), the host loses it. Check the list above."
  confirm "Proceed?" || die "Aborted."
fi

# --- Identical-GPU detection ---------------------------------------------
# Binding by vendor:device ID is the simple path, but if both GPUs are the
# same model they share an ID and vfio-pci would swallow both, leaving you
# with no host display. Detect that and bind by PCI address instead.
sel_id=$(lspci -D -n -s "$sel_addr" | awk '{print $3}')
collision=0
for g in "${gpus[@]}"; do
  a=${g%% *}
  [[ $a == "$sel_addr" ]] && continue
  other_id=$(lspci -D -n -s "$a" | awk '{print $3}')
  [[ $other_id == "$sel_id" ]] && collision=1
done

hr
if [[ $collision == 1 ]]; then
  warn "Your two GPUs report the same PCI ID ($sel_id)."
  note "Binding by ID would capture both and leave the host headless, so this"
  note "kit will bind by PCI address using an early-boot initramfs hook instead."
  bind_mode=address
else
  bind_mode=id
fi

# --- Write the vfio configuration ----------------------------------------
uniq_ids=$(printf '%s\n' "${group_ids[@]}" | sort -u | paste -sd,)

if [[ $bind_mode == id ]]; then
  info "Binding by device ID: $uniq_ids"
  {
    printf '# CachyOS QEMU/VFIO kit. Delete this file to give the GPU back to the host.\n'
    printf 'options vfio-pci ids=%s\n' "$uniq_ids"
    printf '\n# Make vfio-pci load before the native drivers can claim the card.\n'
    for drv in amdgpu radeon nouveau nvidia nvidia_drm nvidia_modeset i915 xe snd_hda_intel; do
      printf 'softdep %s pre: vfio-pci\n' "$drv"
    done
  } | own_file /etc/modprobe.d/vfio.conf
else
  info "Binding by PCI address: ${group_devs[*]}"
  {
    printf '# CachyOS QEMU/VFIO kit — identical GPUs, bound by address in initramfs.\n'
    for drv in amdgpu radeon nouveau nvidia nvidia_drm nvidia_modeset i915 xe; do
      printf 'softdep %s pre: vfio-pci\n' "$drv"
    done
  } | own_file /etc/modprobe.d/vfio.conf

  # Runtime hook: claim the devices by writing driver_override before udev
  # gets a chance to autoload the native driver.
  {
    printf '#!/usr/bin/ash\n\n'
    printf 'run_hook() {\n'
    printf '    modprobe -i vfio-pci\n'
    printf '    for dev in %s; do\n' "${group_devs[*]}"
    printf '        [ -e "/sys/bus/pci/devices/$dev" ] || continue\n'
    printf '        echo "vfio-pci" > "/sys/bus/pci/devices/$dev/driver_override"\n'
    printf '        if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then\n'
    printf '            echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind"\n'
    printf '        fi\n'
    printf '        echo "$dev" > /sys/bus/pci/drivers_probe\n'
    printf '    done\n'
    printf '}\n'
  } | own_file /etc/initcpio/hooks/vfio-override 0755

  {
    printf '#!/usr/bin/env bash\n\n'
    printf 'build() {\n'
    printf '    add_module "vfio-pci"\n'
    printf '    add_module "vfio_iommu_type1"\n'
    printf '    add_runscript\n'
    printf '}\n\n'
    printf 'help() {\n'
    printf '    cat <<HELPEOF\n'
    printf 'Binds specific PCI addresses to vfio-pci before native drivers load.\n'
    printf 'HELPEOF\n'
    printf '}\n'
  } | own_file /etc/initcpio/install/vfio-override 0755
fi

record "vfio:${group_devs[*]}"
record "vfio_ids:$uniq_ids"

# Persist the selection so 04-create-windows-vm.sh can build the hostdev list.
{
  printf 'VFIO_ADDRESSES="%s"\n' "${group_devs[*]}"
  printf 'VFIO_IDS="%s"\n' "$uniq_ids"
  printf 'VFIO_PRIMARY="%s"\n' "$sel_addr"
  printf 'VFIO_BIND_MODE="%s"\n' "$bind_mode"
} | own_file "$STATE_DIR/vfio.env"

# --- mkinitcpio -----------------------------------------------------------
# The vfio modules must exist in the initramfs, and load before the GPU
# drivers do. Editing MODULES/HOOKS in place, with a backup.
info "Updating /etc/mkinitcpio.conf"
backup_once /etc/mkinitcpio.conf

add_to_array() {
  local key=$1 value=$2
  if grep -qE "^${key}=\(.*\b${value}\b.*\)" /etc/mkinitcpio.conf; then
    note "$value already in $key"
    return
  fi
  sed -i -E "s|^${key}=\((.*)\)|${key}=(\1 ${value})|" /etc/mkinitcpio.conf
  # Collapse the leading space that appears when the array started empty.
  sed -i -E "s|^${key}=\( +|${key}=(|" /etc/mkinitcpio.conf
  ok "added $value to $key"
}

add_to_array MODULES vfio_pci
add_to_array MODULES vfio
add_to_array MODULES vfio_iommu_type1

if [[ $bind_mode == address ]]; then
  if grep -qE '^HOOKS=\(.*\bvfio-override\b' /etc/mkinitcpio.conf; then
    note "vfio-override hook already present"
  else
    # Must run after udev is available but before modconf autoloads amdgpu.
    sed -i -E 's|^(HOOKS=\(.*\budev\b)|\1 vfio-override|' /etc/mkinitcpio.conf
    ok "inserted vfio-override hook after udev"
  fi
fi

grep -E '^(MODULES|HOOKS)=' /etc/mkinitcpio.conf | sed 's/^/    /'

regen_initramfs
mark_reboot

hr
printf '%sVFIO configured.%s\n' "${c_grn}${c_bld}" "$c_reset"
note "After rebooting, confirm the binding took with:"
note "  lspci -nnk -s $sel_addr"
note "It should say 'Kernel driver in use: vfio-pci'. If it still says amdgpu"
note "or nvidia, see docs/troubleshooting.md."
echo
note "Then: sudo ./04-create-windows-vm.sh"
reboot_notice
