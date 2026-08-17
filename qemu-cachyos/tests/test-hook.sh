#!/usr/bin/env bash
# Tests for hooks/qemu — the libvirt lifecycle hook.
#
# The hook decides which CPUs the host is evacuated onto. Getting that
# backwards would confine the host to the guest's cores, which is worse than
# doing nothing at all, so the split is verified against real domain XML.
#
# systemctl, logger and nproc are stubbed so this runs anywhere.
#
# Run: ./tests/test-hook.sh

set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
HOOK=$(readlink -f hooks/qemu)

pass=0; fail=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# --- stubs ----------------------------------------------------------------
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
# is-active must report irqbalance as absent so the hook does not try to
# stop and restart a service that is not there.
[[ $* == *is-active* ]] && exit 1
exit 0
EOF
cat >"$TMP/bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/bin/nproc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_NPROC:-32}"
EOF
chmod +x "$TMP/bin"/*
export PATH="$TMP/bin:$PATH"
export STUB_LOG="$TMP/calls.log"

check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  \e[32mPASS\e[0m %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  \e[31mFAIL\e[0m %s\n        expected: %s\n        actual:   %s\n' \
      "$label" "$expected" "$actual"; fail=$((fail + 1))
  fi
}

# Extract the AllowedCPUs value the hook asked systemd for.
allowed_cpus() { sed -n 's/.*AllowedCPUs=\([0-9,-]*\).*/\1/p' "$STUB_LOG" | head -1; }

printf '\n\e[1mhooks/qemu\e[0m\n\n'

# --- A 7950X-style domain: 16 vCPUs on CCD1 ------------------------------
# Guest owns 8-15 and 24-31. The host must be left with 0-7 and 16-23.
{
  printf '<domain><cputune>\n'
  for i in 0 1 2 3 4 5 6 7; do
    printf "  <vcpupin vcpu='%d' cpuset='%d'/>\n" "$((i * 2))"     "$((8 + i))"
    printf "  <vcpupin vcpu='%d' cpuset='%d'/>\n" "$((i * 2 + 1))" "$((24 + i))"
  done
  # These deliberately point at housekeeping cores and must NOT be treated
  # as guest-exclusive, or the emulator thread gets stranded.
  printf "  <emulatorpin cpuset='0,16'/>\n"
  printf "  <iothreadpin iothread='1' cpuset='0,16'/>\n"
  printf '</cputune></domain>\n'
} >"$TMP/domain.xml"

printf 'Ryzen 9 7950X domain, 16 vCPUs pinned to CCD1\n'
: >"$STUB_LOG"
FAKE_NPROC=32 "$HOOK" win-cad prepare begin - <"$TMP/domain.xml" >"$TMP/out" 2>&1
check "hook exits 0" "0" "$?"

expected_host="0,1,2,3,4,5,6,7,16,17,18,19,20,21,22,23"
check "host confined to non-guest CPUs" "$expected_host" "$(allowed_cpus)"
check "confines system.slice"  "1" "$(grep -c 'system.slice AllowedCPUs' "$STUB_LOG")"
check "confines user.slice"    "1" "$(grep -c 'user.slice AllowedCPUs' "$STUB_LOG")"
check "confines init.scope"    "1" "$(grep -c 'init.scope AllowedCPUs' "$STUB_LOG")"

# emulatorpin cores (0 and 16) must remain available to the host.
host_set=",$(allowed_cpus),"
check "emulator core 0 left to host"  "yes" "$([[ $host_set == *,0,*  ]] && echo yes || echo no)"
check "emulator core 16 left to host" "yes" "$([[ $host_set == *,16,* ]] && echo yes || echo no)"
check "guest core 8 not given to host"  "no" "$([[ $host_set == *,8,*  ]] && echo yes || echo no)"
check "guest core 31 not given to host" "no" "$([[ $host_set == *,31,* ]] && echo yes || echo no)"

# --- release restores everything -----------------------------------------
printf '\nRelease\n'
: >"$STUB_LOG"
FAKE_NPROC=32 "$HOOK" win-cad release end - <"$TMP/domain.xml" >/dev/null 2>&1
check "hook exits 0" "0" "$?"
check "restores full CPU range" "0-31" "$(allowed_cpus)"

# --- range syntax in cpuset ----------------------------------------------
printf '\nRange syntax (cpuset="4-7")\n'
cat >"$TMP/range.xml" <<'EOF'
<domain><cputune>
  <vcpupin vcpu='0' cpuset='4-7'/>
</cputune></domain>
EOF
: >"$STUB_LOG"
FAKE_NPROC=8 "$HOOK" t prepare begin - <"$TMP/range.xml" >/dev/null 2>&1
check "expands ranges correctly" "0,1,2,3" "$(allowed_cpus)"

# --- safety: unpinned domain ---------------------------------------------
printf '\nSafety guards\n'
printf '<domain><cputune/></domain>\n' >"$TMP/nopin.xml"
: >"$STUB_LOG"
FAKE_NPROC=8 "$HOOK" t prepare begin - <"$TMP/nopin.xml" >"$TMP/out" 2>&1
check "exits 0 on unpinned domain" "0" "$?"
check "does not confine the host"  "" "$(allowed_cpus)"

# A domain pinned to every CPU would leave the host nowhere to run.
{
  printf '<domain><cputune>\n'
  for i in $(seq 0 7); do printf "  <vcpupin vcpu='%d' cpuset='%d'/>\n" "$i" "$i"; done
  printf '</cputune></domain>\n'
} >"$TMP/allcpus.xml"
: >"$STUB_LOG"
FAKE_NPROC=8 "$HOOK" t prepare begin - <"$TMP/allcpus.xml" >"$TMP/out" 2>&1
check "exits 0 when guest owns every CPU" "0" "$?"
check "refuses to confine host to nothing" "" "$(allowed_cpus)"
check "says why" "1" "$(grep -c 'refusing to isolate' "$TMP/out")"

printf '\n'
if (( fail == 0 )); then
  printf '\e[32m\e[1mAll %d assertions passed.\e[0m\n\n' "$pass"; exit 0
else
  printf '\e[31m\e[1m%d passed, %d FAILED.\e[0m\n\n' "$pass" "$fail"; exit 1
fi
