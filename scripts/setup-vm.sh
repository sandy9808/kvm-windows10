#!/bin/bash
# Create and configure the Windows 10 KVM VM (libvirt/virt)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

echo "=== Windows 10 KVM VM Setup ==="

if [ ! -f "$OVMF_VARS" ]; then
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS"
    echo "Created UEFI vars: $OVMF_VARS"
fi

if [ ! -f "$DISK" ]; then
    if [ -f "$VM_DIR/disks/win10-vicecity.qcow2" ]; then
        mv "$VM_DIR/disks/win10-vicecity.qcow2" "$DISK"
        echo "Renamed legacy disk to: $DISK"
    else
        qemu-img create -f qcow2 "$DISK" 80G
        echo "Created disk: $DISK"
    fi
fi

if [ ! -f "$ISO" ]; then
    echo "ISO not ready yet: $ISO"
    echo "Run: $SCRIPT_DIR/download-windows.sh"
    exit 1
fi

ISO_SIZE=$(stat -c%s "$ISO")
if [ "$ISO_SIZE" -lt 4000000000 ]; then
    echo "ISO appears incomplete ($(numfmt --to=iec-i --suffix=B "$ISO_SIZE"))"
    exit 1
fi

for OLD in win10-vicecity; do
    if virsh dominfo "$OLD" &>/dev/null; then
        virsh destroy "$OLD" 2>/dev/null || true
        virsh undefine "$OLD" --nvram 2>/dev/null || virsh undefine "$OLD" 2>/dev/null || true
        echo "Removed legacy VM definition: $OLD"
    fi
done

if virsh dominfo "$VM_NAME" &>/dev/null; then
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --nvram 2>/dev/null || virsh undefine "$VM_NAME" 2>/dev/null || true
    echo "Removed existing VM definition"
fi

render_domain_xml | virsh define /dev/stdin
echo "VM defined: $VM_NAME"

echo ""
echo "Resources allocated:"
echo "  CPU:    4 cores (host-passthrough)"
echo "  RAM:    8 GB"
echo "  Disk:   $(qemu-img info "$DISK" | awk -F': ' '/virtual size/ {print $2}')"
echo "  GPU:    QXL + SPICE"
echo "  Sound:  ich9"
echo "  Net:    user-mode NAT (internet) + SSH host:$SSH_HOST_PORT -> guest:22"
echo ""
echo "Start with:  $SCRIPT_DIR/start-vm.sh"