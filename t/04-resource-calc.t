#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 13;

# ---------------------------------------------------------------------------
# Resource calculation helpers (standalone, no PVE deps)
# ---------------------------------------------------------------------------

# Compute per-VF lmem given total bytes and number of VFs (integer division)
sub calc_lmem_per_vf {
    my ($total_bytes, $num_vfs) = @_;
    return undef if !$num_vfs || $num_vfs <= 0;
    return int($total_bytes / $num_vfs);
}

# Apply template defaults then override with explicit params
sub resolve_vf_params {
    my ($template, $explicit) = @_;
    my %result = %{ $template // {} };
    for my $k (keys %{ $explicit // {} }) {
        $result{$k} = $explicit->{$k};
    }
    return \%result;
}

# Validate that num_vfs * lmem_per_vf <= total_lmem
sub validate_allocation {
    my ($num_vfs, $lmem_per_vf, $total_lmem) = @_;
    return ($num_vfs * $lmem_per_vf) <= $total_lmem ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# 1. Even split: 16106127360 / 4 = 4026531840
is(calc_lmem_per_vf(16106127360, 4), 4026531840, 'even split 4 VFs');

# 2. Even split: 16106127360 / 8 = 2013265920
is(calc_lmem_per_vf(16106127360, 8), 2013265920, 'even split 8 VFs');

# 3. Template values used as-is when no explicit params
{
    my $tmpl = { lmem_per_vf => 2048, ggtt_per_vf => 64 };
    my $res  = resolve_vf_params($tmpl, {});
    is($res->{lmem_per_vf}, 2048, 'template lmem_per_vf used as-is');
    is($res->{ggtt_per_vf}, 64,   'template ggtt_per_vf used as-is');
}

# 4. Template values overridden by explicit params
{
    my $tmpl     = { lmem_per_vf => 2048, ggtt_per_vf => 64 };
    my $explicit = { lmem_per_vf => 8192 };
    my $res      = resolve_vf_params($tmpl, $explicit);
    is($res->{lmem_per_vf}, 8192, 'explicit param overrides template lmem_per_vf');
    is($res->{ggtt_per_vf}, 64,   'non-overridden template key preserved');
}

# 5. Validation: total allocation exceeds available -> detect (fail)
{
    # 4 VFs * 5 GB each = 20 GB > 16 GB total
    my $ok = validate_allocation(4, 5 * 1024**3, 16 * 1024**3);
    is($ok, 0, 'over-allocation detected (4 VFs * 5GB > 16GB)');
}

# 6. Validation: num_vfs * lmem_per_vf <= total_lmem -> pass
{
    my $ok = validate_allocation(4, 4026531840, 16106127360);
    is($ok, 1, 'exact-fit allocation passes validation');
}

# 7. Validation: num_vfs * lmem_per_vf > total_lmem -> fail
{
    my $ok = validate_allocation(4, 4026531841, 16106127360);
    is($ok, 0, 'one-byte-over allocation fails validation');
}

# 8. Edge: single VF gets all resources
{
    my $per_vf = calc_lmem_per_vf(16106127360, 1);
    is($per_vf, 16106127360, 'single VF receives full lmem');
    is(validate_allocation(1, $per_vf, 16106127360), 1, 'single VF allocation validates');
}

# 9. Edge: max VFs (31) with minimum per-VF allocation
{
    my $total   = 16106127360;
    my $num_vfs = 31;
    my $per_vf  = calc_lmem_per_vf($total, $num_vfs);
    # int(16106127360 / 31) = 519552495
    is($per_vf, 519552495, 'max 31 VFs per-VF lmem calculated correctly');
    is(validate_allocation($num_vfs, $per_vf, $total), 1,
        'max 31 VFs allocation validates (integer division fits)');
}
