# GPU Manager for Proxmox VE

A Proxmox VE plugin for Intel discrete GPU management with SR-IOV virtual function lifecycle management. Compatible with PVE 8.x and 9.x.

## Features

- **GPU Discovery** -- Automatic detection of Intel Flex, Ponte Vecchio, and Battlemage GPUs
- **Real-time Telemetry** -- Temperature (core & VRAM), power, clock speed, fan RPM, GPU utilization, memory usage
- **SR-IOV Management** -- Create, modify, and remove virtual functions with per-VF memory allocation
- **VM Tracking** -- Shows which VMs are assigned to GPU VFs (supports PVE resource mappings)
- **Health Monitoring** -- Temperature and throttle threshold alerts
- **Boot Persistence** -- VF configuration survives reboots via systemd service
- **Dark Mode** -- Follows PVE's Proxmox Dark theme
- **Firmware Info** -- Displays GuC firmware version

## Supported Hardware

| Family | Device IDs | Max VFs | Driver |
|--------|-----------|---------|--------|
| Flex (ATS-M) | 0x56c0, 0x56c1, 0x56c2 | 31 | i915 |
| Ponte Vecchio | 0x0bd4, 0x0bd5, 0x0bd6 | 62 | i915 |
| Ponte Vecchio Extended | 0x0bda, 0x0bdb, 0x0b6e | 63 | i915 |
| Battlemage | 0xe211, 0xe212, 0xe222 | 24 | xe |
| Battlemage (12VF) | 0xe223 | 12 | xe |

## Installation

### From GitHub Release

```bash
wget https://github.com/Azerothian/pmx-gpu-manager/releases/latest/download/pve-gpu-manager_1.0.0-1_all.deb
dpkg -i pve-gpu-manager_1.0.0-1_all.deb
```

### Build from Source

```bash
git clone https://github.com/Azerothian/pmx-gpu-manager.git
cd pmx-gpu-manager
make deb
dpkg -i ../pve-gpu-manager_*.deb
```

### Dependencies

- Proxmox VE >= 8.0
- Perl, libpve-common-perl, pciutils
- linux-perf (for GPU utilization monitoring)

## Usage

After installation, a **GPU** tab appears in the Proxmox web UI under each node. Select a node in the left sidebar and click the GPU section.

### GPU Devices Grid

Shows all detected Intel GPUs with:
- Core and VRAM temperatures
- Power consumption and clock speed
- GPU utilization percentage
- Fan speed and health status
- VRAM usage
- SR-IOV VF count and assigned VMs

### SR-IOV Virtual Functions

For SR-IOV capable GPUs, the VF management panel allows:
- **Modify VFs** -- Adjust VF count and per-VF memory allocation
- Per-VF LMEM displayed with assigned VM tracking
- Constraints enforced: cannot exceed max VFs, cannot remove assigned VFs, minimum 128MB per VF

### Telemetry Card

Detailed telemetry for the selected GPU:
- Temperature gauge (0-105C with color coding)
- Power draw (watts)
- Clock speed (current / max MHz)
- Fan speed (RPM)
- Local memory usage bar

## Uninstall

```bash
dpkg -r pve-gpu-manager
```

This cleanly removes the plugin, restores patched PVE files, and disables the systemd service.

## Development

### Project Structure

```
src/
  PVE/API2/Hardware/XPU.pm    # Perl backend (API endpoints)
  js/pve-xpu-plugin.js        # ExtJS frontend (UI plugin)
  scripts/                     # Boot persistence and patch scripts
  systemd/                     # Systemd service
config/                        # Default VF templates, APT hook
debian/                        # Debian packaging
t/                             # Perl unit tests
test/
  e2e/                         # Playwright UI tests
  fake-sysfs/                  # Fake sysfs tree for testing
  qemu/                        # QEMU-based integration tests
scripts/
  e2e.sh                       # Automated end-to-end test runner
```

### Running Tests

```bash
# Unit tests
make test

# Full e2e tests (requires QEMU + PVE ISO)
bash scripts/e2e.sh

# Playwright UI tests (requires running PVE VM)
cd test/e2e && npm install && npx playwright test
```

### API Endpoints

All endpoints are under `/api2/json/nodes/{node}/hardware/xpu/`:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | List GPU devices with telemetry |
| GET | `/{bdf}` | Device detail |
| GET | `/{bdf}/sriov` | SR-IOV status and prechecks |
| POST | `/{bdf}/sriov` | Create/modify virtual functions |
| DELETE | `/{bdf}/sriov` | Remove virtual functions |
| GET | `/{bdf}/vf` | List virtual functions |
| GET | `/{bdf}/vf/{index}` | VF detail |

## License

See [LICENSE](LICENSE) for details.
