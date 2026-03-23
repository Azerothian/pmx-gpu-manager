#!/bin/sh
# Idempotent script to re-apply PVE GPU Manager patches after PVE upgrades
# Called by APT hook: /etc/apt/apt.conf.d/99-pve-gpu-reapply
# POSIX-compliant; safe for PVE 8.x and 9.x

set -eu

INDEX_TPL="/usr/share/pve-manager/index.html.tpl"
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
SCRIPT_TAG='<script src="/pve2/js/pve-gpu-plugin.js"></script>'
USE_STMT='use PVE::API2::Hardware::XPU;'
REGISTER_STMT="PVE::API2::Nodes->register_method({ name => 'xpu', path => 'xpu', method => 'GET', description => 'XPU hardware management', permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] }, parameters => { additionalProperties => 0, properties => { node => get_standard_option('pve-node') } }, returns => { type => 'array', items => { type => 'object' } }, code => sub { return PVE::API2::Hardware::XPU->index(\$_[0]); } });"

APPLIED=0

log() {
    logger -t pve-gpu-patches "$@" || true
    echo "pve-gpu-patches: $*"
}

backup_if_needed() {
    local file="$1"
    local backup="${file}.pre-gpu"
    if [ ! -f "$backup" ] && [ -f "$file" ]; then
        cp "$file" "$backup"
        log "Backed up $file -> $backup"
    fi
}

patch_index_html() {
    if [ ! -f "$INDEX_TPL" ]; then
        log "WARNING: $INDEX_TPL not found, skipping"
        return 0
    fi

    # Check if already patched
    if grep -qF "$SCRIPT_TAG" "$INDEX_TPL"; then
        log "index.html.tpl already patched, skipping"
        return 0
    fi

    backup_if_needed "$INDEX_TPL"

    # Insert script tag before </head>
    # Use a temp file for atomic replacement
    local tmp
    tmp=$(mktemp)
    sed "s|</head>|${SCRIPT_TAG}\n</head>|" "$INDEX_TPL" > "$tmp"
    mv "$tmp" "$INDEX_TPL"
    log "Patched $INDEX_TPL: inserted script tag before </head>"
    APPLIED=1
}

patch_nodes_pm_use() {
    if [ ! -f "$NODES_PM" ]; then
        log "WARNING: $NODES_PM not found, skipping"
        return 0
    fi

    # Check if already patched
    if grep -qF "$USE_STMT" "$NODES_PM"; then
        log "Nodes.pm use statement already present, skipping"
        return 0
    fi

    backup_if_needed "$NODES_PM"

    # Insert after the last 'use PVE::' line
    local tmp
    tmp=$(mktemp)
    awk -v stmt="$USE_STMT" '
        /^use PVE::/ { last_use = NR; lines[NR] = $0; next }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (i == last_use) print stmt
            }
        }
    ' "$NODES_PM" > "$tmp"
    mv "$tmp" "$NODES_PM"
    log "Patched $NODES_PM: inserted $USE_STMT"
    APPLIED=1
}

patch_nodes_pm_register() {
    if [ ! -f "$NODES_PM" ]; then
        return 0
    fi

    # Check if already patched
    if grep -qF "PVE::API2::Hardware::XPU" "$NODES_PM"; then
        log "Nodes.pm register_method already present, skipping"
        return 0
    fi

    backup_if_needed "$NODES_PM"

    # Insert register_method call before the final 1; line
    local tmp
    tmp=$(mktemp)
    awk -v stmt="$REGISTER_STMT" '
        /^1;[[:space:]]*$/ && !inserted {
            print stmt
            print ""
            inserted = 1
        }
        { print }
    ' "$NODES_PM" > "$tmp"
    mv "$tmp" "$NODES_PM"
    log "Patched $NODES_PM: inserted register_method call"
    APPLIED=1
}

restart_pveproxy() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart pveproxy || log "WARNING: Failed to restart pveproxy"
        log "Restarted pveproxy"
    else
        log "WARNING: systemctl not found, cannot restart pveproxy"
    fi
}

main() {
    log "Checking PVE GPU Manager patches..."

    patch_index_html
    patch_nodes_pm_use
    patch_nodes_pm_register

    if [ "$APPLIED" -eq 1 ]; then
        log "Patches applied, restarting pveproxy"
        restart_pveproxy
    else
        log "All patches already in place, nothing to do"
    fi

    log "Done"
}

main "$@"
