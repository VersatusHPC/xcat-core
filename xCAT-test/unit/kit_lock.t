#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Test::More;
use XCAT::Test::File qw(repo_path);

require(repo_path('xCAT-server/lib/xcat/plugins/kit.pm'));

# The kit lock lives in /var/lock/xcat, so the test decides whether another process holds it.
our ($HELD, @LOCKED, @RAN);
{
    no warnings qw(redefine once);
    *xCAT::Utils::is_locked    = sub { return $HELD ? 1 : 0 };
    *xCAT::Utils::acquire_lock = sub { push @LOCKED, $_[1]; return {} };
    *xCAT::Utils::release_lock = sub { return };
    *xCAT_plugin::kit::lskit   = sub { push @RAN, 'lskit'; return 0 };
}

sub lskit {
    my @errors;
    (@LOCKED, @RAN) = ();
    xCAT_plugin::kit::process_request({ command => ['lskit'], arg => [] }, sub { push @errors, @{ $_[0]{error} || [] } });
    return join("\n", @errors);
}

{
    local ($HELD, $::PID) = (0, undef);
    is(lskit(), '', 'a kit command reports no error while no process holds the kit lock');
    is_deeply(\@LOCKED, ['kit'], 'a kit command takes the kit lock');
    is_deeply(\@RAN, ['lskit'], 'a kit command runs with the kit lock');
}

{
    local ($HELD, $::PID) = (1, undef);
    like(lskit(), qr/another process is running/, 'a kit command reports the kit lock that another process holds');
    is_deeply(\@RAN, [], 'a kit command does not run while another process holds the kit lock');
}

{
    local ($HELD, $::PID) = (1, $$);
    is(lskit(), '', 'a kit command that a kit command of the same process runs reports no error');
    is_deeply(\@RAN, ['lskit'], 'a kit command that a kit command of the same process runs goes on');
}

done_testing();
