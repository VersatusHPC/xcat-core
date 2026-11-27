#!/usr/bin/env perl
# The dhcp plugin's FreeBSD host and class rendering, in process. The ISC and Kea parsers read
# the same output in xCAT-test/integration/freebsd_dhcp_plugin.t.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib grep { defined($_) } $ENV{XCAT_FREEBSD_DHCP_POLICY_DIR};
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON ();
use Test::More;
use xCAT::CommandUtils;

BEGIN {
    package xCAT::Table;
    our %rows;
    sub new { return bless { name => $_[1] }, $_[0]; }
    sub getNodesAttribs {
        my ($self, $nodes, $attributes) = @_;
        my %result;
        for my $node (@$nodes) {
            my $row = $rows{$self->{name}}{$node} || next;
            $result{$node} = [ { map { $_ => $row->{$_} } @$attributes } ];
        }
        return \%result;
    }
    $INC{'xCAT/Table.pm'} = __FILE__;

    package xCAT::TableUtils;
    our $tftpdir;
    sub getTftpDir { return $tftpdir; }
    sub get_site_attribute { return; }
    $INC{'xCAT/TableUtils.pm'} = __FILE__;

    package xCAT::NetworkUtils;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::getipaddr"} = \&getipaddr;
    }
    sub getipaddr { return '192.0.2.20'; }
    sub my_ip_facing { return (0, '192.0.2.1'); }
    sub node_is_ipv6_only { return 0; }
    sub isIpv6addr { return ($_[1] // '') =~ /:/ ? 1 : 0; }
    $INC{'xCAT/NetworkUtils.pm'} = __FILE__;

    package xCAT::ServiceNodeUtils;
    $INC{'xCAT/ServiceNodeUtils.pm'} = __FILE__;
    package xCAT::NodeRange;
    $INC{'xCAT/NodeRange.pm'} = __FILE__;
}

my $temporary = tempdir(CLEANUP => 1);
local $ENV{XCATROOT} = $temporary;
$xCAT::TableUtils::tftpdir = "$temporary/tftp";
make_path("$temporary/tftp/xcat");
for my $loader (qw(xnba.kpxe xnba.efi)) {
    open(my $file, '>', "$temporary/tftp/xcat/$loader") or die $!;
    print {$file} 'loader fixture';
    close($file);
}
require xCAT::Utils;
{
    no warnings qw(once redefine);
    *xCAT::Utils::osver = sub { return 'ubuntu22.04'; };
    *xCAT::Utils::runcmd = sub { return; };
}
my $plugin = $ENV{XCAT_FREEBSD_DHCP_PLUGIN} || "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm";
require $plugin;

{
    package FreeBSDDHCPBackend;
    sub subnet_id_for_ip { return 1; }
}
my $backend = bless {}, 'FreeBSDDHCPBackend';
my @messages;
{
    no warnings qw(once redefine);
    local *xCAT::MsgUtils::message = sub { return; };
    local *xCAT::MsgUtils::trace = sub { return; };
    local @ARGV;
    my $mask = umask;
    xCAT_plugin::dhcp::process_request(
        { _xcatpreprocessed => [0], arg => ['-q', '-a'] },
        sub { push @messages, @_ },
    );
    umask $mask;
}
@messages = ();

sub fixture {
    my (%change) = @_;
    %xCAT::Table::rows = (
        noderes => { node01 => { netboot => 'xnba', xcatmaster => '192.0.2.1', %{$change{noderes} || {}} } },
        nodetype => { node01 => { os => 'freebsd15.1', arch => 'x86_64', %{$change{nodetype} || {}} } },
        mac => { node01 => { mac => '52:54:00:12:34:56', %{$change{mac} || {}} } },
        chain => { node01 => { currstate => 'install' } },
        iscsi => { node01 => $change{iscsi} || {} },
    );
    @messages = ();
}

sub isc_config {
    my $node = shift || 'node01';
    xCAT_plugin::dhcp::kea_build_node_reservations($backend, {}, [$node]);
    my @config;
    my $writer = \&xCAT_plugin::dhcp::_add_isc_static_host;
    no warnings qw(once redefine);
    local *xCAT::DBobjUtils::getNetwkInfo = sub { return ($node => { mgtifname => 'eth0' }); };
    local *xCAT_plugin::dhcp::_add_isc_static_host = sub {
        my @arguments = @_;
        $arguments[8] = \@config;
        $writer->(@arguments);
    };
    xCAT_plugin::dhcp::addnode($node);
    return join('', @config);
}

sub node_classes {
    return xCAT_plugin::dhcp::kea_node_client_classes_for_nodes(@_)->{classes}
        if xCAT_plugin::dhcp->can('kea_node_client_classes_for_nodes');
    return xCAT_plugin::dhcp::kea_xnba_client_classes_for_nodes(@_);
}

sub sync_classes {
    my $sync = xCAT_plugin::dhcp->can('kea_sync_node_client_classes') ||
        xCAT_plugin::dhcp->can('kea_sync_xnba_client_classes');
    return $sync->(@_);
}

sub remove_classes {
    my $remove = xCAT_plugin::dhcp->can('kea_remove_node_client_classes') ||
        xCAT_plugin::dhcp->can('kea_remove_xnba_client_classes');
    return $remove->(@_);
}

my $root_path = 'tftp://192.0.2.1/xcat/freebsd/node01';
fixture();
my $isc = isc_config();
like($isc, qr/if option user-class-identifier = 07:46:72:65:65:42:53:44 \{ option root-path "\Q$root_path\E"; \}/,
    'ISC host configuration limits the native root to the exact FreeBSD user class');
unlike($isc, qr/tftp:\/\/\$\{next-server\}/, 'ISC resolves a concrete server rather than an xNBA expansion');
like($isc, qr/xcat\/xnba\.kpxe/, 'firmware keeps the existing xNBA loader');
my $classes = node_classes(['node01']);
my ($native) = grep { ($_->{'user-context'}{'xcat-purpose'} || '') eq 'freebsd-native-loader' } @$classes;
is_deeply($native->{'option-data'}, [{ name => 'root-path', data => $root_path, 'always-send' => JSON::true }],
    'Kea native class sends the per-node TFTP root');
is($native->{test}, 'option[77].exists and option[77].hex == 0x0746726565425344 and pkt4.mac == 0x525400123456',
    'Kea uses the exact tuple and MAC without firmware architecture assumptions');
ok(!exists($native->{'boot-file-name'}), 'the native class does not replace xNBA boot filenames');
my $reservations = xCAT_plugin::dhcp::kea_build_node_reservations($backend, {}, ['node01']);
is_deeply([grep { $_->{name} eq 'root-path' } @{$reservations->[0]{'option-data'}}], [],
    'Kea reservations never expose the FreeBSD root to firmware or xNBA');

for my $os (qw(freebsd15.1 rhels9)) {
    fixture(nodetype => { os => $os });
    for my $table (values %xCAT::Table::rows) {
        $table->{filename01} = delete $table->{node01};
    }
    $xCAT::Table::rows{noderes}{filename01}{xcatmaster} = '' if $os eq 'rhels9';
    my $named = isc_config('filename01');
    like($named, qr/filename = "xcat\/xnba\.kpxe";/, "$os filename01 keeps its BIOS firmware loader");
    like($named, qr/filename = "xcat\/xnba\.efi";/, "$os filename01 keeps its UEFI firmware loader");
    my $server = $os eq 'freebsd15.1' ? '192.0.2.1' : '${next-server}';
    like($named, qr{filename = "http://\Q$server\E/tftpboot/xcat/xnba/nodes/filename01";},
        "$os filename01 keeps its BIOS second stage");
    like($named, qr{filename = "http://\Q$server\E/tftpboot/xcat/xnba/nodes/filename01\.uefi";},
        "$os filename01 keeps its UEFI second stage");
    if ($os eq 'freebsd15.1') {
        like($named, qr{option root-path "tftp://192\.0\.2\.1/xcat/freebsd/filename01";},
            'filename01 receives its native FreeBSD root path');
        $xCAT::Table::rows{iscsi}{filename01} = { server => '192.0.2.2', target => 'iqn.example:disk' };
        is(isc_config('filename01'), '', 'filename01 with a SAN conflict still rejects the entire host update');
    } else {
        unlike($named, qr/option root-path/, 'Linux filename01 does not receive a native root path');
    }
}

fixture(noderes => { tftpserver => '192.0.2.9' });
like(isc_config(), qr{tftp://192\.0\.2\.9/xcat/freebsd/node01}, 'ISC honors the explicit node TFTP server');
$classes = node_classes(['node01']);
($native) = grep { ($_->{'user-context'}{'xcat-purpose'} || '') eq 'freebsd-native-loader' } @$classes;
is($native->{'option-data'}[0]{data}, 'tftp://192.0.2.9/xcat/freebsd/node01', 'Kea honors the explicit node TFTP server');
fixture(noderes => { xcatmaster => '' });
like(isc_config(), qr{tftp://192\.0\.2\.1/xcat/freebsd/node01}, 'ISC resolves the server facing the node when no server is configured');

fixture(nodetype => { os => 'rhels9' }, iscsi => { server => '192.0.2.2', target => 'iqn.example:disk' });
like(isc_config(), qr/option root-path "iscsi:192\.0\.2\.2:6:3260:0:iqn\.example:disk";/,
    'Linux ISC iSCSI policy remains unchanged');
$reservations = xCAT_plugin::dhcp::kea_build_node_reservations($backend, {}, ['node01']);
is_deeply([grep { $_->{name} eq 'root-path' } @{$reservations->[0]{'option-data'}}],
    [{ name => 'root-path', data => 'iscsi:192.0.2.2:6:3260:0:iqn.example:disk' }],
    'Linux Kea iSCSI policy remains unchanged');

for my $change (
    { nodetype => { os => 'rhels9' } }, { nodetype => { os => 'freebsd15.0' } },
    { nodetype => { arch => 'aarch64' } }, { nodetype => { arch => '' } },
    { noderes => { netboot => 'pxe' } }, { noderes => { netboot => '' } },
) {
    fixture(%$change);
    unlike(isc_config(), qr/option root-path/, 'non-target ISC profiles do not receive the FreeBSD root');
    my $other = node_classes(['node01']);
    is(scalar(grep { ($_->{'user-context'}{'xcat-purpose'} || '') eq 'freebsd-native-loader' } @$other), 0,
        'non-target Kea profiles do not receive a native class');
}

for my $change (
    { iscsi => { server => '192.0.2.2', target => 'iqn.example:disk' } },
    { noderes => { tftpserver => 'invalid.invalid' } },
) {
    fixture(%$change);
    no warnings qw(once redefine);
    my $resolve = \&Socket::inet_aton;
    local *xCAT_plugin::dhcp::inet_aton = sub {
        return if $_[0] eq 'invalid.invalid';
        return $resolve->(@_);
    };
    is(isc_config(), '', 'invalid FreeBSD boot inputs produce no ISC host update');
    is_deeply(xCAT_plugin::dhcp::kea_build_node_reservations($backend, {}, ['node01']), [],
        'invalid FreeBSD boot inputs produce no Kea reservation update');
    my $invalid = node_classes(['node01']);
    is(scalar(@$invalid), 0, 'invalid FreeBSD boot inputs produce no Kea boot classes');
    ok(scalar(grep { $_->{error} } @messages), 'invalid FreeBSD boot inputs report an error');
}

fixture(mac => { mac => '52:54:00:12:34:56|52:54:00:12:34:57!*NOIP*' });
$classes = node_classes(['node01']);
is(scalar(grep { ($_->{'user-context'}{'xcat-purpose'} || '') eq 'freebsd-native-loader' } @$classes), 1,
    'a secondary NOIP interface does not get a FreeBSD root');

fixture();
my $config = { Dhcp4 => { 'client-classes' => [ {name => 'unowned'}, {
    name => 'other-node', 'user-context' => { 'xcat-purpose' => 'freebsd-native-loader', 'xcat-node' => 'node02' },
} ] } };
sync_classes($config, ['node01']);
my $first = scalar(@{$config->{Dhcp4}{'client-classes'}});
sync_classes($config, ['node01']);
is(scalar(@{$config->{Dhcp4}{'client-classes'}}), $first, 'repeated updates do not duplicate native classes');
fixture(nodetype => { os => 'rhels9' });
sync_classes($config, ['node01']);
is(scalar(grep { ($_->{'user-context'}{'xcat-purpose'} || '') eq 'freebsd-native-loader' &&
    ($_->{'user-context'}{'xcat-node'} || '') eq 'node01' } @{$config->{Dhcp4}{'client-classes'}}), 0,
    'changing the node OS removes its native class');
remove_classes($config, ['node01']);
is_deeply([map { $_->{name} } @{$config->{Dhcp4}{'client-classes'}}], ['unowned', 'other-node'],
    'class deletion preserves unowned policy and other nodes');

{
    package FreeBSDPolicyBackend;
    our @ISA = ('xCAT::DHCP::Backend::Kea');
    sub subnet_id_for_ip { return 1; }
    sub check_services { return {}; }
    sub service_account { return; }
    sub host_cmds_hook_path { return '/fixture/libdhcp_host_cmds.so'; }
    sub restart_services { $_[0]{restarts}++; return {}; }
}

done_testing;
