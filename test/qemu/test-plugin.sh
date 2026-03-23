#!/bin/bash
# Run smoke tests against the QEMU PVE VM via serial socket
#
# Usage: ./test-plugin.sh [socket-path]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOCKET="${1:-${SCRIPT_DIR}/pve-serial.sock}"
SERIAL="${SCRIPT_DIR}/serial-cmd.sh"
PASS=0
FAIL=0

if [ ! -S "$SOCKET" ]; then
    echo "ERROR: Serial socket not found at $SOCKET"
    echo "Start the VM first: ./run-pve-vm.sh"
    exit 1
fi

scmd() { bash "$SERIAL" "$SOCKET" "$@"; }

run_test() {
    local name="$1"
    shift
    echo -n "  TEST: $name ... "
    if scmd "$@" >/dev/null 2>&1; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
}

run_test_output() {
    local name="$1"
    local expected="$2"
    shift 2
    echo -n "  TEST: $name ... "
    local output
    output=$(scmd "$@" 2>/dev/null) || true
    if echo "$output" | grep -q "$expected"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (expected '$expected' in output)"
        echo "  Got: $output"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== PVE GPU Plugin Smoke Tests (via serial) ==="
echo ""

# Get hostname for API calls
HOSTNAME=$(scmd "hostname" 2>/dev/null | tr -d '[:space:]')
echo "VM hostname: $HOSTNAME"
echo ""

echo "--- Installation checks ---"
run_test "Perl module exists" "test -f /usr/share/perl5/PVE/API2/Hardware/GPU.pm"
run_test "JS plugin exists" "test -f /usr/share/pve-manager/js/pve-gpu-plugin.js"
run_test "Apply script exists" "test -x /usr/lib/pve-gpu/apply-sriov-config.sh"
run_test "JS patch applied" "grep -q pve-gpu-plugin /usr/share/pve-manager/index.html.tpl"
run_test "Nodes.pm patch applied" "grep -q GPU /usr/share/perl5/PVE/API2/Nodes.pm"
run_test "Systemd service enabled" "systemctl is-enabled pve-gpu-sriov.service"
run_test "Perl module loads" "perl -I/usr/share/perl5 -MPVE::API2::Hardware::GPU -e 1"

echo ""
echo "--- API endpoint tests ---"
run_test_output "List devices" "0000:03:00.0" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu --output-format json"
run_test_output "Device detail" "56c0" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:03:00.0 --output-format json"
run_test_output "Telemetry temp" "42" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:03:00.0 --output-format json"
run_test_output "SR-IOV status" "all_pass" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:03:00.0/sriov --output-format json"
run_test_output "BMG device listed" "0000:04:00.0" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu --output-format json"

echo ""
echo "--- VF lifecycle tests ---"
run_test "Create 2 VFs" \
    "pvesh create /nodes/$HOSTNAME/hardware/gpu/0000:03:00.0/sriov --num_vfs 2 --persist 1"
run_test_output "List VFs" "vf_index" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:03:00.0/vf --output-format json"
run_test_output "VF detail" "0000:03:00.1" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:03:00.0/vf/1 --output-format json"
run_test "Remove VFs" \
    "pvesh delete /nodes/$HOSTNAME/hardware/gpu/0000:03:00.0/sriov"

echo ""
echo "--- Persistence tests ---"
run_test "Config file exists" "test -f /etc/pve/local/gpu-sriov.conf"
run_test_output "Config has BDF" "0000:03:00.0" "cat /etc/pve/local/gpu-sriov.conf"

echo ""
echo "--- Fake sysfs integrity ---"
run_test_output "Fake vendor" "0x8086" "cat /tmp/fake-gpu/sys/bus/pci/devices/0000:03:00.0/vendor"
run_test_output "Fake device" "0x56c0" "cat /tmp/fake-gpu/sys/bus/pci/devices/0000:03:00.0/device"
run_test_output "Fake temp" "42000" "cat /tmp/fake-gpu/sys/class/drm/card0/device/hwmon/hwmon0/temp1_input"

echo ""
echo "--- Uninstall test ---"
run_test "Uninstall plugin" "dpkg -r pve-gpu-manager"
run_test "Perl module removed" "test ! -f /usr/share/perl5/PVE/API2/Hardware/GPU.pm"
run_test "JS patch reverted" "! grep -q pve-gpu-plugin /usr/share/pve-manager/index.html.tpl"
run_test "Nodes.pm patch reverted" "! grep -q GPU /usr/share/perl5/PVE/API2/Nodes.pm"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
