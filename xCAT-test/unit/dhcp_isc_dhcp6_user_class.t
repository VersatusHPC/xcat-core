#!/usr/bin/env perl
#
# The ISC DHCPv6 host of a chainloading node chooses its boot file with
# "substring(option dhcp6.user-class, 2, 4)". ISC DHCP 4.4 defines no dhcp6.user-class, so
# dhcpd refused the host with "no option named user-class in space dhcp6", omshell reported
# "can't open object: parse error(s) occurred", and the node got no DHCPv6 reservation.
use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More tests => 7;

$ENV{XCATCFG} ||= 'SQLite:/tmp';

my $source_dhcp_plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm";
if ( -f $source_dhcp_plugin ) {
    require $source_dhcp_plugin;
} else {
    require xCAT_plugin::dhcp;
}

my $DECL = qr/^option dhcp6\.user-class code 15 = string;$/;

like(
    xCAT::DHCP::BootPolicy->isc_dhcp6_boot_stage_statement(
        loader_url => 'tftp://[2001:db8::1]/shim.efi',
        script_url => 'http://[2001:db8::1]/node.uefi'
    ),
    qr/option dhcp6\.user-class/,
    'the boot stage statement reads dhcp6.user-class'
);

# A dhcpd6.conf that an older makedhcp -n wrote.
my @conf = (
    "#xCAT generated dhcp configuration\n",
    "\n",
    "ddns-update-style interim;\n",
    "shared-network ens2 {\n",
    "} # ens2 nic_end\n",
);
is( xCAT::DHCP::BootPolicy->isc_dhcp6_declare_user_class( \@conf ), 1,
    'an older configuration gets the declaration' );
is( scalar( grep { /$DECL/ } @conf ), 1, 'the configuration declares option 15 once' );
my ($decl)   = grep { $conf[$_] =~ /$DECL/ } 0 .. $#conf;
my ($shared) = grep { $conf[$_] =~ /^shared-network/ } 0 .. $#conf;
ok( defined($decl) && $decl < $shared, 'the declaration comes before the first shared-network' );
is( $conf[0], "#xCAT generated dhcp configuration\n",
    'the xCAT header stays the first line, so the next makedhcp keeps the file' );

is( xCAT::DHCP::BootPolicy->isc_dhcp6_declare_user_class( \@conf ), 0,
    'a configuration that has the declaration gets no second one' );

# makedhcp -n writes a new configuration.
my @written;
{
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::_omapi_settings          = sub { return {} };
    local *xCAT_plugin::dhcp::_append_omapi_key_config = sub { @written = @{ $_[0] } };
    xCAT_plugin::dhcp::newconfig6();
}
is( scalar( grep { /$DECL/ } @written ), 1,
    'makedhcp -n declares option 15 in a new dhcpd6.conf' );
