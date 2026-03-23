#!/bin/bash
# Creates a complete fake sysfs/procfs/debugfs tree for testing the PVE GPU plugin
# without requiring real Intel GPU hardware.
#
# Usage: setup-fake-sysfs.sh [--root DIR]
#   --root DIR: root of fake tree (default: /tmp/fake-gpu)

set -e

ROOT="/tmp/fake-gpu"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            ROOT="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

echo "Setting up fake sysfs tree at: $ROOT"

# Remove existing tree and recreate clean
if [ -d "$ROOT" ]; then
    rm -rf "$ROOT"
fi

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
mkfile() {
    local path="$1"
    local content="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
    chmod 666 "$path"   # simulate writable sysfs files
}

# ---------------------------------------------------------------------------
# /proc/cpuinfo
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/proc"
cat > "$ROOT/proc/cpuinfo" << 'EOF'
processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6
model		: 106
model name	: Intel(R) Xeon(R) Gold 6338N CPU @ 2.20GHz
stepping	: 6
microcode	: 0xd0003e9
cpu MHz		: 2200.000
cache size	: 48640 KB
physical id	: 0
siblings	: 4
core id		: 0
cpu cores	: 4
apicid		: 0
initial apicid	: 0
fpu		: yes
fpu_exception	: yes
cpuid level	: 27
wp		: yes
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc art arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni pclmulqdq dtes64 monitor ds_cpl vmx smx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid dca sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm 3dnowprefetch cpuid_fault epb cat_l3 cat_l2 cdp_l3 invpcid_single ssbd mba ibrs ibpb stibp ibrs_enhanced tpr_shadow vnmi flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid cqm rdt_a avx512f avx512dq rdseed adx smap avx512ifma clflushopt clwb intel_pt avx512cd sha_ni avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local split_lock_detect avx512_vpopcntdq avx512_vbmi2 avx512_vnni avx512_bitalg avx512_vp2intersect rdpid movdiri movdir64b md_clear ibt flush_l1d arch_capabilities
bogomips	: 4400.00
EOF
chmod 444 "$ROOT/proc/cpuinfo"

# ---------------------------------------------------------------------------
# IOMMU
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/sys/class/iommu/dmar0"

# ---------------------------------------------------------------------------
# Flex 170 GPU — BDF 0000:03:00.0
# ---------------------------------------------------------------------------
PF0="$ROOT/sys/bus/pci/devices/0000:03:00.0"
mkdir -p "$PF0"

mkfile "$PF0/vendor"                  "0x8086"
mkfile "$PF0/device"                  "0x56c0"
mkfile "$PF0/subsystem_vendor"        "0x8086"
mkfile "$PF0/subsystem_device"        "0x4905"
mkfile "$PF0/numa_node"               "0"
mkfile "$PF0/sriov_totalvfs"          "31"
mkfile "$PF0/sriov_numvfs"            "0"
mkfile "$PF0/sriov_drivers_autoprobe" "1"

# driver symlink: basename must be "i915"
mkdir -p "$ROOT/sys/module/i915"
# relative path from $PF0 up to ROOT/sys/module/i915
ln -sfn "../../../../module/i915" "$PF0/driver"

# drm render node (empty dir)
mkdir -p "$PF0/drm/renderD128"

# virtfn symlinks pointing at VF PCI device dirs (relative)
ln -sfn "../0000:03:00.1" "$PF0/virtfn0"
ln -sfn "../0000:03:00.2" "$PF0/virtfn1"
ln -sfn "../0000:03:00.3" "$PF0/virtfn2"
ln -sfn "../0000:03:00.4" "$PF0/virtfn3"

# hwmon under the PF device
mkdir -p "$PF0/hwmon/hwmon0"
mkfile "$PF0/hwmon/hwmon0/temp1_input"  "42000"
mkfile "$PF0/hwmon/hwmon0/power1_input" "65300000"

# VF PCI device stubs (with physfn symlink back to PF)
for bdf in 0000:03:00.1 0000:03:00.2 0000:03:00.3 0000:03:00.4; do
    VF="$ROOT/sys/bus/pci/devices/$bdf"
    mkdir -p "$VF"
    mkfile "$VF/vendor" "0x8086"
    mkfile "$VF/device" "0x56c0"
    ln -sfn "../0000:03:00.0" "$VF/physfn"
done

# DRM class entry for card0
mkdir -p "$ROOT/sys/class/drm/card0"
# card0/device -> the PF PCI device dir (absolute symlink for reliability)
ln -sfn "$PF0" "$ROOT/sys/class/drm/card0/device"
# card0 -> PCI device (canonical DRM sysfs layout)
ln -sfn "../../bus/pci/devices/0000:03:00.0" "$ROOT/sys/class/drm/card0/device_rel"

# SR-IOV IOV directory under card0
IOV="$ROOT/sys/class/drm/card0/iov"

# PF GT0 available resources
mkfile "$IOV/pf/gt0/available/lmem_free"      "16106127360"
mkfile "$IOV/pf/gt0/available/ggtt_free"      "4026531840"
mkfile "$IOV/pf/gt0/available/contexts_free"  "8192"
mkfile "$IOV/pf/gt0/available/doorbells_free" "480"

# VF slots vf1..vf4
for vf in vf1 vf2 vf3 vf4; do
    mkfile "$IOV/$vf/gt0/lmem_quota"         "0"
    mkfile "$IOV/$vf/gt0/ggtt_quota"         "0"
    mkfile "$IOV/$vf/gt0/exec_quantum_ms"    "0"
    mkfile "$IOV/$vf/gt0/preempt_timeout_us" "0"
done

# Also expose the IOV dir from the PCI device path (some drivers do both)
ln -sfn "$IOV" "$PF0/iov"

# ---------------------------------------------------------------------------
# BMG GPU — BDF 0000:04:00.0
# ---------------------------------------------------------------------------
PF1="$ROOT/sys/bus/pci/devices/0000:04:00.0"
mkdir -p "$PF1"

mkfile "$PF1/vendor"                  "0x8086"
mkfile "$PF1/device"                  "0xe211"
mkfile "$PF1/subsystem_vendor"        "0x8086"
mkfile "$PF1/subsystem_device"        "0x0000"
mkfile "$PF1/numa_node"               "0"
mkfile "$PF1/sriov_totalvfs"          "24"
mkfile "$PF1/sriov_numvfs"            "0"
mkfile "$PF1/sriov_drivers_autoprobe" "1"

# BMG uses the xe driver
mkdir -p "$ROOT/sys/module/xe"
ln -sfn "../../../../module/xe" "$PF1/driver"

mkdir -p "$PF1/drm/renderD129"

# DRM class entry for card1
mkdir -p "$ROOT/sys/class/drm/card1"
ln -sfn "$PF1" "$ROOT/sys/class/drm/card1/device"

# Debugfs paths for BMG
DBG="$ROOT/sys/kernel/debug/dri/0000:04:00.0"
mkfile "$DBG/gt0/vf1/lmem_quota" "0"
mkfile "$DBG/gt0/vf2/lmem_quota" "0"
mkfile "$DBG/gt0/pf/lmem_spare"  "134217728"
mkfile "$DBG/gt0/pf/lmem_provisioned" ""

# VRAM info
cat > "$DBG/vram0_mm" << 'VRAMEOF'
  use_type: 1
  use_tt: 0
  size: 25669140480
  usage: 134217728
default_page_size: 4KiB
VRAMEOF
chmod 666 "$DBG/vram0_mm"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Fake sysfs tree created at: $ROOT"
echo ""
echo "Devices:"
echo "  Flex 170 (0x56c0)  BDF=0000:03:00.0  card=card0  render=renderD128  driver=i915"
echo "    SR-IOV totalvfs=31  VF stubs: 0000:03:00.1..4 (with physfn)"
echo "    IOV: $IOV"
echo "    hwmon: temp=42°C  power=65.3W"
echo "  BMG    (0xe211)  BDF=0000:04:00.0  card=card1  render=renderD129  driver=xe"
echo "    SR-IOV totalvfs=24"
echo "    debugfs: $DBG  vram=25669140480 bytes"
echo ""
echo "Set PVE_GPU_SYSFS_ROOT=$ROOT to use this tree."
