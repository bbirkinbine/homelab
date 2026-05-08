# 99-sysprep.ps1
#
# Final step: sysprep generalize + shutdown. After this runs, the disk is the
# template artifact. Boot of the cloned VM goes through OOBE-mini and lands
# at cloudbase-init for per-clone identity.
#
# Sysprep terminates the WinRM session as part of generalize. Packer expects
# the disconnect — the build block has valid_exit_codes set to allow it.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 99-sysprep ==="

# Sanity check: cloudbase-init must be installed and stopped.
$cbi = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
if ($null -eq $cbi) {
    throw "cloudbase-init service not found. Run 30-install-cloudbase-init.ps1 before this script."
}
if ($cbi.Status -eq "Running") {
    Write-Host "Stopping cloudbase-init service..."
    Stop-Service -Name "cloudbase-init" -Force
}

# Optional: write an unattended file that disables auto-activation on first
# boot of clones. Otherwise Windows tries to phone home immediately.
$unattendPath = "$env:SystemRoot\System32\Sysprep\unattend.xml"
@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
    </component>
    <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipAutoActivation>true</SkipAutoActivation>
    </component>
  </settings>
</unattend>
"@ | Set-Content -Path $unattendPath -Encoding UTF8

Write-Host "Running sysprep /generalize /oobe /shutdown..."
$sysprep = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
& $sysprep /generalize /oobe /shutdown /unattend:$unattendPath

# Sysprep starts shutdown async. The script should not return — Windows is
# in the process of going down. If we got here Packer will see the WinRM
# disconnect and conclude the build successfully.
Write-Host "Sysprep initiated. Shutdown in progress."
