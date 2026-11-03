#!/usr/bin/env perl
# makenetworks must not write an IPv6 network the networks table already defines. A second row
# for one prefix makes makedhcp write the same subnet6 twice, and Kea rejects the whole
# configuration: "subnet with the prefix of '2001:db8:172::/64' already exists". Both DHCP
# services then stay down and no node gets a lease, on either family.
use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage)

use FindBin;
use Test::More;

BEGIN {
    package xCAT::Table;
    $INC{'xCAT/Table.pm'} = __FILE__;

    package xCAT::Utils;
    $INC{'xCAT/Utils.pm'} = __FILE__;

    package xCAT::TableUtils;
    $INC{'xCAT/TableUtils.pm'} = __FILE__;

    package xCAT::NetworkUtils;
    $INC{'xCAT/NetworkUtils.pm'} = __FILE__;

    package xCAT::ServiceNodeUtils;
    $INC{'xCAT/ServiceNodeUtils.pm'} = __FILE__;
}

my $plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/networks.pm";
$plugin = "$ENV{XCATROOT}/lib/perl/xCAT_plugin/networks.pm" unless -f $plugin;
require $plugin;

my $defined = \&xCAT_plugin::networks::_ipv6_network_defined;

# The form mkdef writes: the prefix length is in mask, not in net.
my %mkdef_row = (ipv6prov => { net => '2001:db8:172::', mask => '/64' });
ok($defined->(\%mkdef_row, '2001:db8:172::/64'),
    'a row that keeps its prefix length in mask defines the prefix');

# The form makenetworks itself writes: the prefix length is in net.
my %discovered_row = ('2001:db8:172::/64' => { net => '2001:db8:172::/64', mask => '/64' });
ok($defined->(\%discovered_row, '2001:db8:172::/64'),
    'a row that carries its prefix length in net defines the prefix');

# Equivalent spellings of one address are one network.
ok($defined->({ r => { net => '2001:0db8:0172:0000::', mask => '/64' } }, '2001:db8:172::/64'),
    'an expanded address and a compressed address are the same network');

# A different prefix, and the same address at a different length, are other networks.
ok(!$defined->(\%mkdef_row, '2001:db8:173::/64'), 'another prefix is not defined');
ok(!$defined->(\%mkdef_row, '2001:db8:172::/48'), 'the same address at another length is not defined');

# An IPv4 row never answers for an IPv6 prefix.
ok(!$defined->({ v4 => { net => '192.168.172.0', mask => '255.255.255.0' } }, '2001:db8:172::/64'),
    'an IPv4 row does not define an IPv6 prefix');

# Nothing defined, and inputs the caller can really pass.
ok(!$defined->({}, '2001:db8:172::/64'), 'an empty table defines nothing');
ok(!$defined->(\%mkdef_row, '2001:db8:172::'), 'a prefix with no length is not a prefix');
ok(!$defined->(\%mkdef_row, undef), 'undef is not a prefix');

done_testing();
