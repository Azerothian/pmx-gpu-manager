#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 12;

# BDF validation regex as used in XPU.pm
my $BDF_RE = qr/^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$/;

# --- Valid cases ---
ok('0000:03:00.0' =~ $BDF_RE, 'valid: standard BDF 0000:03:00.0');
ok('0000:ff:1f.7' =~ $BDF_RE, 'valid: max bus/device/function 0000:ff:1f.7');
ok('ABCD:EF:01.3' =~ $BDF_RE, 'valid: uppercase hex ABCD:EF:01.3');
ok('abcd:ef:01.3' =~ $BDF_RE, 'valid: lowercase hex abcd:ef:01.3');

# --- Invalid cases ---
ok('0000:03:00.8' !~ $BDF_RE, 'invalid: function 8 (> 7)');
ok('000:03:00.0'  !~ $BDF_RE, 'invalid: domain too short (3 hex digits)');
ok('0000:3:00.0'  !~ $BDF_RE, 'invalid: bus too short (1 hex digit)');
ok('0000:03:0.0'  !~ $BDF_RE, 'invalid: device too short (1 hex digit)');
ok('0000:03:00.'  !~ $BDF_RE, 'invalid: missing function digit');
ok(''             !~ $BDF_RE, 'invalid: empty string');
ok('0000:03:00.0 ' !~ $BDF_RE, 'invalid: trailing space');
ok('0000:GG:00.0' !~ $BDF_RE, 'invalid: non-hex characters GG');
