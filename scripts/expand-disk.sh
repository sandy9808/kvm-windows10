#!/bin/bash
# Grow the Windows VM disk while it is running (no shutdown required)
# Usage: ./expand-disk.sh [+SIZE]   e.g. ./expand-disk.sh +20G
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ADD_SIZE="${1:-+20G}"

if [ ! -f "$DISK" ]; then
    echo "Disk not found: $DISK"
    exit 1
fi

echo "Current disk:"
qemu-img info "$DISK" | awk -F': ' '/image:|virtual size|disk size/ {print "  "$1": "$2}'

echo ""
echo "Growing qcow2 by $ADD_SIZE (VM may stay running)..."
qemu-img resize "$DISK" "$ADD_SIZE"

echo ""
echo "New virtual size:"
qemu-img info "$DISK" | awk -F': ' '/virtual size/ {print "  "$1": "$2}'
echo ""
echo "Next step inside Windows (no reboot required for SATA):"
echo "  1. Open Disk Management (diskmgmt.msc)"
echo "  2. Action -> Rescan Disks"
echo "  3. Right-click C: -> Extend Volume -> use all unallocated space"
echo ""
echo "PowerShell alternative (run as Administrator):"
echo '  Update-HostStorageCache'
echo '  $part = Get-Partition -DriveLetter C'
echo '  $size = Get-PartitionSupportedSize -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber'
echo '  Resize-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -Size $size.SizeMax'