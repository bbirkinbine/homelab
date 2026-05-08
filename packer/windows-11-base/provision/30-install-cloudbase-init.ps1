# 30-install-cloudbase-init.ps1
#
# Install cloudbase-init -- the Windows port of cloud-init. After sysprep,
# cloudbase-init runs on first boot of every clone, reads the cloud-init
# data drive (Proxmox attaches one; libvirt expects a NoCloud seed ISO),
# and configures the per-clone identity (hostname, network, admin, SSH keys).
#
# This is the Windows analog to the Ubuntu base's cloud-init package
# pre-install step. Without it, Terraform/OpenTofu can't customize Windows
# clones automatically.
#
# Two bugs to be aware of when editing the conf below (verified 2026-05-07
# by manual cloudbase-init run on a sysprep'd clone):
#   1. The conf file MUST NOT have a UTF-8 BOM. PowerShell's
#      `Set-Content -Encoding UTF8` writes a BOM (`EF BB BF`); the BOM byte
#      makes oslo_config's INI parser choke on the literal first line
#      `[DEFAULT]` and the service crashes immediately at boot with
#      WIN32_EXIT_CODE 1067 and never writes a log. We use
#      [System.IO.File]::WriteAllText with UTF8Encoding($false) instead.
#   2. CreateUserPlugin lives at cloudbaseinit.plugins.windows.createuser
#      in current versions, NOT cloudbaseinit.plugins.common.createuser.
#      The common path only exposes BaseCreateUserPlugin (abstract).
#
# Note for clone-time consumers: cloudbase-init does NOT understand
# Proxmox's `qm set --ciuser X --cipassword Y` shortcut format (which
# writes `user:` / `password:` / `chpasswd:` top-level cloud-config that
# cloudbase-init's cloudconfig plugin treats as unsupported). To pass
# credentials at clone time, use `qm set --cicustom user=local:snippets/...`
# pointing at a proper cloud-config snippet with `users:` (list) syntax --
# or set the password via the Cloudbase-Init `username=` default below
# combined with `admin_pass` in meta_data.json.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 30-install-cloudbase-init ==="

$installerUrl  = "https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$installerPath = "$env:TEMP\CloudbaseInitSetup.msi"

Write-Host "Downloading cloudbase-init..."
Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

Write-Host "Installing cloudbase-init (silent, no auto-start)..."
$args = @(
    "/i", $installerPath,
    "/qn",                        # silent
    "/norestart",
    "RUN_SERVICE_AS_LOCAL_SYSTEM=1"
)
$proc = Start-Process -FilePath msiexec.exe -ArgumentList $args -Wait -PassThru
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "cloudbase-init MSI failed with exit code $($proc.ExitCode)"
}

# Replace the default conf with one that matches Proxmox's cloud-init drive
# and the "config drive + NoCloud" pattern libvirt uses.
$confDir = "$env:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\conf"
$mainConf = Join-Path $confDir "cloudbase-init.conf"

$confContent = @"
[DEFAULT]
username=Administrator
groups=Administrators
inject_user_password=true
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe
mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\
verbose=true
debug=true
log_dir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
log_file=cloudbase-init.log
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
logging_serial_port_settings=
mtu_use_dhcp_config=true
ntp_use_dhcp_config=true
local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\

# Datasources, in priority order. NoCloud covers libvirt seed ISOs;
# ConfigDrive covers Proxmox / OpenStack-style cloud-init drives.
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService

# Plugin paths use the Windows-specific module for CreateUserPlugin --
# cloudbaseinit.plugins.common.createuser only contains the abstract
# BaseCreateUserPlugin in current versions, and configuring the common
# path triggers an immediate AttributeError at service start.
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.windows.ntpclient.NTPClientPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin
"@

# Write the conf as UTF-8 WITHOUT a BOM -- see the header comment for the
# story behind this. PowerShell 5.1's `Set-Content -Encoding UTF8` always
# writes a BOM; we sidestep it via .NET's System.IO.File.WriteAllText
# with a UTF8Encoding constructed with $emitBom=$false.
[System.IO.File]::WriteAllText(
    $mainConf,
    $confContent,
    (New-Object System.Text.UTF8Encoding $false)
)

# Stop the cloudbase-init service so it doesn't run during the build itself.
# Sysprep + first boot of the clone is when it should actually fire.
Set-Service -Name "cloudbase-init" -StartupType Automatic
Stop-Service -Name "cloudbase-init" -Force -ErrorAction SilentlyContinue

Write-Host "=== 30-install-cloudbase-init done ==="
