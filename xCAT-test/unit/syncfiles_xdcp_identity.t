#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins";
use Test::More;

my $plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/syncfiles.pm";
require $plugin;

sub run_syncfiles {
    my (@args) = @_;
    my @subrequests;
    no warnings 'redefine';
    local *xCAT_plugin::syncfiles::noderange = sub { return $_[0]; };
    local *xCAT::SvrUtils::getsynclistfile = sub {
        return { node01 => '/install/custom/sync-a,/install/custom/sync-b' };
    };
    local *xCAT::MsgUtils::message = sub { return; };
    local @ARGV;
    local $::RCP;

    xCAT_plugin::syncfiles::process_request(
        {
            command          => ['syncfiles'],
            arg              => \@args,
            _xcat_clienthost => ['node01'],
        },
        sub { },
        sub { push @subrequests, $_[0] },
    );
    return \@subrequests;
}

my $requests = run_syncfiles();
is(scalar(@$requests), 2, 'one xdcp request is emitted for each sync list');
foreach my $index (0 .. $#$requests) {
    my $synclist = $index == 0
      ? '/install/custom/sync-a'
      : '/install/custom/sync-b';
    is_deeply($requests->[$index]->{command}, ['xdcp'], 'the subrequest invokes xdcp');
    is_deeply($requests->[$index]->{username}, ['root'], 'the xdcp identity uses the consumer arrayref contract');
    is_deeply($requests->[$index]->{node}, ['node01'], 'the xdcp request targets the requesting node');
    is_deeply($requests->[$index]->{arg}, ['-F', $synclist], 'the xdcp request names its sync list');
    is_deeply($requests->[$index]->{env}, ["DSH_RSYNC_FILE=$synclist"], 'the sync list is exported to xdcp');
}

$requests = run_syncfiles('-r', 'scp');
is_deeply(
    $requests->[0]->{arg},
    ['-F', '/install/custom/sync-a', '-r', 'scp'],
    'the requested remote-copy command is carried into xdcp',
);
is_deeply($requests->[0]->{username}, ['root'], 'the remote-copy variant retains the xdcp identity');

done_testing();
