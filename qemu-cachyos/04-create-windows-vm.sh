#!/usr/bin/env bash
# 04-create-windows-vm.sh — generate and define the tuned Windows domain.
#
# Reads the GPU selection saved by 03-vfio-bind.sh, works out a cache-aware
# CPU pinning layout for your specific chip, fills in the domain template and
# hands the result to libvirt.
#
# Environment knobs:
#   VM_NAME=win-cad        domain name
#   VM_RAM_GB=32           guest RAM (must match what 02 reserved as hugepages)
#   VM_VCPUS=16            logical vCPUs (rounded down to an even number)
#   VM_DISK_GB=250         system disk size
#   WINDOWS_ISO=/path.iso  Windows installation media
#   KIT_DRY_RUN=1          write the XML but do not define it

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

need_root "$@"
init_state

VM_NAME=${VM_NAME:-win-cad}
VM_RAM_GB=${VM_RAM_GB:-16}
VM_DISK_GB=${VM_DISK_GB:-250}
IMG_DIR=/var/lib/libvirt/images
DISK_PATH="$IMG_DIR/${VM_NAME}.raw"
VIRTIO_ISO="$IMG_DIR/virtio-win.iso"

hr
printf '%sCreate Windows workstation VM%s\n' "$c_bld" "$c_reset"
hr

# --- Inputs ---------------------------------------------------------------
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  die "A domain named '$VM_NAME' already exists. Set VM_NAME=<other> or run: virsh undefine --nvram $VM_NAME"
fi

WINDOWS_ISO=${WINDOWS_ISO:-}
if [[ -z $WINDOWS_ISO ]]; then
  mapfile -t candidates < <(find "$IMG_DIR" /home -maxdepth 3 -iname '*.iso' 2>/dev/null \
    | grep -iv virtio | head -10 || true)
  if [[ ${#candidates[@]} -gt 0 ]]; then
    info "Windows ISOs found:"
    for i in "${!candidates[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${candidates[$i]}"; done
    read -r -p "Which ISO? [1-${#candidates[@]}, or paste a path] " pick </dev/tty
    if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#candidates[@]} )); then
      WINDOWS_ISO=${candidates[$((pick - 1))]}
    else
      WINDOWS_ISO=$pick
    fi
  else
    read -r -p "Path to your Windows ISO: " WINDOWS_ISO </dev/tty
  fi
fi
[[ -f $WINDOWS_ISO ]] || die "Windows ISO not found: $WINDOWS_ISO"
[[ -f $VIRTIO_ISO ]] || die "virtio-win.iso not found at $VIRTIO_ISO — re-run 01-install-packages.sh"

# --- OVMF firmware --------------------------------------------------------
# Package layouts have moved around between edk2-ovmf releases, so find the
# files rather than hardcoding a path that breaks on the next update.
info "Locating OVMF firmware"
OVMF_CODE=""; OVMF_VARS=""; SECURE=no
for base in /usr/share/edk2/x64 /usr/share/edk2-ovmf/x64 /usr/share/OVMF /usr/share/ovmf/x64; do
  [[ -d $base ]] || continue
  for c in OVMF_CODE.secboot.4m.fd OVMF_CODE.secboot.fd OVMF_CODE.4m.fd OVMF_CODE.fd; do
    if [[ -f $base/$c ]]; then
      OVMF_CODE="$base/$c"
      [[ $c == *secboot* ]] && SECURE=yes
      break
    fi
  done
  [[ -n $OVMF_CODE ]] || continue
  for v in OVMF_VARS.4m.fd OVMF_VARS.fd; do
    [[ -f $base/$v ]] && { OVMF_VARS="$base/$v"; break; }
  done
  break
done
[[ -n $OVMF_CODE && -n $OVMF_VARS ]] || die "OVMF firmware not found. Install edk2-ovmf."
ok "code: $OVMF_CODE"
ok "vars: $OVMF_VARS"
[[ $SECURE == yes ]] && ok "Secure Boot capable firmware (Windows 11 requirement satisfied)" \
                     || warn "Only non-Secure-Boot OVMF found; Windows 11 setup may refuse to install."

# ---------------------------------------------------------------------------
# CPU topology and pinning
#
# The goal: give the guest a set of host CPUs that (a) are real sibling pairs
# so the guest sees honest SMT, (b) sit inside as few L3 domains as possible,
# and (c) exclude the cores the host keeps for itself.
#
# On Ryzen/Threadripper, cores in different CCDs do not share L3. A thread
# migrating across that boundary loses its entire cache working set. SolidWorks
# is dominated by one hot thread, so that single migration is exactly the
# stutter people blame on "virtualisation overhead".
# ---------------------------------------------------------------------------
source "$KIT_DIR/lib/topology.sh"

info "Analysing CPU topology"
set +e
compute_pinning "${VM_VCPUS:-}"
topo_rc=$?
set -e
case $topo_rc in
  0) ;;
  1) die "Could not read CPU topology from sysfs." ;;
  2) die "Only one physical core detected; nothing to pin." ;;
  3) die "Requested ${VM_VCPUS} vCPUs, but fewer are available after reserving a core for the host." ;;
  4) die "Need at least 2 vCPUs." ;;
  *) die "Topology analysis failed (rc=$topo_rc)." ;;
esac

smt=$TOPO_SMT
n_cores=$TOPO_CORES
VM_VCPUS=$TOPO_VCPUS
housekeeping=$TOPO_HOUSEKEEPING
vcpupin=$TOPO_VCPUPIN

ok "${#TOPO_PAIRS[@]} physical cores, SMT=${smt}"
ok "host keeps CPUs: $housekeeping"
info "Free L3 domains"
for d in "${!TOPO_BY_L3[@]}"; do
  printf '  domain %-12s %2d cores:%s\n' "$d" "$(wc -w <<<"${TOPO_BY_L3[$d]}")" "${TOPO_BY_L3[$d]}"
done

if (( TOPO_DOMAINS_USED > 1 )); then
  warn "This vCPU count spans ${TOPO_DOMAINS_USED} L3 domains (CCDs)."
  warn "For SolidWorks specifically, a smaller VM that fits one domain often"
  warn "feels faster than a larger one that straddles two."
  warn "To stay inside one domain, use VM_VCPUS=$(( TOPO_BIGGEST_DOMAIN * smt ))."
else
  ok "all $VM_VCPUS vCPUs sit inside a single L3 domain"
fi


# --- Hugepage sanity ------------------------------------------------------
hp_free=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)
hp_size=$(awk '/Hugepagesize/ {print $2}' /proc/meminfo)
hp_free_gb=$(( hp_free * hp_size / 1024 / 1024 ))
if (( hp_free_gb < VM_RAM_GB )); then
  warn "Only ${hp_free_gb} GiB of hugepages are free but the VM wants ${VM_RAM_GB} GiB."
  warn "The domain will fail to start. Either re-run 02-host-tune.sh with"
  warn "VM_RAM_GB=${VM_RAM_GB} and reboot, or lower VM_RAM_GB here."
  confirm "Generate the XML anyway?" || die "Aborted."
else
  ok "${hp_free_gb} GiB of hugepages free, need ${VM_RAM_GB} GiB"
fi

# --- GPU hostdevs ---------------------------------------------------------
info "Building passthrough device list"
hostdevs=""
if [[ -f $STATE_DIR/vfio.env ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/vfio.env"
  for addr in $VFIO_ADDRESSES; do
    # 0000:03:00.0 -> domain/bus/slot/function
    dom=${addr%%:*}; rest=${addr#*:}
    bus=${rest%%:*}; rest=${rest#*:}
    slot=${rest%%.*}; func=${rest#*.}
    drv=$(lspci -D -k -s "$addr" | sed -n 's/.*Kernel driver in use: //p')
    if [[ $drv != vfio-pci ]]; then
      warn "$addr is bound to '${drv:-<none>}', not vfio-pci."
      warn "Did you reboot after 03-vfio-bind.sh? The VM will not start until you do."
    else
      ok "$addr bound to vfio-pci"
    fi
    hostdevs+="    <hostdev mode='subsystem' type='pci' managed='yes'>"$'\n'
    hostdevs+="      <source>"$'\n'
    hostdevs+="        <address domain='0x${dom}' bus='0x${bus}' slot='0x${slot}' function='0x${func}'/>"$'\n'
    hostdevs+="      </source>"$'\n'
    hostdevs+="    </hostdev>"$'\n'
  done
  hostdevs=${hostdevs%$'\n'}
else
  warn "No VFIO configuration found — run 03-vfio-bind.sh for GPU passthrough."
  warn "Generating a domain WITHOUT a passed-through GPU. SolidWorks will fall"
  warn "back to software rendering and the viewport will be slow."
  hostdevs="    <!-- no GPU passed through -->"
fi

# --- Disk -----------------------------------------------------------------
info "System disk"
if [[ -f $DISK_PATH ]]; then
  ok "reusing existing $DISK_PATH"
else
  install -d -m 0711 "$IMG_DIR"
  # falloc preallocation: the extents are reserved up front, so the guest
  # never pays for block allocation during a write, and the file does not
  # fragment across the disk as it grows.
  qemu-img create -f raw -o preallocation=falloc "$DISK_PATH" "${VM_DISK_GB}G" >/dev/null
  chown root:root "$DISK_PATH"; chmod 0600 "$DISK_PATH"
  record "owned:$DISK_PATH"
  ok "created ${VM_DISK_GB} GiB raw image at $DISK_PATH"
fi

# --- Audio backend --------------------------------------------------------
audio=spice
if pgrep -x pipewire >/dev/null 2>&1; then audio=pipewire
elif pgrep -x pulseaudio >/dev/null 2>&1; then audio=pulseaudio; fi
ok "audio backend: $audio"

# --- Stable MAC -----------------------------------------------------------
# Derived from the VM name so re-running this script reproduces the same MAC.
# Licence servers key off it; a changing MAC means re-activating every time.
mac="52:54:00$(printf '%s' "$VM_NAME" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/:\1:\2:\3/')"
ok "MAC: $mac"

# --- Render ---------------------------------------------------------------
info "Rendering domain XML"
out="$STATE_DIR/${VM_NAME}.xml"
template="$KIT_DIR/templates/windows-workstation.xml.in"
[[ -f $template ]] || die "Template missing: $template"

printf '%s\n' "$vcpupin"  >"$STATE_DIR/.vcpupin"
printf '%s\n' "$hostdevs" >"$STATE_DIR/.hostdevs"

# lib/render.py does the substitution and refuses to write a file with any
# placeholder left in it. tests/test-render.sh drives the same script.
python3 "$KIT_DIR/lib/render.py" "$template" "$out" \
  "VM_NAME=$VM_NAME" \
  "MEM_KIB=$(( VM_RAM_GB * 1024 * 1024 ))" \
  "VCPUS=$VM_VCPUS" \
  "CORES=$n_cores" \
  "THREADS=$smt" \
  "HOUSEKEEPING=$housekeeping" \
  "OVMF_CODE=$OVMF_CODE" \
  "OVMF_VARS=$OVMF_VARS" \
  "SECURE=$SECURE" \
  "DISK_PATH=$DISK_PATH" \
  "DISK_FORMAT=raw" \
  "WINDOWS_ISO=$WINDOWS_ISO" \
  "VIRTIO_ISO=$VIRTIO_ISO" \
  "MAC_ADDR=$mac" \
  "AUDIO_BACKEND=$audio" \
  "HV_VENDOR=AuthenticAMD" \
  --file "VCPUPIN=$STATE_DIR/.vcpupin" \
  --file "HOSTDEVS=$STATE_DIR/.hostdevs" \
  || die "Template rendering failed; refusing to define an incomplete domain."

rm -f "$STATE_DIR/.vcpupin" "$STATE_DIR/.hostdevs"
ok "XML written to $out"

# --- Validate and define --------------------------------------------------
info "Validating against the libvirt schema"
if virt-xml-validate "$out" domain >/dev/null 2>&1; then
  ok "schema valid"
else
  warn "virt-xml-validate reported problems:"
  virt-xml-validate "$out" domain 2>&1 | sed 's/^/    /' || true
fi

if [[ ${KIT_DRY_RUN:-0} == 1 ]]; then
  hr
  printf 'Dry run — domain not defined. Review %s then run:\n  virsh define %s\n' "$out" "$out"
  exit 0
fi

info "Defining the domain"
virsh define "$out"
record "domain:$VM_NAME"
ok "domain '$VM_NAME' defined"

hr
printf '%sVM ready.%s\n' "${c_grn}${c_bld}" "$c_reset"
cat <<EOF

  Start it:        virsh start $VM_NAME
  Console:         virt-viewer --connect qemu:///system $VM_NAME
  Edit later:      virsh edit $VM_NAME
  Generated XML:   $out

  During Windows setup, the installer will show NO DRIVES. That is expected —
  the disk is virtio and Windows has no driver for it yet:

    1. Click "Load driver"
    2. Browse to the virtio CD -> amd64\\w11  (or \\w10 for Windows 10)
    3. Load the "Red Hat VirtIO SCSI controller" driver
    4. The ${VM_DISK_GB} GiB disk appears; continue as normal

  After Windows is installed, run virtio-win-guest-tools.exe from the same CD
  to get the network, balloon, and guest-agent drivers, then read
  docs/guest-tuning.md before installing SolidWorks or MATLAB.

EOF
hr
