# Fix common post-installation issues in the KVM Windows 10 VM.
# Run as Administrator:
#   powershell -ExecutionPolicy Bypass -File .\fix-vm.ps1
#
# Addresses:
#   - OpenSSH Server (sshd) not installed
#   - Passthrough GPU missing a vendor driver
#   - Display PnP devices in error state

#Requires -RunAsAdministrator

param(
    [switch]$SkipGpu,
    [switch]$SkipSsh,
    [switch]$RebootIfNeeded
)

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Install-OpenSshServer {
    Write-Section "OpenSSH Server"

    $capability = Get-WindowsCapability -Online |
        Where-Object { $_.Name -like 'OpenSSH.Server*' } |
        Select-Object -First 1

    if (-not $capability) {
        Write-Host "OpenSSH Server capability not found on this Windows image." -ForegroundColor Red
        return $false
    }

    if ($capability.State -ne 'Installed') {
        Write-Host "Installing OpenSSH Server..."
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    } else {
        Write-Host "OpenSSH Server already installed."
    }

    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name sshd -ErrorAction SilentlyContinue

    $firewall = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $firewall) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
            -ErrorAction SilentlyContinue | Out-Null
    }

    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshd -and $sshd.Status -eq 'Running') {
        Write-Host "sshd is running. Connect from Linux host:" -ForegroundColor Green
        Write-Host "  ssh -p 2222 Administrator@localhost"
        return $true
    }

    Write-Host "sshd failed to start. Check: Get-Service sshd" -ForegroundColor Red
    return $false
}

function Get-PassthroughDisplayDevices {
    Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -match 'VEN_10DE|VEN_1002' -and
            $_.FriendlyName -notmatch 'QXL|Red Hat|Microsoft Basic'
        }
}

function Install-DriversFromWindowsUpdate {
    param([string[]]$TitlePatterns = @('NVIDIA', 'AMD', 'Radeon', 'Display', 'Graphics'))

    Write-Host "Searching Windows Update for driver packages..."
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and Type='Driver'")

    if ($result.Updates.Count -eq 0) {
        Write-Host "No pending driver updates returned by Windows Update." -ForegroundColor Yellow
        return $false
    }

    $selected = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $result.Updates) {
        $title = [string]$update.Title
        foreach ($pattern in $TitlePatterns) {
            if ($title -match $pattern) {
                Write-Host "  Queued: $title"
                $selected.Add($update) | Out-Null
                break
            }
        }
    }

    if ($selected.Count -eq 0) {
        Write-Host "No display-related drivers in Windows Update queue." -ForegroundColor Yellow
        return $false
    }

    Write-Host "Downloading $($selected.Count) driver update(s)..."
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $selected
    $download = $downloader.Download()
    if ($download.ResultCode -ne 2) {
        Write-Host "Driver download failed (code $($download.ResultCode))." -ForegroundColor Red
        return $false
    }

    Write-Host "Installing driver update(s)..."
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $selected
    $install = $installer.Install()
    if ($install.ResultCode -eq 2) {
        Write-Host "Driver updates installed successfully." -ForegroundColor Green
        return $true
    }

    Write-Host "Driver install finished with code $($install.ResultCode). A reboot may be required." -ForegroundColor Yellow
    return $true
}

function Install-NvidiaDriverFallback {
    param([string]$HardwareId)

    Write-Host ""
    Write-Host "Windows Update did not install a GPU driver." -ForegroundColor Yellow
    Write-Host "Passthrough GPU hardware id: $HardwareId"
    Write-Host ""
    Write-Host "Install the NVIDIA driver manually:" -ForegroundColor Yellow
    Write-Host "  1. Open https://www.nvidia.com/Download/index.aspx"
    Write-Host "  2. Choose your GPU model, OS: Windows 10 64-bit, Download Type: Game Ready or Studio"
    Write-Host "  3. Run the installer inside this VM"
    Write-Host "  4. Reboot, then re-run: .\check-vm.ps1"
    Write-Host ""

    if ($HardwareId -match 'VEN_10DE&DEV_([0-9A-F]{4})') {
        $devId = $Matches[1]
        Write-Host "NVIDIA PCI device id: $devId (use this on nvidia.com if auto-detect fails)" -ForegroundColor DarkGray
    }

    $opened = $false
    foreach ($browser in @(
            "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
        )) {
        if (Test-Path $browser) {
            Start-Process $browser 'https://www.nvidia.com/Download/index.aspx'
            $opened = $true
            break
        }
    }

    if (-not $opened) {
        Start-Process 'https://www.nvidia.com/Download/index.aspx'
    }

    return $false
}

function Repair-DisplayDrivers {
    Write-Section "GPU and display drivers"

    $null = Start-Process pnputil.exe -ArgumentList '/scan-devices' -Wait -NoNewWindow -PassThru

    $passthrough = @(Get-PassthroughDisplayDevices)
    $problem = @($passthrough | Where-Object { $_.Status -ne 'OK' })

    if ($passthrough.Count -eq 0) {
        Write-Host "No passthrough NVIDIA/AMD display device found." -ForegroundColor Yellow
        Write-Host "If you expected GPU passthrough, verify VFIO on the Linux host:"
        Write-Host "  ./scripts/setup-gpu.sh --status"
        Write-Host "  ./scripts/stop-vm.sh && ./scripts/setup-vm.sh && ./scripts/start-vm.sh"
        return $false
    }

    Write-Host "Passthrough display device(s):"
    $passthrough | Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize

    $alreadyOk = @($passthrough | Where-Object { $_.Status -eq 'OK' })
    if ($alreadyOk.Count -gt 0 -and $problem.Count -eq 0) {
        Write-Host "Passthrough GPU driver already loaded." -ForegroundColor Green
        return $true
    }

    $nvidiaSmi = @(
        "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "${env:Windir}\System32\nvidia-smi.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($nvidiaSmi) {
        Write-Host "nvidia-smi already available:" -ForegroundColor Green
        & $nvidiaSmi
        return $true
    }

    $wuOk = Install-DriversFromWindowsUpdate
    if ($wuOk) {
        $null = Start-Process pnputil.exe -ArgumentList '/scan-devices' -Wait -NoNewWindow -PassThru
        Start-Sleep -Seconds 3
        $problem = @(Get-PassthroughDisplayDevices | Where-Object { $_.Status -ne 'OK' })
        if ($problem.Count -eq 0) {
            Write-Host "Display devices are healthy after Windows Update." -ForegroundColor Green
            return $true
        }
    }

    $hardwareId = ($problem | Select-Object -First 1).InstanceId
    if (-not $hardwareId) {
        $hardwareId = ($passthrough | Select-Object -First 1).InstanceId
    }

    if ($hardwareId -match 'VEN_10DE') {
        return Install-NvidiaDriverFallback -HardwareId $hardwareId
    }

    if ($hardwareId -match 'VEN_1002') {
        Write-Host "Install the AMD Adrenalin driver from https://www.amd.com/en/support" -ForegroundColor Yellow
        Start-Process 'https://www.amd.com/en/support'
        return $false
    }

    Write-Host "Unknown passthrough GPU. Install the vendor driver manually." -ForegroundColor Yellow
    return $false
}

Write-Host ""
Write-Host "KVM Windows VM - Post-Installation Fix" -ForegroundColor Yellow
Write-Host "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$sshOk = $true
$gpuOk = $true

if (-not $SkipSsh) {
    $sshOk = Install-OpenSshServer
}

if (-not $SkipGpu) {
    $gpuOk = Repair-DisplayDrivers
}

Write-Section "Next steps"

if (-not $sshOk) {
    Write-Host "- OpenSSH still needs attention. Re-run this script or scripts/enable-openssh.ps1" -ForegroundColor Yellow
}

if (-not $gpuOk) {
    Write-Host "- GPU driver still needs a manual install and reboot." -ForegroundColor Yellow
}

Write-Host "- Verify everything: powershell -ExecutionPolicy Bypass -File .\check-vm.ps1" -ForegroundColor Cyan

if ($RebootIfNeeded -and -not $gpuOk) {
    Write-Host ""
    $answer = Read-Host "Reboot now to finish driver setup? (y/N)"
    if ($answer -match '^[Yy]') {
        Restart-Computer -Force
    }
}

if ($sshOk -and $gpuOk) {
    exit 0
}

exit 1