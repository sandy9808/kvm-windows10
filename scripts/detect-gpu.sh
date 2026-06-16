#!/bin/bash
# List discrete GPUs suitable for VFIO passthrough
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

pick=0
if [ "${1:-}" = "--pick" ]; then
    pick=1
fi

iommu_group_for() {
    local slot="$1"
    local link
    link=$(readlink -f "/sys/bus/pci/devices/0000:${slot}/iommu_group" 2>/dev/null || true)
    [ -n "$link" ] && basename "$link"
}

is_discrete_gpu() {
    local slot="$1"
    local class vendor
    class=$(lspci -n -s "$slot" 2>/dev/null | awk '{print $2}' | tr -d ':')
    vendor=$(lspci -n -s "$slot" 2>/dev/null | awk '{print $3}' | cut -d: -f1)
    [ "$class" = "0300" ] || return 1
    case "$vendor" in
        10de|1002|1b36) return 0 ;;
        *) return 1 ;;
    esac
}

join_slots() {
    local IFS=,
    echo "$*"
}

related_audio_slots() {
    local gpu_slot="$1"
    local group gpu_domain gpu_bus gpu_dev gpu_func
    group=$(iommu_group_for "$gpu_slot") || return 0
    [ -n "$group" ] || return 0

    gpu_domain="0000"
    if [[ "$gpu_slot" =~ ^([0-9a-fA-F]{4}): ]]; then
        gpu_domain="${BASH_REMATCH[1]}"
        gpu_slot="${gpu_slot#*:}"
    fi

    IFS=: read -r gpu_bus gpu_dev_func <<< "$gpu_slot"
    gpu_dev="${gpu_dev_func%.*}"

    for dev in "/sys/kernel/iommu_groups/$group/devices/"*; do
        [ -e "$dev" ] || continue
        local full="${dev##*/}"
        local short="${full#0000:}"
        local class
        class=$(lspci -n -s "$short" 2>/dev/null | awk '{print $2}' | tr -d ':')
        if [ "$class" = "0403" ] && [[ "$short" =~ ^${gpu_bus}:${gpu_dev}\. ]]; then
            echo "$short"
        fi
    done
}

declare -A seen_groups=()
candidates=()

while IFS= read -r line; do
    slot=$(echo "$line" | awk '{print $1}' | sed 's/0000://')
    name=$(echo "$line" | sed 's/^[^ ]* //')
    group=$(iommu_group_for "$slot" || true)

    if ! is_discrete_gpu "$slot"; then
        continue
    fi

    if [ -n "${seen_groups[$group]:-}" ]; then
        continue
    fi
    seen_groups[$group]=1

    slots=("$slot")
    while IFS= read -r audio; do
        [ -n "$audio" ] && slots+=("$audio")
    done < <(related_audio_slots "$slot")

    joined=$(join_slots "${slots[@]}")
    candidates+=("$joined")
    if [ "$pick" = "1" ]; then
        echo "$joined"
        exit 0
    fi

    driver=$(lspci -k -s "$slot" 2>/dev/null | awk '/Kernel driver in use/ {print $5; exit}')
    printf '%s\n    %s\n' "$joined" "$name"
    printf '    IOMMU group: %s  driver: %s\n' "${group:-unknown}" "${driver:-none}"
done < <(lspci -nn | grep -E 'VGA compatible controller|3D controller')

if [ "$pick" = "1" ]; then
    exit 1
fi

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "No discrete NVIDIA/AMD GPUs found."
    echo "Integrated graphics (Intel) is usually kept for the host."
    exit 1
fi

echo ""
echo "Pass these slots to setup-gpu.sh or gpu.conf as GPU_PCI_SLOTS."