#!/bin/bash
# Download Windows 10 22H2 from UUP dump and convert to ISO
# Source: https://uupdump.net/known.php?q=category:w10-22h2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

UUP_DIR="$VM_DIR/uup"
BUILD_ID="d54f8d1f-6539-4c20-8c18-47adf9c64603"

echo "=== Windows 10 22H2 Download (UUP Dump) ==="
echo "Source: https://uupdump.net/selectlang.php?id=$BUILD_ID"
echo ""

cd "$UUP_DIR"

if [ ! -f files/convert.sh ]; then
    echo "Fetching converter scripts..."
    curl -fsSL -o files/convert.sh \
        "https://raw.githubusercontent.com/gitntel/uup_converter/master/convert.sh"
    curl -fsSL -o files/convert_ve_plugin \
        "https://raw.githubusercontent.com/gitntel/uup_converter/master/convert_ve_plugin"
    chmod +x files/convert.sh files/convert_ve_plugin
fi

if [ ! -f uup-package.zip ]; then
    echo "Creating UUP download package..."
    curl -fsSL -X POST \
        "https://uupdump.net/get.php?id=$BUILD_ID&pack=en-us&edition=professional" \
        -d "autodl=2" -o uup-package.zip
    unzip -o uup-package.zip
fi

tempScript="aria2_script.txt"
if [ ! -f "$tempScript" ]; then
    echo "Fetching aria2 download script..."
    aria2c --no-conf -o"$tempScript" --allow-overwrite=true \
        "https://uupdump.net/get.php?id=$BUILD_ID&pack=en-us&edition=professional&aria2=2"
fi

mkdir -p UUPs
echo "Downloading UUP files..."
aria2c --no-conf --console-log-level=warn -x16 -s16 -j5 -c -R \
    -d"UUPs" -i"$tempScript"

echo "Converting UUP files to ISO..."
chmod +x files/convert.sh
cd files && ./convert.sh wim "$UUP_DIR/UUPs" 0
cd "$UUP_DIR"

mkdir -p "$(dirname "$ISO")"
GENERATED=$(find "$UUP_DIR" -maxdepth 2 -type f -iname '*.iso' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$GENERATED" ]; then
    echo "ERROR: ISO conversion failed"
    exit 1
fi

mv -f "$GENERATED" "$ISO"
echo "ISO ready: $ISO ($(du -h "$ISO" | cut -f1))"
echo "Next: $SCRIPT_DIR/setup-vm.sh"