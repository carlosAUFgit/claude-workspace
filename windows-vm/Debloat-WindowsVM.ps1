#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Shrinks a Windows 10/11 VM installation by removing bundled apps, cleaning
    the component store, and releasing freed blocks back to the host image.

.DESCRIPTION
    Written for a Windows guest running under QEMU/KVM, where several things
    Windows does by default are pure waste: hibernation, System Restore, and
    Reserved Storage all cost gigabytes and are better handled by host-side
    VM snapshots.

    Realistic result on a freshly-updated Windows 10:
        before  ~25 GB
        after   ~13-15 GB

    Run it AFTER Windows Update has finished, not before. The single biggest
    saving is ResetBase, which discards superseded update files — and there is
    nothing to discard until the updates have installed.

.PARAMETER DryRun
    Report what would be done and how much is in play, change nothing.

.PARAMETER KeepPagefile
    Leave the pagefile at Windows' automatic setting. Use this if you run
    MATLAB or anything else that allocates large arrays; the default here
    caps it at 4 GB, which is fine for most work but not for everything.

.PARAMETER SkipCompactOS
    Skip filesystem compression of Windows binaries. CompactOS saves ~2 GB at
    a small CPU cost on file reads. Worth keeping unless the guest feels slow.

.EXAMPLE
    .\Debloat-WindowsVM.ps1 -DryRun
    .\Debloat-WindowsVM.ps1
    .\Debloat-WindowsVM.ps1 -KeepPagefile

.NOTES
    TAKE A SNAPSHOT FIRST. From the CachyOS host:
        sudo virsh snapshot-create-as win10 pre-debloat
    Rolling back is then instant if anything here goes wrong.

    ResetBase is irreversible: after it runs you can no longer uninstall the
    updates that were installed before it. That is the trade for the space.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$KeepPagefile,
    [switch]$SkipCompactOS
)

$ErrorActionPreference = 'Continue'
$script:StepNumber = 0

function Write-Step {
    param([string]$Text)
    $script:StepNumber++
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $script:StepNumber, $Text) -ForegroundColor Cyan
    Write-Host ("-" * 64) -ForegroundColor DarkGray
}

function Write-Ok   { param($m) Write-Host "  ok   $m" -ForegroundColor Green }
function Write-Skip { param($m) Write-Host "  skip $m" -ForegroundColor DarkGray }
function Write-Warn { param($m) Write-Host "  warn $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "  FAIL $m" -ForegroundColor Red }

function Get-FreeGB {
    $d = Get-PSDrive -Name C
    [math]::Round($d.Free / 1GB, 2)
}

function Get-UsedGB {
    $d = Get-PSDrive -Name C
    [math]::Round($d.Used / 1GB, 2)
}

# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Windows VM debloat" -ForegroundColor White
Write-Host ("=" * 64)
$startFree = Get-FreeGB
$startUsed = Get-UsedGB
Write-Host ("  C: currently using {0} GB, {1} GB free" -f $startUsed, $startFree)

if ($DryRun) {
    Write-Host ""
    Write-Host "  DRY RUN — nothing will be changed." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Warn "This makes irreversible changes (see ResetBase in the notes)."
    Write-Warn "Snapshot from the host first:  sudo virsh snapshot-create-as win10 pre-debloat"
    $answer = Read-Host "  Continue? (y/N)"
    if ($answer -notmatch '^[yY]') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# ---------------------------------------------------------------------------
Write-Step "Removing bundled apps"

# Explicit list rather than a keep-list: predictable, and it cannot
# accidentally take out a runtime that something else depends on.
# Deliberately NOT removed: the Store, Calculator, Photos, the VCLibs and
# .NET Native runtimes (removing those breaks other apps), Terminal, Notepad.
$appsToRemove = @(
    'Microsoft.3DBuilder'
    'Microsoft.549981C3F5F10'              # Cortana
    'Microsoft.BingFinance'
    'Microsoft.BingFoodAndDrink'
    'Microsoft.BingHealthAndFitness'
    'Microsoft.BingNews'
    'Microsoft.BingSports'
    'Microsoft.BingTranslator'
    'Microsoft.BingTravel'
    'Microsoft.BingWeather'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.Messaging'
    'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MixedReality.Portal'
    'Microsoft.NetworkSpeedTest'
    'Microsoft.Office.OneNote'
    'Microsoft.OneConnect'
    'Microsoft.People'
    'Microsoft.Print3D'
    'Microsoft.SkypeApp'
    'Microsoft.Todos'
    'Microsoft.Wallet'
    'Microsoft.WindowsAlarms'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxApp'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.YourPhone'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'MicrosoftTeams'
    'Microsoft.MicrosoftStickyNotes'
    'Clipchamp.Clipchamp'
    'Microsoft.GamingApp'
)

$removed = 0
foreach ($app in $appsToRemove) {
    $installed = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
    if (-not $installed) { continue }

    if ($DryRun) {
        Write-Host "  would remove  $app"
        $removed++
        continue
    }

    try {
        $installed | Remove-AppxPackage -AllUsers -ErrorAction Stop
        Write-Ok "removed $app"
        $removed++
    }
    catch {
        Write-Warn "could not remove $app"
    }

    # Also drop it from the provisioned set, or it reinstalls for new users.
    try {
        Get-AppxProvisionedPackage -Online |
            Where-Object { $_.DisplayName -eq $app } |
            Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null
    }
    catch { }
}
Write-Host ("  {0} app(s) {1}" -f $removed, $(if ($DryRun) { "would be removed" } else { "processed" }))

# ---------------------------------------------------------------------------
Write-Step "Removing OneDrive"

$oneDrive = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $oneDrive)) { $oneDrive = "$env:SystemRoot\System32\OneDriveSetup.exe" }

if (Test-Path $oneDrive) {
    if ($DryRun) {
        Write-Host "  would uninstall OneDrive"
    }
    else {
        Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Process $oneDrive -ArgumentList '/uninstall' -Wait -NoNewWindow
        Write-Ok "OneDrive uninstalled"
    }
}
else {
    Write-Skip "OneDrive not present"
}

# ---------------------------------------------------------------------------
Write-Step "Disabling hibernation"

# hiberfil.sys is sized at ~40% of RAM. In a VM you snapshot from the host
# instead, so this file is pure loss — roughly 3 GB on an 8 GB guest.
$hiberfil = "$env:SystemDrive\hiberfil.sys"
if (Test-Path $hiberfil) {
    $sizeGB = [math]::Round((Get-Item $hiberfil -Force).Length / 1GB, 2)
    if ($DryRun) {
        Write-Host "  would reclaim $sizeGB GB"
    }
    else {
        powercfg.exe /hibernate off
        Write-Ok "hibernation off, reclaimed ~$sizeGB GB"
    }
}
else {
    Write-Skip "hibernation already disabled"
}

# ---------------------------------------------------------------------------
Write-Step "Disabling System Restore"

# Host-side VM snapshots are faster, smaller and roll back the whole machine.
# Paying for restore points on top is redundant.
if ($DryRun) {
    Write-Host "  would disable System Restore on C: and delete existing points"
}
else {
    try {
        Disable-ComputerRestore -Drive "C:\" -ErrorAction Stop
        vssadmin.exe delete shadows /all /quiet 2>&1 | Out-Null
        Write-Ok "System Restore disabled, shadow copies deleted"
    }
    catch {
        Write-Warn "could not disable System Restore: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
Write-Step "Disabling Reserved Storage"

# Windows 10 1903+ sets aside ~7 GB for updates. On a fixed-size virtual disk
# that reservation is money you never get back.
if ($DryRun) {
    Write-Host "  would disable Reserved Storage (~7 GB)"
}
else {
    $out = & DISM.exe /Online /Set-ReservedStorageState /State:Disabled 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Reserved Storage disabled"
    }
    else {
        Write-Skip "Reserved Storage not applicable on this build"
    }
}

# ---------------------------------------------------------------------------
Write-Step "Clearing Windows Update cache"

if ($DryRun) {
    $sd = "$env:SystemRoot\SoftwareDistribution\Download"
    if (Test-Path $sd) {
        $sz = [math]::Round((Get-ChildItem $sd -Recurse -Force -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum / 1GB, 2)
        Write-Host "  would reclaim $sz GB"
    }
}
else {
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service -Name bits    -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" `
        -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    Start-Service -Name bits     -ErrorAction SilentlyContinue
    Write-Ok "update cache cleared"

    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        Write-Ok "Delivery Optimization cache cleared"
    }
    catch {
        Write-Skip "no Delivery Optimization cache"
    }
}

# ---------------------------------------------------------------------------
Write-Step "Cleaning the component store (WinSxS)"

# The big one, usually 4-6 GB. ResetBase throws away every superseded version
# of every component, which is why this must run after updates, and why it
# cannot be undone.
if ($DryRun) {
    Write-Host "  would run: DISM /StartComponentCleanup /ResetBase"
    & DISM.exe /Online /Cleanup-Image /AnalyzeComponentStore
}
else {
    Write-Host "  This takes 5-15 minutes. Leave it alone." -ForegroundColor DarkGray
    & DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "component store cleaned"
    }
    else {
        Write-Warn "DISM returned $LASTEXITCODE"
    }
}

# ---------------------------------------------------------------------------
Write-Step "Removing temporary files"

$tempPaths = @(
    "$env:SystemRoot\Temp\*"
    "$env:TEMP\*"
    "$env:SystemRoot\Prefetch\*"
    "$env:SystemRoot\Logs\CBS\*.log"
    "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*"
    "$env:SystemDrive\Windows.old"
)

foreach ($path in $tempPaths) {
    if ($DryRun) {
        Write-Host "  would clear  $path"
        continue
    }
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $DryRun) { Write-Ok "temporary files cleared" }

# ---------------------------------------------------------------------------
Write-Step "Pagefile"

if ($KeepPagefile) {
    Write-Skip "left at Windows' automatic setting (-KeepPagefile)"
}
elseif ($DryRun) {
    Write-Host "  would set a fixed 2-4 GB pagefile"
}
else {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($cs.AutomaticManagedPagefile) {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
        }
        $pf = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pf) {
            Set-CimInstance -InputObject $pf -Property @{ InitialSize = 2048; MaximumSize = 4096 }
            Write-Ok "pagefile fixed at 2-4 GB"
        }
        else {
            Write-Skip "no pagefile setting object found"
        }
    }
    catch {
        Write-Warn "could not adjust pagefile: $($_.Exception.Message)"
    }
    Write-Host "  If MATLAB throws out-of-memory errors later, re-run with -KeepPagefile." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
Write-Step "Compressing Windows binaries (CompactOS)"

if ($SkipCompactOS) {
    Write-Skip "skipped (-SkipCompactOS)"
}
elseif ($DryRun) {
    Write-Host "  would run: compact /CompactOS:always  (~2 GB)"
}
else {
    Write-Host "  This takes several minutes." -ForegroundColor DarkGray
    & compact.exe /CompactOS:always | Out-Null
    Write-Ok "system files compressed"
}

# ---------------------------------------------------------------------------
Write-Step "Releasing freed space back to the host image"

# Everything above frees space inside the guest, but the host's qcow2 file
# stays exactly as large as it ever was. TRIM is what tells the host those
# blocks are dead so the image can shrink.
#
# This only works if the virtual disk was created with discard enabled:
#     --disk path=...,bus=virtio,discard=unmap
# Without it the guest cannot signal anything and the image never shrinks.
if ($DryRun) {
    Write-Host "  would run: Optimize-Volume -DriveLetter C -ReTrim"
}
else {
    try {
        Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop
        Write-Ok "TRIM issued"
    }
    catch {
        Write-Warn "TRIM failed — the disk probably lacks discard=unmap"
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 64)
$endFree = Get-FreeGB
$endUsed = Get-UsedGB

if ($DryRun) {
    Write-Host "Dry run complete. Nothing was changed." -ForegroundColor Yellow
    Write-Host "Re-run without -DryRun to apply."
}
else {
    Write-Host ("  before : {0} GB used, {1} GB free" -f $startUsed, $startFree)
    Write-Host ("  after  : {0} GB used, {1} GB free" -f $endUsed, $endFree)
    Write-Host ("  saved  : {0} GB" -f [math]::Round($startUsed - $endUsed, 2)) -ForegroundColor Green
    Write-Host ""
    Write-Host "  Reboot the VM, then from the CachyOS host shrink the disk image:" -ForegroundColor DarkGray
    Write-Host "    sudo virsh shutdown win10" -ForegroundColor DarkGray
    Write-Host "    sudo qemu-img convert -O qcow2 win10.qcow2 win10-small.qcow2" -ForegroundColor DarkGray
}
Write-Host ("=" * 64)
Write-Host ""
