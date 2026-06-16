#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

UUP_DIR="$VM_DIR/uup"

echo "=== Converting UUP to ISO ==="
cd "$UUP_DIR/files"
chmod +x convert.sh
./convert.sh wim "$UUP_DIR/UUPs" 0

GENERATED=$(find "$UUP_DIR" -maxdepth 2 -type f -iname '*.iso' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$GENERATED" ]; then
    echo "ERROR: No ISO produced by converter"
    exit 1
fi

mkdir -p "$(dirname "$ISO")"
mv -f "$GENERATED" "$ISO"
echo "ISO ready: $ISO ($(du -h "$ISO" | cut -f1))"
"$SCRIPT_DIR/setup-vm.sh"