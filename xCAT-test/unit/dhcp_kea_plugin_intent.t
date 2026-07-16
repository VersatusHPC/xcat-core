use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage, TestingAndDebugging::ProhibitNoStrict, TestingAndDebugging::ProhibitNoWarnings)
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Temp qw(tempdir);
use Test::More;

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

    package xCAT::Utils;
    sub osver { return 'rhels9'; }
    sub runcmd { return; }
    $INC{'xCAT/Utils.pm'} = __FILE__;

    package xCAT::NetworkUtils;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::getipaddr"} = \&getipaddr;
    }
    sub getipaddr { return '10.0.0.1'; }
    sub my_ip_facing { return ( 0, '10.0.0.1' ); }
    sub my_ip_facing_family { return ( 0, '2001:db8::1' ); }
    sub node_is_ipv6_only {
        my $node = $_[-1];
        return 0 if getipaddr($node, OnlyV4 => 1);
        return getipaddr($node, OnlyV6 => 1) ? 1 : 0;
    }
    sub ipv6_server_for_node {
        my ( $class, $node, $server ) = @_;
        ( $node, $server ) = ( $class, $node ) if $class ne __PACKAGE__;
        if (!defined($server) || $server eq '!myipfn!' || $server eq '<xcatmaster>') {
            my @facing = my_ip_facing_family(__PACKAGE__, $node, 6);
            return unless @facing && !$facing[0];
            return $facing[1];
        }
        return $server if $server =~ /:/ && isValidIPAddress(__PACKAGE__, $server);
        return getipaddr($server, OnlyV6 => 1);
    }
    sub isValidIPAddress {
        my $addr = $_[-1];
        return 0 unless defined($addr) && length($addr);
        return 1 if $addr =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
        return 1 if $addr =~ /^[0-9a-fA-F:]+$/ && $addr =~ /:/;
        return 0;
    }
    sub getIPv6PrefixLength {
        my ( $class, $network, $mask ) = @_;
        ( $network, $mask ) = ( $class, $network ) if $class ne __PACKAGE__;
        return $1 if defined($network) && $network =~ m{/([0-9]+)$} && $1 <= 128;
        return $1 if defined($mask) && $mask =~ m{^/?([0-9]+)$} && $1 <= 128;
        return;
    }
    sub getIPv6ReverseZone {
        my ( $class, $network, $mask ) = @_;
        ( $network, $mask ) = ( $class, $network ) if $class ne __PACKAGE__;
        my $prefix = getIPv6PrefixLength(__PACKAGE__, $network, $mask);
        return unless defined($prefix);
        return '0.0.0.0.9.0.3.7.8.b.d.0.1.0.0.2.ip6.arpa.'
          if $network =~ /^2001:db8:7309::/ && $prefix == 64;
        return;
    }
    sub format_uri_host {
        my ($host) = @_;
        $host = $_[1] if defined($host) && $host eq __PACKAGE__;
        return "[$host]" if defined($host) && $host =~ /:/;
        return $host;
    }
    sub thishostisnot { return 0; }
    sub ip_forwarding_enabled { return 0; }
    sub nodeonmynet { return 1; }
    $INC{'xCAT/NetworkUtils.pm'} = __FILE__;

    package xCAT::ServiceNodeUtils;
    sub getSNList { return; }
    $INC{'xCAT/ServiceNodeUtils.pm'} = __FILE__;

    package xCAT::NodeRange;
    $INC{'xCAT/NodeRange.pm'} = __FILE__;
}

my $source_dhcp_plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm";
if ( -f $source_dhcp_plugin ) {
    require $source_dhcp_plugin;
} else {
    require xCAT_plugin::dhcp;
}

{
    package DHCPKeaIntentNetTable;
    sub new {
        my ( $class, $entry ) = @_;
        return bless { entry => $entry }, $class;
    }
    sub getAllAttribs {
        my ( $self, @attrs ) = @_;
        return { domain => $self->{entry}{domain} } if @attrs == 1 && $attrs[0] eq 'domain';
        return { %{ $self->{entry} } };
    }
    sub getAttribs {
        my ($self) = @_;
        return { %{ $self->{entry} } };
    }
    sub close { return; }

    package DHCPKeaIntentFilteredNetTable;
    our @ISA = ('DHCPKeaIntentNetTable');
    sub getAllAttribs {
        my ( $self, @attrs ) = @_;
        return {
            map { $_ => $self->{entry}{$_} }
              grep { exists $self->{entry}{$_} } @attrs
        };
    }
}

my %network_entry = (
    net          => '10.0.0.0',
    mask         => '255.255.255.0',
    mgtifname    => 'eth0',
    dynamicrange => '10.0.0.100-10.0.0.150',
    domain       => 'cluster.test',
    tftpserver   => '<xcatmaster>',
);

ok(xCAT_plugin::dhcp::dhcpd_sysconfig_uses_interface_key('opensuse-leap15.6'), 'openSUSE Leap head node uses SUSE dhcpd interface key');
ok(xCAT_plugin::dhcp::dhcpd_sysconfig_uses_interface_key('leap15.6'), 'Leap head node osver uses SUSE dhcpd interface key');
ok(!xCAT_plugin::dhcp::dhcpd_sysconfig_uses_interface_key('opensuse-tumbleweed'), 'generic openSUSE names do not enable Leap-specific dhcpd handling');

{
    # Regression: makenetworks stores some IPv6 networks as a literal in
    # networks.net and a numeric prefix in networks.mask. Reverse-zone
    # generation must consume that representation without looping.
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::getipaddr = sub {
        my ( $address, %options ) = @_;
        return Math::BigInt->new('0x20010db8730900000000000000000000')
          if $address eq '2001:db8:7309::' && $options{GetNumber};
        return;
    };

    my ($zone, $error);
    {
        local $SIG{ALRM} = sub { die "IPv6 reverse-zone generation timed out\n" };
        eval {
            alarm 2;
            $zone = xCAT_plugin::dhcp::getzonesfornet(
                '2001:db8:7309::', '64'
            );
            alarm 0;
            1;
        } or $error = $@;
        alarm 0;
    }
    is($error, undef, 'Kea DDNS reverse-zone generation terminates');
    is(
        $zone,
        '0.0.0.0.9.0.3.7.8.b.d.0.1.0.0.2.ip6.arpa.',
        'Kea DDNS accepts an IPv6 network with a separate numeric prefix mask'
    );
    is_deeply(
        [ xCAT_plugin::dhcp::getzonesfornet('2001:db8:7309::', undef) ],
        [],
        'Kea DDNS rejects a missing IPv6 prefix without looping'
    );
    is_deeply(
        [ xCAT_plugin::dhcp::getzonesfornet('2001:db8:7309::', '129') ],
        [],
        'Kea DDNS rejects an out-of-range IPv6 prefix without looping'
    );
}

{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $fake_ip = "$tmpdir/ip";
    open(my $ip_fh, '>', $fake_ip) or die "Cannot write fake ip command: $!";
    print {$ip_fh} "#!/bin/sh\n";
    print {$ip_fh} "cat <<'EOF'\n";
    print {$ip_fh} "default via 192.168.1.1 dev eth1 proto dhcp\n";
    print {$ip_fh} "10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.1\n";
    print {$ip_fh} "192.168.1.0/24 dev eth1 proto kernel scope link src 192.168.1.20\n";
    print {$ip_fh} "EOF\n";
    close($ip_fh);
    chmod 0755, $fake_ip;

    no warnings 'redefine';
    local *xCAT_plugin::dhcp::kea_command_path = sub {
        my ($command) = @_;
        return $fake_ip if $command eq 'ip';
        return;
    };

    is_deeply(
        [ xCAT_plugin::dhcp::local_ipv4_routes() ],
        [
            [ '0.0.0.0',     'eth1', '0.0.0.0',       'G' ],
            [ '10.0.0.0',    'eth0', '255.255.255.0', '' ],
            [ '192.168.1.0', 'eth1', '255.255.255.0', '' ],
        ],
        'local IPv4 route detection prefers ip route output'
    );
}

{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $fake_netstat = "$tmpdir/netstat";
    open(my $netstat_fh, '>', $fake_netstat) or die "Cannot write fake netstat command: $!";
    print {$netstat_fh} "#!/bin/sh\n";
    print {$netstat_fh} "cat <<'EOF'\n";
    print {$netstat_fh} "Kernel IP routing table\n";
    print {$netstat_fh} "Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface\n";
    print {$netstat_fh} "0.0.0.0         192.168.1.1     0.0.0.0         UG        0 0          0 eth1\n";
    print {$netstat_fh} "10.0.0.0        0.0.0.0         255.255.255.0   U         0 0          0 eth0\n";
    print {$netstat_fh} "EOF\n";
    close($netstat_fh);
    chmod 0755, $fake_netstat;

    no warnings 'redefine';
    local *xCAT_plugin::dhcp::kea_command_path = sub {
        my ($command) = @_;
        return $fake_netstat if $command eq 'netstat';
        return;
    };

    is_deeply(
        [ xCAT_plugin::dhcp::local_ipv4_routes() ],
        [
            [ '0.0.0.0',  'eth1', '0.0.0.0',       'UG' ],
            [ '10.0.0.0', 'eth0', '255.255.255.0', 'U' ],
        ],
        'local IPv4 route detection falls back to netstat output'
    );
}

{
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::kea_ipv4_routes = sub {
        return (
            [ '10.0.0.0',    'eth0',  '255.255.255.0', '' ],
            [ '192.168.1.0', 'enp3s0', '255.255.255.0', '' ],
        );
    };
    local *xCAT_plugin::dhcp::kea_boot_client_classes = sub { return []; };
    local *xCAT_plugin::dhcp::kea_option_defs = sub { return []; };
    local *xCAT_plugin::dhcp::kea_global_option_data = sub { return []; };
    local *xCAT_plugin::dhcp::kea_dhcp_lease_time = sub { return 43200; };
    local *xCAT_plugin::dhcp::kea_control_agent_enabled = sub { return 0; };

    local $xCAT::Table::networks = DHCPKeaIntentNetTable->new( \%network_entry );

    my $intent = xCAT_plugin::dhcp::kea_build_dhcp4_intent( bless({}, 'DHCPKeaIntentBackend'), {} );

    is_deeply( $intent->{interfaces}, ['eth0'], 'empty dhcpinterfaces infers the local provisioning interface' );
    is( scalar @{ $intent->{subnets} }, 1, 'empty dhcpinterfaces still renders local routed subnet' );
    is( $intent->{subnets}[0]{subnet}, '10.0.0.0/24', 'rendered subnet comes from local route' );
}

{
    package DHCPKeaControlSocketBackend;
    sub control_socket_name {
        my ( $self, $name ) = @_;
        return "shared-$name";
    }
    sub host_cmds_hook_path { return '/usr/lib64/kea/hooks/libdhcp_host_cmds.so'; }

    package main;
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::kea_ipv4_routes = sub {
        return ([ '10.0.0.0', 'eth0', '255.255.255.0', '' ]);
    };
    local *xCAT_plugin::dhcp::kea_boot_client_classes = sub { return []; };
    local *xCAT_plugin::dhcp::kea_option_defs = sub { return []; };
    local *xCAT_plugin::dhcp::kea_global_option_data = sub { return []; };
    local *xCAT_plugin::dhcp::kea_dhcp_lease_time = sub { return 43200; };
    local *xCAT_plugin::dhcp::kea_control_agent_enabled = sub { return 1; };

    my $backend = bless {}, 'DHCPKeaControlSocketBackend';
    local $xCAT::Table::networks = DHCPKeaIntentNetTable->new( \%network_entry );
    my $intent4 = xCAT_plugin::dhcp::kea_build_dhcp4_intent($backend, { eth0 => 1 });
    is(
        $intent4->{'control-socket'}{'socket-name'},
        'shared-kea4-ctrl-socket',
        'DHCPv4 and Control Agent use the shared Kea socket-name policy'
    );

    local $xCAT::Table::networks = DHCPKeaIntentNetTable->new(
        {
            net       => '2001:db8:7309::',
            mask      => '64',
            mgtifname => 'eth0',
            domain    => 'cluster.test',
        }
    );
    my $intent6 = xCAT_plugin::dhcp::kea_build_dhcp6_intent($backend, { eth0 => 1 });
    is(
        $intent6->{'control-socket'}{'socket-name'},
        'shared-kea6-ctrl-socket',
        'DHCPv6 and Control Agent use the shared Kea socket-name policy'
    );
}

{
    no warnings 'redefine';
    local *xCAT::NetworkUtils::thishostisnot = sub { return 1; };

    my $nettab = DHCPKeaIntentNetTable->new(
        {
            %network_entry,
            dhcpserver => 'service-node-a',
        }
    );

    my $subnet = xCAT_plugin::dhcp::kea_subnet4_intent( $nettab, '10.0.0.0', '255.255.255.0', 'eth0', 0, 1, 80 );
    ok( !defined( $subnet->{dynamicrange} ), 'non-owning Kea server does not render dynamic pool' );
}

{
    no warnings 'redefine';
    local *xCAT::NetworkUtils::thishostisnot = sub { return 0; };

    my $nettab = DHCPKeaIntentNetTable->new(
        {
            %network_entry,
            dhcpserver => 'service-node-a',
        }
    );

    my $subnet = xCAT_plugin::dhcp::kea_subnet4_intent( $nettab, '10.0.0.0', '255.255.255.0', 'eth0', 0, 1, 80 );
    is( $subnet->{dynamicrange}, $network_entry{dynamicrange}, 'owning Kea server renders dynamic pool' );
}

{
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::kea_dhcp_lease_time = sub { return 43200; };
    local *xCAT_plugin::dhcp::kea_control_agent_enabled = sub { return 0; };

    my %network6_entry = (
        net          => '2001:db8:7309::',
        mask         => '64',
        mgtifname    => 'eth0',
        dynamicrange => '2001:db8:7309::100/120',
        domain       => 'cluster.test',
        dhcpserver   => 'service-node-a',
    );
    my $backend = bless {}, 'DHCPKeaIntentBackend';

    {
        local *xCAT::NetworkUtils::thishostisnot = sub { return 1; };
        local $xCAT::Table::networks = DHCPKeaIntentFilteredNetTable->new( \%network6_entry );

        my $intent = xCAT_plugin::dhcp::kea_build_dhcp6_intent( $backend, { eth0 => 1 } );
        ok( !defined( $intent->{subnets}[0]{dynamicrange} ), 'non-owning Kea DHCPv6 server does not render dynamic pool' );
    }

    {
        local *xCAT::NetworkUtils::thishostisnot = sub { return 0; };
        local $xCAT::Table::networks = DHCPKeaIntentFilteredNetTable->new( \%network6_entry );

        my $intent = xCAT_plugin::dhcp::kea_build_dhcp6_intent( $backend, { eth0 => 1 } );
        is( $intent->{subnets}[0]{dynamicrange}, $network6_entry{dynamicrange}, 'owning Kea DHCPv6 server renders dynamic pool' );
    }

    {
        local *xCAT::NetworkUtils::my_ip_facing_family = sub {
            return ( 0, '2001:db8:7309::1' );
        };
        my $v6_getipaddr = sub {
            my ( $host, %options ) = @_;
            return unless $options{OnlyV6};
            return '2001:db8::53' if $host eq 'dns6.example.test';
            return;
        };
        local *xCAT::NetworkUtils::getipaddr = $v6_getipaddr;
        local *xCAT_plugin::dhcp::getipaddr = $v6_getipaddr;

        is(
            xCAT_plugin::dhcp::kea_ipv6_nameservers(
                '2001:db8:7309::/64',
                '<xcatmaster>, 192.0.2.53, dns6.example.test'
            ),
            '2001:db8:7309::1, 2001:db8::53',
            'DHCPv6 resolves the local xCAT server and filters IPv4 DNS fallbacks'
        );

        my %dns_network6 = (
            %network6_entry,
            nameservers => '<xcatmaster>, 192.0.2.53',
        );
        my $subnet = xCAT_plugin::dhcp::kea_subnet6_intent(
            \%dns_network6, 'eth0', 0, 10001
        );
        my ($dns_option) = grep { $_->{name} eq 'dns-servers' }
          @{ $subnet->{option_data} || [] };
        is(
            $dns_option->{data},
            '2001:db8:7309::1',
            'service-node DHCPv6 advertises its compute-facing IPv6 DNS address'
        );
    }
}

{
    # Regression: networks.nameservers / site.nameservers default to the
    # <xcatmaster> placeholder.  Kea D2 rejects a non-IP dns-servers ip-address,
    # so kea_build_ddns_intent must resolve <xcatmaster> to the management IP
    # facing the network (via my_ip_facing) before rendering DDNS domains.
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::kea_ddns_enabled = sub { 1 };
    local *xCAT_plugin::dhcp::kea_ddns_key     = sub { ( 'HMAC-SHA256', 'YWJjMTIz' ); };

    local $xCAT::Table::networks = DHCPKeaIntentNetTable->new(
        {
            %network_entry,
            nameservers => '<xcatmaster>',
        }
    );

    my $ddns_intent = xCAT_plugin::dhcp::kea_build_ddns_intent();

    ok( $ddns_intent && !$ddns_intent->{error}, 'kea_build_ddns_intent succeeds with <xcatmaster> nameservers' );
    ok( scalar @{ $ddns_intent->{forward_domains} || [] }, 'kea_build_ddns_intent renders a forward DDNS domain' );
    ok( scalar @{ $ddns_intent->{reverse_domains} || [] }, 'kea_build_ddns_intent renders a reverse DDNS domain' );

    my @dns_ips =
      map { $_->{'ip-address'} }
      map { @{ $_->{'dns-servers'} || [] } }
      ( @{ $ddns_intent->{forward_domains} || [] }, @{ $ddns_intent->{reverse_domains} || [] } );

    ok( scalar @dns_ips, 'rendered DDNS domains carry dns-servers' );
    foreach my $ip (@dns_ips) {
        isnt( $ip, '<xcatmaster>', 'DDNS dns-server ip-address is never the literal <xcatmaster> placeholder' );
        is( $ip, '10.0.0.1', 'DDNS dns-server ip-address resolves to the management IP facing the network' );
        like( $ip, qr/^\d+\.\d+\.\d+\.\d+$/, 'DDNS dns-server ip-address is a valid IPv4 literal' );
    }
}

{
    # The same placeholder resolution and reverse-zone path must work when an
    # IPv6 network stores its prefix in networks.mask instead of CIDR notation.
    no warnings 'redefine';
    local *xCAT_plugin::dhcp::kea_ddns_enabled = sub { 1 };
    local *xCAT_plugin::dhcp::kea_ddns_key     = sub { ( 'HMAC-SHA256', 'YWJjMTIz' ); };
    local *xCAT_plugin::dhcp::getipaddr = sub {
        my ( $address, %options ) = @_;
        return Math::BigInt->new('0x20010db8730900000000000000000000')
          if $address eq '2001:db8:7309::' && $options{GetNumber};
        return;
    };
    local $xCAT::Table::networks = DHCPKeaIntentNetTable->new(
        {
            net         => '2001:db8:7309::',
            mask        => '64',
            nameservers => '<xcatmaster>',
            domain      => 'cluster.test',
        }
    );

    my ($ddns_intent, $error);
    {
        local $SIG{ALRM} = sub { die "IPv6 Kea DDNS intent timed out\n" };
        eval {
            alarm 2;
            $ddns_intent = xCAT_plugin::dhcp::kea_build_ddns_intent();
            alarm 0;
            1;
        } or $error = $@;
        alarm 0;
    }

    is($error, undef, 'IPv6 Kea DDNS intent generation terminates');
    ok(
        $ddns_intent && !$ddns_intent->{error},
        'IPv6 Kea DDNS intent accepts a separate numeric prefix mask'
    );
    is(
        $ddns_intent->{reverse_domains}[0]{name},
        '0.0.0.0.9.0.3.7.8.b.d.0.1.0.0.2.ip6.arpa.',
        'IPv6 Kea DDNS intent renders the expected reverse zone'
    );
    is(
        $ddns_intent->{reverse_domains}[0]{'dns-servers'}[0]{'ip-address'},
        '2001:db8::1',
        'IPv6 Kea DDNS resolves <xcatmaster> to the IPv6-facing management address'
    );
}

{
    # Regression: a service node (noderes.servicenode set, groups=service) must
    # get a Kea host reservation exactly like a regular compute node.  The Kea
    # reservation builder loops over every requested node without filtering on
    # service-node membership, so kea_build_node_reservations must emit an
    # ip/mac/hostname reservation whose next-server is resolved (via
    # my_ip_facing) to the management server that serves the node's subnet.
    package DHCPKeaResTable;
    sub new { my ( $class, $rows ) = @_; return bless { rows => $rows }, $class; }
    sub getNodesAttribs {
        my ( $self, $nodes, $attrs ) = @_;
        my %out;
        foreach my $node (@$nodes) {
            my $row = $self->{rows}{$node} || {};
            $out{$node} = [ { map { exists($row->{$_}) ? ($_ => $row->{$_}) : () } @$attrs } ];
        }
        return \%out;
    }
    sub close { return; }

    package main;

    my %res_tables = (
        noderes  => DHCPKeaResTable->new( { 'svc01' => { netboot => 'xnba', servicenode => '192.168.201.20', tftpserver => '<xcatmaster>' } } ),
        chain    => DHCPKeaResTable->new( { 'svc01' => {} } ),
        nodetype => DHCPKeaResTable->new( { 'svc01' => { arch => 'x86_64', provmethod => 'install', os => 'rhels9' } } ),
        iscsi    => DHCPKeaResTable->new( {} ),
        mac      => DHCPKeaResTable->new( { 'svc01' => { mac => '42:d7:c0:a8:c9:15' } } ),
    );

    no warnings 'redefine';
    local *xCAT::Table::new = sub {
        my ( $class, $name ) = @_;
        return $res_tables{$name};
    };
    my $svc_getipaddr = sub {
        my ( $host, %opt ) = @_;
        return if $opt{OnlyV6};
        return '192.168.201.21';
    };
    local *xCAT::NetworkUtils::getipaddr = $svc_getipaddr;
    # dhcp.pm imports getipaddr into its own namespace at use-time, so override
    # the imported copy as well.
    local *xCAT_plugin::dhcp::getipaddr = $svc_getipaddr;
    local *xCAT::NetworkUtils::my_ip_facing = sub { return ( 0, '192.168.201.20' ); };
    local *xCAT_plugin::dhcp::ipIsDynamic = sub { return 0; };

    my @errors;
    local $xCAT_plugin::dhcp::callback = sub {
        my $resp = shift;
        push @errors, @{ $resp->{error} } if $resp->{error};
    };

    my $backend = bless {}, 'DHCPKeaResBackend';
    {
        package DHCPKeaResBackend;
        sub subnet_id_for_ip { return 1; }
    }

    my $reservations = xCAT_plugin::dhcp::kea_build_node_reservations( $backend, {}, ['svc01'] );

    is( scalar(@errors), 0, 'service node reservation builds without errors' );
    is( scalar( @{ $reservations || [] } ), 1, 'service node yields exactly one Kea host reservation' );
    my $r = $reservations->[0] || {};
    is( $r->{'ip-address'},  '192.168.201.21',    'service node reservation carries the node IP' );
    is( $r->{'hw-address'},  '42:d7:c0:a8:c9:15', 'service node reservation carries the node MAC' );
    is( $r->{hostname},      'svc01',             'service node reservation carries the hostname' );
    is( $r->{'next-server'}, '192.168.201.20',    'service node reservation next-server resolves to the serving management IP' );
}

{
    my %res_tables = (
        noderes => DHCPKeaResTable->new(
            {
                'nodev6'     => { netboot => 'grub2',      tftpserver => '<xcatmaster>' },
                'nodev6http' => { netboot => 'grub2-http', tftpserver => 'boot6.example.test' },
                'nodev6tftp' => { netboot => 'grub2-tftp', tftpserver => 'boot6.example.test' },
                'nodev6xnba' => { netboot => 'xnba',       tftpserver => 'boot6.example.test' },
            }
        ),
        mac => DHCPKeaResTable->new(
            {
                'nodev6'     => { mac => '02:00:00:00:00:61' },
                'nodev6http' => { mac => '02:00:00:00:00:62' },
                'nodev6tftp' => { mac => '02:00:00:00:00:64' },
                'nodev6xnba' => { mac => '02:00:00:00:00:63' },
            }
        ),
        vpd => DHCPKeaResTable->new(
            {
                'nodev6'     => { uuid => '00112233-4455-6677-8899-aabbccddeeff' },
                'nodev6http' => {},
                'nodev6tftp' => {},
                'nodev6xnba' => {},
            }
        ),
    );

    no warnings 'redefine';
    local *xCAT::Table::new = sub {
        my ( $class, $name ) = @_;
        return $res_tables{$name};
    };
    my %node_addresses = (
        nodev6             => '2001:db8:61::50',
        nodev6http         => '2001:db8:62::50',
        nodev6tftp         => '2001:db8:64::50',
        nodev6xnba         => '2001:db8:63::50',
        'boot6.example.test' => '2001:db8::10',
    );
    my $v6_getipaddr = sub {
        my ( $host, %opt ) = @_;
        return unless $opt{OnlyV6};
        return $node_addresses{$host};
    };
    local *xCAT::NetworkUtils::getipaddr = $v6_getipaddr;
    local *xCAT_plugin::dhcp::getipaddr = $v6_getipaddr;
    local *xCAT::NetworkUtils::my_ip_facing_family = sub {
        my ( $class, $peer, $family ) = @_;
        return ( 1, 'unexpected address family' ) unless $family == 6;
        return ( 0, '2001:db8::1' );
    };
    local *xCAT_plugin::dhcp::ipIsDynamic = sub { return 0; };

    my @errors;
    local $xCAT_plugin::dhcp::callback = sub {
        my $resp = shift;
        push @errors, @{ $resp->{error} } if $resp->{error};
    };

    my $backend = bless {}, 'DHCPKeaRes6Backend';
    {
        package DHCPKeaRes6Backend;
        sub subnet_id_for_ip { return 61; }
    }

    my $reservations = xCAT_plugin::dhcp::kea_build_node_reservations6(
        $backend,
        {},
        [qw(nodev6 nodev6http nodev6tftp nodev6xnba)]
    );

    is( scalar(@errors), 0, 'DHCPv6 reservations build without errors' );
    is( scalar(@$reservations), 4, 'all known IPv6 nodes receive reservations' );

    my %by_hostname = map { $_->{hostname} => $_ } @$reservations;
    my $grub2 = $by_hostname{nodev6};
    is( $grub2->{duid}, '00:04:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff', 'DHCPv6 reservation retains DUID-UUID matching' );
    is( $grub2->{'option-data'}[0]{name}, 'bootfile-url', 'grub2 reservation carries RFC 5970 bootfile-url' );
    is( $grub2->{'option-data'}[0]{data}, 'tftp://[2001:db8::1]/boot/grub2/grub2-nodev6', 'grub2 bootfile URL uses the IPv6-facing xCAT server and bracketed authority' );
    ok( $grub2->{'option-data'}[0]{'always-send'}, 'grub2 bootfile URL is always sent' );

    my $grub2_http = $by_hostname{nodev6http};
    is( $grub2_http->{'hw-address'}, '02:00:00:00:00:62', 'DHCPv6 reservation retains hardware-address fallback' );
    is( $grub2_http->{'option-data'}[0]{data}, 'tftp://[2001:db8::10]/boot/grub2/grub2-nodev6http', 'grub2-http firmware handoff still loads GRUB over TFTP from the configured IPv6 server' );

    my $grub2_tftp = $by_hostname{nodev6tftp};
    is( $grub2_tftp->{'option-data'}[0]{data}, 'tftp://[2001:db8::10]/boot/grub2/grub2-nodev6tftp', 'grub2-tftp receives the DHCPv6 bootfile URL advertised as supported on x86_64' );

    ok( !exists($by_hostname{nodev6xnba}{'option-data'}), 'unsupported IPv6 netboot modes do not receive a GRUB bootfile URL' );
}

done_testing();
