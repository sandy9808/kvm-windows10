#!/bin/bash
# Shared paths and helpers for Windows KVM scripts
VM_NAME="win10-vm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISK="$VM_DIR/disks/win10-vm.qcow2"
ISO="$VM_DIR/iso/win10-22h2.iso"
XML_TEMPLATE="$SCRIPT_DIR/win10-vm.xml"
OVMF_VARS="$VM_DIR/disks/OVMF_VARS.fd"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"

render_domain_xml() {
    sed "s|@VM_DIR@|$VM_DIR|g" "$XML_TEMPLATE"
}