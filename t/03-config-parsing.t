#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 18;
use File::Temp qw(tempfile);

# Standalone parse_ini logic copied from XPU.pm parse_ini_config()
sub parse_ini {
    my ($path) = @_;
    my %data;
    return undef unless defined $path;
    return {} unless -f $path;

    open(my $fh, '<', $path) or return {};
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

sub write_tmp {
    my ($content) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh $content;
    close($fh);
    return $path;
}

# 1. Simple section with key-value pairs
{
    my $p = write_tmp("[gpu]\nnum_vfs = 4\nfamily = flex\n");
    my $cfg = parse_ini($p);
    is($cfg->{gpu}{num_vfs}, '4',    'simple: num_vfs = 4');
    is($cfg->{gpu}{family},  'flex', 'simple: family = flex');
}

# 2. Multiple sections
{
    my $p = write_tmp("[sec_a]\nkey1 = val1\n[sec_b]\nkey2 = val2\n");
    my $cfg = parse_ini($p);
    is($cfg->{sec_a}{key1}, 'val1', 'multi-section: sec_a key1');
    is($cfg->{sec_b}{key2}, 'val2', 'multi-section: sec_b key2');
}

# 3. Comments (# lines) are ignored
{
    my $p = write_tmp("[s]\n# this is a comment\nkey = value\n");
    my $cfg = parse_ini($p);
    ok(!exists $cfg->{s}{'# this is a comment'}, 'comment line not parsed as key');
    is($cfg->{s}{key}, 'value', 'key after comment is parsed');
}

# 4. Blank lines are ignored
{
    my $p = write_tmp("[s]\n\n\nkey = value\n\n");
    my $cfg = parse_ini($p);
    is($cfg->{s}{key}, 'value', 'blank lines ignored');
    is(scalar keys %{$cfg->{s}}, 1, 'only one key in section despite blank lines');
}

# 5. Whitespace around keys and values is trimmed
{
    my $p = write_tmp("[s]\n  key  =  value  \n");
    my $cfg = parse_ini($p);
    is($cfg->{s}{key}, 'value', 'whitespace trimmed from key and value');
}

# 6. Subsection format [bdf/vf1]
{
    my $p = write_tmp("[0000:03:00.0/vf1]\nlmem = 4096\n");
    my $cfg = parse_ini($p);
    is($cfg->{'0000:03:00.0/vf1'}{lmem}, '4096', 'subsection bdf/vf1 parsed');
}

# 7. Values with special chars (commas in device_ids)
{
    my $p = write_tmp("[devices]\ndevice_ids = 0x56c0,0x56c1,0x56c2\n");
    my $cfg = parse_ini($p);
    is($cfg->{devices}{device_ids}, '0x56c0,0x56c1,0x56c2', 'comma-separated value preserved');
}

# 8. Empty file returns empty hash
{
    my $p = write_tmp('');
    my $cfg = parse_ini($p);
    is(ref($cfg), 'HASH', 'empty file returns hashref');
    is(scalar keys %$cfg, 0, 'empty file returns empty hash');
}

# 9. Missing file returns undef or empty
{
    my $cfg_undef = parse_ini(undef);
    is($cfg_undef, undef, 'undef path returns undef');

    my $cfg_missing = parse_ini('/nonexistent/path/does/not/exist.conf');
    is(ref($cfg_missing), 'HASH', 'missing file returns hashref');
    is(scalar keys %$cfg_missing, 0, 'missing file returns empty hash');
}

# Extra: keys in multiple sections do not bleed across sections
{
    my $p = write_tmp("[a]\nkey = from_a\n[b]\nkey = from_b\n");
    my $cfg = parse_ini($p);
    is($cfg->{a}{key}, 'from_a', 'section a key isolated');
    is($cfg->{b}{key}, 'from_b', 'section b key isolated');
}
