# Run in Windows PowerShell as Administrator.
# Creates D: on the second SATA disk (200 GB) attached by the host.

$ErrorActionPreference = 'Stop'

$disk = Get-Disk | Where-Object {
    $_.OperationalStatus -eq 'Online' -and
    $_.PartitionStyle -eq 'RAW' -and
    $_.Size -ge 180GB
} | Select-Object -First 1

if (-not $disk) {
    Write-Host 'No uninitialized disk found. Open diskmgmt.msc and check for an unallocated 200 GB disk.'
    exit 1
}

Write-Host "Initializing Disk $($disk.Number) ($([math]::Round($disk.Size/1GB)) GB) as D: ..."

Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false
$part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter D
Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'Data' -Confirm:$false

Write-Host 'Done. D: drive is ready.'
Get-Volume -DriveLetter D | Format-List DriveLetter, FileSystemLabel, FileSystem, Size, SizeRemaining