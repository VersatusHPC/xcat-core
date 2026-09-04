use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage, TestingAndDebugging::ProhibitNoStrict, TestingAndDebugging::ProhibitNoWarnings)
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

use JSON;
use Math::BigInt ();
use Socket ();
use Test::More;
use XCAT::Test::File qw(repo_path);

BEGIN {
    package xCAT::Table;
    our $networks;
    sub new {
        my ( $class, $name ) = @_;
        return $name eq 'networks' ? $networks : undef;
    }
    $INC{'xCAT/Table.pm'} = __FILE__;

    package xCAT::TableUtils;
    sub getTftpDir { return '/tftpboot'; }
    sub get_site_attribute { return; }
    $INC{'xCAT/TableUtils.pm'} = __FILE__;

    package xCAT::NetworkUtils;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::getipaddr"} = \&getipaddr;
    }
    our %hostip;
    sub getipaddr {
        my ( $host, %opt ) = @_;
        return if $opt{OnlyV6};
        my $ip = $hostip{$host};
        $ip = $host  if !$ip && $host =~ /^\d+(?:\.\d+){3}$/;
        $ip = '10.0.0.1' unless $ip;
        return $ip unless $opt{GetNumber};
        return Math::BigInt->new( unpack( 'N', Socket::inet_aton($ip) ) );
    }
    sub my_ip_facing { return ( 0, '10.0.0.1' ); }
    sub thishostisnot { return 0; }
    sub ip_forwarding_enabled { return 0; }
    sub nodeonmynet { return 1; }
    sub formatNetmask {
        my ( $mask, $orig_type, $new_type ) = @_;
        my $mask_number;

        if ( $orig_type == 0 ) {
            $mask_number = unpack( 'N', Socket::inet_aton($mask) );
        } elsif ( $orig_type == 1 ) {
            $mask_number = ( 2**$mask - 1 ) << ( 32 - $mask );
        } else {
            return;
        }

        return Socket::inet_ntoa( pack( 'N', $mask_number ) ) if $new_type == 0;
        if ( $new_type == 1 ) {
            my $binary_mask = unpack( 'B32', pack( 'N', $mask_number ) );
            return $binary_mask =~ tr/1/1/;
        }
        return;
    }
    sub isInSameSubnet {
        my ( $ip1, $ip2, $mask, $mask_type ) = @_;
        return unless $mask_type == 0;

        my $mask_number = unpack( 'N', Socket::inet_aton($mask) );
        my $ip1_number  = unpack( 'N', Socket::inet_aton($ip1) );
        my $ip2_number  = unpack( 'N', Socket::inet_aton($ip2) );
        return ( $ip1_number & $mask_number ) == ( $ip2_number & $mask_number ) ? 1 : 0;
    }
    $INC{'xCAT/NetworkUtils.pm'} = __FILE__;

    package xCAT::ServiceNodeUtils;
    sub getSNList { return; }
    $INC{'xCAT/ServiceNodeUtils.pm'} = __FILE__;

    package xCAT::NodeRange;
    $INC{'xCAT/NodeRange.pm'} = __FILE__;
}

require xCAT::Utils;
{
    no warnings 'redefine';
    *xCAT::Utils::osver  = sub { return 'rhels10'; };
    *xCAT::Utils::runcmd = sub { return; };
}

my $source_dhcp_plugin = repo_path('xCAT-server/lib/xcat/plugins/dhcp.pm');
require $source_dhcp_plugin;
require xCAT::DHCP::Backend::Kea;

# The networks table of the makedhcp_remote_network case: one local provisioning
# network, and one network the management node does not face, reached by a DHCP
# relay.  The relay network is marked by the !remote! prefix on mgtifname.
my %local_network = (
    net          => '10.0.0.0',
    mask         => '255.255.255.0',
    mgtifname    => 'eth0',
    dynamicrange => '10.0.0.100-10.0.0.150',
    nameservers  => '10.0.0.1',
    domain       => 'cluster.test',
    tftpserver   => '<xcatmaster>',
    gateway      => '10.0.0.1',
);

my %remote_network = (
    net          => '100.100.100.0',
    mask         => '255.255.255.0',
    mgtifname    => '!remote!eth0',
    dynamicrange => undef,
    nameservers  => '10.0.0.1',
    domain       => 'cluster.test',
    tftpserver   => '10.0.0.1',
    gateway      => '100.100.100.1',
);

{
    package DHCPKeaRemoteNetTable;
    sub new {
        my ( $class, @entries ) = @_;
        return bless { entries => [@entries] }, $class;
    }
    sub getAllAttribs {
        my ( $self, @attrs ) = @_;
        return map { { domain => $_->{domain} } } @{ $self->{entries} }
          if @attrs == 1 && $attrs[0] eq 'domain';
        return map { { %{$_} } } @{ $self->{entries} };
    }
    sub getAttribs {
        my ( $self, $keys ) = @_;
        foreach my $entry ( @{ $self->{entries} } ) {
            next unless $entry->{net} eq $keys->{net} && $entry->{mask} eq $keys->{mask};
            return { %{$entry} };
        }
        return;
    }
    sub close { return; }
}

{
    package DHCPKeaRemoteNodeTable;
    sub new { my ( $class, $rows ) = @_; return bless { rows => $rows }, $class; }
    sub getNodesAttribs {
        my ( $self, $nodes, $attrs ) = @_;
        my %out;
        $out{$_} = [ $self->{rows}{$_} || {} ] for @$nodes;
        return \%out;
    }
    sub close { return; }
}

my $backend = xCAT::DHCP::Backend::Kea->new();

# dhcp.pm keeps its response callback in a file lexical that only process_request
# assigns.  Run one no-op request so the reservation builder can report through
# @plugin_warnings and @plugin_errors.
my @plugin_warnings;
my @plugin_errors;
{
    no warnings 'redefine';
    local *xCAT::MsgUtils::message = sub { return; };
    local *xCAT::MsgUtils::trace   = sub { return; };
    local $::XCATSITEVALS{externaldhcpservers};

    my $saved_umask      = umask;
    my $saved_ignorecase = $Getopt::Long::ignorecase;
    {
        local @ARGV;
        xCAT_plugin::dhcp::process_request(
            { _xcatpreprocessed => [0], arg => [ '-q', '-a' ] },
            sub {
                my ($response) = @_;
                push @plugin_warnings, @{ $response->{warning} || [] };
                push @plugin_errors,   @{ $response->{error}   || [] };
            }
        );
    }
    umask $saved_umask;
    $Getopt::Long::ignorecase = $saved_ignorecase;
    Getopt::Long::Configure('pass_through');
}
@plugin_warnings = ();
@plugin_errors   = ();

# Build the Kea DHCPv4 configuration the way makedhcp -n does, with
# site.dhcpinterfaces naming only the local provisioning interface.
sub dhcp4_config {
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::local_ipv4_routes = sub {
        return ( [ '10.0.0.0', 'eth0', '255.255.255.0', '' ] );
    };
    local *xCAT_plugin::dhcp::kea_boot_client_classes  = sub { return []; };
    local *xCAT_plugin::dhcp::kea_option_defs          = sub { return []; };
    local *xCAT_plugin::dhcp::kea_global_option_data   = sub { return []; };
    local *xCAT_plugin::dhcp::kea_dhcp_lease_time      = sub { return 43200; };
    local *xCAT_plugin::dhcp::kea_control_agent_enabled = sub { return 0; };
    local *xCAT::NetworkUtils::my_ip_facing = sub {
        my ( $class, $net ) = @_;
        return ( 0, '10.0.0.1' ) if $net eq '10.0.0.0';
        return (1);
    };

    local $xCAT::Table::networks =
      DHCPKeaRemoteNetTable->new( \%local_network, \%remote_network );

    my $intent = xCAT_plugin::dhcp::kea_build_dhcp4_intent( $backend, { eth0 => 1 } );
    BAIL_OUT("kea_build_dhcp4_intent failed: $intent->{error}") if $intent->{error};

    return ( $intent, decode_json( $backend->render_dhcp4_config($intent) ) );
}

my ( $intent, $config ) = dhcp4_config();

my %subnet_by_cidr = map { $_->{subnet} => $_ } @{ $config->{Dhcp4}{subnet4} || [] };
my $remote_subnet = $subnet_by_cidr{'100.100.100.0/24'};

ok( $subnet_by_cidr{'10.0.0.0/24'}, 'the local provisioning network keeps its subnet4' );
ok( $remote_subnet,
    'a network reached by a DHCP relay gets a subnet4 without !remote! in dhcpinterfaces' );

is( $subnet_by_cidr{'10.0.0.0/24'}{interface},
    'eth0', 'the local subnet4 binds to the local provisioning interface' );
ok( $remote_subnet && !exists $remote_subnet->{interface},
    'the relayed subnet4 binds to no local interface' );

is_deeply( $config->{Dhcp4}{'interfaces-config'}{interfaces},
    ['eth0'], 'kea listens only on the local provisioning interface' );

is_deeply( $remote_subnet && $remote_subnet->{pools},
    [], 'the relayed network declares no dynamic pool' );

# The reservation builder resolves the node IP to a subnet id.  Drive it against
# the configuration above, the way makedhcp <node> does.
{
    no warnings 'redefine';

    my %node_tables = (
        noderes  => DHCPKeaRemoteNodeTable->new( { testnode => { netboot => 'xnba', tftpserver => '10.0.0.1' } } ),
        chain    => DHCPKeaRemoteNodeTable->new( { testnode => {} } ),
        nodetype => DHCPKeaRemoteNodeTable->new( { testnode => { arch => 'x86_64', provmethod => 'install', os => 'rhels10' } } ),
        iscsi    => DHCPKeaRemoteNodeTable->new( {} ),
        mac      => DHCPKeaRemoteNodeTable->new( { testnode => { mac => '42:3d:0a:05:27:0b' } } ),
    );
    local *xCAT::Table::new = sub {
        my ( $class, $name ) = @_;
        return $node_tables{$name};
    };

    local $xCAT::NetworkUtils::hostip{testnode} = '100.100.100.2';
    local *xCAT_plugin::dhcp::ipIsDynamic    = sub { return 0; };
    local *xCAT::NetworkUtils::my_ip_facing  = sub { return ( 0, '10.0.0.1' ); };
    local *xCAT::MsgUtils::message           = sub { return; };
    local *xCAT::MsgUtils::trace             = sub { return; };

    my $reservations =
      xCAT_plugin::dhcp::kea_build_node_reservations( $backend, $config, ['testnode'] );

    is( scalar(@plugin_errors),   0, 'a node on a relayed network reserves without errors' );
    is( scalar(@plugin_warnings), 0, 'a node on a relayed network reserves without warnings' );
    is( scalar( @{ $reservations || [] } ),
        1, 'a node on a relayed network yields one Kea host reservation' );

    my $reservation = $reservations->[0] || {};
    is( $reservation->{'ip-address'}, '100.100.100.2',
        'the reservation carries the node IP on the relayed network' );
    is( $reservation->{'hw-address'}, '42:3d:0a:05:27:0b', 'the reservation carries the node MAC' );
    is( $reservation->{hostname},     'testnode',          'the reservation carries the node name' );
    ok(
        $remote_subnet
          && defined( $reservation->{'subnet-id'} )
          && $reservation->{'subnet-id'} == $remote_subnet->{id},
        'the reservation lands in the subnet of the relayed network'
    );
}

done_testing();
