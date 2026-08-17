#!/usr/bin/env bash
# CPU topology analysis and vCPU pinning layout.
#
# Split out of 04-create-windows-vm.sh so tests/test-topology.sh can exercise
# it against simulated CPU layouts (SYSFS_ROOT) without needing the real
# hardware, root, or libvirt.
#
# compute_pinning [requested_vcpus] sets these globals:
#   TOPO_SMT           threads per core (1 or 2)
#   TOPO_PAIRS         all physical cores, as comma-joined sibling lists
#   TOPO_HOUSEKEEPING  the core reserved for the host
#   TOPO_VCPUS         final vCPU count
#   TOPO_CORES         guest cores (TOPO_VCPUS / TOPO_SMT)
#   TOPO_VCPUPIN       the <vcpupin/> XML block
#   TOPO_DOMAINS_USED  how many L3 domains the guest spans
#   TOPO_BIGGEST_DOMAIN cores in the largest single free L3 domain

expand_list() {
  # "0-3,8" -> one integer per line
  local part start end i out=() parts
  IFS=',' read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    if [[ $part == *-* ]]; then
      start=${part%-*}; end=${part#*-}
      for ((i = start; i <= end; i++)); do out+=("$i"); done
    else
      out+=("$part")
    fi
  done
  printf '%s\n' "${out[@]}"
}

# Reads the host topology into TOPO_PAIRS / TOPO_PAIR_L3.
topo_scan() {
  local root=${SYSFS_ROOT:-/sys}
  local cpudir sibs l3 n
  declare -gA TOPO_PAIR_L3=()
  local -A seen=()
  TOPO_PAIRS=()

  # Iterate CPUs in numeric order. The shell glob is lexicographic, which
  # yields cpu0, cpu1, cpu10, cpu11, ... cpu2 — so relying on it means core
  # selection starts in the middle of a CCD and the "first free core" is not
  # the lowest-numbered one.
  local cpus=()
  for cpudir in "$root"/devices/system/cpu/cpu[0-9]*; do
    [[ -d $cpudir ]] || continue
    cpus+=("${cpudir##*/cpu}")
  done
  [[ ${#cpus[@]} -gt 0 ]] || return 1
  mapfile -t cpus < <(printf '%s\n' "${cpus[@]}" | sort -n)

  for n in "${cpus[@]}"; do
    cpudir="$root/devices/system/cpu/cpu$n"
    [[ -r $cpudir/topology/thread_siblings_list ]] || continue
    sibs=$(expand_list "$(<"$cpudir/topology/thread_siblings_list")" | sort -n | paste -sd,)
    [[ -n ${seen[$sibs]:-} ]] && continue
    seen[$sibs]=1
    if [[ -r $cpudir/cache/index3/id ]]; then
      l3=$(<"$cpudir/cache/index3/id")
    elif [[ -r $cpudir/cache/index3/shared_cpu_list ]]; then
      l3=$(<"$cpudir/cache/index3/shared_cpu_list")
    else
      l3=0
    fi
    TOPO_PAIRS+=("$sibs")
    TOPO_PAIR_L3[$sibs]=$l3
  done

  [[ ${#TOPO_PAIRS[@]} -gt 0 ]] || return 1
  TOPO_SMT=2
  [[ ${TOPO_PAIRS[0]} == *,* ]] || TOPO_SMT=1
  return 0
}

compute_pinning() {
  local requested=${1:-}
  local p d c v t

  topo_scan || return 1
  [[ ${#TOPO_PAIRS[@]} -ge 2 ]] || return 2

  # The core owning CPU 0 stays with the host: timer interrupts, the QEMU
  # emulator thread, and whatever else the host still has to do.
  TOPO_HOUSEKEEPING=""
  local avail=()
  for p in "${TOPO_PAIRS[@]}"; do
    if [[ ",$p," == *",0,"* ]]; then TOPO_HOUSEKEEPING=$p; else avail+=("$p"); fi
  done
  if [[ -z $TOPO_HOUSEKEEPING ]]; then
    TOPO_HOUSEKEEPING=${TOPO_PAIRS[0]}
    avail=("${TOPO_PAIRS[@]:1}")
  fi

  # Group free cores by L3 domain. On Ryzen/Threadripper an L3 domain is a
  # CCD; a thread that migrates across that boundary loses its whole cache
  # working set, which is exactly the stutter blamed on "virtualisation".
  declare -gA TOPO_BY_L3=()
  for p in "${avail[@]}"; do
    d=${TOPO_PAIR_L3[$p]}
    TOPO_BY_L3[$d]="${TOPO_BY_L3[$d]:-} $p"
  done

  # Largest domain first, so we fill one CCD before spilling into the next.
  # Ties break toward the lowest-numbered domain, so the layout is stable and
  # reproducible across runs rather than depending on hash iteration order.
  local ordered=()
  while read -r _ d; do
    for p in ${TOPO_BY_L3[$d]}; do ordered+=("$p"); done
  done < <(for d in "${!TOPO_BY_L3[@]}"; do
             printf '%s %s\n' "$(wc -w <<<"${TOPO_BY_L3[$d]}")" "$d"
           done | sort -k1,1nr -k2,2n)

  TOPO_BIGGEST_DOMAIN=$(for d in "${!TOPO_BY_L3[@]}"; do
                          wc -w <<<"${TOPO_BY_L3[$d]}"
                        done | sort -rn | head -1)

  local max_vcpus=$(( ${#ordered[@]} * TOPO_SMT ))
  local default_vcpus=$max_vcpus
  (( default_vcpus > 16 )) && default_vcpus=16
  TOPO_VCPUS=${requested:-$default_vcpus}
  (( TOPO_VCPUS % TOPO_SMT == 0 )) || TOPO_VCPUS=$(( TOPO_VCPUS / TOPO_SMT * TOPO_SMT ))
  (( TOPO_VCPUS <= max_vcpus )) || return 3
  (( TOPO_VCPUS >= 2 )) || return 4

  TOPO_CORES=$(( TOPO_VCPUS / TOPO_SMT ))
  local chosen=("${ordered[@]:0:$TOPO_CORES}")

  local -A used=()
  for p in "${chosen[@]}"; do used[${TOPO_PAIR_L3[$p]}]=1; done
  TOPO_DOMAINS_USED=${#used[@]}

  # Guest core k's threads land on host sibling pair k, in order, so the
  # guest's "these two vCPUs share a core" is actually true of the hardware.
  TOPO_VCPUPIN=""
  v=0
  for p in "${chosen[@]}"; do
    local threads
    IFS=',' read -ra threads <<<"$p"
    for t in "${threads[@]}"; do
      TOPO_VCPUPIN+="    <vcpupin vcpu='${v}' cpuset='${t}'/>"$'\n'
      v=$((v + 1))
    done
  done
  TOPO_VCPUPIN=${TOPO_VCPUPIN%$'\n'}
  return 0
}
