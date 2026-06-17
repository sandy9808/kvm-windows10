# Post-installation health check for the KVM Windows 10 VM.
# Run inside Windows as Administrator:
#   powershell -ExecutionPolicy Bypass -File .\check-vm.ps1
#
# Verifies GPU passthrough, drivers, network, SSH, and disk layout.

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Write-Result {
    param(
        [string]$Label,
        [bool]$Passed,
        [string]$Detail = ""
    )
    $status = if ($Passed) { "PASS" } else { "FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    $line = "[$status] $Label"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $color
}

$results = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail = ""
    )
    $results.Add([PSCustomObject]@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    }) | Out-Null
    Write-Result -Label $Name -Passed $Passed -Detail $Detail
}

Write-Host ""
Write-Host "KVM Windows VM - Post-Installation Check" -ForegroundColor Yellow
Write-Host "Host repo: https://github.com/sandy9808/kvm-windows10" -ForegroundColor DarkGray
Write-Host "Run time:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- System -------------------------------------------------------------------

Write-Section "System"

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

Add-Check -Name "Windows edition" -Passed $true -Detail $os.Caption
Add-Check -Name "System memory" -Passed ($cs.TotalPhysicalMemory -ge 6GB) `
    -Detail ("{0:N1} GB" -f ($cs.TotalPhysicalMemory / 1GB))
Add-Check -Name "Logical processors" -Passed ($cs.NumberOfLogicalProcessors -ge 2) `
    -Detail $cs.NumberOfLogicalProcessors

# --- GPU / Display ------------------------------------------------------------

Write-Section "GPU and display adapters"

$videoControllers = @(Get-CimInstance Win32_VideoController)
$displayDevices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)

if ($videoControllers.Count -eq 0) {
    Add-Check -Name "Video controllers detected" -Passed $false -Detail "None found"
} else {
    Add-Check -Name "Video controllers detected" -Passed $true -Detail "$($videoControllers.Count) adapter(s)"
}

$gpuRows = foreach ($gpu in $videoControllers) {
    $ramGb = if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) {
        [math]::Round($gpu.AdapterRAM / 1GB, 2)
    } else {
        $null
    }

    [PSCustomObject]@{
        Name          = $gpu.Name
        Manufacturer  = $gpu.AdapterCompatibility
        DriverVersion = $gpu.DriverVersion
        Status        = $gpu.Status
        RAM_GB        = $ramGb
        IsNvidia      = $gpu.Name -match 'NVIDIA'
        IsAmd         = $gpu.Name -match 'AMD|Radeon'
        IsQxl         = $gpu.Name -match 'QXL|Red Hat'
        Passthrough   = $gpu.PNPDeviceID -match 'VEN_10DE|VEN_1002'
        PNPDeviceID   = $gpu.PNPDeviceID
    }
}

$gpuRows | Format-Table Name, Manufacturer, DriverVersion, Status, RAM_GB, Passthrough -AutoSize

$passthroughGpu = $gpuRows | Where-Object { $_.Passthrough -and -not $_.IsQxl } | Select-Object -First 1
$qxlAdapter = $gpuRows | Where-Object { $_.IsQxl } | Select-Object -First 1

if ($passthroughGpu) {
    $driverOk = $passthroughGpu.Status -eq 'OK' -and $passthroughGpu.DriverVersion
    Add-Check -Name "GPU passthrough device present" -Passed $true -Detail $passthroughGpu.Name
    Add-Check -Name "Passthrough GPU driver loaded" -Passed $driverOk `
        -Detail $(if ($driverOk) { "v$($passthroughGpu.DriverVersion)" } else { "Install vendor GPU driver" })
} else {
    Add-Check -Name "GPU passthrough device present" -Passed $false `
        -Detail "Only virtual display found (QXL/Basic). Enable VFIO on host or install GPU driver."
}

if ($qxlAdapter) {
    Add-Check -Name "QXL secondary display (SPICE)" -Passed $true -Detail $qxlAdapter.Name
}

Write-Host ""
Write-Host "PnP display devices:" -ForegroundColor DarkGray
$displayDevices |
    Select-Object Status, FriendlyName, InstanceId |
    Format-Table -AutoSize

$badDisplays = @($displayDevices | Where-Object { $_.Status -ne 'OK' })
Add-Check -Name "All display PnP devices healthy" -Passed ($badDisplays.Count -eq 0) `
    -Detail $(if ($badDisplays.Count) { "$($badDisplays.Count) device(s) need attention" } else { "OK" })

Write-Host ""
Write-Host "PCI display-related devices:" -ForegroundColor DarkGray
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'PCI\\VEN_' } |
    Where-Object { $_.FriendlyName -match 'NVIDIA|AMD|Radeon|GeForce|Display' } |
    Select-Object Status, FriendlyName, InstanceId |
    Format-Table -AutoSize

# --- NVIDIA SMI ---------------------------------------------------------------

Write-Section "NVIDIA tools"

$nvidiaSmi = @(
    "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
    "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi",
    "${env:Windir}\System32\nvidia-smi.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($nvidiaSmi) {
    Add-Check -Name "nvidia-smi available" -Passed $true -Detail $nvidiaSmi
    Write-Host ""
    & $nvidiaSmi
} else {
    $needsNvidia = $passthroughGpu -and $passthroughGpu.IsNvidia
    Add-Check -Name "nvidia-smi available" -Passed (-not $needsNvidia) `
        -Detail $(if ($needsNvidia) { "Install NVIDIA driver from nvidia.com/drivers" } else { "Not required (non-NVIDIA GPU)" })
}

# --- DirectX ------------------------------------------------------------------

Write-Section "DirectX"

$dxPath = Join-Path $env:TEMP "kvm-vm-dxdiag.txt"
try {
    $proc = Start-Process -FilePath "dxdiag.exe" -ArgumentList "/t", $dxPath -PassThru -Wait -WindowStyle Hidden
    if (Test-Path $dxPath) {
        Select-String -Path $dxPath -Pattern 'Card name:|Driver Version:|Manufacturer:' |
            ForEach-Object { Write-Host $_.Line.Trim() }
        Add-Check -Name "DirectX diagnostic report" -Passed $true -Detail $dxPath
    } else {
        Add-Check -Name "DirectX diagnostic report" -Passed $false -Detail "dxdiag output not created"
    }
} catch {
    Add-Check -Name "DirectX diagnostic report" -Passed $false -Detail $_.Exception.Message
}

# --- Network ------------------------------------------------------------------

Write-Section "Network"

$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
Add-Check -Name "Physical network adapter up" -Passed ($adapters.Count -gt 0) `
    -Detail $(if ($adapters.Count) { $adapters[0].Name } else { "No active adapter" })

try {
    $ping = Test-Connection -ComputerName "1.1.1.1" -Count 2 -Quiet -ErrorAction Stop
    Add-Check -Name "Internet connectivity (1.1.1.1)" -Passed $ping
} catch {
    Add-Check -Name "Internet connectivity (1.1.1.1)" -Passed $false -Detail $_.Exception.Message
}

# --- OpenSSH ------------------------------------------------------------------

Write-Section "OpenSSH Server"

$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($sshd) {
    Add-Check -Name "sshd service installed" -Passed $true
    Add-Check -Name "sshd service running" -Passed ($sshd.Status -eq 'Running') -Detail $sshd.Status
    Add-Check -Name "sshd set to automatic" -Passed ($sshd.StartType -eq 'Automatic') -Detail $sshd.StartType
} else {
    Add-Check -Name "sshd service installed" -Passed $false `
        -Detail "Run scripts/enable-openssh.ps1 from the Linux host repo"
}

# --- Disks --------------------------------------------------------------------

Write-Section "Disks and volumes"

Get-Volume |
    Where-Object { $_.DriveLetter } |
    Sort-Object DriveLetter |
    Select-Object DriveLetter, FileSystemLabel, FileSystem,
        @{ N = 'Size_GB'; E = { [math]::Round($_.Size / 1GB, 1) } },
        @{ N = 'Free_GB'; E = { [math]::Round($_.SizeRemaining / 1GB, 1) } } |
    Format-Table -AutoSize

$cDrive = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
Add-Check -Name "C: system volume present" -Passed ([bool]$cDrive) `
    -Detail $(if ($cDrive) { "{0:N1} GB free" -f ($cDrive.SizeRemaining / 1GB) } else { "Missing" })

# --- Summary ------------------------------------------------------------------

Write-Section "Summary"

$passed = @($results | Where-Object { $_.Passed }).Count
$failed = @($results | Where-Object { -not $_.Passed }).Count
$total = $results.Count

Write-Host "Checks passed: $passed / $total" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })

if ($failed -gt 0) {
    Write-Host ""
    Write-Host "Failed checks:" -ForegroundColor Red
    $results | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "  - $($_.Name): $($_.Detail)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Auto-fix (run as Administrator):" -ForegroundColor Cyan
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\fix-vm.ps1"
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "All post-installation checks passed." -ForegroundColor Green
    exit 0
}

Write-Host "Some checks failed. Run fix-vm.ps1 or review the output above." -ForegroundColor Yellow
exit 1