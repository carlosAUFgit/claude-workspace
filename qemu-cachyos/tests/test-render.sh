#!/usr/bin/env bash
# Tests for the domain template + lib/render.py.
#
# Confirms the rendered domain is well-formed XML, contains no leftover
# placeholders, and that the performance-critical elements actually survive
# into the output — a template typo that silently drops <hugepages/> or the
# hyperv block costs real performance and is invisible until you benchmark.
#
# Run: ./tests/test-render.sh

set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

pass=0; fail=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  \e[32mPASS\e[0m %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  \e[31mFAIL\e[0m %s\n        expected: %s\n        actual:   %s\n' \
      "$label" "$expected" "$actual"; fail=$((fail + 1))
  fi
}
contains() {
  local label=$1 needle=$2
  if grep -qF -- "$needle" "$TMP/out.xml"; then
    printf '  \e[32mPASS\e[0m %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  \e[31mFAIL\e[0m %s (missing: %s)\n' "$label" "$needle"; fail=$((fail + 1))
  fi
}

printf '\n\e[1mtemplates/windows-workstation.xml.in\e[0m\n\n'

# Realistic inputs: a 7950X-class guest with a passed-through GPU.
cat >"$TMP/vcpupin" <<'EOF'
    <vcpupin vcpu='0' cpuset='8'/>
    <vcpupin vcpu='1' cpuset='24'/>
    <vcpupin vcpu='2' cpuset='9'/>
    <vcpupin vcpu='3' cpuset='25'/>
EOF
cat >"$TMP/hostdevs" <<'EOF'
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
      </source>
    </hostdev>
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x03' slot='0x00' function='0x1'/>
      </source>
    </hostdev>
EOF

printf 'Rendering\n'
python3 lib/render.py templates/windows-workstation.xml.in "$TMP/out.xml" \
  "VM_NAME=win-cad" "MEM_KIB=33554432" "VCPUS=4" "CORES=2" "THREADS=2" \
  "HOUSEKEEPING=0,16" \
  "OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd" \
  "OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd" "SECURE=yes" \
  "DISK_PATH=/var/lib/libvirt/images/win-cad.raw" "DISK_FORMAT=raw" \
  "WINDOWS_ISO=/var/lib/libvirt/images/Win11.iso" \
  "VIRTIO_ISO=/var/lib/libvirt/images/virtio-win.iso" \
  "MAC_ADDR=52:54:00:ab:cd:ef" "AUDIO_BACKEND=pipewire" "HV_VENDOR=AuthenticAMD" \
  --file "VCPUPIN=$TMP/vcpupin" --file "HOSTDEVS=$TMP/hostdevs"
check "render exits cleanly" "0" "$?"

printf '\nStructure\n'
xmllint --noout "$TMP/out.xml" 2>"$TMP/xmlerr"
check "well-formed XML" "0" "$?"
[[ -s $TMP/xmlerr ]] && sed 's/^/        /' "$TMP/xmlerr"
check "no leftover @TOKENS@" "0" "$(grep -co '@[A-Z_]*@' "$TMP/out.xml")"

printf '\nPerformance-critical elements survived\n'
contains "1 GiB hugepage backing"      "<page size='1048576' unit='KiB'/>"
contains "memory locked for VFIO"      "<locked/>"
contains "host-passthrough CPU"        "mode='host-passthrough'"
contains "AMD topoext (SMT visible)"   "name='topoext'"
contains "cache passthrough"           "<cache mode='passthrough'/>"
contains "hyperv stimer direct"        "<direct state='on'/>"
contains "hyperv tlbflush"             "<tlbflush state='on'/>"
contains "hyperv ipi"                  "<ipi state='on'/>"
contains "HPET disabled"               "name='hpet' present='no'"
contains "io_uring disk backend"       "io='io_uring'"
contains "disk cache=none (O_DIRECT)"  "cache='none'"
contains "iothread bound to disk"      "iothread='1'"
contains "virtio disk bus"             "bus='virtio'"
contains "vhost multiqueue net"        "name='vhost' queues='4'"
contains "balloon disabled"            "<memballoon model='none'/>"
contains "TPM 2.0 for Windows 11"      "version='2.0'"
contains "q35 machine type"            "machine='q35'"
contains "Secure Boot enabled"         "secure='yes'"

printf '\nSubstituted values\n'
contains "guest topology"              "sockets='1' dies='1' cores='2' threads='2'"
contains "memory"                      "<memory unit='KiB'>33554432</memory>"
contains "emulator on housekeeping"    "<emulatorpin cpuset='0,16'/>"
contains "vcpu0 pinned"                "<vcpupin vcpu='0' cpuset='8'/>"
contains "both GPU functions"          "function='0x1'"
contains "stable MAC"                  "52:54:00:ab:cd:ef"
contains "audio backend"               "type='pipewire'"
check "two hostdevs present" "2" "$(grep -c "<hostdev " "$TMP/out.xml")"
check "four vcpupin entries" "4" "$(grep -c "<vcpupin " "$TMP/out.xml")"

printf '\nFailure handling\n'
python3 lib/render.py templates/windows-workstation.xml.in "$TMP/bad.xml" \
  "VM_NAME=x" >/dev/null 2>&1
check "rejects incomplete substitution" "1" "$?"
check "writes nothing on failure"       "no" "$([[ -f $TMP/bad.xml ]] && echo yes || echo no)"

printf '\n'
if (( fail == 0 )); then
  printf '\e[32m\e[1mAll %d assertions passed.\e[0m\n\n' "$pass"; exit 0
else
  printf '\e[31m\e[1m%d passed, %d FAILED.\e[0m\n\n' "$pass" "$fail"; exit 1
fi
