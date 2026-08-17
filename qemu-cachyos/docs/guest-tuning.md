# Guest-side tuning for SolidWorks and MATLAB

The host scripts get the hardware to the guest. This is what to do *inside*
Windows, which is where a surprising amount of the remaining performance is.

Work through it in order — several steps depend on the ones before.

---

## 1. Right after Windows finishes installing

### Install the virtio guest tools

The virtio CD is still attached. Run `virtio-win-guest-tools.exe` from it.
This installs the network, memory-balloon, serial and guest-agent drivers.

Without the guest agent, `virsh shutdown` cannot ask Windows to shut down
cleanly — it just yanks the power, and eventually you get a corrupted
filesystem and a Windows repair loop.

Verify afterwards:

```
virsh domifaddr win-cad        # should report the guest's IP
virsh shutdown win-cad         # should shut down cleanly, not hang
```

### Install the GPU driver

Install the vendor driver for the *passed-through* card exactly as you would
on bare metal — AMD Adrenalin / Radeon Pro, or the NVIDIA driver.

Once it is installed, Windows will have two displays: the virtio virtual
display and the real GPU. Plug a physical monitor into the passed-through
card, or use Looking Glass if you want the output in a host window.

> Keep the virtio display attached. It costs nothing and it is how you get
> back in when a GPU driver update goes wrong.

### Power plan

Windows defaults to *Balanced*, which parks cores and clocks down aggressively.
In a VM this interacts badly with pinned vCPUs — the guest asks for a lower
P-state on a core the host has already dedicated to it.

```
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c   # High performance
```

Or *Ultimate Performance*, if the OEM exposed it:

```
powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
```

---

## 2. If you enabled AVIC on the host

`KIT_ENABLE_AVIC=1` turns off nested virtualisation. Windows 11 enables
Virtualisation-Based Security by default, which *needs* nesting — leave both
on and the guest boots slowly, or not at all.

Turn VBS off inside the guest:

1. Windows Security → Device Security → Core Isolation
2. Turn **Memory Integrity** off
3. Reboot

Confirm with `msinfo32` — *Virtualisation-based security* should read
**Not enabled**.

If you would rather keep VBS, re-run `02-host-tune.sh` without
`KIT_ENABLE_AVIC` and reboot. Nested virt costs less than a broken guest.

---

## 3. SolidWorks

### Graphics driver certification

SolidWorks checks the graphics driver against a certified list and silently
disables **RealView** and the enhanced graphics pipeline on anything it does
not recognise. Passthrough does not change the card's PCI ID, so a certified
card stays certified inside the VM — this is one of the ways passthrough
beats every virtual-GPU approach.

Check: SolidWorks → Help → *System Options* → Performance. If RealView is
greyed out, the driver is not certified, not the VM's fault.

### Settings that matter more in a VM than on metal

Tools → Options → System Options → Performance:

| Setting | Value | Why |
|---|---|---|
| Level of detail | Medium/High | Dynamic LOD hides the frame-time cost of large assemblies |
| Verification on rebuild | **Off** | Enormous CPU cost, needed only when debugging geometry errors |
| Enhanced graphics performance | On | Uses the modern render path; turn off only if you see artefacts |
| No preview during open | On | Skips a full render of every file in the open dialog |

Tools → Options → System Options → Assemblies:

- **Load components lightweight** — large assemblies open dramatically faster
- **Use large assembly settings** at a threshold near your typical part count

### Licensing

SolidWorks node-locked activation keys off hardware identity, and network
licences key off the MAC address. The kit derives a **stable MAC** from the VM
name, so re-running `04-create-windows-vm.sh` reproduces it. Do not
hand-edit the `<mac>` element after activating, and do not let virt-manager
regenerate it — you will burn an activation.

If you use a network licence server, check the guest can reach it:

```
Test-NetConnection <license-server> -Port 25734
```

---

## 4. MATLAB

### Thread count

MATLAB's default is one computational thread per **physical** core, detected
via CPUID. In a VM with `topoext` exposed (the kit sets this) the detection is
correct and you should leave it alone.

Verify it matches the guest core count the kit assigned:

```matlab
maxNumCompThreads          % should equal <cores> from your domain XML
```

If it reports the *logical* count instead, SMT is being misreported — check
that `<feature policy='require' name='topoext'/>` is present in your domain.
Running MATLAB with 2x the threads it has physical cores for is measurably
slower, not faster, on BLAS-heavy work.

### Confirm the fast math kernels are active

`host-passthrough` exists so MATLAB's BLAS sees the real CPU flags. Confirm:

```matlab
version -blas
version -lapack
```

You want an AVX2 (or AVX-512) kernel. If it reports a generic SSE2 kernel, the
CPU model is not being passed through properly — check for
`mode='host-passthrough'` in the domain, not `mode='custom'`.

Quick sanity benchmark against your bare-metal expectations:

```matlab
A = rand(8000); B = rand(8000);
tic; C = A*B; toc      % expect within a few % of native
```

Memory bandwidth is where the hugepage backing shows up:

```matlab
n = 5e8; x = rand(n,1,'single');
tic; s = sum(x); toc
```

### Parallel Computing Toolbox

Set the pool to the physical core count, not the vCPU count:

```matlab
parpool('Processes', maxNumCompThreads);
```

Oversubscribing a pinned VM is worse than on bare metal — there is no
host scheduler slack to absorb it, because the kit deliberately removed it.

### GPU arrays

`gpuArray` needs CUDA, so it only works if the card you passed through is an
NVIDIA one. `gpuDevice` will report it directly if so. An AMD card gives you
SolidWorks acceleration but nothing for MATLAB's GPU features.

---

## 5. General Windows hygiene for CAD workloads

### Exclude project directories from Defender

Real-time scanning on a directory full of large assembly files is a
significant, constant tax:

```powershell
Add-MpPreference -ExclusionPath "C:\SolidWorks Projects"
Add-MpPreference -ExclusionPath "C:\MATLAB"
Add-MpPreference -ExclusionProcess "SLDWORKS.exe"
Add-MpPreference -ExclusionProcess "MATLAB.exe"
```

### Turn off search indexing on those directories

Right-click the folder → Properties → uncheck *Allow files to have contents
indexed*.

### Disable core parking

Pinned vCPUs and Windows core parking work against each other:

```
powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100
powercfg -setactive SCHEME_CURRENT
```

### Leave TRIM alone

The domain uses `discard='unmap'`, so Windows' normal TRIM propagates through
to the host filesystem and the image stops growing forever. Do not disable it.
Confirm Windows sees the disk as trim-capable:

```
fsutil behavior query DisableDeleteNotify     # want DisableDeleteNotify = 0
```

---

## 6. Verifying it all worked, from the host

While the VM is running under load:

```bash
# vCPU threads should sit on exactly the pinned cores
virsh vcpupin win-cad

# Host confined to housekeeping cores
systemctl show system.slice -p AllowedCPUs

# Hugepages actually consumed (Free should have dropped by the guest's RAM)
grep -i huge /proc/meminfo

# The GPU is in use by the guest
lspci -nnk -s <your-gpu-address>    # driver in use: vfio-pci

# Per-vCPU host utilisation — look for one core pegged while others idle,
# which is the signature of a workload that wants a faster core, not more
virsh cpu-stats win-cad --total
```

A guest that feels slow *despite* all of this is usually bound by one of:
single-thread clock (nothing to do about it), storage (check with `iostat -x 1`
on the host), or the GPU genuinely being the wrong card for the model size.
