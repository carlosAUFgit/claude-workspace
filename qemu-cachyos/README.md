# QEMU/KVM on CachyOS — a tuned setup for SolidWorks and MATLAB

Scripted installation and tuning for a Windows workstation VM on an AMD
CachyOS host, with the GPU passed through. Built for CAD and numerical work
rather than gaming, though the two overlap heavily.

Every script is reversible, explains what it is doing, and refuses to guess
about your hardware — it detects it.

---

## Is this worth it, versus just `pacman -S qemu-full`?

Honestly, it depends entirely on which application you care about:

| | MATLAB | SolidWorks |
|---|---|---|
| **GPU passthrough** | Only matters for `gpuArray`/CUDA | **Decisive.** Without it the viewport is software-rendered — fine for a bracket, miserable for an assembly |
| virtio disk + drivers | Big — toolbox loads, data I/O | Big — assembly load times |
| CPU pinning within one CCD | Moderate; 5–15% on multithreaded solves | Moderate; protects the one hot thread SolidWorks lives on |
| 1 GiB hugepages | Moderate — large matrices, constant TLB pressure | Small |
| `mitigations=off` | Small, low single digits | Small |

A plain install gets you roughly 90–95% of native CPU throughput, and MATLAB
will be genuinely fine on it. **SolidWorks is the one that needs the extra
work**, and the extra work is overwhelmingly "pass through a real GPU" rather
than any amount of sysctl tuning.

If you do not have a second GPU to give up, install QEMU normally and skip
this kit — the remaining optimisations are real but modest, and not worth
reserving hugepages and isolating cores for.

---

## Requirements

- CachyOS (or Arch — everything here is Arch-family)
- AMD Ryzen or Threadripper with SVM enabled in firmware (Intel works too)
- **Two GPUs** — one for the host, one for the guest
- 32 GiB RAM or more, realistically
- A Windows ISO

### AMD iGPU host + NVIDIA card for the guest

That pairing has its own page:
[`docs/nvidia-igpu-notes.md`](docs/nvidia-igpu-notes.md). It avoids several
problems (no PCI ID collision, no AMD reset bug, CUDA available to MATLAB in
the guest) but adds two you must settle first:

- **Is the discrete card muxless?** If it has no display outputs of its own —
  the normal wiring on laptops — passing it through gives the guest a working
  GPU that renders where you cannot see it. `00-preflight.sh` reports
  connectors per GPU and `03-vfio-bind.sh` refuses to proceed silently.
- **Is the iGPU set as primary in UEFI?** If the discrete card still owns the
  console, the host loses its display the moment the guest takes the card.

It also sets expectations honestly for a GeForce card in SolidWorks
(RealView is certified-driver-only, and VRAM is the binding constraint).

---

## Usage

```bash
git clone <this repo>
cd qemu-cachyos

./00-preflight.sh                 # read-only survey — start here, changes nothing
sudo ./01-install-packages.sh     # QEMU, libvirt, OVMF, swtpm, virtio drivers
sudo VM_RAM_GB=32 ./02-host-tune.sh   # IOMMU, hugepages, KVM options, storage
sudo reboot

sudo ./03-vfio-bind.sh            # pick the GPU the VM gets
sudo reboot

sudo ./05-install-hooks.sh        # dynamic core isolation while a VM runs
sudo VM_RAM_GB=32 VM_VCPUS=16 WINDOWS_ISO=/path/to/Win11.iso ./04-create-windows-vm.sh

virsh start win-cad
virt-viewer --connect qemu:///system win-cad
```

Read `00-preflight.sh`'s output before going further. It tells you whether
passthrough is viable on your machine, which is the one thing worth knowing
before you invest an evening in this.

Then read [`docs/guest-tuning.md`](docs/guest-tuning.md) — a meaningful
fraction of the total performance is inside Windows, not on the host.

### The two reboots

They are not optional and not padding. IOMMU groups only exist after the
kernel boots with `iommu=pt`, hugepages are reserved at boot, and vfio-pci has
to claim the GPU before `amdgpu` does — which happens in the initramfs.

---

## Environment variables

| Variable | Default | Used by | Meaning |
|---|---|---|---|
| `VM_RAM_GB` | half of host RAM, capped at 32 | 02, 04 | Guest RAM, reserved as 1 GiB hugepages |
| `VM_VCPUS` | free cores × threads, capped at 16 | 04 | Logical vCPUs; rounded down to even |
| `VM_NAME` | `win-cad` | 04 | Domain name |
| `VM_DISK_GB` | 250 | 04 | System disk size |
| `WINDOWS_ISO` | prompts | 04 | Path to installation media |
| `KIT_ENABLE_AVIC` | 0 | 02 | Hardware interrupt delivery; **disables nested virt** |
| `KIT_MITIGATIONS_OFF` | 0 | 02 | Disable CPU speculation mitigations |
| `KIT_DRY_RUN` | 0 | 04 | Generate the XML but do not define it |
| `KIT_ASSUME_YES` | 0 | all | Skip confirmation prompts |

`VM_RAM_GB` must match between `02` and `04`. If `04` asks for more RAM than
`02` reserved as hugepages, the domain will not start — `04` checks and warns.

---

## What each script does

**`00-preflight.sh`** — Read-only. Reports CPU topology and L3/CCD layout,
whether SVM and IOMMU are on, your GPUs, their IOMMU groups and their display
connectors, which GPU owns the console, RAM, filesystem, and what is already
installed. Flags anything that will block you — including a muxless discrete
GPU or a laptop chassis.

**`01-install-packages.sh`** — Installs `qemu-full`, libvirt, virt-manager,
OVMF, swtpm, virtiofsd and friends. Downloads the virtio-win driver ISO.
Enables the libvirt sockets and the default NAT network, adds you to the
`libvirt` and `kvm` groups.

**`02-host-tune.sh`** — Kernel parameters for IOMMU and hugepages, KVM module
options, memlock limits, and storage preparation (including disabling CoW on
Btrfs, which matters a lot). Detects your bootloader — **CachyOS defaults to
Limine**, and guides that only edit `/etc/default/grub` do nothing there.

**`03-vfio-bind.sh`** — Shows your GPUs, you pick one, it binds that card and
everything else in its IOMMU group to `vfio-pci`. Detects the identical-GPU
case (where binding by PCI ID would capture both and leave the host headless)
and switches to address-based binding via an initramfs hook. Stops if the card
you picked has no display outputs of its own, rather than letting you find out
after two reboots.

**`04-create-windows-vm.sh`** — Works out a cache-aware pinning layout for
your specific chip, renders the domain template, validates it, defines it.

**`05-install-hooks.sh`** — Installs a libvirt hook that isolates the guest's
cores from the host, steers IRQs away from them and switches the governor to
performance — **only while a VM is running**. This is what `isolcpus` does,
except your desktop gets all its cores back when the VM is off.

**`99-uninstall.sh`** — Reverts everything, from a manifest of what was
actually changed. Backups in `/var/lib/qemu-cachyos-kit/backups/`.

---

## The CPU pinning, specifically

This is the part most guides get wrong, and it matters more on Ryzen than on
anything else.

On Ryzen and Threadripper, cores are grouped into CCDs, and **cores in
different CCDs do not share L3 cache**. A thread that migrates across that
boundary loses its entire cache working set. SolidWorks is dominated by one
hot thread, so that single migration is exactly the stutter people blame on
"virtualisation overhead" — it is a cache miss storm, not hypervisor cost.

So `04-create-windows-vm.sh`:

1. Reads the real sibling and L3 topology from sysfs
2. Reserves the core owning CPU 0 for the host — timers, IRQs, the QEMU
   emulator thread
3. Groups the remaining cores by L3 domain and fills the **largest single
   domain first**, so the guest stays inside one CCD wherever possible
4. Maps guest core *k*'s two threads onto a real host sibling pair, so the
   guest's view of "these vCPUs share a core" is actually true
5. Warns you, with a specific suggested `VM_VCPUS`, if the size you asked for
   spans CCDs

A smaller VM that fits inside one CCD is routinely faster than a larger one
that straddles two, for this kind of workload. That is counterintuitive enough
that the script says so out loud.

---

## Security notes, stated plainly

**Mitigations.** `KIT_MITIGATIONS_OFF=1` disables Spectre/Meltdown/MDS/Retbleed
mitigations for the whole host, not just the VM — your browser included. The
realistic gain for SolidWorks and MATLAB is low single-digit percent. It is
off by default and the script makes you confirm.

**ACS override.** If your GPU shares an IOMMU group with something you need,
`troubleshooting.md` describes the ACS override patch. It makes the kernel
treat devices as isolated when the hardware does not guarantee it, which
permits peer-to-peer DMA between them. Fine for a trusted Windows guest on
your own workstation; not fine for anything untrusted.

**`<kvm><hidden state='on'/></kvm>`** hides the hypervisor from the guest. It
is in the template for ISV licensing and legacy NVIDIA driver compatibility,
not to evade anything. Remove it if you do not need it.

**AVIC.** `KIT_ENABLE_AVIC=1` disables nested virtualisation, which breaks
Windows 11's VBS/Memory Integrity. That is a real security feature in the
guest. Off by default.

---

## Tests

The pinning arithmetic, XML rendering and hook logic are unit-tested against
simulated Ryzen and Threadripper topologies. No root, no KVM, no hardware:

```bash
./tests/run-all.sh
```

74 assertions across three suites, covering 7950X, 7700X, Threadripper 7970X
and non-SMT layouts, plus the domain template's performance-critical elements
and the hook's host/guest CPU split.

This exists because the pinning maths is the part most likely to be quietly
wrong on hardware the author does not have in front of them — and a silently
wrong pinning layout looks exactly like a correct one until you benchmark it.

---

## Further reading

- [`docs/guest-tuning.md`](docs/guest-tuning.md) — Windows-side setup,
  SolidWorks graphics and licensing, MATLAB thread counts and BLAS kernels
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — IOMMU groups, the AMD
  reset bug, black screens, boot recovery
- [`docs/nvidia-igpu-notes.md`](docs/nvidia-igpu-notes.md) — AMD iGPU host with an
  NVIDIA guest GPU: muxless check, UEFI primary display, APU memory budget,
  and what a GeForce card does and does not give you in SolidWorks
- [ArchWiki: PCI passthrough via OVMF](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)
- [CachyOS: Boot manager configuration](https://wiki.cachyos.org/configuration/boot_manager_configuration/)
