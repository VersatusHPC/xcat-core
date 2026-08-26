#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../perl-xCAT";
use Getopt::Long;
use Test::More;

$ENV{XCATCFG} ||= 'SQLite:/tmp';

my $plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm";
require $plugin;

{
    package DHCPDispatchNetworks;
    sub getAllEntries { return []; }
}

sub dispatch {
    my (%case) = @_;
    my @service_nodes = @{ $case{service_nodes} || [] };
    my $mapping = $case{mapping} || {};
    my @local_names = @{ $case{local_names} || ['mn'] };
    my $is_service_node = $case{is_service_node} || 0;

    no warnings 'redefine';
    local *xCAT::Table::new = sub { return bless {}, 'DHCPDispatchNetworks'; };
    local *xCAT::TableUtils::get_site_attribute = sub {
        return ('mn') if $_[-1] eq 'master';
        return;
    };
    local *xCAT::ServiceNodeUtils::getSNList = sub { return @service_nodes; };
    local *xCAT::ServiceNodeUtils::getSNformattedhash = sub { return $mapping; };
    local *xCAT::NetworkUtils::determinehostname = sub { return @local_names; };
    local *xCAT::Utils::isServiceNode = sub { return $is_service_node; };
    local *xCAT::MsgUtils::trace = sub { return; };
    local *xCAT::MsgUtils::message = sub { return; };
    local @ARGV;

    my $request = {
        command               => ['makedhcp'],
        arg                   => $case{args} || [],
        _xcatpreprocessed     => [0],
    };
    $request->{node} = $case{nodes} if $case{nodes};

    return xCAT_plugin::dhcp::preprocess_request($request, sub { });
}

sub destinations {
    my ($requests) = @_;
    return [ map { $_->{_xcatdest} // 'local' } @{$requests} ];
}

my $requests = dispatch(
    nodes         => [qw(node01 node02)],
    service_nodes => [qw(sn01 sn02)],
    mapping       => { sn01 => [qw(node01 node02)] },
);
is_deeply(
    destinations($requests),
    [qw(local sn01)],
    'a named noderange reaches only the service node that serves it',
);
is_deeply($requests->[1]->{node}, [qw(node01 node02)], 'the selected service node receives its served nodes');

$requests = dispatch(
    nodes         => ['unknown'],
    service_nodes => [qw(sn01 sn02)],
    mapping       => {},
);
is_deeply(
    destinations($requests),
    [qw(local sn01 sn02)],
    'an unmapped noderange retains the previous all-service-node fallback',
);

$requests = dispatch(
    args          => ['-n'],
    service_nodes => [qw(sn01 sn02)],
    mapping       => { sn01 => ['node01'] },
);
is_deeply(
    destinations($requests),
    [qw(local sn01 sn02)],
    'network regeneration reaches every DHCP service node',
);

$requests = dispatch(
    nodes         => ['sn01'],
    service_nodes => [qw(sn01 sn02)],
    mapping       => { sn01 => ['sn01'] },
);
is_deeply(
    destinations($requests),
    ['local'],
    'a request for the service node itself is not dispatched back to it',
);

$requests = dispatch(
    nodes           => ['node02'],
    service_nodes   => [qw(sn01 sn02)],
    mapping         => { sn01 => ['node02'], sn02 => ['node02'] },
    local_names     => ['sn02'],
    is_service_node => 1,
);
is_deeply(
    destinations($requests),
    [qw(local mn sn01)],
    'a service node dispatches to the manager and skips its own service-node address',
);

done_testing();
