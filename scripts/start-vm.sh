#!/bin/bash
# Start the Windows 10 KVM VM and enable SSH port forwarding
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM not defined. Run: $SCRIPT_DIR/setup-vm.sh"
    exit 1
fi

STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
if [ "$STATE" = "running" ]; then
    echo "VM is already running."
    virsh domdisplay "$VM_NAME" 2>/dev/null || true
    exit 0
fi

# shellcheck source=common.sh
load_gpu_config
if [ "$GPU_PASSTHROUGH" = "1" ]; then
    echo "GPU passthrough enabled: $GPU_PCI_SLOTS"
    echo "Connect display to the passed-through GPU output (not SPICE)."
    check_vfio_gpu_available
fi

echo "Starting $VM_NAME..."
virsh start "$VM_NAME"

# SLIRP user networking: add SSH port forward via QEMU monitor
sleep 2
virsh qemu-monitor-command "$VM_NAME" --hmp "hostfwd_add tcp::${SSH_HOST_PORT}-:22" 2>/dev/null || true

echo ""
echo "VM started. Connect via:"
echo "  virt-viewer $VM_NAME"
echo "  virt-manager"
echo ""
echo "Internet: enabled automatically (user-mode NAT)"
echo "SSH (after enabling OpenSSH in Windows):"
echo "  ssh -p ${SSH_HOST_PORT} Administrator@localhost"