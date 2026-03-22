#!/bin/bash
# Create a small FAT disk image containing the PVE auto-install answer file.
# The PVE installer searches for a partition labeled "proxmox-ais" and reads answer.toml from it.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSWER_FILE="${1:-${SCRIPT_DIR}/answer.toml}"
ANSWER_DISK="${SCRIPT_DIR}/answer-disk.img"
LABEL="proxmox-ais"

if [ ! -f "$ANSWER_FILE" ]; then
    echo "ERROR: Answer file not found: $ANSWER_FILE"
    exit 1
fi

echo "Creating answer disk image..."

# Create a 1MB raw disk image
dd if=/dev/zero of="$ANSWER_DISK" bs=1M count=1 status=none

# Create FAT filesystem with the required label
mkfs.vfat -n "$LABEL" "$ANSWER_DISK" >/dev/null

# Mount and copy answer file
MOUNT_DIR=$(mktemp -d /tmp/pve-answer.XXXXXX)
sudo mount -o loop "$ANSWER_DISK" "$MOUNT_DIR"
sudo cp "$ANSWER_FILE" "$MOUNT_DIR/answer.toml"
sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo "Answer disk created: $ANSWER_DISK (label=$LABEL)"
echo "Contents:"
mdir -i "$ANSWER_DISK" ::/ 2>/dev/null || file "$ANSWER_DISK"
