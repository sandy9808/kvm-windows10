# Run this inside Windows (PowerShell as Administrator) after install
# Enables OpenSSH Server for SSH access via host port 2222

Write-Host "Installing OpenSSH Server..."
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

Write-Host "Starting and enabling sshd service..."
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

Write-Host "Configuring firewall for SSH..."
New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "SSH is ready. From Linux host, connect with:"
Write-Host "  ssh -p 2222 Administrator@localhost"
Write-Host ""
Write-Host "Set a password if needed:"
Write-Host "  net user Administrator YourPassword"