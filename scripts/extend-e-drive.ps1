# Run in Windows PowerShell as Administrator.
# Extends E: into the 100 GB unallocated space on the same disk (200 -> 300 GB).

$ErrorActionPreference = 'Stop'

Update-HostStorageCache

$part = Get-Partition -DriveLetter E
$size = Get-PartitionSupportedSize -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber
$addedGB = [math]::Round(($size.SizeMax - $part.Size) / 1GB, 1)

if ($addedGB -lt 1) {
    Write-Host 'No extendable space found next to E:.'
    Write-Host 'Open diskmgmt.msc -> Action -> Rescan Disks, then retry.'
    exit 1
}

Write-Host "Extending E: by about $addedGB GB ..."
Resize-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -Size $size.SizeMax

Get-Volume -DriveLetter E | Format-List DriveLetter, FileSystemLabel, FileSystem, Size, SizeRemaining