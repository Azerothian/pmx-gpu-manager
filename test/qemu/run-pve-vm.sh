#!/bin/bash
# Launch a QEMU VM for PVE 9.1 testing
# Usage: ./run-pve-vm.sh [--install]
#   --install: Unattended install from ISO using answer disk
#   (default): Boot from installed disk
#
# Exposes:
#   - Serial socket at ./pve-serial.sock (for serial-cmd.sh)
#   - Web UI forwarded to localhost:8006

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="${SCRIPT_DIR}/pve-test.qcow2"
ISO="${SCRIPT_DIR}/proxmox-ve_9.1-1.iso"
ANSWER_DISK="${SCRIPT_DIR}/answer-disk.img"
SERIAL_SOCK="${SCRIPT_DIR}/pve-serial.sock"
MONITOR_SOCK="${SCRIPT_DIR}/pve-monitor.sock"
WEB_PORT="${WEB_PORT:-8006}"

# Clean up stale sockets
rm -f "$SERIAL_SOCK" "$MONITOR_SOCK"

# Create disk if needed
if [ ! -f "$DISK" ]; then
    echo "Creating 32GB disk image..."
    qemu-img create -f qcow2 "$DISK" 32G
fi

if [ "$1" = "--install" ]; then
    # === UNATTENDED INSTALL MODE ===
    if [ ! -f "$ISO" ]; then
        echo "Downloading PVE 9.1 ISO..."
        wget -O "$ISO" "https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso"
    fi

    # Create answer disk if needed
    if [ ! -f "$ANSWER_DISK" ]; then
        echo "Creating answer disk..."
        bash "$SCRIPT_DIR/create-answer-disk.sh"
    fi

    echo "=== UNATTENDED INSTALL MODE ==="
    echo "  The PVE installer will detect the answer disk (label=proxmox-ais)"
    echo "  and install automatically. VM will shut down when done."
    echo ""
    echo "  Serial socket: ${SERIAL_SOCK}"
    echo "  Monitor install: socat -,raw,echo=0 UNIX-CONNECT:${SERIAL_SOCK}"
    echo ""

    # Run as daemon so we can send keystrokes via monitor
    # Attach answer disk as a USB mass storage device (most reliable detection)
    qemu-system-x86_64 \
        -enable-kvm \
        -m 2048 \
        -smp 2 \
        -drive file="$DISK",format=qcow2,if=virtio \
        -cdrom "$ISO" \
        -boot d \
        -drive file="$ANSWER_DISK",format=raw,if=none,id=ais \
        -device usb-ehci,id=ehci \
        -device usb-storage,bus=ehci.0,drive=ais,removable=on \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::${WEB_PORT}-:8006 \
        -vga std \
        -chardev socket,id=serial0,path="$SERIAL_SOCK",server=on,wait=off \
        -serial chardev:serial0 \
        -monitor unix:"$MONITOR_SOCK",server,nowait \
        -vnc :0 \
        -daemonize

    echo "VM started. Waiting for boot menu..."
    sleep 15

    # Send keystrokes to select "Automated Installation" in GRUB menu
    # PVE 9.1 boot menu: 1) Install, 2) Install (Debug), 3) Rescue, 4) Automated Install
    # Send 3x "down" arrow + Enter to select Automated Installation
    echo "Selecting 'Automated Installation' from boot menu..."
    for i in 1 2 3; do
        echo "sendkey down" | socat - UNIX-CONNECT:"$MONITOR_SOCK"
        sleep 0.5
    done
    sleep 0.5
    echo "sendkey ret" | socat - UNIX-CONNECT:"$MONITOR_SOCK"

    echo "Automated install started. Monitoring disk growth..."

    # Wait for install to complete (disk grows then QEMU exits)
    TIMEOUT=600
    ELAPSED=0
    LAST_SIZE=0
    STABLE_COUNT=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if ! pgrep -f "pve-test.qcow2" >/dev/null 2>&1; then
            echo "VM shut down — install complete!"
            break
        fi

        CUR_SIZE=$(stat -c%s "$DISK" 2>/dev/null || echo 0)
        if [ "$CUR_SIZE" -gt 200000 ] && [ "$CUR_SIZE" = "$LAST_SIZE" ]; then
            STABLE_COUNT=$((STABLE_COUNT + 1))
        else
            STABLE_COUNT=0
        fi
        LAST_SIZE=$CUR_SIZE

        # Log progress every 30s
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            echo "  [${ELAPSED}s] disk size: $(du -h "$DISK" | cut -f1)"
        fi

        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done

    if pgrep -f "pve-test.qcow2" >/dev/null 2>&1; then
        echo "WARNING: Install may still be running (timeout after ${TIMEOUT}s)"
        echo "Check VNC :0 for status. Kill with: kill \$(pgrep -f pve-test.qcow2)"
    fi

    echo ""
    echo "=== Run without --install to boot from installed disk. ==="

else
    # === NORMAL BOOT MODE ===
    echo "Starting PVE VM..."
    echo "  Serial socket: ${SERIAL_SOCK}"
    echo "  Web UI: https://localhost:${WEB_PORT}"
    echo ""
    echo "  Connect to console:  socat -,raw,echo=0 UNIX-CONNECT:${SERIAL_SOCK}"
    echo "  Run commands:        ./serial-cmd.sh ${SERIAL_SOCK} 'hostname'"
    echo "  Wait for boot:       ./serial-cmd.sh ${SERIAL_SOCK} --wait-login"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -m 2048 \
        -smp 2 \
        -drive file="$DISK",format=qcow2,if=virtio \
        -boot c \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::${WEB_PORT}-:8006 \
        -vga std \
        -chardev socket,id=serial0,path="$SERIAL_SOCK",server=on,wait=off \
        -serial chardev:serial0 \
        -monitor unix:"$MONITOR_SOCK",server,nowait \
        -display none \
        -daemonize

    echo "VM started in background"
    echo "Waiting for serial socket..."

    for i in $(seq 1 10); do
        [ -S "$SERIAL_SOCK" ] && break
        sleep 1
    done

    if [ ! -S "$SERIAL_SOCK" ]; then
        echo "ERROR: Serial socket did not appear at $SERIAL_SOCK"
        exit 1
    fi

    echo "Serial socket ready: $SERIAL_SOCK"
fi
