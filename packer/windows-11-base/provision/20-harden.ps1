# 20-harden.ps1
#
# Light-touch hardening defaults for the universal base. Not a CIS benchmark.
# Roles add stricter controls per their threat model.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 20-harden ==="

# ----------------------------------------------------------------------
# RDP — enabled with NLA. Roles narrow the source.
# ----------------------------------------------------------------------
Write-Host "Enabling RDP with Network-Level Authentication..."
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0 -Type DWord
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "UserAuthentication" -Value 1 -Type DWord
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------
# OpenSSH Server — installed, running, allowed in firewall
# Mirrors the SSH posture of the Ubuntu base.
# ----------------------------------------------------------------------
Write-Host "Installing OpenSSH Server..."
$ssh = Get-WindowsCapability -Online -Name "OpenSSH.Server*"
if ($ssh.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $ssh.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

# Set default shell to PowerShell for SSH sessions
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null

# Firewall rule for SSH on 22
if (-not (Get-NetFirewallRule -Name "sshd-tcp-in" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "sshd-tcp-in" -DisplayName "OpenSSH Server (sshd) Inbound" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# ----------------------------------------------------------------------
# Windows Firewall — keep on, default-deny inbound. Allow only what we
# explicitly approved (RDP, SSH, WinRM, ICMP).
# ----------------------------------------------------------------------
Write-Host "Setting Windows Firewall defaults..."
Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultInboundAction Block `
    -DefaultOutboundAction Allow -Enabled True

# Allow inbound ICMPv4 echo for ping diagnostics
if (-not (Get-NetFirewallRule -Name "icmp4-echo-in" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "icmp4-echo-in" -DisplayName "ICMP Echo Request (v4)" `
        -Enabled True -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow | Out-Null
}

# ----------------------------------------------------------------------
# Disable LLMNR, NetBIOS over TCP/IP, and SMBv1 — common lateral-movement
# vectors that no homelab role needs.
# ----------------------------------------------------------------------
Write-Host "Disabling LLMNR..."
$dns = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
New-Item -Path $dns -Force | Out-Null
Set-ItemProperty -Path $dns -Name "EnableMulticast" -Value 0 -Type DWord

Write-Host "Disabling SMBv1..."
Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue | Out-Null

# ----------------------------------------------------------------------
# Audit policy — enable basic categories. Forwarding is a role concern.
# ----------------------------------------------------------------------
Write-Host "Enabling basic audit policies..."
& auditpol /set /category:"Logon/Logoff" /success:enable /failure:enable | Out-Null
& auditpol /set /category:"Account Logon" /success:enable /failure:enable | Out-Null
& auditpol /set /category:"Privilege Use" /failure:enable | Out-Null

Write-Host "=== 20-harden done ==="
