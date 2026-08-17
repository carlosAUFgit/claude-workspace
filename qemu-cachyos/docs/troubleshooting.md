# Troubleshooting

Ordered roughly by how often each one actually bites.

---

## The machine will not boot after `02-host-tune.sh`

At the boot menu, edit the entry and remove the parameters the kit added
(`iommu=pt`, `hugepages=...`, etc.), then boot normally and run:

```bash
sudo ./99-uninstall.sh
```

The most common cause is reserving too many hugepages — if `hugepages=N`
leaves the kernel too little normal memory, it panics early. Re-run with a
smaller `VM_RAM_GB`.

**Limine specifically**: CachyOS's default bootloader is Limine, not GRUB.
Press `e` at the menu to edit the entry for one boot. The kit's changes live
in a marked block at the end of `/etc/default/limine`; delete the block and
run `sudo limine-update`.

---

## IOMMU groups do not appear after reboot

```bash
ls /sys/kernel/iommu_groups
```

Empty or missing means IOMMU is off in firmware. The kernel parameters cannot
turn on hardware that the firmware disabled.

In your UEFI setup, look for — names vary by vendor:

- **SVM Mode** (must be Enabled) — this is AMD-V, the prerequisite
- **IOMMU** (Enabled, not Auto — "Auto" often means off)
- **AMD CBS → NBIO → IOMMU** on some ASUS/Gigabyte boards
- **ACS Enable** (Enabled) — improves group separation

Confirm the parameters actually reached the kernel:

```bash
cat /proc/cmdline
```

If your additions are not there, the kit edited a bootloader config that is
not the one in charge. Check which is actually installed:

```bash
bash -c 'source qemu-cachyos/lib/common.sh; detect_bootloader'
```

---

## The GPU still shows `amdgpu` / `nvidia` instead of `vfio-pci`

```bash
lspci -nnk -s 0000:03:00.0
```

Work through, in order:

1. **Did you reboot?** The binding happens at boot, not when the script runs.

2. **Is vfio-pci in the initramfs?**
   ```bash
   lsinitcpio /boot/initramfs-linux-cachyos.img | grep vfio
   ```
   Nothing? Re-run `sudo mkinitcpio -P` and check `/etc/mkinitcpio.conf`
   has `vfio_pci vfio vfio_iommu_type1` in `MODULES`.

3. **Did the native driver win the race?** Check the order:
   ```bash
   dmesg | grep -E 'vfio|amdgpu|nvidia' | head -20
   ```
   If `amdgpu` binds first, the `softdep` lines in `/etc/modprobe.d/vfio.conf`
   are not taking effect. Add the native driver to the initramfs blacklist as
   a fallback — but note this disables it for the host entirely, so only do
   this if the host runs on the *other* vendor's GPU.

4. **Both GPUs the same model?** They share a PCI ID, so `ids=` grabs both.
   `03-vfio-bind.sh` detects this and switches to address-based binding
   automatically — if you edited the config by hand, you lost that.

---

## VM fails to start: "Cannot allocate memory" / "unable to map backing store"

Hugepages. Either not enough are reserved, or the memlock limit is too low.

```bash
grep -i huge /proc/meminfo
```

`HugePages_Free` must be at least the guest's RAM in 1 GiB units. If
`HugePages_Total` is 0, the kernel parameter did not apply — see the boot
section above.

If hugepages look fine, check memlock:

```bash
ulimit -l                       # as your user
grep -r memlock /etc/security/limits.d/
```

`02-host-tune.sh` writes `/etc/security/limits.d/99-kvm-memlock.conf`, but
limits only apply to **new login sessions**. Log out and back in.

For a VM running under `qemu:///system` (which is what this kit uses), also
check libvirt's own limit:

```bash
systemctl show libvirtd -p LimitMEMLOCK
```

---

## VM starts, monitor stays black

1. **Is the monitor plugged into the passed-through card?** The virtio display
   goes to SPICE, the real GPU goes to its physical port. They are separate.

2. **Check the guest is actually alive**:
   ```bash
   virt-viewer --connect qemu:///system win-cad
   ```
   If the SPICE display shows Windows running, the guest is fine and the
   problem is GPU output specifically.

3. **UEFI vs legacy ROM**. Cards from before ~2014 have no UEFI GOP in their
   VBIOS and cannot post under OVMF. Check:
   ```bash
   sudo dmesg | grep -i 'vfio.*rom'
   ```
   The fix is dumping a UEFI-patched VBIOS and passing it via `romfile=`.

---

## AMD GPU works once, then the VM will not restart

This is the **AMD reset bug**. Affected cards (Polaris, Vega, and Navi 10 in
particular) do not implement a functioning PCI reset, so after the guest
releases the card it is left in a state the host cannot recover. The second VM
start hangs, and often takes the host down with it.

Symptoms: first boot fine, second boot black screen or host lockup, and
`dmesg` full of

```
vfio-pci 0000:03:00.0: Refused to change power state
```

Fix — install the `vendor-reset` kernel module:

```bash
sudo pacman -S vendor-reset-dkms-git      # from the CachyOS/AUR repos
echo vendor-reset | sudo tee /etc/modules-load.d/vendor-reset.conf
```

Then set the reset method in a libvirt hook, before the VM starts:

```bash
echo device_specific | sudo tee /sys/bus/pci/devices/0000:03:00.0/reset_method
```

RDNA 2 (RX 6000) and later largely fixed this in hardware. If your card is
RX 6000+ or RTX 30-series+, this is almost certainly not your problem.

---

## IOMMU group contains devices you need on the host

```
group 15 contains:
  03:00.0 VGA controller
  03:00.1 Audio device
  00:01.1 PCI bridge
  02:00.0 NVMe controller     <-- you need this
```

The IOMMU cannot split a group. Options, best first:

1. **Move the GPU to a different PCIe slot.** Slots wired directly to the CPU
   usually get their own group; chipset-attached slots share. This is the only
   solution with no downside — try it first.

2. **Enable ACS in firmware** if your board exposes it.

3. **ACS override patch.** `linux-cachyos` ships with it available; add
   `pcie_acs_override=downstream,multifunction` to the kernel command line.
   Understand what you are doing: it makes the kernel *claim* devices are
   isolated when the hardware does not guarantee it. A malicious or buggy
   guest can then reach host memory via peer-to-peer DMA. Acceptable for a
   trusted Windows CAD guest on your own workstation; not acceptable for
   anything untrusted.

---

## NVIDIA "Error 43" in Device Manager

Largely historical — drivers from 465 onward officially support consumer GPUs
in VMs. If you hit it anyway, the domain already contains both mitigations:

```xml
<kvm><hidden state='on'/></kvm>
<hyperv><vendor_id state='on' value='AuthenticAMD'/></hyperv>
```

If it persists, the usual cause is a stale driver install from before the
passthrough worked. Uninstall with DDU in safe mode, then reinstall.

---

## Guest stutters under load despite pinning

Check the host is genuinely off the guest's cores while the VM runs:

```bash
systemctl show system.slice -p AllowedCPUs
cat /proc/irq/*/smp_affinity_list | sort -u
```

Both should show only housekeeping cores. If not, the libvirt hook did not
fire:

```bash
journalctl -t 'libvirt-hook[win-cad]' -n 50
ls -l /etc/libvirt/hooks/qemu        # must be executable
```

Then confirm the vCPUs really are where you think:

```bash
virsh vcpupin win-cad
```

If the pinning spans two CCDs, that alone can be the stutter. `04` warns about
this; re-run it with a `VM_VCPUS` that fits inside one L3 domain. **A smaller
VM that fits one CCD is routinely faster than a larger one that straddles
two** for SolidWorks-shaped workloads.

---

## Disk feels slower than the host

```bash
# On the host, while the guest is doing I/O
iostat -x 1
```

Check, in order:

- The image is **raw**, not qcow2 (`qemu-img info <path>`)
- On Btrfs, CoW is off: `lsattr /var/lib/libvirt/images/` shows `C`
- The guest is using the **virtio** driver, not the SATA fallback — Device
  Manager should show "Red Hat VirtIO SCSI"
- `io='io_uring'` and `cache='none'` are in the domain XML

A guest disk that benchmarks fast but *feels* slow is usually Defender
scanning; see `guest-tuning.md`.

---

## Undoing everything

```bash
sudo ./99-uninstall.sh              # config only, keeps packages and images
sudo ./99-uninstall.sh --packages   # also removes QEMU/libvirt
sudo ./99-uninstall.sh --images     # also deletes VM disk images
```

Original copies of every file the kit modified are kept in
`/var/lib/qemu-cachyos-kit/backups/` and are not deleted by the uninstaller.
