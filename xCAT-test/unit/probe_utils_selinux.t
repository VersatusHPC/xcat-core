#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-probe/lib/perl";

use Test::More;

require probe_utils;

sub mode_for {
    my ($enabled, $enforcing) = @_;

    no warnings qw(redefine once);
    local *probe_utils::is_selinux_enable    = sub { return $enabled; };
    local *probe_utils::is_selinux_enforcing = sub { return $enforcing; };
    return probe_utils::selinux_mode();
}

is(mode_for(0, 0), 'disabled',   'selinux_mode reports disabled when selinuxenabled fails');
is(mode_for(1, 0), 'permissive', 'selinux_mode reports permissive when SELinux is on and not enforcing');
is(mode_for(1, 1), 'enforcing',  'selinux_mode reports enforcing when getenforce says Enforcing');

my %level;
my %msg;
foreach my $mode (qw(disabled permissive enforcing)) {
    ($level{$mode}, $msg{$mode}) = probe_utils::selinux_verdict($mode);
}

is($level{disabled},   'o', 'disabled SELinux is an ok result');
is($level{permissive}, 'w', 'permissive SELinux is a warning');
is($level{enforcing},  'w', 'enforcing SELinux is a warning, not a failed result');

like($msg{enforcing}, qr/makedns/,
    'the enforcing warning names the command that is incomplete under SELinux');
like($msg{permissive}, qr/permissive/i, 'the permissive warning names the mode');
unlike($msg{permissive}, qr/makedns/,
    'the permissive warning does not claim makedns is incomplete');

done_testing();
