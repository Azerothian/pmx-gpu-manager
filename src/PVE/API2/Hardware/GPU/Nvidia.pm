package PVE::API2::Hardware::GPU::Nvidia;

use strict;
use warnings;
use File::Basename;
use PVE::Tools qw(run_command);

# ---------------------------------------------------------------------------
# Known NVIDIA device IDs
# ---------------------------------------------------------------------------
my $DEVICE_NAMES = {
    '0x2684' => 'NVIDIA GeForce RTX 4090',
    '0x2704' => 'NVIDIA GeForce RTX 4080',
    '0x2782' => 'NVIDIA GeForce RTX 4070 Ti',
    '0x2786' => 'NVIDIA GeForce RTX 4070',
    '0x2204' => 'NVIDIA GeForce RTX 3090',
    '0x2206' => 'NVIDIA GeForce RTX 3080',
    '0x2484' => 'NVIDIA GeForce RTX 3070',
    '0x20b0' => 'NVIDIA A100',
    '0x20b2' => 'NVIDIA A100 (80GB)',
    '0x20f1' => 'NVIDIA A100 (PCIe)',
    '0x2230' => 'NVIDIA A10',
    '0x2236' => 'NVIDIA A10G',
    '0x2330' => 'NVIDIA H100',
    '0x2331' => 'NVIDIA H100 (PCIe)',
    '0x2339' => 'NVIDIA H100 (NVL)',
    '0x2321' => 'NVIDIA H200',
    '0x26b1' => 'NVIDIA L40',
    '0x26b5' => 'NVIDIA L40S',
    '0x27b0' => 'NVIDIA L4',
    '0x20b5' => 'NVIDIA A30',
    '0x25b6' => 'NVIDIA A16',
    '0x1db4' => 'NVIDIA Tesla V100 (16GB)',
    '0x1db6' => 'NVIDIA Tesla V100 (32GB)',
    '0x1eb8' => 'NVIDIA Tesla T4',
    '0x20f3' => 'NVIDIA A800',
};

# ---------------------------------------------------------------------------
# Plugin interface: identify_device
# ---------------------------------------------------------------------------
sub identify_device {
    my ($class, $device_id) = @_;
    $device_id = lc($device_id);
    $device_id = "0x$device_id" unless $device_id =~ /^0x/;

    my $name = $DEVICE_NAMES->{$device_id} // 'NVIDIA GPU';

    # NVIDIA GPUs: no SR-IOV VFs (consumer), 1 tile equivalent
    return {
        family  => 'nvidia',
        max_vfs => 0,
        tiles   => 1,
        name    => $name,
    };
}

# ---------------------------------------------------------------------------
# Plugin interface: device_name_fallback
# ---------------------------------------------------------------------------
sub device_name_fallback {
    my ($class, $device_id) = @_;
    my $norm = lc($device_id);
    $norm = "0x$norm" unless $norm =~ /^0x/;
    return $DEVICE_NAMES->{$norm} // "NVIDIA GPU ($device_id)";
}

# ---------------------------------------------------------------------------
# Plugin interface: read_telemetry
# ---------------------------------------------------------------------------
sub read_telemetry {
    my ($class, $card, $bdf, $driver) = @_;
    my $result = {
        temperature_c      => undef,
        mem_temperature_c  => undef,
        power_w            => undef,
        power_tdp_w        => undef,
        clock_mhz          => undef,
        clock_max_mhz      => undef,
        gpu_util_pct       => undef,
        lmem_total_mb      => undef,
        lmem_used_mb       => undef,
        fan_rpm            => undef,
        throttled          => undef,
        health             => 'OK',
    };

    # Attempt nvidia-smi query
    eval {
        my $output = '';
        run_command(
            [
                'nvidia-smi',
                '--query-gpu=temperature.gpu,power.draw,clocks.current.graphics,clocks.max.graphics,memory.used,memory.total,utilization.gpu,fan.speed',
                '--format=csv,noheader,nounits',
                '-i', $bdf,
            ],
            outfunc => sub { $output .= $_[0] . "\n" },
            errfunc => sub { },
            timeout => 5,
        );

        chomp $output;
        my @fields = split(/\s*,\s*/, $output);
        if (scalar @fields >= 8) {
            $result->{temperature_c}  = $fields[0] + 0 if $fields[0] =~ /^\d+/;
            $result->{power_w}        = sprintf("%.1f", $fields[1]) if $fields[1] =~ /^\d/;
            $result->{clock_mhz}      = int($fields[2]) if $fields[2] =~ /^\d+/;
            $result->{clock_max_mhz}  = int($fields[3]) if $fields[3] =~ /^\d+/;
            $result->{lmem_used_mb}   = int($fields[4]) if $fields[4] =~ /^\d+/;
            $result->{lmem_total_mb}  = int($fields[5]) if $fields[5] =~ /^\d+/;
            $result->{gpu_util_pct}   = $fields[6] + 0 if $fields[6] =~ /^\d+/;
            # fan.speed is percentage, store as-is (no RPM available via this query)
            $result->{fan_rpm}        = undef;  # nvidia-smi reports % not RPM
        }
    };
    # Non-fatal: nvidia-smi may not be installed or device not accessible

    # Derive health status from thresholds
    my @issues;
    if (defined $result->{temperature_c} && $result->{temperature_c} >= 95) {
        push @issues, 'GPU temp critical';
    }
    if (@issues) {
        $result->{health} = join(', ', @issues);
    }

    return $result;
}

# ---------------------------------------------------------------------------
# Plugin interface: get_vf_paths
# ---------------------------------------------------------------------------
sub get_vf_paths {
    my ($class, $family, $card, $bdf, $vf_index, $tile) = @_;
    # NVIDIA consumer GPUs do not support SR-IOV VFs
    return undef;
}

# ---------------------------------------------------------------------------
# Plugin interface: read_firmware_version
# ---------------------------------------------------------------------------
sub read_firmware_version {
    my ($class, $bdf) = @_;
    my $version;
    eval {
        my $output = '';
        run_command(
            [
                'nvidia-smi',
                '--query-gpu=vbios_version',
                '--format=csv,noheader',
                '-i', $bdf,
            ],
            outfunc => sub { $output .= $_[0] },
            errfunc => sub { },
            timeout => 5,
        );
        chomp $output;
        $version = $output if $output =~ /\S/;
    };
    return $version;
}

# ---------------------------------------------------------------------------
# Plugin interface: native_drivers
# ---------------------------------------------------------------------------
sub native_drivers {
    my ($class) = @_;
    return ['nvidia', 'nouveau'];
}

# ---------------------------------------------------------------------------
# Plugin interface: run_prechecks
# ---------------------------------------------------------------------------
sub run_prechecks {
    my ($class, $bdf, $card, $driver) = @_;

    my $pass = ($driver eq 'nvidia') ? 1 : 0;
    return {
        pass   => $pass ? \1 : \0,
        detail => $pass
            ? "nvidia driver bound"
            : "Driver '$driver' bound (expected nvidia)",
    };
}

# ---------------------------------------------------------------------------
# Register with GPU framework
# ---------------------------------------------------------------------------
PVE::API2::Hardware::GPU::register_vendor('10de', __PACKAGE__);

1;
