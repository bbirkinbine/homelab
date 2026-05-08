# 10-install-virtio.ps1
#
# Install the full virtio-win driver suite + QEMU guest agent. The build
# itself runs on scsihw=lsi (LSI 53C895A) because Win11 24H2's setup host
# ignores Autounattend DriverPaths and we don't want to ship a custom-rolled
# Win11 ISO; lsi has a built-in Win11 driver so install proceeds without
# any runtime injection. By the time this script runs, the boot disk is
# already on lsi.
#
# What we install here: vioscsi (so clones can switch to virtio-scsi-single
# hardware and boot — vioscsi gets registered as a boot-critical service),
# NetKVM (NIC), Balloon (memory ballooning), vioserial, viorng, plus
# QEMU-GA (the guest agent). virtio-win-guest-tools.exe wraps all of these
# in one MSI-equivalent and is the canonical install entry point.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 10-install-virtio ==="

# Find the virtio-win.iso mount point. It's normally D: or E: depending on
# CD-ROM order — search every drive letter for the marker file.
$virtioRoot = $null
foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
    $candidate = Join-Path $drive.Root "virtio-win-guest-tools.exe"
    if (Test-Path $candidate) {
        $virtioRoot = $drive.Root
        Write-Host "Found virtio-win.iso mount at: $virtioRoot"
        break
    }
}

if ($null -eq $virtioRoot) {
    throw "virtio-win.iso not found in any mounted drive. Check that the ISO is attached as a second CDROM during build."
}

$installer = Join-Path $virtioRoot "virtio-win-guest-tools.exe"
Write-Host "Running: $installer /install /passive /norestart"
$proc = Start-Process -FilePath $installer -ArgumentList "/install","/passive","/norestart" -Wait -PassThru
Write-Host "virtio-win-guest-tools exit code: $($proc.ExitCode)"

if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED, which is fine
    throw "virtio-win-guest-tools installer failed with exit code $($proc.ExitCode)"
}

# Verify QEMU guest agent service exists and is running
$svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "QEMU Guest Agent service: $($svc.Status)"
    if ($svc.Status -ne "Running") {
        Set-Service -Name "QEMU-GA" -StartupType Automatic
        Start-Service -Name "QEMU-GA"
    }
} else {
    Write-Host "WARNING: QEMU-GA service not found. Proxmox guest-agent integration won't work."
}

Write-Host "=== 10-install-virtio done ==="
