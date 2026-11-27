#!/usr/bin/env perl
#
# makedhcp -n on the ISC backend took every "ip -6 route" entry as a subnet6 to write. A route
# on an interface that is not in site.dhcpinterfaces has no shared-network block in dhcpd6.conf,
# so addnet6 reported "Could not add the subnet 64:ff9b::/96 for interface nat64" and makedhcp
# exited 1. The DHCPv4 path already serves only the routes of an active interface.
use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More tests => 4;

$ENV{XCATCFG} ||= 'SQLite:/tmp';

my $source_dhcp_plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm";
if ( -f $source_dhcp_plugin ) {
    require $source_dhcp_plugin;
} else {
    require xCAT_plugin::dhcp;
}

# The routes of an IPv6 management node with a NAT64 translator and a second provisioning NIC.
my @routes = (
    { net => '64:ff9b::/96',      iface => 'nat64' },
    { net => '2001:db8:147::/64', iface => 'ens2' },
    { net => '2001:db8:147::/64', iface => 'ens3' },
    { net => '2001:db8:200::/64', iface => 'ens4' },
);

my @served = xCAT_plugin::dhcp::dhcp6_served_routes( \@routes, { ens2 => 1, ens4 => 1 } );
is_deeply(
    \@served,
    [
        { net => '2001:db8:147::/64', iface => 'ens2' },
        { net => '2001:db8:200::/64', iface => 'ens4' },
    ],
    'only the routes of a DHCP interface are served, in route order'
);

ok( !grep( { $_->{iface} eq 'nat64' } @served ),
    'the NAT64 translator route is not served' );

is_deeply( [ xCAT_plugin::dhcp::dhcp6_served_routes( \@routes, {} ) ],
    [], 'no DHCP interface serves no IPv6 subnet' );

is_deeply( [ xCAT_plugin::dhcp::dhcp6_served_routes( [], { ens2 => 1 } ) ],
    [], 'no route serves no IPv6 subnet' );
