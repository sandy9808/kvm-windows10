#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
virsh shutdown "$VM_NAME" --timeout 120 2>/dev/null || virsh destroy "$VM_NAME" 2>/dev/null || true
echo "VM stopped."