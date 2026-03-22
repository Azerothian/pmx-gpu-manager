#!/bin/bash
# serial-cmd.sh — Execute a command inside the QEMU VM via serial socket
#
# Usage:
#   serial-cmd.sh <socket-path> <command>
#   serial-cmd.sh <socket-path> --file <script-path>
#   serial-cmd.sh <socket-path> --wait-login
#   serial-cmd.sh <socket-path> --send-file <local-path> <remote-path>
#
# Requires: socat
#
# Protocol:
#   1. Connect to QEMU serial unix socket via socat
#   2. Send command, wrapped with unique markers for output capture
#   3. Read output until end marker appears
#   4. Return the captured output and exit code

set -euo pipefail

SOCKET="${1:?Usage: serial-cmd.sh <socket> <command|--file path|--wait-login|--send-file local remote>}"
shift

TIMEOUT="${SERIAL_TIMEOUT:-30}"
SOCAT_OPTS="UNIX-CONNECT:${SOCKET},nonblock"

# Verify socket exists
if [ ! -S "$SOCKET" ]; then
    echo "ERROR: Serial socket not found: $SOCKET" >&2
    exit 1
fi

# Check socat is available
if ! command -v socat &>/dev/null; then
    echo "ERROR: socat is required but not installed" >&2
    exit 1
fi

# Generate unique marker for this invocation
MARKER="__SERIAL_$(date +%s%N)__"

# Send raw bytes to the serial socket
serial_send() {
    echo -ne "$1" | socat - "$SOCAT_OPTS" 2>/dev/null
}

# Send a command and capture output between markers
# Uses a background socat listener to capture output
serial_exec() {
    local cmd="$1"
    local outfile
    outfile=$(mktemp /tmp/serial-out.XXXXXX)
    local rcfile
    rcfile=$(mktemp /tmp/serial-rc.XXXXXX)

    # Start background listener that captures everything from the socket
    socat "$SOCAT_OPTS" - > "$outfile" 2>/dev/null &
    local listener_pid=$!

    # Small delay to let listener attach
    sleep 0.3

    # Send the command wrapped with markers
    # The markers let us extract just our command's output
    # We also capture the exit code
    local wrapped_cmd
    wrapped_cmd=$(cat <<EOFCMD
echo "${MARKER}_START"
${cmd}
echo "\${?}" > /tmp/_serial_rc
echo "${MARKER}_END"
cat /tmp/_serial_rc
echo "${MARKER}_RC"
EOFCMD
)

    # Send each line with a small delay to avoid serial buffer overflow
    while IFS= read -r line; do
        echo "$line" | socat - "$SOCAT_OPTS" 2>/dev/null
        sleep 0.05
    done <<< "$wrapped_cmd"

    # Wait for end marker or timeout
    local elapsed=0
    while [ $elapsed -lt "$TIMEOUT" ]; do
        if grep -q "${MARKER}_RC" "$outfile" 2>/dev/null; then
            break
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done

    # Kill listener
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true

    if [ $elapsed -ge "$TIMEOUT" ]; then
        rm -f "$outfile" "$rcfile"
        echo "ERROR: Command timed out after ${TIMEOUT}s" >&2
        return 124
    fi

    # Extract output between START and END markers
    local output
    output=$(sed -n "/${MARKER}_START/,/${MARKER}_END/p" "$outfile" \
        | grep -v "${MARKER}_START" \
        | grep -v "${MARKER}_END")

    # Extract return code between END and RC markers
    local rc
    rc=$(sed -n "/${MARKER}_END/,/${MARKER}_RC/p" "$outfile" \
        | grep -v "${MARKER}_END" \
        | grep -v "${MARKER}_RC" \
        | tr -d '[:space:]')

    rm -f "$outfile" "$rcfile"

    # Output the command result
    [ -n "$output" ] && echo "$output"

    # Return the exit code from inside the VM
    return "${rc:-1}"
}

# Wait for VM login prompt (indicates boot complete)
wait_for_login() {
    local outfile
    outfile=$(mktemp /tmp/serial-wait.XXXXXX)
    local login_timeout="${SERIAL_LOGIN_TIMEOUT:-300}"

    echo "Waiting for VM login prompt (timeout: ${login_timeout}s)..."

    socat "$SOCAT_OPTS" - > "$outfile" 2>/dev/null &
    local listener_pid=$!

    local elapsed=0
    while [ $elapsed -lt "$login_timeout" ]; do
        if grep -qE "(login:|Welcome to)" "$outfile" 2>/dev/null; then
            echo "Login prompt detected after ${elapsed}s"
            kill "$listener_pid" 2>/dev/null || true
            wait "$listener_pid" 2>/dev/null || true
            rm -f "$outfile"

            # Send login credentials
            sleep 1
            serial_send "root\n"
            sleep 1
            serial_send "${VM_PASSWORD:-password}\n"
            sleep 2

            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    rm -f "$outfile"
    echo "ERROR: No login prompt after ${login_timeout}s" >&2
    return 1
}

# Transfer a file into the VM via serial using base64 encoding
send_file() {
    local local_path="$1"
    local remote_path="$2"

    if [ ! -f "$local_path" ]; then
        echo "ERROR: Local file not found: $local_path" >&2
        return 1
    fi

    echo "Sending $(basename "$local_path") -> $remote_path"

    # Base64-encode the file and send it in chunks via serial
    local b64
    b64=$(base64 -w0 "$local_path")
    local chunk_size=512
    local total=${#b64}
    local offset=0

    # Create/truncate the target b64 file
    serial_exec "rm -f /tmp/_serial_transfer.b64"

    # Send in chunks to avoid serial buffer overflow
    while [ $offset -lt $total ]; do
        local chunk="${b64:$offset:$chunk_size}"
        serial_exec "echo -n '${chunk}' >> /tmp/_serial_transfer.b64" >/dev/null
        offset=$((offset + chunk_size))
    done

    # Decode and move to final path
    serial_exec "mkdir -p \$(dirname '$remote_path') && base64 -d /tmp/_serial_transfer.b64 > '$remote_path' && rm -f /tmp/_serial_transfer.b64 && echo 'OK: $(basename "$local_path") transferred'"
}

# Main dispatch
case "${1:-}" in
    --wait-login)
        wait_for_login
        ;;
    --file)
        shift
        script_path="${1:?--file requires a script path}"
        if [ ! -f "$script_path" ]; then
            echo "ERROR: Script not found: $script_path" >&2
            exit 1
        fi
        serial_exec "$(cat "$script_path")"
        ;;
    --send-file)
        shift
        local_path="${1:?--send-file requires <local-path> <remote-path>}"
        remote_path="${2:?--send-file requires <local-path> <remote-path>}"
        send_file "$local_path" "$remote_path"
        ;;
    *)
        # Direct command execution
        serial_exec "$*"
        ;;
esac
