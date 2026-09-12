#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use XCAT::Test::XcatRoot;    # before the first xCAT module

use lib "$FindBin::Bin/../../xCAT-server/lib";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

$ENV{XCATCFG} ||= 'SQLite:/tmp';

my $source_dhcp_plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm";
if ( -f $source_dhcp_plugin ) {
    require $source_dhcp_plugin;
} else {
    require xCAT_plugin::dhcp;
}

my ($name, $ip, $mac) = xCAT_plugin::dhcp::_parse_omshell_host_output(
    'node01',
    'name = "node01"',
    'ip-address = 0a:00:00:05',
    'hardware-address = 00:11:22:33:44:55',
);

is($name, 'node01', 'host name is parsed');
is($ip, 'ip-address = 10.0.0.5', 'IPv4 OMAPI hex address is converted to dotted decimal');
is($mac, 'hardware-address = 00:11:22:33:44:55', 'hardware address is preserved');

($name, $ip, $mac) = xCAT_plugin::dhcp::_parse_omshell_host_output(
    'nodev6',
    'name = "nodev6"',
    'ip-address = 2001:db8::50',
    'hardware-address = 00:aa:bb:cc:dd:ee',
);

is($name, 'nodev6', 'IPv6 host name is parsed');
is($ip, 'ip-address = 2001:db8::50', 'IPv6 address is preserved');
is($mac, 'hardware-address = 00:aa:bb:cc:dd:ee', 'IPv6 hardware address is preserved');

done_testing();
