#!/usr/bin/env perl
#
# configfirewall stopped firewalld on EL and wrote iptables rules. These are the decisions of
# the firewalld backend.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../xCAT/postscripts";

use Test::More tests => 21;

use xCAT::FirewallUtils;

# backend
is( xCAT::FirewallUtils::backend( redhat => 1, firewalld_unit => 1 ), 'firewalld',
    'EL with firewalld.service uses firewalld' );
is( xCAT::FirewallUtils::backend( redhat => 1, firewalld_unit => 0 ), 'iptables',
    'EL without firewalld.service uses iptables' );
is( xCAT::FirewallUtils::backend( openeuler => 1, firewalld_unit => 1 ), 'firewalld',
    'openEuler with firewalld.service uses firewalld' );
is( xCAT::FirewallUtils::backend( suse => 1, firewalld_unit => 1 ), 'suse', 'SUSE keeps its own path' );
is( xCAT::FirewallUtils::backend( ubuntu => 1 ), 'ubuntu', 'Ubuntu keeps its own path' );
is( xCAT::FirewallUtils::backend(), undef, 'an unknown OS has no backend' );

# port_list
my @ports = xCAT::FirewallUtils::port_list(undef);
ok( ( grep { $_ eq '443' } @ports ), 'the REST API port 443 is open by default' );
ok( ( grep { $_ eq '3001' } @ports ) && ( grep { $_ eq '3002' } @ports ), 'the xcatd ports are open by default' );
is_deeply( [ ( xCAT::FirewallUtils::port_list('22,8080, 9090') )[ -2, -1 ] ], [ '8080', '9090' ],
    'extra ports follow the defaults, once each' );

# zone_plan
my $plan = xCAT::FirewallUtils::zone_plan( [ 'ens4', 'ens5' ], 'ens3' );
is_deeply( $plan, { trusted => [ 'ens4', 'ens5' ], public => ['ens3'] },
    'private NICs are trusted, the public NIC is public' );
is_deeply( xCAT::FirewallUtils::zone_plan( ['ens3'], 'ens3' ), { trusted => ['ens3'], public => [] },
    'a NIC that is both private and public stays trusted' );

# firewalld_commands
my @cmds = map { join ' ', @$_ } xCAT::FirewallUtils::firewalld_commands( $plan, ['443'], undef );
ok( ( grep { $_ eq '--permanent --zone=trusted --change-interface=ens4' } @cmds ), 'a private NIC moves to trusted' );
ok( ( grep { $_ eq '--permanent --zone=public --change-interface=ens3' } @cmds ), 'the public NIC moves to public' );
ok( ( grep { $_ eq '--permanent --zone=public --add-port=443/tcp --add-port=443/udp' } @cmds ),
    'a port opens on the public zone' );
ok( !( grep { /--remove-|--set-target|--load-zone-defaults/ } @cmds ),
    'no command removes what another tool added' );
ok( !( grep { /masquerade|policy/ } @cmds ), 'no NAT without --nat' );

# nat_plan
my $nat = xCAT::FirewallUtils::nat_plan($plan);
my @natcmds = map { join ' ', @$_ } xCAT::FirewallUtils::firewalld_commands( $plan, [], $nat );
ok( ( grep { $_ eq '--permanent --zone=public --add-masquerade' } @natcmds ), '--nat masquerades out of the public zone' );
ok( ( grep { $_ eq '--permanent --policy=xcat-nat --set-target=ACCEPT' } @natcmds )
      && ( grep { $_ eq '--permanent --policy=xcat-nat --add-ingress-zone=trusted' } @natcmds ),
    '--nat forwards from trusted' );
is( xCAT::FirewallUtils::nat_plan( { trusted => ['ens3'], public => [] } ), undef, 'no public NIC, no NAT' );

# networks and private_nics
my %env = (
    NETWORKS_LINES => 2,
    NETWORKS_LINE1 => 'netname=prov||net=192.168.183.0||mask=255.255.255.0||mgtifname=',
    NETWORKS_LINE2 => 'netname=prov6||net=2001:db8:188::/64||mask=/64||mgtifname=',
);
my @nets = xCAT::FirewallUtils::networks_from_env( \%env );
my %addrs = ( ens3 => ['192.168.201.183'], ens4 => ['192.168.183.1'], ens5 => ['2001:db8:188::1'], lo => ['127.0.0.1'] );
is_deeply( [ xCAT::FirewallUtils::private_nics( \@nets, \%addrs ) ], [ 'ens4', 'ens5' ],
    'NICs in an xCAT IPv4 or IPv6 network are private' );
my @tab = xCAT::FirewallUtils::networks_from_tabdump( '#netname,net,mask,mgtifname',
    '"prov","192.168.183.0","255.255.255.0","ens4"' );
is_deeply( \@tab, [ { net => '192.168.183.0', mask => '255.255.255.0' } ], 'tabdump networks gives net and mask' );
