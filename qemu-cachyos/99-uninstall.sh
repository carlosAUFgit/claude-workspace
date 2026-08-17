#!/usr/bin/env bash
# 99-uninstall.sh — revert everything this kit changed.
#
# Works off the manifest in /var/lib/qemu-cachyos-kit: restores backed-up
# files, deletes files the kit created, strips its marked config blocks and
# undoes the mkinitcpio edits. Packages are left installed unless you pass
# --packages, because removing them is rarely what you actually want.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

need_root "$@"

REMOVE_PACKAGES=0
KEEP_IMAGES=1
for arg in "$@"; do
  case $arg in
    --packages) REMOVE_PACKAGES=1 ;;
    --images)   KEEP_IMAGES=0 ;;
    --help|-h)
      cat <<EOF
Usage: sudo $0 [--packages] [--images]

  --packages  also pacman -Rns the virtualisation packages
  --images    also delete VM disk images (destructive, asks first)

With no flags: reverts all configuration, keeps packages and VM images.
EOF
      exit 0 ;;
  esac
done

[[ -f $MANIFEST ]] || die "No manifest at $MANIFEST — nothing recorded to undo."

hr
printf '%sReverting the CachyOS QEMU/VFIO kit%s\n' "$c_bld" "$c_reset"
hr

info "The manifest records these changes:"
sed 's/^/    /' "$MANIFEST"
echo
confirm "Revert all of it?" || die "Aborted."

# --- 1. Stop and undefine domains ----------------------------------------
while IFS= read -r line; do
  [[ $line == domain:* ]] || continue
  dom=${line#domain:}
  if virsh dominfo "$dom" >/dev/null 2>&1; then
    info "Undefining domain $dom"
    virsh destroy "$dom" >/dev/null 2>&1 || true
    virsh undefine --nvram "$dom" >/dev/null 2>&1 \
      || virsh undefine "$dom" >/dev/null 2>&1 || warn "could not undefine $dom"
    ok "removed domain $dom"
  fi
done <"$MANIFEST"

# --- 2. Delete files the kit created -------------------------------------
while IFS= read -r line; do
  [[ $line == owned:* ]] || continue
  path=${line#owned:}
  # Disk images and the virtio ISO are data, not configuration.
  if [[ $path == *.raw || $path == *.qcow2 || $path == *virtio-win.iso ]]; then
    if [[ $KEEP_IMAGES == 1 ]]; then
      note "keeping $path (pass --images to delete)"
      continue
    fi
    confirm "DELETE $path permanently?" || { note "kept $path"; continue; }
  fi
  if [[ -e $path ]]; then
    rm -rf -- "$path"
    ok "removed $path"
  fi
done <"$MANIFEST"

# --- 3. Restore backed-up files ------------------------------------------
while IFS= read -r line; do
  [[ $line == file:* ]] || continue
  path=${line#file:}
  backup="$BACKUP_DIR/$(printf '%s' "$path" | sed 's|/|_|g')"
  if [[ -e $backup ]]; then
    cp -a -- "$backup" "$path"
    ok "restored $path"
  else
    # No backup means the file did not exist before; strip our block instead.
    strip_block "$path" && note "stripped kit block from $path"
  fi
done <"$MANIFEST"

# --- 4. Strip config blocks that survived a partial restore --------------
for f in /etc/default/limine /etc/default/grub /etc/kernel/cmdline; do
  [[ -f $f ]] && strip_block "$f"
done

# --- 5. Undo mkinitcpio edits --------------------------------------------
if [[ -f /etc/mkinitcpio.conf ]]; then
  info "Cleaning /etc/mkinitcpio.conf"
  for m in vfio_pci vfio_iommu_type1 vfio; do
    sed -i -E "s/(^MODULES=\(.*)\b${m}\b ?(.*\))/\1\2/" /etc/mkinitcpio.conf
  done
  sed -i -E 's/(^HOOKS=\(.*)\bvfio-override\b ?(.*\))/\1\2/' /etc/mkinitcpio.conf
  # Tidy the double/trailing spaces those deletions leave behind.
  sed -i -E 's/^(MODULES|HOOKS)=\( +/\1=(/; s/ +\)$/)/; s/  +/ /g' /etc/mkinitcpio.conf
  grep -E '^(MODULES|HOOKS)=' /etc/mkinitcpio.conf | sed 's/^/    /'
fi

# --- 6. Group membership -------------------------------------------------
while IFS= read -r line; do
  [[ $line == group:* ]] || continue
  rest=${line#group:}; grp=${rest%%:*}; usr=${rest#*:}
  if id -nG "$usr" 2>/dev/null | grep -qw "$grp"; then
    gpasswd -d "$usr" "$grp" >/dev/null 2>&1 && ok "removed $usr from $grp" || true
  fi
done <"$MANIFEST"

# --- 7. Regenerate boot and initramfs ------------------------------------
regen_boot || warn "boot regeneration failed; check your bootloader config by hand"
regen_initramfs || warn "initramfs rebuild failed"

# --- 8. Packages ---------------------------------------------------------
if [[ $REMOVE_PACKAGES == 1 ]]; then
  pkgs=$(sed -n 's/^packages://p' "$MANIFEST" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  if [[ -n ${pkgs// /} ]]; then
    warn "About to remove: $pkgs"
    if confirm "Remove these packages?"; then
      systemctl disable --now libvirtd.socket virtlogd.socket 2>/dev/null || true
      # shellcheck disable=SC2086
      pacman -Rns --noconfirm $pkgs || warn "some packages could not be removed"
    fi
  fi
else
  note "Packages left installed (pass --packages to remove them)."
fi

# --- 9. Clear runtime state ----------------------------------------------
for unit in system.slice user.slice init.scope; do
  systemctl set-property --runtime -- "$unit" "AllowedCPUs=0-$(( $(nproc) - 1 ))" 2>/dev/null || true
done
rm -f /run/libvirt-hook-*.state*

mv "$MANIFEST" "$MANIFEST.reverted-$(date +%Y%m%d%H%M%S)"

hr
printf '%sRevert complete.%s Backups kept in %s\n' "${c_grn}${c_bld}" "$c_reset" "$BACKUP_DIR"
printf 'Reboot to return the GPU to the host and release the hugepages.\n'
hr
