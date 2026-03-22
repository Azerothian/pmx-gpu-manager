#!/bin/bash
# Apply Intel GPU SR-IOV Configuration at boot
# Called by pve-xpu-sriov.service

set -o pipefail

SRIOV_CONF="/etc/pve/local/xpu-sriov.conf"
TEMPLATE_CONF="/etc/pve/local/xpu-vf-templates.conf"
DRM_TIMEOUT=60

log() { logger -t pve-xpu-sriov "$@"; echo "$@"; }

# Wait for DRM devices
wait_for_drm() {
    local elapsed=0
    while [ $elapsed -lt $DRM_TIMEOUT ]; do
        if ls /sys/class/drm/card* >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log "WARNING: No DRM devices found after ${DRM_TIMEOUT}s"
    return 1
}

# Parse INI config - outputs "section|key|value" lines
parse_ini() {
    local file="$1" section=""
    while IFS= read -r line; do
        line="${line%%#*}"  # strip comments
        line="${line#"${line%%[![:space:]]*}"}"  # trim leading
        line="${line%"${line##*[![:space:]]}"}"  # trim trailing
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            echo "${section}|${key}|${val}"
        fi
    done < "$file"
}

# Resolve BDF to DRM card name
resolve_card() {
    local bdf="$1"
    for card_path in /sys/class/drm/card[0-9]*; do
        [ -d "$card_path" ] || continue
        local dev_link
        dev_link=$(readlink -f "$card_path/device" 2>/dev/null) || continue
        if [[ "$dev_link" == *"/$bdf" ]]; then
            basename "$card_path"
            return 0
        fi
    done
    return 1
}

# Fallback: match by device_id
resolve_card_by_device_id() {
    local target_device_id="$1"
    for card_path in /sys/class/drm/card[0-9]*; do
        [ -d "$card_path" ] || continue
        local did
        did=$(cat "$card_path/device/device" 2>/dev/null) || continue
        if [[ "$did" == "$target_device_id" ]]; then
            log "WARNING: Fallback match by device_id $target_device_id -> $(basename "$card_path")"
            basename "$card_path"
            return 0
        fi
    done
    return 1
}

# Determine if device is BMG family (uses debugfs)
is_bmg() {
    local device_id="$1"
    case "$device_id" in
        0xe211|0xe212|0xe222|0xe223) return 0 ;;
        *) return 1 ;;
    esac
}

# Write VF resource quotas
write_vf_resources() {
    local card="$1" bdf="$2" device_id="$3" vf_index="$4" tile="$5"
    local lmem="$6" ggtt="$7" exec_q="$8" preempt="$9"

    if is_bmg "$device_id"; then
        # BMG uses debugfs
        local base="/sys/kernel/debug/dri/$bdf/gt${tile}/vf${vf_index}"
        [ -n "$lmem" ] && echo "$lmem" > "$base/lmem_quota" 2>/dev/null
    else
        # Standard sysfs (Flex, PVC)
        local base="/sys/class/drm/$card/iov/vf${vf_index}/gt${tile}"
        [ -n "$lmem" ] && echo "$lmem" > "$base/lmem_quota" 2>/dev/null
        [ -n "$ggtt" ] && echo "$ggtt" > "$base/ggtt_quota" 2>/dev/null
        [ -n "$exec_q" ] && echo "$exec_q" > "$base/exec_quantum_ms" 2>/dev/null
        [ -n "$preempt" ] && echo "$preempt" > "$base/preempt_timeout_us" 2>/dev/null
    fi
}

# Main
main() {
    if [ ! -f "$SRIOV_CONF" ]; then
        log "No SR-IOV config found at $SRIOV_CONF, nothing to apply"
        exit 0
    fi

    wait_for_drm || exit 0

    # Parse configs
    declare -A config
    while IFS='|' read -r section key value; do
        config["$section|$key"]="$value"
    done < <(parse_ini "$SRIOV_CONF")

    declare -A templates
    if [ -f "$TEMPLATE_CONF" ]; then
        while IFS='|' read -r section key value; do
            templates["$section|$key"]="$value"
        done < <(parse_ini "$TEMPLATE_CONF")
    fi

    # Get unique device sections (BDF format, not sub-sections with /)
    declare -A devices
    for key in "${!config[@]}"; do
        local section="${key%%|*}"
        [[ "$section" == */* ]] && continue  # skip VF override sections
        [[ "${config[$section|persist]}" == "1" ]] || continue
        devices["$section"]=1
    done

    for bdf in $(echo "${!devices[@]}" | tr ' ' '\n' | sort); do
        log "Processing device $bdf"

        local device_id="${config[$bdf|device_id]}"
        local num_vfs="${config[$bdf|num_vfs]}"
        local template="${config[$bdf|template]:-}"

        if [ -z "$num_vfs" ] || [ "$num_vfs" -lt 1 ]; then
            log "ERROR: Invalid num_vfs for $bdf"
            continue
        fi

        # Resolve card
        local card
        card=$(resolve_card "$bdf") || card=$(resolve_card_by_device_id "$device_id") || {
            log "ERROR: Cannot resolve DRM card for $bdf (device_id=$device_id)"
            continue
        }

        # Get per-VF defaults from config section, then template overrides
        local tpl_lmem="${config[$bdf|lmem_per_vf]:-}"
        local tpl_ggtt="${config[$bdf|ggtt_per_vf]:-}"
        local tpl_contexts="" tpl_doorbells=""
        local tpl_autoprobe="${config[$bdf|drivers_autoprobe]:-0}"
        if [ -n "$template" ]; then
            tpl_lmem="${templates[$template|vf_lmem]:-$tpl_lmem}"
            tpl_ggtt="${templates[$template|vf_ggtt]:-$tpl_ggtt}"
            tpl_contexts="${templates[$template|vf_contexts]:-}"
            tpl_doorbells="${templates[$template|vf_doorbells]:-}"
            tpl_autoprobe="${templates[$template|drivers_autoprobe]:-$tpl_autoprobe}"
        fi

        # Determine tile count (1 for flex/bmg, 2 for pvc)
        local tiles=1
        case "$device_id" in
            0x0bd4|0x0bd5|0x0bd6|0x0bda|0x0bdb|0x0b6e) tiles=2 ;;
        esac

        # Write per-VF resources
        for vf in $(seq 1 "$num_vfs"); do
            for tile in $(seq 0 $((tiles - 1))); do
                local lmem="${config[$bdf/vf${vf}|lmem_quota]:-$tpl_lmem}"
                local ggtt="${config[$bdf/vf${vf}|ggtt_quota]:-$tpl_ggtt}"
                local exec_q="${config[$bdf/vf${vf}|exec_quantum_ms]:-20}"
                local preempt="${config[$bdf/vf${vf}|preempt_timeout_us]:-1000}"

                write_vf_resources "$card" "$bdf" "$device_id" "$vf" "$tile" \
                    "$lmem" "$ggtt" "$exec_q" "$preempt"
            done
        done

        # Write drivers_autoprobe
        echo "$tpl_autoprobe" > "/sys/class/drm/$card/device/sriov_drivers_autoprobe" 2>/dev/null || true

        # Create VFs
        echo "$num_vfs" > "/sys/class/drm/$card/device/sriov_numvfs" 2>/dev/null
        local actual
        actual=$(cat "/sys/class/drm/$card/device/sriov_numvfs" 2>/dev/null)
        if [ "$actual" = "$num_vfs" ]; then
            log "SUCCESS: Created $num_vfs VFs for $bdf ($card)"
        else
            log "ERROR: Requested $num_vfs VFs for $bdf but got $actual"
        fi
    done

    log "SR-IOV configuration apply complete"
}

main "$@"

# Always exit 0 — never block boot
exit 0
