#!/bin/bash
# Build and deploy the plugin to a running QEMU PVE VM via serial socket
# Requires: socat, base64
#
# Usage: ./deploy-plugin.sh [socket-path]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOCKET="${1:-${SCRIPT_DIR}/pve-serial.sock}"
SERIAL="${SCRIPT_DIR}/serial-cmd.sh"

if [ ! -S "$SOCKET" ]; then
    echo "ERROR: Serial socket not found at $SOCKET"
    echo "Start the VM first: ./run-pve-vm.sh"
    exit 1
fi

scmd() { bash "$SERIAL" "$SOCKET" "$@"; }
sfile() { bash "$SERIAL" "$SOCKET" --send-file "$@"; }

echo "=== Building .deb package ==="
cd "$PROJECT_ROOT"
make deb

DEB=$(find "$PROJECT_ROOT" -maxdepth 2 -name 'pve-xpu-manager_*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)

if [ -z "$DEB" ]; then
    echo "ERROR: No .deb file found after build"
    exit 1
fi

echo "=== Transferring $DEB to VM via serial ==="
sfile "$DEB" "/tmp/$(basename "$DEB")"

echo "=== Installing plugin ==="
scmd "dpkg -i /tmp/$(basename "$DEB")"

echo "=== Transferring fake sysfs setup script ==="
sfile "$SCRIPT_DIR/../fake-sysfs/setup-fake-sysfs.sh" "/tmp/setup-fake-sysfs.sh"

echo "=== Setting up fake sysfs ==="
scmd "bash /tmp/setup-fake-sysfs.sh"

echo "=== Configuring pvedaemon with fake sysfs ==="
scmd "mkdir -p /etc/systemd/system/pvedaemon.service.d"
scmd "cat > /etc/systemd/system/pvedaemon.service.d/fake-xpu.conf << 'EOF'
[Service]
Environment=PVE_XPU_SYSFS_ROOT=/tmp/fake-xpu
EOF"
scmd "systemctl daemon-reload"
scmd "systemctl restart pvedaemon"

echo "=== Deployment complete ==="
