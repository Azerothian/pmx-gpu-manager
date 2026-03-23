package PVE::API2::Hardware::GPU;

use strict;
use warnings;
use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::RESTHandler);
use Fcntl qw(O_WRONLY O_RDONLY);
use File::Basename;
use File::Glob ':bsd_glob';
use PVE::Tools qw(run_command file_get_contents file_set_contents);

# ---------------------------------------------------------------------------
# Vendor plugin registry
# ---------------------------------------------------------------------------
my %VENDOR_PLUGINS;

sub register_vendor {
    my ($vendor_id, $plugin) = @_;
    $VENDOR_PLUGINS{lc($vendor_id)} = $plugin;
}

sub get_vendor_plugin {
    my ($vendor_id) = @_;
    $vendor_id =~ s/^0x//;
    return $VENDOR_PLUGINS{lc($vendor_id)};
}

# Load vendor plugins (they register themselves on use)
use PVE::API2::Hardware::GPU::Intel;
use PVE::API2::Hardware::GPU::Nvidia;

# BDF format regex
my $BDF_RE = '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]';

# Config paths
my $GPU_SRIOV_CONF      = '/etc/pve/local/gpu-sriov.conf';
my $GPU_VF_TEMPLATES    = '/etc/pve/local/gpu-vf-templates.conf';

# ---------------------------------------------------------------------------
# Fake sysfs helper
# ---------------------------------------------------------------------------
my $_sysfs_root_cache;
my $_sysfs_root_conf = '/etc/pve-gpu-sysfs-root';

sub _get_sysfs_root {
    return $_sysfs_root_cache if defined $_sysfs_root_cache;

    # Check env var first (works for CLI tools, tests)
    if (my $root = $ENV{PVE_GPU_SYSFS_ROOT}) {
        $root =~ s{/$}{};
        $_sysfs_root_cache = $root;
        return $root;
    }

    # Fallback: read from config file (works inside pvedaemon which clears env)
    if (-f $_sysfs_root_conf) {
        if (open(my $fh, '<', $_sysfs_root_conf)) {
            my $root = <$fh>;
            close($fh);
            if (defined $root) {
                chomp $root;
                $root =~ s{/$}{};
                if ($root ne '' && -d $root) {
                    $_sysfs_root_cache = $root;
                    return $root;
                }
            }
        }
    }

    $_sysfs_root_cache = '';
    return '';
}

sub sysfs_path {
    my ($path) = @_;
    my $root = _get_sysfs_root();
    return "$root$path" if $root;
    return $path;
}

# ---------------------------------------------------------------------------
# Sysfs I/O helpers
# ---------------------------------------------------------------------------
sub read_sysfs {
    my ($path) = @_;
    my $full = sysfs_path($path);
    return undef unless -e $full;
    open(my $fh, '<', $full) or return undef;
    my $val = <$fh>;
    close($fh);
    return undef unless defined $val;
    chomp $val;
    return $val;
}

sub write_sysfs {
    my ($path, $value) = @_;
    my $full = sysfs_path($path);
    sysopen(my $fh, $full, O_WRONLY)
        or die "Cannot open sysfs '$full' for writing: $!\n";
    print $fh $value
        or die "Cannot write to sysfs '$full': $!\n";
    close($fh)
        or die "Cannot close sysfs '$full': $!\n";
    return 1;
}

# ---------------------------------------------------------------------------
# Resolve DRM card name from BDF
# ---------------------------------------------------------------------------
sub resolve_drm_card {
    my ($bdf) = @_;
    # BDF comes in domain:bus:dev.fn form, e.g. 0000:03:00.0
    # The symlink in /sys/class/drm/card*/device resolves to a PCI path
    # whose last component is the BDF (without domain in some kernels).
    my $base = sysfs_path('/sys/class/drm');
    my @cards = bsd_glob("$base/card*/device");
    for my $link (@cards) {
        my $target = readlink($link);
        next unless defined $target;
        # Normalise: strip leading path components
        my $dev_bdf = basename($target);
        if ($dev_bdf eq $bdf) {
            # Return just "cardN"
            my $card_path = dirname($link);
            return basename($card_path);
        }
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Run pre-flight checks
# ---------------------------------------------------------------------------
sub run_prechecks {
    my ($bdf, $card, $vendor_id) = @_;

    my %checks;
    my $all_pass = 1;

    # 1. CPU virtualisation (vmx = Intel VT-x, svm = AMD-V)
    {
        my $cpuinfo = '';
        eval { $cpuinfo = file_get_contents('/proc/cpuinfo') // '' };
        my $pass = ($cpuinfo =~ /\b(vmx|svm)\b/) ? 1 : 0;
        $all_pass = 0 unless $pass;
        $checks{cpu_virtualization} = {
            pass   => $pass ? \1 : \0,
            detail => $pass
                ? 'CPU virtualization extensions present'
                : 'No vmx/svm flag found in /proc/cpuinfo',
        };
    }

    # 2. IOMMU: at least one entry under /sys/class/iommu/
    {
        my @iommu = bsd_glob(sysfs_path('/sys/class/iommu') . '/*');
        my $pass = (@iommu > 0) ? 1 : 0;
        $all_pass = 0 unless $pass;
        $checks{iommu} = {
            pass   => $pass ? \1 : \0,
            detail => $pass
                ? sprintf('%d IOMMU group(s) found', scalar @iommu)
                : 'No IOMMU groups found — enable IOMMU in BIOS/kernel',
        };
    }

    # 3. SR-IOV BIOS support: sriov_maxvfs > 0
    {
        my $totalvfs_path = "/sys/bus/pci/devices/$bdf/sriov_totalvfs";
        my $totalvfs = read_sysfs($totalvfs_path) // 0;
        my $pass = ($totalvfs > 0) ? 1 : 0;
        $all_pass = 0 unless $pass;
        $checks{sriov_bios} = {
            pass   => $pass ? \1 : \0,
            detail => $pass
                ? "sriov_maxvfs=$totalvfs"
                : 'sriov_maxvfs is 0 — SR-IOV not supported by firmware',
        };
    }

    # 4. GPU kernel driver bound — delegate to vendor plugin
    {
        my $driver_link = sysfs_path("/sys/bus/pci/devices/$bdf/driver");
        my $driver = '';
        if (-l $driver_link) {
            $driver = basename(readlink($driver_link) // '');
        }

        my $plugin = get_vendor_plugin($vendor_id);
        if ($plugin) {
            my $driver_check = $plugin->run_prechecks($bdf, $card, $driver);
            $all_pass = 0 unless $driver_check->{pass};
            $checks{gpu_driver} = $driver_check;
        } else {
            # Fallback: just report the driver
            $checks{gpu_driver} = {
                pass   => $driver ne '' ? \1 : \0,
                detail => $driver ne '' ? "$driver driver bound" : 'No driver bound',
            };
            $all_pass = 0 unless $driver ne '';
        }
    }

    return {
        checks   => \%checks,
        all_pass => $all_pass ? \1 : \0,
    };
}

# ---------------------------------------------------------------------------
# INI config helpers
# ---------------------------------------------------------------------------
sub parse_ini_config {
    my ($path) = @_;
    my %data;
    return \%data unless -f $path;

    open(my $fh, '<', $path) or return \%data;
    my $section = '__global__';
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        next if $line =~ /^#/;
        if ($line =~ /^\[(.+)\]$/) {
            $section = $1;
            $data{$section} //= {};
        } elsif ($line =~ /^([^=]+?)\s*=\s*(.*)$/) {
            $data{$section}{$1} = $2;
        }
    }
    close($fh);
    return \%data;
}

sub write_ini_config {
    my ($path, $data) = @_;
    my $tmp = "$path.tmp.$$";
    open(my $fh, '>', $tmp)
        or die "Cannot write config to '$tmp': $!\n";

    for my $section (sort keys %$data) {
        next if $section eq '__global__';
        print $fh "[$section]\n";
        for my $key (sort keys %{$data->{$section}}) {
            print $fh "$key = $data->{$section}{$key}\n";
        }
        print $fh "\n";
    }
    close($fh);
    rename($tmp, $path)
        or die "Cannot rename '$tmp' to '$path': $!\n";
    return 1;
}

# ---------------------------------------------------------------------------
# Get VF quota file paths — delegated to vendor plugin
# ---------------------------------------------------------------------------
sub get_vf_paths {
    my ($family, $card, $bdf, $vf_index, $tile, $vendor_id) = @_;

    my $plugin = get_vendor_plugin($vendor_id);
    return $plugin->get_vf_paths($family, $card, $bdf, $vf_index, $tile) if $plugin;
    return undef;
}

# ---------------------------------------------------------------------------
# Check if a specific BDF is assigned to any VM (direct or via mapping)
# Returns vmid if assigned, undef otherwise
# ---------------------------------------------------------------------------
sub _find_bdf_vm_assignment {
    my ($target_bdf) = @_;

    # Build mapping name → BDF lookup
    my %mapping_to_bdf;
    my $mapping_file = '/etc/pve/mapping/pci.cfg';
    if (open(my $mfh, '<', $mapping_file)) {
        my $current_name;
        while (my $line = <$mfh>) {
            chomp $line;
            if ($line =~ /^(\S+)\s*$/) {
                $current_name = $1;
            } elsif ($line =~ /^\s+map\s+.*path=([0-9a-fA-F:\.]+)/ && defined $current_name) {
                $mapping_to_bdf{$current_name} = $1;
            }
        }
        close($mfh);
    }

    my @conf_files = bsd_glob('/etc/pve/qemu-server/*.conf');
    for my $conf (@conf_files) {
        my ($vmid) = basename($conf) =~ /^(\d+)\.conf$/;
        next unless defined $vmid;
        open(my $fh, '<', $conf) or next;
        while (my $line = <$fh>) {
            next unless $line =~ /^hostpci\d+:\s*(.+)/;
            my $val = $1;
            chomp $val;

            my $resolved_bdf;
            if ($val =~ /mapping=(\S+)/) {
                my $name = $1;
                $name =~ s/,.*//;
                $resolved_bdf = $mapping_to_bdf{$name};
            } else {
                ($resolved_bdf) = $val =~ /^([0-9a-fA-F:\.]+)/;
            }

            if (defined $resolved_bdf && $resolved_bdf eq $target_bdf) {
                close($fh);
                return int($vmid);
            }
        }
        close($fh);
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Check VF→VM assignments
# Returns arrayref of { vf_index, bdf, vmid } for assigned VFs
# ---------------------------------------------------------------------------
sub check_vf_vm_assignments {
    my ($bdf, $card, $num_vfs) = @_;

    # Build mapping name → BDF lookup from PVE resource mappings
    my %mapping_to_bdf;
    my $mapping_file = '/etc/pve/mapping/pci.cfg';
    if (open(my $mfh, '<', $mapping_file)) {
        my $current_name;
        while (my $line = <$mfh>) {
            chomp $line;
            if ($line =~ /^(\S+)\s*$/) {
                $current_name = $1;
            } elsif ($line =~ /^\s+map\s+.*path=([0-9a-fA-F:\.]+)/ && defined $current_name) {
                $mapping_to_bdf{$current_name} = $1;
            }
        }
        close($mfh);
    }

    # Collect all VF BDFs
    my %vf_bdf_to_index;
    for my $vf_index (1 .. $num_vfs) {
        my $virtfn_link = sysfs_path(
            "/sys/bus/pci/devices/$bdf/virtfn" . ($vf_index - 1)
        );
        my $vf_target = readlink($virtfn_link);
        next unless defined $vf_target;
        my $vf_bdf = basename($vf_target);
        $vf_bdf_to_index{$vf_bdf} = $vf_index;
    }

    my @assigned;
    my @conf_files = bsd_glob('/etc/pve/qemu-server/*.conf');
    for my $conf (@conf_files) {
        my ($vmid) = basename($conf) =~ /^(\d+)\.conf$/;
        next unless defined $vmid;
        open(my $fh, '<', $conf) or next;
        while (my $line = <$fh>) {
            next unless $line =~ /^hostpci\d+:\s*(.+)/;
            my $val = $1;
            chomp $val;

            my $resolved_bdf;
            if ($val =~ /mapping=(\S+)/) {
                # Resolve resource mapping to BDF
                my $name = $1;
                $name =~ s/,.*//;  # strip trailing options
                $resolved_bdf = $mapping_to_bdf{$name};
            } else {
                # Direct BDF reference (strip options after comma)
                ($resolved_bdf) = $val =~ /^([0-9a-fA-F:\.]+)/;
            }

            next unless defined $resolved_bdf;

            # Check if this BDF matches any of our VFs
            if (exists $vf_bdf_to_index{$resolved_bdf}) {
                push @assigned, {
                    vf_index => $vf_bdf_to_index{$resolved_bdf},
                    bdf      => $resolved_bdf,
                    vmid     => int($vmid),
                };
            }
            # Also check if PF itself is assigned (whole GPU passthrough)
            if ($resolved_bdf eq $bdf) {
                push @assigned, {
                    vf_index => 0,
                    bdf      => $resolved_bdf,
                    vmid     => int($vmid),
                };
            }
        }
        close($fh);
    }

    return \@assigned;
}

# ---------------------------------------------------------------------------
# Internal helper: get device name via lspci, fallback to static map
# ---------------------------------------------------------------------------
sub _get_device_name {
    my ($bdf, $device_id, $vendor_id) = @_;
    my $name;
    eval {
        my $output = '';
        run_command(['lspci', '-s', $bdf, '-mm'],
            outfunc => sub { $output .= $_[0] . "\n" },
            errfunc => sub { },
        );
        # lspci -mm output: "Slot" "Class" "Vendor" "Device" ...
        # Fields are double-quoted and tab/newline separated
        if ($output =~ /"Device"\s+"([^"]+)"/ ||
            $output =~ /^[^\n]*\t[^\n]*\t[^\n]*\t"?([^"\n]+)"?/m) {
            $name = $1;
        }
    };
    return $name if defined $name && $name ne '';

    my $plugin = get_vendor_plugin($vendor_id);
    if ($plugin && $plugin->can('device_name_fallback')) {
        return $plugin->device_name_fallback($device_id);
    }
    return "GPU ($device_id)";
}

# ---------------------------------------------------------------------------
# Internal helper: check if device has SR-IOV capability via lspci
# ---------------------------------------------------------------------------
sub _has_sriov_cap {
    my ($bdf) = @_;

    # First check sriov_maxvfs in sysfs — works for both i915 and xe drivers
    my $totalvfs = read_sysfs("/sys/bus/pci/devices/$bdf/sriov_totalvfs");
    return 1 if defined $totalvfs && $totalvfs =~ /^\d+$/ && $totalvfs > 0;

    # Fallback: check lspci for SR-IOV capability
    my $found = 0;
    eval {
        run_command(['lspci', '-vs', $bdf],
            outfunc => sub {
                $found = 1 if $_[0] =~ /Single Root I\/O Virtualization/i;
            },
            errfunc => sub { },
        );
    };
    return $found;
}

# ---------------------------------------------------------------------------
# Internal: collect full device record from sysfs for a given BDF
# Returns undef if device is not found or not an Intel GPU
# ---------------------------------------------------------------------------
sub _collect_device {
    my ($bdf, $with_telemetry) = @_;

    my $base = "/sys/bus/pci/devices/$bdf";

    # Skip SR-IOV Virtual Functions — they share the PF's device ID
    # but must not appear as standalone GPU devices.
    return undef if -l sysfs_path("$base/physfn");

    my $vendor_id  = read_sysfs("$base/vendor")    // '';
    my $plugin = get_vendor_plugin($vendor_id);
    return undef unless defined $plugin;

    my $device_id  = read_sysfs("$base/device")    // '';
    my $info = $plugin->identify_device($device_id);
    return undef unless defined $info;

    my $card = resolve_drm_card($bdf);

    my $subsystem_vendor = read_sysfs("$base/subsystem_vendor") // '';
    my $subsystem_device = read_sysfs("$base/subsystem_device") // '';
    my $numa_node        = read_sysfs("$base/numa_node")        // -1;
    my $sriov_maxvfs   = read_sysfs("$base/sriov_totalvfs")   // 0;
    my $sriov_numvfs     = read_sysfs("$base/sriov_numvfs")     // 0;

    my $driver = '';
    my $driver_link = sysfs_path("$base/driver");
    if (-l $driver_link) {
        $driver = basename(readlink($driver_link) // '');
    }

    my $render_node = undef;
    if (defined $card) {
        # renderD* usually sits alongside card* in /sys/class/drm
        my $render_base = sysfs_path('/sys/class/drm');
        my @renders = bsd_glob("$render_base/renderD*");
        for my $rlink (@renders) {
            my $rtarget = readlink("$rlink/device");
            if (defined $rtarget && basename($rtarget) eq $bdf) {
                $render_node = basename($rlink);
                last;
            }
        }
    }

    my $norm_device_id = lc($device_id);
    $norm_device_id = "0x$norm_device_id" unless $norm_device_id =~ /^0x/;
    my $device_name = _get_device_name($bdf, $norm_device_id, $vendor_id);

    # Check persistence
    my $persist_config = parse_ini_config($GPU_SRIOV_CONF);
    my $persisted = (exists $persist_config->{$bdf}) ? \1 : \0;

    my $sriov_capable = _has_sriov_cap($bdf) ? \1 : \0;

    my $record = {
        bdf              => $bdf,
        vendor_id        => $vendor_id,
        device_id        => $norm_device_id,
        subsystem_vendor => $subsystem_vendor,
        subsystem_device => $subsystem_device,
        device_name      => $device_name,
        family           => $info->{family},
        max_vfs          => $info->{max_vfs},
        tiles            => $info->{tiles},
        driver           => $driver,
        numa_node        => int($numa_node),
        sriov_capable    => $sriov_capable,
        sriov_maxvfs   => int($sriov_maxvfs),
        sriov_numvfs     => int($sriov_numvfs),
        drm_card         => $card // '',
        render_node      => $render_node // '',
        persisted        => $persisted,
    };

    # Check VFIO persistence file for this device's BDF
    my $vfio_bdfs = _read_vfio_bdfs();
    $record->{vfio_configured} = (grep { $_ eq $bdf } @$vfio_bdfs) ? \1 : \0;

    # Check if PF itself is assigned to a VM (whole-GPU passthrough)
    my $pf_vm = _find_bdf_vm_assignment($bdf);
    $record->{pf_assigned} = defined $pf_vm ? \1 : \0;
    $record->{pf_vmid} = $pf_vm;

    # Get VMs assigned to this GPU's VFs
    if (int($sriov_numvfs) > 0 && defined $card) {
        my $assigned = check_vf_vm_assignments($bdf, $card, int($sriov_numvfs));
        my %seen;
        # Include PF VM if assigned
        $seen{$pf_vm} = 1 if defined $pf_vm;
        my @vm_ids = defined $pf_vm ? ($pf_vm) : ();
        push @vm_ids, grep { !$seen{$_}++ } map { $_->{vmid} } @$assigned;
        $record->{assigned_vms} = \@vm_ids;
    } else {
        $record->{assigned_vms} = defined $pf_vm ? [$pf_vm] : [];
    }

    # Read firmware version from vendor plugin
    if (defined $bdf) {
        $record->{firmware_version} = $plugin->read_firmware_version($bdf) // '';
    }

    if ($with_telemetry && defined $card) {
        $record->{telemetry} = $plugin->read_telemetry($card, $bdf, $driver);
    }

    return $record;
}

# ---------------------------------------------------------------------------
# Internal: enumerate all supported GPU devices on the system
# ---------------------------------------------------------------------------
sub _enumerate_devices {
    my @devices;
    my @pci_devs = bsd_glob(sysfs_path('/sys/bus/pci/devices') . '/*');
    for my $dev_path (@pci_devs) {
        my $bdf = basename($dev_path);
        next unless $bdf =~ /^$BDF_RE$/o;
        my $rec = _collect_device($bdf, 1);
        push @devices, $rec if defined $rec;
    }
    return sort { $a->{bdf} cmp $b->{bdf} } @devices;
}

# ---------------------------------------------------------------------------
# Internal: read available resources for a PF tile
# ---------------------------------------------------------------------------
sub _read_pf_available {
    my ($card, $tile) = @_;
    my $base = "/sys/class/drm/$card/iov/pf/gt$tile/available";
    return {
        lmem_free   => int(read_sysfs("$base/lmem_free")   // 0),
        ggtt_free   => int(read_sysfs("$base/ggtt_free")   // 0),
        contexts    => int(read_sysfs("$base/contexts")    // 0),
        doorbells   => int(read_sysfs("$base/doorbells")   // 0),
    };
}

# ---------------------------------------------------------------------------
# API endpoint definitions
# ---------------------------------------------------------------------------

__PACKAGE__->register_method({
    name        => 'list_devices',
    path        => '',
    method      => 'GET',
    description => 'List Intel discrete GPU devices on this node.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type  => 'array',
        items => { type => 'object' },
        links => [{ rel => 'child', href => '{bdf}' }],
    },
    code => sub {
        my ($param) = @_;
        my @devices = _enumerate_devices();
        return \@devices;
    },
});

__PACKAGE__->register_method({
    name        => 'device_detail',
    path        => '{bdf}',
    method      => 'GET',
    description => 'Get detailed information for a specific GPU device, including telemetry.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI Bus:Device.Function address (e.g. 0000:03:00.0)',
                pattern     => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $bdf = $param->{bdf};
        my $rec = _collect_device($bdf, 1);
        die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;
        return $rec;
    },
});

__PACKAGE__->register_method({
    name        => 'sriov_status',
    path        => '{bdf}/sriov',
    method      => 'GET',
    description => 'Get SR-IOV status, pre-flight checks, and available resources for a GPU.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI BDF address',
                pattern     => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $bdf = $param->{bdf};

        my $rec = _collect_device($bdf, 0);
        die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;

        my $card        = $rec->{drm_card};
        my $prechecks   = run_prechecks($bdf, $card, $rec->{vendor_id});

        # Available resources per tile
        my @tile_resources;
        if (defined $card && $card ne '') {
            for my $t (0 .. ($rec->{tiles} - 1)) {
                my $avail = _read_pf_available($card, $t);
                $avail->{tile} = $t;
                push @tile_resources, $avail;
            }
        }

        # Load persisted config
        my $persist_config = parse_ini_config($GPU_SRIOV_CONF);
        my $persisted_section = $persist_config->{$bdf};

        # Drift detection
        my $drift = \0;
        if (defined $persisted_section && defined $persisted_section->{num_vfs}) {
            my $persisted_num_vfs = int($persisted_section->{num_vfs});
            my $current_num_vfs  = int($rec->{sriov_numvfs});
            $drift = \1 if $persisted_num_vfs != $current_num_vfs;
        }

        return {
            bdf             => $bdf,
            prechecks       => $prechecks,
            sriov_numvfs    => int($rec->{sriov_numvfs}),
            sriov_maxvfs  => int($rec->{sriov_maxvfs}),
            tile_resources  => \@tile_resources,
            persisted_config => $persisted_section // {},
            config_drift    => $drift,
        };
    },
});

__PACKAGE__->register_method({
    name        => 'create_vfs',
    path        => '{bdf}/sriov',
    method      => 'POST',
    description => 'Create SR-IOV Virtual Functions for an GPU device.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            bdf     => {
                type        => 'string',
                description => 'PCI BDF address',
                pattern     => $BDF_RE,
            },
            num_vfs => {
                type        => 'integer',
                description => 'Number of VFs to create (0 to remove all)',
                minimum     => 0,
            },
            template => {
                type        => 'string',
                description => 'Name of VF quota template to apply',
                optional    => 1,
            },
            lmem_per_vf => {
                type        => 'integer',
                description => 'Local memory per VF in bytes',
                optional    => 1,
            },
            ggtt_per_vf => {
                type        => 'integer',
                description => 'GGTT aperture per VF in bytes',
                optional    => 1,
            },
            contexts_per_vf => {
                type        => 'integer',
                description => 'GPU contexts per VF',
                optional    => 1,
            },
            doorbells_per_vf => {
                type        => 'integer',
                description => 'Doorbells per VF',
                optional    => 1,
            },
            exec_quantum_ms => {
                type        => 'integer',
                description => 'Execution quantum in milliseconds',
                optional    => 1,
                default     => 20,
            },
            preempt_timeout_us => {
                type        => 'integer',
                description => 'Preemption timeout in microseconds',
                optional    => 1,
                default     => 1000,
            },
            drivers_autoprobe => {
                type        => 'boolean',
                description => 'Automatically probe drivers for VFs',
                optional    => 1,
                default     => 0,
            },
            persist => {
                type        => 'boolean',
                description => 'Save configuration to persist across reboots',
                optional    => 1,
                default     => 1,
            },
        },
    },
    returns => {
        type  => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;
        my $bdf = $param->{bdf};

        my $rec = _collect_device($bdf, 0);
        die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;

        my $family    = $rec->{family};
        my $card      = $rec->{drm_card};
        my $vid       = $rec->{vendor_id};
        my $num_vfs   = int($param->{num_vfs});
        my $max_vfs   = int($rec->{max_vfs});
        my $tiles     = int($rec->{tiles});

        die "Requested $num_vfs VFs exceeds device maximum $max_vfs\n"
            if $num_vfs > $max_vfs;

        # Handle num_vfs=0: remove all VFs
        if ($num_vfs == 0) {
            eval { write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0) };
            die "Failed to remove VFs: $@\n" if $@;
            my $config = parse_ini_config($GPU_SRIOV_CONF);
            delete $config->{$bdf};
            write_ini_config($GPU_SRIOV_CONF, $config);
            return { removed => 1 };
        }

        # Pre-flight checks
        my $prechecks = run_prechecks($bdf, $card, $vid);
        unless ($prechecks->{all_pass}) {
            my @failures;
            for my $check (sort keys %{$prechecks->{checks}}) {
                my $c = $prechecks->{checks}{$check};
                push @failures, "$check: $c->{detail}" unless $c->{pass};
            }
            die "Pre-flight checks failed: " . join('; ', @failures) . "\n";
        }

        my $exec_quantum_ms    = $param->{exec_quantum_ms}    // 20;
        my $preempt_timeout_us = $param->{preempt_timeout_us} // 1000;
        my $drivers_autoprobe  = $param->{drivers_autoprobe}  ? 1 : 0;
        my $do_persist         = defined $param->{persist} ? $param->{persist} : 1;

        # Resolve quotas: template > explicit params > even-split
        my ($lmem_per_vf, $ggtt_per_vf, $contexts_per_vf, $doorbells_per_vf);

        if (defined $param->{template}) {
            my $templates = parse_ini_config($GPU_VF_TEMPLATES);
            my $tmpl = $templates->{$param->{template}};
            die "Template '$param->{template}' not found in $GPU_VF_TEMPLATES\n"
                unless defined $tmpl;
            $lmem_per_vf      = $tmpl->{lmem_per_vf};
            $ggtt_per_vf      = $tmpl->{ggtt_per_vf};
            $contexts_per_vf  = $tmpl->{contexts_per_vf};
            $doorbells_per_vf = $tmpl->{doorbells_per_vf};
        }

        # Override with explicit params if provided
        $lmem_per_vf      = $param->{lmem_per_vf}      if defined $param->{lmem_per_vf};
        $ggtt_per_vf      = $param->{ggtt_per_vf}      if defined $param->{ggtt_per_vf};
        $contexts_per_vf  = $param->{contexts_per_vf}  if defined $param->{contexts_per_vf};
        $doorbells_per_vf = $param->{doorbells_per_vf} if defined $param->{doorbells_per_vf};

        # Even-split from tile 0 available resources if still not set
        if (!defined $lmem_per_vf || !defined $ggtt_per_vf ||
            !defined $contexts_per_vf || !defined $doorbells_per_vf)
        {
            if (defined $card && $card ne '') {
                my $avail = _read_pf_available($card, 0);
                $lmem_per_vf      //= int($avail->{lmem_free}  / $num_vfs);
                $ggtt_per_vf      //= int($avail->{ggtt_free}  / $num_vfs);
                $contexts_per_vf  //= int($avail->{contexts}   / $num_vfs);
                $doorbells_per_vf //= int($avail->{doorbells}  / $num_vfs);
            } else {
                $lmem_per_vf      //= 0;
                $ggtt_per_vf      //= 0;
                $contexts_per_vf  //= 0;
                $doorbells_per_vf //= 0;
            }
        }

        # Validate totals for each tile (only when availability data exists)
        for my $t (0 .. ($tiles - 1)) {
            next unless defined $card && $card ne '';
            my $avail = _read_pf_available($card, $t);

            # Skip validation if availability paths don't exist (xe driver / BMG)
            next if !$avail->{lmem_free} && !$avail->{ggtt_free};

            if ($avail->{lmem_free} && $lmem_per_vf * $num_vfs > $avail->{lmem_free}) {
                die sprintf(
                    "lmem request (%d x %d = %d) exceeds available %d on tile %d\n",
                    $lmem_per_vf, $num_vfs, $lmem_per_vf * $num_vfs,
                    $avail->{lmem_free}, $t
                );
            }
            if ($avail->{ggtt_free} && $ggtt_per_vf * $num_vfs > $avail->{ggtt_free}) {
                die sprintf(
                    "ggtt request (%d x %d = %d) exceeds available %d on tile %d\n",
                    $ggtt_per_vf, $num_vfs, $ggtt_per_vf * $num_vfs,
                    $avail->{ggtt_free}, $t
                );
            }
        }

        my $current_numvfs = int(read_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs") // 0);

        if ($num_vfs < $current_numvfs) {
            # DECREASE: write 0 first (kernel requires it), then new count
            # Set memory quotas for remaining VFs first (decrease, then adjust)
            eval { write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0) };
            die "Failed to remove VFs for decrease: $@\n" if $@;

            # Set quotas for new (lower) count
            eval {
                for my $vf (1 .. $num_vfs) {
                    for my $t (0 .. ($tiles - 1)) {
                        my $paths = get_vf_paths($family, $card, $bdf, $vf, $t, $vid);
                        write_sysfs($paths->{lmem_quota},         $lmem_per_vf);
                        write_sysfs($paths->{ggtt_quota},         $ggtt_per_vf);
                        write_sysfs($paths->{exec_quantum_ms},    $exec_quantum_ms);
                        write_sysfs($paths->{preempt_timeout_us}, $preempt_timeout_us);
                    }
                }
            };
            die "Failed to programme VF quotas: $@\n" if $@;

            # Re-enable with lower count
            eval { write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", $num_vfs) };
            die "Failed to set VF count: $@\n" if $@;

        } elsif ($num_vfs > $current_numvfs) {
            # INCREASE: xe/i915 drivers require writing 0 before any count change
            # Try in-place increase first; if it fails, reset and re-enable
            my $needs_reset = 0;
            eval { write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", $num_vfs) };
            if ($@) {
                # In-place increase not supported — must go through 0
                $needs_reset = 1;
            } else {
                # In-place increase succeeded — verify
                my $check = int(read_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs") // 0);
                $needs_reset = 1 if $check != $num_vfs;
            }

            if ($needs_reset) {
                # Reset to 0, set quotas for all VFs, then re-enable
                eval { write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0) };
                die "Failed to reset VF count for increase: $@\n" if $@;

                # Set quotas for all VFs (smallest to largest for new ones)
                eval {
                    for my $vf (1 .. $num_vfs) {
                        for my $t (0 .. ($tiles - 1)) {
                            my $paths = get_vf_paths($family, $card, $bdf, $vf, $t, $vid);
                            write_sysfs($paths->{lmem_quota},         $lmem_per_vf);
                            write_sysfs($paths->{ggtt_quota},         $ggtt_per_vf);
                            write_sysfs($paths->{exec_quantum_ms},    $exec_quantum_ms);
                            write_sysfs($paths->{preempt_timeout_us}, $preempt_timeout_us);
                        }
                    }
                };
                die "Failed to programme VF quotas: $@\n" if $@;

                eval { write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", $num_vfs) };
                if ($@) {
                    eval { write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0) };
                    die "Failed to increase VF count: $@\n";
                }
            }

            # Set quotas on all VFs (they exist now)
            eval {
                for my $vf (1 .. $num_vfs) {
                    for my $t (0 .. ($tiles - 1)) {
                        my $paths = get_vf_paths($family, $card, $bdf, $vf, $t, $vid);
                        write_sysfs($paths->{lmem_quota},         $lmem_per_vf);
                        write_sysfs($paths->{ggtt_quota},         $ggtt_per_vf);
                    }
                }
            };
            # Non-fatal: best-effort quota assignment

        } else {
            # SAME COUNT: just adjust quotas
            eval {
                for my $vf (1 .. $num_vfs) {
                    for my $t (0 .. ($tiles - 1)) {
                        my $paths = get_vf_paths($family, $card, $bdf, $vf, $t, $vid);
                        write_sysfs($paths->{lmem_quota},         $lmem_per_vf);
                        write_sysfs($paths->{ggtt_quota},         $ggtt_per_vf);
                        write_sysfs($paths->{exec_quantum_ms},    $exec_quantum_ms);
                        write_sysfs($paths->{preempt_timeout_us}, $preempt_timeout_us);
                    }
                }
            };
            die "Failed to programme VF quotas: $@\n" if $@;
        }

        # Set drivers_autoprobe
        eval {
            write_sysfs(
                "/sys/bus/pci/devices/$bdf/sriov_drivers_autoprobe",
                $drivers_autoprobe
            );
        };
        # Non-fatal if path doesn't exist on older kernels

        # Verify
        my $actual_numvfs = int(read_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs") // 0);
        unless ($actual_numvfs == $num_vfs) {
            die "VF count verification failed: requested $num_vfs, got $actual_numvfs\n";
        }

        # Persist configuration
        if ($do_persist) {
            my $config = parse_ini_config($GPU_SRIOV_CONF);
            $config->{$bdf} = {
                persist            => 1,
                num_vfs            => $num_vfs,
                lmem_per_vf        => $lmem_per_vf,
                ggtt_per_vf        => $ggtt_per_vf,
                contexts_per_vf    => $contexts_per_vf,
                doorbells_per_vf   => $doorbells_per_vf,
                exec_quantum_ms    => $exec_quantum_ms,
                preempt_timeout_us => $preempt_timeout_us,
                drivers_autoprobe  => $drivers_autoprobe,
                family             => $family,
                device_id          => $rec->{device_id},
            };
            write_ini_config($GPU_SRIOV_CONF, $config);
        }

        # Build return list
        my @vf_list;
        for my $vf (1 .. $num_vfs) {
            my $virtfn_link = sysfs_path(
                "/sys/bus/pci/devices/$bdf/virtfn" . ($vf - 1)
            );
            my $vf_target = readlink($virtfn_link);
            my $vf_bdf    = defined $vf_target ? basename($vf_target) : undef;
            push @vf_list, {
                vf_index         => $vf,
                bdf              => $vf_bdf // '',
                lmem_per_vf      => $lmem_per_vf,
                ggtt_per_vf      => $ggtt_per_vf,
                contexts_per_vf  => $contexts_per_vf,
                doorbells_per_vf => $doorbells_per_vf,
                exec_quantum_ms  => $exec_quantum_ms,
                preempt_timeout_us => $preempt_timeout_us,
            };
        }
        return \@vf_list;
    },
});

__PACKAGE__->register_method({
    name        => 'remove_vfs',
    path        => '{bdf}/sriov',
    method      => 'DELETE',
    description => 'Remove all SR-IOV Virtual Functions from an GPU device.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI BDF address',
                pattern     => $BDF_RE,
            },
            remove_persist => {
                type        => 'boolean',
                description => 'Remove persisted configuration entry',
                optional    => 1,
                default     => 0,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $bdf = $param->{bdf};

        my $rec = _collect_device($bdf, 0);
        die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;

        my $current_numvfs = int($rec->{sriov_numvfs});

        if ($current_numvfs > 0) {
            # Check no VFs are assigned to running VMs
            my $assigned = check_vf_vm_assignments($bdf, $rec->{drm_card}, $current_numvfs);
            if (@$assigned) {
                my @info = map { "VF$_->{vf_index} (VMID $_->{vmid})" } @$assigned;
                die "Cannot remove VFs: still assigned to VM(s): " . join(', ', @info) . "\n";
            }
        }

        write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0);

        # Verify
        my $after = int(read_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs") // 0);
        die "Failed to remove VFs: sriov_numvfs still reports $after\n" if $after != 0;

        if ($param->{remove_persist}) {
            my $config = parse_ini_config($GPU_SRIOV_CONF);
            if (exists $config->{$bdf}) {
                delete $config->{$bdf};
                write_ini_config($GPU_SRIOV_CONF, $config);
            }
        }

        return { success => 1, bdf => $bdf, sriov_numvfs => 0 };
    },
});

# ---------------------------------------------------------------------------
# VFIO persistence paths
# ---------------------------------------------------------------------------
my $VFIO_CONF     = '/etc/pve-gpu-vfio.conf';
my $VFIO_MODPROBE = '/etc/modprobe.d/pve-gpu-vfio.conf';
my $VFIO_MODULES  = '/etc/modules-load.d/pve-gpu-vfio.conf';

sub _read_vfio_bdfs {
    return [] unless -f $VFIO_CONF;
    open(my $fh, '<', $VFIO_CONF) or return [];
    my @bdfs;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/#.*//;
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        push @bdfs, $line;
    }
    close($fh);
    return \@bdfs;
}

sub _write_vfio_config {
    my ($bdfs) = @_;

    if (@$bdfs) {
        my $content = "# BDFs to bind to vfio-pci at boot\n";
        $content .= "$_\n" for @$bdfs;
        file_set_contents($VFIO_CONF, $content);

        # Blacklist all known GPU drivers so VFIO service can bind first
        my @blacklist;
        for my $vp (values %VENDOR_PLUGINS) {
            push @blacklist, @{$vp->native_drivers()};
        }
        my %seen_drv;
        @blacklist = grep { !$seen_drv{$_}++ } sort @blacklist;
        my $bl_content = "# Managed by pve-gpu-manager - blacklist GPU drivers for VFIO binding\n";
        $bl_content .= "blacklist $_\n" for @blacklist;
        file_set_contents($VFIO_MODPROBE, $bl_content);
        file_set_contents($VFIO_MODULES,
            "vfio\nvfio_iommu_type1\nvfio-pci\n");
    } else {
        unlink $VFIO_CONF     if -f $VFIO_CONF;
        unlink $VFIO_MODPROBE if -f $VFIO_MODPROBE;
        unlink $VFIO_MODULES  if -f $VFIO_MODULES;
    }

    # Update initramfs so blacklist takes effect at boot
    eval { run_command(['update-initramfs', '-u'], errfunc => sub {}) };
}

__PACKAGE__->register_method({
    name        => 'vfio_toggle',
    path        => '{bdf}/vfio',
    method      => 'POST',
    description => 'Bind or unbind a GPU device to/from vfio-pci driver.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI BDF address',
                pattern     => $BDF_RE,
            },
            action => {
                type        => 'string',
                description => 'bind or unbind',
                enum        => ['bind', 'unbind'],
            },
            persist => {
                type        => 'boolean',
                description => 'Persist across reboots (systemd service + modprobe blacklist)',
                optional    => 1,
                default     => 1,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $bdf     = $param->{bdf};
        my $action  = $param->{action};
        my $persist = defined($param->{persist}) ? $param->{persist} : 1;

        my $rec = _collect_device($bdf, 0);
        die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;

        my $current_driver = $rec->{driver} // '';

        if ($action eq 'bind') {
            my $numvfs = int($rec->{sriov_numvfs} // 0);
            die "Cannot bind to vfio-pci while SR-IOV VFs are active ($numvfs VFs)\n" if $numvfs > 0;

            # Only do runtime bind if not already on vfio-pci
            if ($current_driver ne 'vfio-pci') {
                run_command(['modprobe', 'vfio-pci'], errfunc => sub {});

                eval {
                    open(my $fh, '>', sysfs_path("/sys/bus/pci/devices/$bdf/driver/unbind")) or die $!;
                    print $fh $bdf;
                    close($fh);
                };

                eval {
                    open(my $fh, '>', sysfs_path("/sys/bus/pci/devices/$bdf/driver_override")) or die $!;
                    print $fh "vfio-pci";
                    close($fh);
                };
                die "Failed to set driver_override: $@\n" if $@;

                eval {
                    open(my $fh, '>', sysfs_path("/sys/bus/pci/drivers/vfio-pci/bind")) or die $!;
                    print $fh $bdf;
                    close($fh);
                };
                die "Failed to bind to vfio-pci: $@\n" if $@;
            }

            if ($persist) {
                my $bdfs = _read_vfio_bdfs();
                my %seen = map { $_ => 1 } @$bdfs;
                push @$bdfs, $bdf unless $seen{$bdf};
                _write_vfio_config($bdfs);
            }

        } elsif ($action eq 'unbind') {
            # Only do runtime unbind if currently on vfio-pci
            if ($current_driver eq 'vfio-pci') {
                eval {
                    open(my $fh, '>', sysfs_path("/sys/bus/pci/devices/$bdf/driver/unbind")) or die $!;
                    print $fh $bdf;
                    close($fh);
                };
                die "Failed to unbind from vfio-pci: $@\n" if $@;

                eval {
                    open(my $fh, '>', sysfs_path("/sys/bus/pci/devices/$bdf/driver_override")) or die $!;
                    print $fh "";
                    close($fh);
                };

                eval {
                    open(my $fh, '>', sysfs_path("/sys/bus/pci/drivers_probe")) or die $!;
                    print $fh $bdf;
                    close($fh);
                };
            }

            if ($persist) {
                my $bdfs = _read_vfio_bdfs();
                $bdfs = [ grep { $_ ne $bdf } @$bdfs ];
                _write_vfio_config($bdfs);
            }
        }

        return { success => 1, reboot_required => $persist ? \1 : \0 };
    },
});

__PACKAGE__->register_method({
    name        => 'list_vfs',
    path        => '{bdf}/vf',
    method      => 'GET',
    description => 'List all active VFs for an GPU device.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI BDF address',
                pattern     => $BDF_RE,
            },
        },
    },
    returns => {
        type  => 'array',
        items => { type => 'object' },
        links => [{ rel => 'child', href => '{vf_index}' }],
    },
    code => sub {
        my ($param) = @_;
        my $bdf = $param->{bdf};

        my $rec = _collect_device($bdf, 0);
        die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;

        my $num_vfs = int($rec->{sriov_numvfs});
        return [] if $num_vfs == 0;

        my $family = $rec->{family};
        my $card   = $rec->{drm_card};
        my $vid    = $rec->{vendor_id};
        my $tiles  = int($rec->{tiles});

        # Get VM assignments
        my $assigned = check_vf_vm_assignments($bdf, $card, $num_vfs);
        my %vf_vmid  = map { $_->{vf_index} => $_->{vmid} } @$assigned;
        my %vf_bdf_map;

        my @vf_list;
        for my $vf (1 .. $num_vfs) {
            my $virtfn_link = sysfs_path(
                "/sys/bus/pci/devices/$bdf/virtfn" . ($vf - 1)
            );
            my $vf_target = readlink($virtfn_link);
            my $vf_bdf    = defined $vf_target ? basename($vf_target) : '';

            # Read quota from tile 0 as representative
            my %quotas;
            if (defined $card && $card ne '') {
                my $paths = get_vf_paths($family, $card, $bdf, $vf, 0, $vid);
                $quotas{lmem_quota}         = int(read_sysfs($paths->{lmem_quota})         // 0);
                $quotas{ggtt_quota}         = int(read_sysfs($paths->{ggtt_quota})         // 0);
                $quotas{exec_quantum_ms}    = int(read_sysfs($paths->{exec_quantum_ms})    // 0);
                $quotas{preempt_timeout_us} = int(read_sysfs($paths->{preempt_timeout_us}) // 0);
            }

            push @vf_list, {
                vf_index  => $vf,
                bdf       => $vf_bdf,
                vmid      => $vf_vmid{$vf},
                assigned  => exists($vf_vmid{$vf}) ? \1 : \0,
                %quotas,
            };
        }

        return [sort { $a->{vf_index} <=> $b->{vf_index} } @vf_list];
    },
});

__PACKAGE__->register_method({
    name        => 'vf_detail',
    path        => '{bdf}/vf/{vfIndex}',
    method      => 'GET',
    description => 'Get detail for a specific VF.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node     => get_standard_option('pve-node'),
            bdf      => {
                type        => 'string',
                description => 'PCI BDF address of the PF',
                pattern     => $BDF_RE,
            },
            vfIndex  => {
                type        => 'integer',
                description => 'VF index (1-based)',
                minimum     => 1,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $bdf      = $param->{bdf};
        my $vf_index = int($param->{vfIndex});

        my $rec = _collect_device($bdf, 0);
        die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;

        my $num_vfs = int($rec->{sriov_numvfs});
        die "No VFs are currently active on device '$bdf'\n" if $num_vfs == 0;
        die "VF index $vf_index out of range (1..$num_vfs)\n"
            if $vf_index < 1 || $vf_index > $num_vfs;

        my $family = $rec->{family};
        my $card   = $rec->{drm_card};
        my $vid    = $rec->{vendor_id};
        my $tiles  = int($rec->{tiles});

        my $virtfn_link = sysfs_path(
            "/sys/bus/pci/devices/$bdf/virtfn" . ($vf_index - 1)
        );
        my $vf_target = readlink($virtfn_link);
        my $vf_bdf    = defined $vf_target ? basename($vf_target) : '';

        # Quota per tile
        my @tile_quotas;
        for my $t (0 .. ($tiles - 1)) {
            my %q = (tile => $t);
            if (defined $card && $card ne '') {
                my $paths = get_vf_paths($family, $card, $bdf, $vf_index, $t, $vid);
                $q{lmem_quota}         = int(read_sysfs($paths->{lmem_quota})         // 0);
                $q{ggtt_quota}         = int(read_sysfs($paths->{ggtt_quota})         // 0);
                $q{exec_quantum_ms}    = int(read_sysfs($paths->{exec_quantum_ms})    // 0);
                $q{preempt_timeout_us} = int(read_sysfs($paths->{preempt_timeout_us}) // 0);
            }
            push @tile_quotas, \%q;
        }

        # VM assignment
        my $assigned_list = check_vf_vm_assignments($bdf, $card, $num_vfs);
        my ($assigned_entry) = grep { $_->{vf_index} == $vf_index } @$assigned_list;

        return {
            vf_index    => $vf_index,
            bdf         => $vf_bdf,
            pf_bdf      => $bdf,
            family      => $family,
            tiles       => $tiles,
            tile_quotas => \@tile_quotas,
            vmid        => defined $assigned_entry ? $assigned_entry->{vmid} : undef,
            assigned    => defined $assigned_entry ? \1 : \0,
        };
    },
});

1;
