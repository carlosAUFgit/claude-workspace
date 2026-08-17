#!/usr/bin/env bash
# Shared helpers for the CachyOS QEMU/VFIO kit.
# Sourced by the numbered scripts; not meant to be executed directly.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR=/var/lib/qemu-cachyos-kit
BACKUP_DIR="$STATE_DIR/backups"
MANIFEST="$STATE_DIR/manifest"
MARK_BEGIN='# >>> qemu-cachyos-kit >>>'
MARK_END='# <<< qemu-cachyos-kit <<<'

if [[ -t 1 ]]; then
  c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'
  c_ylw=$'\e[33m'; c_blu=$'\e[36m'; c_bld=$'\e[1m'; c_dim=$'\e[2m'
else
  c_reset=''; c_red=''; c_grn=''; c_ylw=''; c_blu=''; c_bld=''; c_dim=''
fi

info() { printf '%s==>%s %s\n' "${c_blu}${c_bld}" "$c_reset" "$*"; }
ok()   { printf '%s  ok%s %s\n' "${c_grn}${c_bld}" "$c_reset" "$*"; }
warn() { printf '%swarn%s %s\n' "${c_ylw}${c_bld}" "$c_reset" "$*" >&2; }
note() { printf '%s     %s%s\n' "$c_dim" "$*" "$c_reset"; }
die()  { printf '%sFAIL%s %s\n' "${c_red}${c_bld}" "$c_reset" "$*" >&2; exit 1; }

hr() { printf '%s%s%s\n' "$c_dim" "------------------------------------------------------------" "$c_reset"; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This script must run as root (use: sudo $0 $*)"
}

# The user who invoked sudo, so we can add them to groups / chown things.
target_user() {
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    printf '%s' "$SUDO_USER"
  elif [[ -n ${KIT_USER:-} ]]; then
    printf '%s' "$KIT_USER"
  else
    printf ''
  fi
}

confirm() {
  local prompt=${1:?} reply
  if [[ ${KIT_ASSUME_YES:-0} == 1 ]]; then
    note "auto-confirming: $prompt"
    return 0
  fi
  read -r -p "$prompt [y/N] " reply </dev/tty || return 1
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

init_state() {
  install -d -m 0755 "$STATE_DIR" "$BACKUP_DIR"
  [[ -f $MANIFEST ]] || : >"$MANIFEST"
}

# Copy a file into the backup store once, the first time we touch it.
# Repeated calls are no-ops so re-running a script never clobbers the pristine copy.
backup_once() {
  local src=$1 dest
  init_state
  dest="$BACKUP_DIR/$(printf '%s' "$src" | sed 's|/|_|g')"
  if [[ -e $src && ! -e $dest ]]; then
    cp -a -- "$src" "$dest"
    note "backed up $src"
  fi
  grep -qxF "file:$src" "$MANIFEST" 2>/dev/null || printf 'file:%s\n' "$src" >>"$MANIFEST"
}

record() { init_state; grep -qxF "$1" "$MANIFEST" 2>/dev/null || printf '%s\n' "$1" >>"$MANIFEST"; }

# Write a file we fully own, recording it so the uninstaller can delete it.
own_file() {
  local path=$1 mode=${2:-0644}
  install -d -m 0755 "$(dirname "$path")"
  cat >"$path"
  chmod "$mode" "$path"
  record "owned:$path"
  ok "wrote $path"
}

# Remove our marked block from a config file, leaving the rest untouched.
strip_block() {
  local path=$1
  [[ -f $path ]] || return 0
  grep -qF "$MARK_BEGIN" "$path" || return 0
  sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$path"
}

have() { command -v "$1" >/dev/null 2>&1; }

require_cachyos() {
  [[ -r /etc/os-release ]] || die "No /etc/os-release; this is not an Arch-family system."
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} != cachyos && ${ID_LIKE:-} != *arch* && ${ID:-} != arch ]]; then
    warn "Detected '${PRETTY_NAME:-unknown}', which is not CachyOS/Arch."
    confirm "Continue anyway?" || die "Aborted."
  fi
  have pacman || die "pacman not found — this kit is Arch/CachyOS only."
}

cpu_vendor() {
  if grep -qm1 'AuthenticAMD' /proc/cpuinfo; then printf 'amd'
  elif grep -qm1 'GenuineIntel' /proc/cpuinfo; then printf 'intel'
  else printf 'unknown'; fi
}

cpu_model() { sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1; }

# ---------------------------------------------------------------------------
# Bootloader abstraction.
#
# CachyOS defaults to Limine, but installs may use GRUB, systemd-boot or
# rEFInd. Guides that only edit /etc/default/grub fail silently on a Limine
# box: the file exists (grub may be installed as a leftover) but nothing that
# boots the machine ever reads it. So detect what is actually in charge.
# ---------------------------------------------------------------------------
detect_bootloader() {
  if [[ -f /etc/default/limine ]] && have limine-update; then printf 'limine'; return; fi
  if [[ -f /etc/kernel/cmdline ]]; then printf 'uki'; return; fi
  if [[ -f /etc/default/grub ]] && have grub-mkconfig && [[ -d /boot/grub ]]; then printf 'grub'; return; fi
  if have bootctl && bootctl is-installed >/dev/null 2>&1; then printf 'systemd-boot'; return; fi
  if [[ -f /boot/refind_linux.conf ]]; then printf 'refind'; return; fi
  printf 'unknown'
}

current_cmdline() { cat /proc/cmdline; }

cmdline_has() { grep -qw -- "$1" /proc/cmdline; }

# Append kernel parameters through a clearly-marked block we can remove later.
cmdline_add() {
  local params=$1 bl
  bl=$(detect_bootloader)
  case $bl in
    limine)
      backup_once /etc/default/limine
      strip_block /etc/default/limine
      {
        printf '%s\n' "$MARK_BEGIN"
        printf '# Added by the CachyOS QEMU/VFIO kit. Delete this block to revert.\n'
        printf 'KERNEL_CMDLINE[default]+=" %s"\n' "$params"
        printf '%s\n' "$MARK_END"
      } >>/etc/default/limine
      ok "appended to /etc/default/limine"
      ;;
    grub)
      backup_once /etc/default/grub
      strip_block /etc/default/grub
      {
        printf '%s\n' "$MARK_BEGIN"
        printf '# Added by the CachyOS QEMU/VFIO kit. Delete this block to revert.\n'
        printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT %s"\n' "$params"
        printf '%s\n' "$MARK_END"
      } >>/etc/default/grub
      ok "appended to /etc/default/grub"
      ;;
    uki)
      backup_once /etc/kernel/cmdline
      local existing; existing=$(tr -d '\n' </etc/kernel/cmdline)
      printf '%s %s\n' "$existing" "$params" >/etc/kernel/cmdline
      ok "appended to /etc/kernel/cmdline"
      ;;
    systemd-boot)
      local entry found=0
      for entry in /boot/loader/entries/*.conf /efi/loader/entries/*.conf; do
        [[ -f $entry ]] || continue
        grep -q '^options ' "$entry" || continue
        backup_once "$entry"
        sed -i "s|^options .*|& $params|" "$entry"
        found=1
      done
      [[ $found == 1 ]] && ok "appended to systemd-boot loader entries" \
                        || die "systemd-boot detected but no loader entries with an 'options' line were found."
      ;;
    refind)
      backup_once /boot/refind_linux.conf
      sed -i "s|\"$| $params\"|" /boot/refind_linux.conf
      ok "appended to /boot/refind_linux.conf"
      ;;
    *)
      warn "Could not identify your bootloader. Add these parameters manually:"
      printf '\n    %s\n\n' "$params"
      return 1
      ;;
  esac
  record "cmdline:$params"
}

regen_boot() {
  local bl; bl=$(detect_bootloader)
  info "Regenerating boot configuration ($bl)"
  case $bl in
    limine)       limine-update ;;
    grub)         grub-mkconfig -o /boot/grub/grub.cfg ;;
    uki)          mkinitcpio -P ;;
    systemd-boot) : ;;  # entries edited in place, nothing to regenerate
    refind)       : ;;
    *)            warn "Skipping boot regeneration for unknown bootloader." ; return 0 ;;
  esac
  ok "boot configuration updated"
}

regen_initramfs() {
  info "Rebuilding initramfs for all kernels (this takes a minute)"
  if have limine-mkinitcpio; then
    mkinitcpio -P
  elif have mkinitcpio; then
    mkinitcpio -P
  elif have dracut-rebuild; then
    dracut-rebuild
  else
    warn "Neither mkinitcpio nor dracut found; rebuild your initramfs manually."
    return 1
  fi
  ok "initramfs rebuilt"
}

REBOOT_NEEDED=0
mark_reboot() { REBOOT_NEEDED=1; }
reboot_notice() {
  [[ $REBOOT_NEEDED == 1 ]] || return 0
  hr
  printf '%sA reboot is required for these changes to take effect.%s\n' "${c_ylw}${c_bld}" "$c_reset"
  hr
}
