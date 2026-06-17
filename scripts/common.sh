#!/bin/bash
# Shared paths and helpers for Windows KVM scripts
VM_NAME="win10-vm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISK="$VM_DIR/disks/win10-vm.qcow2"
DATA_DISK="$VM_DIR/disks/win10-vm-d.qcow2"   # E: drive in Windows (300G)
ISO="$VM_DIR/iso/win10-22h2.iso"
XML_TEMPLATE="$SCRIPT_DIR/win10-vm.xml"
OVMF_VARS="$VM_DIR/disks/OVMF_VARS.fd"
GPU_CONF="$SCRIPT_DIR/gpu.conf"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"

GPU_PASSTHROUGH=0
GPU_PCI_SLOTS=""
GPU_AUTO_DETECT=0

load_gpu_config() {
    GPU_PASSTHROUGH=0
    GPU_PCI_SLOTS=""
    GPU_AUTO_DETECT=0

    if [ -f "$GPU_CONF" ]; then
        # shellcheck disable=SC1090
        source "$GPU_CONF"
    fi

    if [ "${GPU_AUTO_DETECT:-0}" = "1" ] && [ -z "$GPU_PCI_SLOTS" ]; then
        GPU_PCI_SLOTS=$("$SCRIPT_DIR/detect-gpu.sh" --pick 2>/dev/null || true)
    fi

    if [ "${GPU_PASSTHROUGH:-0}" = "1" ] && [ -n "$GPU_PCI_SLOTS" ]; then
        GPU_PASSTHROUGH=1
    else
        GPU_PASSTHROUGH=0
    fi
}

pci_slot_to_xml_address() {
    local slot="$1"
    local domain bus dev func

    if [[ "$slot" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
        domain="0x${BASH_REMATCH[1]}"
        bus="0x${BASH_REMATCH[2]}"
        dev="0x${BASH_REMATCH[3]}"
        func="0x${BASH_REMATCH[4]}"
    elif [[ "$slot" =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]]; then
        domain="0x0000"
        bus="0x${BASH_REMATCH[1]}"
        dev="0x${BASH_REMATCH[2]}"
        func="0x${BASH_REMATCH[3]}"
    else
        echo "Invalid PCI slot: $slot" >&2
        return 1
    fi

    printf "domain='%s' bus='%s' slot='%s' function='%s'" "$domain" "$bus" "$dev" "$func"
}

render_gpu_hostdev_xml() {
    local slot xml_addr
    local -a slots=()
    local IFS=','

    read -ra slots <<< "$GPU_PCI_SLOTS"

    for slot in "${slots[@]}"; do
        slot="${slot//[[:space:]]/}"
        [ -n "$slot" ] || continue
        xml_addr=$(pci_slot_to_xml_address "$slot") || return 1
        cat <<EOF
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <driver name='vfio'/>
      <source>
        <address $xml_addr/>
      </source>
    </hostdev>
EOF
    done
}

insert_block_at_marker() {
    local marker="$1"
    local block_file="$2"
    sed "/^${marker}\$/{
        r $block_file
        d
    }"
}

# Guest vIOMMU in domain XML requires libvirt >= 9.4 (Ubuntu 24.04+).
# Host IOMMU (BIOS + kernel) is still required for VFIO; this only affects the XML feature.
libvirt_supports_guest_iommu() {
    local ver="${1:-$(virsh --version 2>/dev/null || echo 0)}"
    local major="${ver%%.*}"
    local minor_patch="${ver#*.}"
    local minor="${minor_patch%%.*}"

    [ "$major" -gt 9 ] || { [ "$major" -eq 9 ] && [ "$minor" -ge 4 ]; }
}

render_domain_xml() {
    load_gpu_config

    local work_dir qxl_primary
    work_dir=$(mktemp -d)
    trap 'rm -rf "$work_dir"' RETURN

    if [ "$GPU_PASSTHROUGH" = "1" ]; then
        qxl_primary="no"
        render_gpu_hostdev_xml > "$work_dir/gpu.xml"
        if libvirt_supports_guest_iommu; then
            if grep -qi '^vendor_id.*AMD' /proc/cpuinfo 2>/dev/null; then
                echo "    <iommu model='amd'/>" > "$work_dir/iommu.xml"
            else
                echo "    <iommu model='intel'/>" > "$work_dir/iommu.xml"
            fi
        else
            : > "$work_dir/iommu.xml"
        fi
        cat > "$work_dir/quirks.xml" <<'EOF'
    <qemu:commandline>
      <qemu:arg value='-fw_cfg'/>
      <qemu:arg value='name=opt/ovmf/X-PciMmio64Mb,string=262144'/>
    </qemu:commandline>
EOF
    else
        qxl_primary="yes"
        : > "$work_dir/gpu.xml"
        : > "$work_dir/iommu.xml"
        : > "$work_dir/quirks.xml"
    fi

    local step="$work_dir/domain.xml"
    sed -e "s|@VM_DIR@|$VM_DIR|g" \
        -e "s|@QXL_PRIMARY@|$qxl_primary|g" \
        "$XML_TEMPLATE" > "$step"

    insert_block_at_marker "@IOMMU_FEATURE@" "$work_dir/iommu.xml" < "$step" > "$work_dir/step1.xml"
    insert_block_at_marker "@GPU_HOSTDEV@" "$work_dir/gpu.xml" < "$work_dir/step1.xml" > "$work_dir/step2.xml"
    insert_block_at_marker "@GPU_QUIRKS@" "$work_dir/quirks.xml" < "$work_dir/step2.xml"
}

gpu_status_line() {
    load_gpu_config
    if [ "$GPU_PASSTHROUGH" = "1" ]; then
        echo "GPU:    VFIO passthrough ($GPU_PCI_SLOTS) + QXL secondary"
    else
        echo "GPU:    QXL + SPICE (run ./scripts/setup-gpu.sh to enable passthrough)"
    fi
}