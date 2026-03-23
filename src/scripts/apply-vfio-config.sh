#!/bin/bash
# Bind configured GPUs to vfio-pci, then load native driver for remaining GPUs
# Called by pve-gpu-vfio.service

set -o pipefail

VFIO_CONF="/etc/pve-gpu-vfio.conf"

log() { logger -t pve-gpu-vfio "$@"; echo "$@"; }

main() {
    if [ ! -f "$VFIO_CONF" ]; then
        log "No VFIO config at $VFIO_CONF, nothing to bind"
        exit 0
    fi

    # Load vfio-pci module
    modprobe vfio-pci || { log "ERROR: Failed to load vfio-pci module"; exit 0; }

    local bound=0
    while IFS= read -r line; do
        line="${line%%#*}"                           # strip comments
        line="${line#"${line%%[![:space:]]*}"}"       # trim leading
        line="${line%"${line##*[![:space:]]}"}"       # trim trailing
        [[ -z "$line" ]] && continue

        local DEV="$line"
        log "Binding $DEV to vfio-pci"

        echo vfio-pci > "/sys/bus/pci/devices/$DEV/driver_override" 2>/dev/null || {
            log "ERROR: Failed to set driver_override for $DEV"; continue
        }

        if [ -e "/sys/bus/pci/devices/$DEV/driver" ]; then
            echo "$DEV" > "/sys/bus/pci/devices/$DEV/driver/unbind" 2>/dev/null || true
        fi

        echo "$DEV" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || {
            log "ERROR: Failed to bind $DEV to vfio-pci"; continue
        }

        log "SUCCESS: Bound $DEV to vfio-pci"
        bound=$((bound + 1))
    done < "$VFIO_CONF"

    # xe/i915 are blacklisted in modprobe.d while VFIO binds exist.
    # Now that targets are bound to vfio-pci, load the native driver
    # so remaining (non-VFIO) GPUs get their normal driver.
    log "Loading native GPU drivers for remaining cards"
    modprobe xe 2>/dev/null || true
    modprobe i915 2>/dev/null || true
    modprobe nvidia 2>/dev/null || true
    modprobe nouveau 2>/dev/null || true

    log "VFIO binding complete ($bound devices bound)"
}

main "$@"

# Always exit 0 — never block boot
exit 0
