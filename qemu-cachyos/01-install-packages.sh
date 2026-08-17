#!/usr/bin/env bash
# 01-install-packages.sh — install the virtualisation stack and enable libvirt.
#
# Safe and fully reversible via 99-uninstall.sh. Makes no kernel or boot
# changes; that is 02-host-tune.sh.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

need_root "$@"
require_cachyos
init_state

# qemu-full pulls every accelerator, display and device backend. It is a few
# hundred MB more than qemu-desktop but avoids the "why is there no virtio-gpu
# / no spice / no TPM" rabbit hole later.
PACKAGES=(
  qemu-full                # emulator + all backends
  libvirt                  # management daemon
  virt-manager             # GUI
  virt-viewer              # standalone guest console
  dnsmasq                  # libvirt's default NAT network
  iptables-nft             # libvirt firewalling (conflicts with plain iptables)
  edk2-ovmf                # UEFI firmware for the guest — required for Windows 11
  swtpm                    # software TPM 2.0 — also required for Windows 11
  virtiofsd                # fast host<->guest directory sharing
  dmidecode                # libvirt reads host DMI for the guest SMBIOS
  spice-vdagent            # clipboard/resolution integration
  libguestfs               # guest image tooling (virt-sysprep, virt-df)
  vde2                     # extra network backends
  bridge-utils             # bridged networking helper
  openbsd-netcat           # remote libvirt over ssh
  pciutils usbutils        # lspci/lsusb, used by our scripts
  nvme-cli                 # storage queue tuning checks
  python-libvirt           # bindings some tools expect
)

info "Refreshing package databases"
pacman -Sy --noconfirm >/dev/null

# iptables-nft conflicts with the iptables package; pacman needs to be told
# it may replace it, otherwise the transaction aborts mid-run.
info "Installing ${#PACKAGES[@]} packages"
pacman -S --needed --noconfirm "${PACKAGES[@]}"
record "packages:${PACKAGES[*]}"
ok "packages installed"

# --- virtio-win driver ISO ------------------------------------------------
# Windows cannot see a virtio disk during setup without these drivers, so the
# installer shows "no drives found" and people give up and use slow SATA.
VIRTIO_ISO=/var/lib/libvirt/images/virtio-win.iso
if [[ ! -f $VIRTIO_ISO ]]; then
  info "Fetching the virtio-win driver ISO (needed during Windows setup)"
  install -d -m 0755 /var/lib/libvirt/images
  if curl -fL --retry 3 --retry-delay 2 -o "$VIRTIO_ISO.part" \
      https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso; then
    mv "$VIRTIO_ISO.part" "$VIRTIO_ISO"
    record "owned:$VIRTIO_ISO"
    ok "virtio-win.iso downloaded"
  else
    rm -f "$VIRTIO_ISO.part"
    warn "Download failed. Grab it manually and save to $VIRTIO_ISO:"
    note "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
  fi
else
  ok "virtio-win.iso already present"
fi

# --- Services -------------------------------------------------------------
# Modern libvirt is modular: libvirtd.service is the monolithic daemon, and
# enabling its socket rather than the service lets systemd start it on demand.
info "Enabling libvirt"
systemctl enable --now libvirtd.socket
systemctl enable --now virtlogd.socket
record "service:libvirtd.socket"
record "service:virtlogd.socket"
ok "libvirt sockets enabled"

# --- Default network ------------------------------------------------------
info "Starting the default NAT network"
if virsh net-info default >/dev/null 2>&1; then
  virsh net-start default >/dev/null 2>&1 || true
  virsh net-autostart default >/dev/null 2>&1 || true
  ok "default network is up and set to autostart"
else
  warn "No 'default' libvirt network found; creating it"
  virsh net-define /usr/share/libvirt/networks/default.xml >/dev/null
  virsh net-start default >/dev/null
  virsh net-autostart default >/dev/null
  ok "default network created"
fi

# --- Group membership -----------------------------------------------------
user=$(target_user)
if [[ -n $user ]]; then
  info "Granting '$user' access to libvirt and KVM"
  for grp in libvirt kvm; do
    if getent group "$grp" >/dev/null; then
      if id -nG "$user" | grep -qw "$grp"; then
        ok "$user is already in $grp"
      else
        usermod -aG "$grp" "$user"
        record "group:$grp:$user"
        ok "added $user to $grp"
      fi
    fi
  done
  note "Group changes apply at your NEXT LOGIN — log out and back in, or the"
  note "'permission denied' errors in virt-manager will confuse you."
else
  warn "Could not determine your username (run this with sudo, not as root directly)."
  note "Add yourself manually: sudo usermod -aG libvirt,kvm \$USER"
fi

# --- Sanity check ---------------------------------------------------------
hr
info "Verifying the stack"
if virsh -c qemu:///system version >/dev/null 2>&1; then
  virsh -c qemu:///system version | sed 's/^/  /'
  ok "libvirt is answering on qemu:///system"
else
  die "libvirt is installed but not responding. Check: systemctl status libvirtd"
fi

hr
printf '%sPackages done.%s Next: sudo ./02-host-tune.sh\n' "${c_grn}${c_bld}" "$c_reset"
hr
