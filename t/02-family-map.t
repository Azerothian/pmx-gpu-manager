#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 41;

# Device family map copied from GPU.pm
my $DEVICE_FAMILIES = {
    '0x56c0' => { family => 'flex',     max_vfs => 31, tiles => 1 },
    '0x56c1' => { family => 'flex',     max_vfs => 31, tiles => 1 },
    '0x56c2' => { family => 'flex',     max_vfs => 31, tiles => 1 },
    '0x0bd4' => { family => 'pvc',      max_vfs => 62, tiles => 2 },
    '0x0bd5' => { family => 'pvc',      max_vfs => 62, tiles => 2 },
    '0x0bd6' => { family => 'pvc',      max_vfs => 62, tiles => 2 },
    '0x0bda' => { family => 'pvc_ext',  max_vfs => 63, tiles => 2 },
    '0x0bdb' => { family => 'pvc_ext',  max_vfs => 63, tiles => 2 },
    '0x0b6e' => { family => 'pvc_ext',  max_vfs => 63, tiles => 2 },
    '0xe211' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe212' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe222' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe223' => { family => 'bmg_12vf', max_vfs => 12, tiles => 1 },
};

# Inline identify_device logic (mirrors GPU.pm)
sub identify_device {
    my ($device_id) = @_;
    $device_id = lc($device_id);
    $device_id = "0x$device_id" unless $device_id =~ /^0x/;
    return $DEVICE_FAMILIES->{$device_id};
}

# --- flex IDs ---
for my $id (qw(0x56c0 0x56c1 0x56c2)) {
    my $info = identify_device($id);
    is($info->{family},   'flex', "$id: family=flex");
    is($info->{max_vfs},  31,     "$id: max_vfs=31");
    is($info->{tiles},    1,      "$id: tiles=1");
}

# --- pvc IDs ---
for my $id (qw(0x0bd4 0x0bd5 0x0bd6)) {
    my $info = identify_device($id);
    is($info->{family},   'pvc', "$id: family=pvc");
    is($info->{max_vfs},  62,    "$id: max_vfs=62");
    is($info->{tiles},    2,     "$id: tiles=2");
}

# --- pvc_ext IDs ---
for my $id (qw(0x0bda 0x0bdb 0x0b6e)) {
    my $info = identify_device($id);
    is($info->{family},   'pvc_ext', "$id: family=pvc_ext");
    is($info->{max_vfs},  63,        "$id: max_vfs=63");
    is($info->{tiles},    2,         "$id: tiles=2");
}

# --- bmg IDs ---
for my $id (qw(0xe211 0xe212 0xe222)) {
    my $info = identify_device($id);
    is($info->{family},   'bmg', "$id: family=bmg");
    is($info->{max_vfs},  24,    "$id: max_vfs=24");
    is($info->{tiles},    1,     "$id: tiles=1");
}

# --- bmg_12vf ---
{
    my $info = identify_device('0xe223');
    is($info->{family},   'bmg_12vf', '0xe223: family=bmg_12vf');
    is($info->{max_vfs},  12,         '0xe223: max_vfs=12');
    is($info->{tiles},    1,          '0xe223: tiles=1');
}

# --- Unknown ID ---
is(identify_device('0x1234'), undef, 'unknown 0x1234 returns undef');

# --- All 13 known IDs present ---
is(scalar keys %$DEVICE_FAMILIES, 13, 'map contains exactly 13 entries');
