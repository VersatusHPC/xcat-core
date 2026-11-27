#!/usr/bin/env perl
# xCAT writes /etc/dhcp/dhcpd6.conf only for an IPv6 network. On a cluster with no IPv6
# network the file stays absent, which makedhcp reads as a configuration to replace, so a
# restart of dhcpd6 must not follow from that alone: the daemon has no subnet to serve.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;
use xCAT::DHCP::Backend::ISC;
use xCAT::Utils;
use File::Temp qw(tempdir);

sub needed { return xCAT::DHCP::Backend::ISC->dhcp6_restart_needed(@_) }

ok( !needed( changed => 1, ipv6 => 0 ),
    'an absent dhcpd6 configuration does not restart dhcpd6 when no network is IPv6' );
ok( needed( changed => 1, ipv6 => 1 ),
    'a replaced dhcpd6 configuration restarts dhcpd6 when a network is IPv6' );
ok( !needed( changed => 0, ipv6 => 1 ),
    'an unchanged dhcpd6 configuration restarts nothing' );
ok( !needed( changed => 0, ipv6 => 0 ), 'neither condition restarts nothing' );

sub stop_needed { return xCAT::DHCP::Backend::ISC->dhcp6_stop_needed(@_) }

# Debian and Ubuntu start dhcpd6 from the package postinst, before xCAT configures it.
ok( stop_needed( debian => 1, ipv6 => 0 ),
    'Debian with no IPv6 network stops the dhcpd6 that the package started' );
ok( !stop_needed( debian => 1, ipv6 => 1 ), 'Debian with an IPv6 network keeps dhcpd6' );
ok( !stop_needed( debian => 0, ipv6 => 0 ),
    'EL with no IPv6 network leaves dhcpd6 alone: its package does not start it' );

# Debian and Ubuntu name the DHCPv6 unit isc-dhcp-server6, and makedhcp restarts it by
# the service name dhcp6.
{
    my $dir = tempdir( CLEANUP => 1 );
    open( my $fh, '>', "$dir/isc-dhcp-server6.service" ) or die "cannot write the unit: $!";
    close($fh);
    is( xCAT::Utils->servicemap( 'dhcp6', { searches => [ { paths => [$dir], suffix => '.service' } ] } ),
        'isc-dhcp-server6', 'the dhcp6 service resolves to the Debian unit isc-dhcp-server6' );
}

# The MN starts dhcpd at xcatd start only once makedhcp -n declared a subnet.
ok( !xCAT::DHCP::Backend::ISC->config_declares_subnet(undef), 'an absent dhcpd.conf declares no subnet' );
ok( !xCAT::DHCP::Backend::ISC->config_declares_subnet("# dhcpd.conf\n#subnet 10.0.0.0 netmask 255.0.0.0 {\n"),
    'the commented example of the packaged dhcpd.conf declares no subnet' );
ok( xCAT::DHCP::Backend::ISC->config_declares_subnet("shared-network eth1 {\n  subnet 192.168.1.0 netmask 255.255.255.0 {\n"),
    'a makedhcp -n configuration declares a subnet' );
ok( xCAT::DHCP::Backend::ISC->config_declares_subnet("subnet6 2001:db8::/64 {\n"), 'a subnet6 declaration counts' );

done_testing();
