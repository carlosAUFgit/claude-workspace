# AMD integrated GPU (host) + NVIDIA GTX 1650 (guest)

Notes specific to this pairing. The generic setup in the README applies; this
covers what differs, and what to check before spending an evening on it.

---

## The good news first

This is a *better* combination than it might look:

- **No PCI ID collision.** The host GPU is AMD, the guest GPU is NVIDIA, so
  binding by device ID is unambiguous. `03-vfio-bind.sh` takes its simple
  path — no initramfs address-binding hook needed.
- **No AMD reset bug.** That affects AMD *discrete* cards (Polaris, Vega,
  Navi 10) being passed through. Your guest card is NVIDIA Turing, which
  resets correctly. You can restart the VM repeatedly without host lockups.
- **Error 43 is history.** NVIDIA officially supports consumer GPUs in VMs
  since driver 465 (2021). The domain still carries the old mitigations
  (`<kvm><hidden/>`, `vendor_id`) because they cost nothing, but you are very
  unlikely to need them.
- **CUDA works.** TU117 is compute capability 7.5, so MATLAB's `gpuArray` and
  the Parallel Computing Toolbox GPU features are available in the guest.
  That is *not* true if you pass through an AMD card.

---

## Check this before anything else: is the 1650 muxless?

**This is the one thing that can make the whole plan unworkable**, and it is
worth resolving before you touch a single config file.

A GTX 1650 paired with an AMD integrated GPU is an extremely common *laptop*
configuration (Ryzen 4600H/5600H class). On most laptops the discrete GPU is
**muxless**: it has no display outputs of its own, and renders into the
integrated GPU's framebuffer, which then drives the panel.

Once you hand that card to a guest, the copy path through the host iGPU is
gone. The guest gets a fully working GPU that renders to nothing you can see.

`00-preflight.sh` checks this for you and reports display outputs per GPU. Or
check manually:

```bash
# For the NVIDIA card's PCI address:
ls /sys/class/drm/ | grep card
for c in /sys/class/drm/card*-*; do
  printf '%s: %s\n' "$c" "$(cat $c/status)"
done
```

**If the 1650 reports zero connectors**, your options are:

1. **Looking Glass** — the guest renders to a shared memory buffer, the host
   displays it in a window. Near-native latency, genuinely good, but it is a
   separate project with its own setup, and it needs a chunk of shared memory
   sized to your resolution.
2. **Don't pass through.** Use virtio-gpu with VirGL. SolidWorks will be
   software-rendered and slow for assemblies.
3. **If it's a desktop** with the 1650 in a PCIe slot: it has its own HDMI/DP
   ports, this whole section does not apply, and you are fine.

If you are on a desktop, plug a monitor (or a cheap HDMI dummy plug) into the
1650 and carry on.

---

## UEFI: make the iGPU primary

Your host desktop must run on the AMD integrated GPU so the NVIDIA card is
free. In UEFI setup, find and set:

- **Primary Video Adapter** / **Initiate Graphic Adapter** / **IGFX
  Multi-Monitor** → set to **IGD / iGPU / Integrated**
- **IOMMU** → Enabled (not Auto)
- **SVM Mode** → Enabled

Then plug your monitor into the **motherboard's** video output, not the
graphics card's. Confirm after booting:

```bash
cat /sys/bus/pci/devices/*/boot_vga | grep -c 1     # should be exactly 1
lspci -nnk | grep -A3 VGA                            # amdgpu should own the iGPU
```

`00-preflight.sh` warns if the NVIDIA card is still the primary adapter.

---

## Memory: the APU tax

An integrated GPU carves a UMA framebuffer out of system RAM at boot, before
Linux sees it. So your memory budget is really:

```
total installed RAM
  − UMA framebuffer (BIOS setting, often 512 MB – 4 GB)
  − hugepages reserved for the guest (VM_RAM_GB)
  = what the host actually gets
```

`02-host-tune.sh` computes from `MemTotal`, which is already net of the UMA
carve-out, so its "left for host" figure is honest. But if you set a large UMA
size in BIOS *and* reserve a lot of hugepages, the host can end up
uncomfortably tight.

For a 32 GB machine, something like: 1 GB UMA (plenty for a desktop on an
iGPU), 16 GB hugepages, ~15 GB host. Do not set UMA to "Auto" and then wonder
where 4 GB went.

---

## nouveau

The host must not let `nouveau` grab the card before vfio-pci does.
`03-vfio-bind.sh` writes `softdep` lines covering `nouveau`, `nvidia`,
`nvidia_drm` and `nvidia_modeset`, which is normally enough.

If after rebooting the card still shows `Kernel driver in use: nouveau`, add a
hard blacklist — safe here, because your host runs on amdgpu and has no use
for nouveau at all:

```bash
echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
sudo mkinitcpio -P
```

**Do not** install the proprietary `nvidia` driver on the host. You do not
need it — the host runs on the iGPU, and the guest brings its own driver. An
installed host driver is just one more thing racing vfio-pci for the card.

---

## The audio function

Most GTX 1650 boards expose an HDMI audio device as a second function:

```
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU117 [GeForce GTX 1650]
01:00.1 Audio device [0403]: NVIDIA Corporation TU116 High Definition Audio Controller
```

Both must go to the guest together — they are in the same IOMMU group.
`03-vfio-bind.sh` collects the whole group automatically, so this is handled.
Some low-profile and OEM 1650 variants omit the audio function entirely;
that is fine too.

---

## What to expect: SolidWorks on a GTX 1650

Being straight with you about this, since it is the reason for the whole
exercise.

**It will be enormously better than software rendering.** That is the win, and
it is a big one.

**But the 1650 is not a CAD card**, and two things follow:

1. **RealView will not be available.** SolidWorks enables RealView and its
   enhanced graphics pipeline only on *certified* drivers — Quadro/RTX A-series
   and Radeon Pro. A GeForce card is not on the list. Passthrough does not
   change this; you would have the same limitation on bare metal. Modelling,
   drawings and simulation all work normally. You lose the glossy realtime
   material preview.

2. **4 GB of VRAM is the real constraint.** Fine for parts and assemblies up
   to a few thousand components. Large assemblies will start swapping graphics
   memory and the viewport gets choppy — and that is a hard limit you cannot
   tune around. Mitigate with *Load components lightweight* and aggressive
   Level of Detail settings (see `guest-tuning.md`).

If your assemblies are big enough to hurt, the fix is a card with more VRAM,
not more host tuning.

---

## What to expect: MATLAB on a GTX 1650

Better story here.

- **CPU work** — which is most of MATLAB — is unaffected by the GPU and will
  run at essentially native speed with the pinning and hugepages in place.
- **`gpuArray` works.** Turing is compute 7.5, supported by every current
  MATLAB release.
- 4 GB VRAM again caps problem size. Check what you actually have:

  ```matlab
  d = gpuDevice;
  fprintf('%s, %.1f GB free of %.1f GB\n', d.Name, ...
          d.AvailableMemory/1e9, d.TotalMemory/1e9);
  ```

- The 1650 has **no tensor cores** and weak FP64 (1/32 rate). For double
  precision linear algebra it can be *slower* than your CPU. Benchmark before
  assuming the GPU helps:

  ```matlab
  A = rand(4096); tic; A*A; toc                    % CPU
  B = gpuArray(single(A)); tic; B*B; wait(gpuDevice); toc   % GPU, single
  ```

  Single precision on the GPU should win comfortably. Double precision often
  will not.

---

## Realistic expectation setting

For an APU + GTX 1650 desktop, with this kit applied, you should land at:

| | vs bare-metal Windows |
|---|---|
| MATLAB CPU work | ~95–98% |
| SolidWorks modelling/rebuild | ~95% |
| SolidWorks viewport | ~90–95% of what a 1650 gives natively |
| Disk | ~90–95% with raw + virtio + io_uring |

The gap between "plain QEMU install" and "this kit" for your workload is
mostly the GPU (huge) and the CPU pinning (moderate). Everything else is
single-digit percentages.
