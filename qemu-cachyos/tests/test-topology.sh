#!/usr/bin/env bash
# Tests for lib/topology.sh against simulated AMD CPU layouts.
#
# The pinning maths is the part of this kit most likely to be quietly wrong
# on hardware the author does not have, so it is exercised against synthetic
# sysfs trees modelled on real Ryzen and Threadripper parts.
#
# Run: ./tests/test-topology.sh

set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
source lib/topology.sh

pass=0; fail=0
FAKE_ROOT=$(mktemp -d)
trap 'rm -rf "$FAKE_ROOT"' EXIT

# Build a fake sysfs. Linux enumerates AMD SMT as: cpu0..cpu(N-1) are thread 0
# of each core, cpu N.. are thread 1 — so core k's siblings are k and k+N.
# ccd_size is cores per L3 domain.
make_topology() {
  local name=$1 cores=$2 smt=$3 ccd_size=$4
  local root="$FAKE_ROOT/$name" c t cpu l3
  rm -rf "$root"
  for ((c = 0; c < cores; c++)); do
    l3=$(( c / ccd_size ))
    for ((t = 0; t < smt; t++)); do
      cpu=$(( c + t * cores ))
      mkdir -p "$root/devices/system/cpu/cpu$cpu/topology" \
               "$root/devices/system/cpu/cpu$cpu/cache/index3"
      if (( smt == 2 )); then
        printf '%d,%d' "$c" "$(( c + cores ))" >"$root/devices/system/cpu/cpu$cpu/topology/thread_siblings_list"
      else
        printf '%d' "$c" >"$root/devices/system/cpu/cpu$cpu/topology/thread_siblings_list"
      fi
      printf '%d' "$l3" >"$root/devices/system/cpu/cpu$cpu/cache/index3/id"
    done
  done
  printf '%s' "$root"
}

check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  \e[32mPASS\e[0m %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  \e[31mFAIL\e[0m %s\n        expected: %s\n        actual:   %s\n' "$label" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

run_case() {
  local name=$1 cores=$2 smt=$3 ccd=$4 req=$5
  SYSFS_ROOT=$(make_topology "$name" "$cores" "$smt" "$ccd")
  export SYSFS_ROOT
  TOPO_PAIRS=(); unset TOPO_BY_L3 TOPO_PAIR_L3
  compute_pinning "$req"
  return $?
}

printf '\n\e[1mlib/topology.sh\e[0m\n\n'

# --- Ryzen 9 7950X: 16 cores / 32 threads, two 8-core CCDs ----------------
printf 'Ryzen 9 7950X (16C/32T, 2 CCDs) — default sizing\n'
run_case r7950x 16 2 8 ""
check "detects 16 physical cores"        "16" "${#TOPO_PAIRS[@]}"
check "detects SMT"                      "2"  "$TOPO_SMT"
check "reserves core 0 pair for host"    "0,16" "$TOPO_HOUSEKEEPING"
check "caps default at 16 vCPUs"         "16" "$TOPO_VCPUS"
check "8 guest cores"                    "8"  "$TOPO_CORES"
# CCD0 has only 7 free cores (core 0 is housekeeping) so the whole VM must
# land on CCD1, which still has all 8.
check "stays within one L3 domain"       "1"  "$TOPO_DOMAINS_USED"
check "vcpu0 -> host cpu8 (CCD1 start)"  "    <vcpupin vcpu='0' cpuset='8'/>" \
                                         "$(head -1 <<<"$TOPO_VCPUPIN")"
check "vcpu1 -> cpu8's SMT sibling"      "    <vcpupin vcpu='1' cpuset='24'/>" \
                                         "$(sed -n 2p <<<"$TOPO_VCPUPIN")"
check "emits 16 vcpupin lines"           "16" "$(grep -c vcpupin <<<"$TOPO_VCPUPIN")"
guest_cpus=$(grep -o "cpuset='[0-9]*'" <<<"$TOPO_VCPUPIN" | sed "s/[^0-9]//g" | sort -n | paste -sd,)
check "never assigns the host's cores"   "0" "$(grep -cw -e 0 -e 16 <<<"$(tr ',' '\n' <<<"$guest_cpus")")"

# --- Same chip, oversized request forced across both CCDs ----------------
printf '\nRyzen 9 7950X — 24 vCPUs (deliberately spans CCDs)\n'
run_case r7950x24 16 2 8 24
check "24 vCPUs granted"                 "24" "$TOPO_VCPUS"
check "correctly reports spanning 2 CCDs" "2" "$TOPO_DOMAINS_USED"
check "suggests 16 to fit one CCD"       "16" "$(( TOPO_BIGGEST_DOMAIN * TOPO_SMT ))"

# --- Ryzen 7 7700X: single CCD -------------------------------------------
printf '\nRyzen 7 7700X (8C/16T, 1 CCD)\n'
run_case r7700x 8 2 8 ""
check "14 vCPUs available after host reservation" "14" "$TOPO_VCPUS"
check "single domain"                    "1"  "$TOPO_DOMAINS_USED"
check "host keeps 0,8"                   "0,8" "$TOPO_HOUSEKEEPING"

# --- Threadripper 7970X: 32 cores, 4 CCDs --------------------------------
printf '\nThreadripper 7970X (32C/64T, 4 CCDs)\n'
run_case tr7970x 32 2 8 16
check "16 vCPUs"                         "16" "$TOPO_VCPUS"
check "fits one CCD"                     "1"  "$TOPO_DOMAINS_USED"
first=$(grep -o "cpuset='[0-9]*'" <<<"$TOPO_VCPUPIN" | head -1 | tr -dc 0-9)
check "starts on a fully-free CCD (cpu>=8)" "yes" "$([[ $first -ge 8 ]] && echo yes || echo no)"

# --- No SMT ---------------------------------------------------------------
printf '\nNo-SMT part (8C/8T, 1 L3)\n'
run_case nosmt 8 1 8 ""
check "SMT detected as 1"                "1"  "$TOPO_SMT"
check "7 vCPUs after host reservation"   "7"  "$TOPO_VCPUS"
check "7 cores"                          "7"  "$TOPO_CORES"
check "host keeps core 0"                "0"  "$TOPO_HOUSEKEEPING"

# --- Error paths ----------------------------------------------------------
printf '\nError handling\n'
run_case toobig 8 2 8 999; rc=$?
check "rejects impossible vCPU count"    "3"  "$rc"
run_case single 1 1 1 ""; rc=$?
check "rejects single-core host"         "2"  "$rc"

printf '\n'
if (( fail == 0 )); then
  printf '\e[32m\e[1mAll %d assertions passed.\e[0m\n\n' "$pass"
  exit 0
else
  printf '\e[31m\e[1m%d passed, %d FAILED.\e[0m\n\n' "$pass" "$fail"
  exit 1
fi
