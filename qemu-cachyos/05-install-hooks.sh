#!/usr/bin/env bash
# 05-install-hooks.sh — install the libvirt lifecycle hook.
#
# The hook isolates the guest's pinned cores from the host, steers interrupts
# away from them and switches the governor to performance — but only while a
# VM is running. Optional: everything works without it, just with more jitter.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

need_root "$@"
init_state

hr
printf '%sLibvirt lifecycle hooks%s\n' "$c_bld" "$c_reset"
hr

src="$KIT_DIR/hooks/qemu"
dst=/etc/libvirt/hooks/qemu
[[ -f $src ]] || die "Hook source missing: $src"

if [[ -e $dst ]] && ! grep -q 'installed by 05-install-hooks.sh' "$dst" 2>/dev/null; then
  warn "$dst already exists and was not installed by this kit."
  confirm "Back it up and replace it?" || die "Aborted."
  backup_once "$dst"
fi

install -d -m 0755 /etc/libvirt/hooks
install -m 0755 "$src" "$dst"
record "owned:$dst"
ok "installed $dst"

# cgroups v2 is required for the AllowedCPUs mechanism the hook relies on.
if [[ ! -f /sys/fs/cgroup/cgroup.controls && ! -d /sys/fs/cgroup/system.slice ]]; then
  warn "cgroups v2 unified hierarchy not detected."
  warn "Host core isolation will be skipped; governor switching still works."
else
  ok "cgroups v2 available — host core isolation will work"
fi

if ! command -v logger >/dev/null; then
  warn "util-linux 'logger' missing; hook logging will be quieter than intended."
fi

info "Reloading libvirt so it picks up the hook"
systemctl reload libvirtd 2>/dev/null || systemctl restart libvirtd.service 2>/dev/null || true
ok "libvirt reloaded"

hr
cat <<EOF
The hook fires automatically on VM start and stop. To watch it work:

  journalctl -t 'libvirt-hook[<vm-name>]' -f

While a VM runs you can confirm the isolation took effect:

  systemctl show system.slice -p AllowedCPUs
  cat /proc/irq/*/smp_affinity_list | sort -u

Both should show only the housekeeping cores. After shutdown they return to
the full CPU range.
EOF
hr
