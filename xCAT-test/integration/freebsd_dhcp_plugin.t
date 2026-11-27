#!/usr/bin/env perl
# The real ISC and Kea parsers read what the dhcp plugin renders for a FreeBSD node. This runs on
# an installed management node, where both parsers exist; the rendering itself is tested in
# process by xCAT-test/unit/freebsd_dhcp.t.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib grep { defined($_) } $ENV{XCAT_FREEBSD_DHCP_POLICY_DIR};
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Capture::Tiny qw(capture);
use File::Copy qw(copy);
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
my $parsers = "$temporary/parsers";
make_path($parsers);
# Copy the installed parsers so host AppArmor profiles do not restrict fixture paths.
for my $command (qw(dhcpd kea-dhcp4)) {
    my $installed = xCAT::CommandUtils::find_executable($command) || next;
    my $copy = "$parsers/$command";
    copy($installed, $copy) or die $!;
    chmod(0755, $copy) or die $!;
    my (undef, undef, $status) = capture { system($copy, '--version') };
    if ($status == -1) {
        unlink($copy) or die $!;
    }
}
local $ENV{PATH} = "$parsers:$ENV{PATH}";
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
my ($plugin) = grep { defined($_) && -f $_ } $ENV{XCAT_FREEBSD_DHCP_PLUGIN},
    "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/dhcp.pm", '/opt/xcat/lib/perl/xCAT_plugin/dhcp.pm';
die "no dhcp plugin\n" unless $plugin;
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


for my $os (qw(freebsd15.1 rhels9)) {
    fixture(nodetype => { os => $os });
    for my $table (values %xCAT::Table::rows) {
        $table->{filename01} = delete $table->{node01};
    }
    $xCAT::Table::rows{noderes}{filename01}{xcatmaster} = '' if $os eq 'rhels9';
    my $named = isc_config('filename01');
    SKIP: {
        my $isc_parser = xCAT::CommandUtils::find_executable('dhcpd');
        skip 'ISC dhcpd is required for configuration validation', 1 unless $isc_parser;
        open(my $file, '>', "$temporary/$os-isc.conf") or die $!;
        print {$file} "option user-class-identifier code 77 = string;\n",
            "option client-architecture code 93 = unsigned integer 16;\n",
            "subnet 192.0.2.0 netmask 255.255.255.0 {}\n", $named;
        close($file) or die $!;
        is(system($isc_parser, '-t', '-cf', "$temporary/$os-isc.conf"), 0,
            "ISC parses the generated $os filename01 host declaration");
    }
}

subtest 'Kea preserves rejected native nodes during mixed updates' => sub {
    require xCAT::DHCP::Backend::Kea;
    plan skip_all => 'kea-dhcp4 is required for configuration validation'
        unless xCAT::CommandUtils::find_executable('kea-dhcp4');
    my @nodes = qw(node01 node02 node03);
    my %addresses = (node01 => '192.0.2.20', node02 => '192.0.2.21', node03 => '192.0.2.22');
    my $resolve = \&Socket::inet_aton;
    no warnings qw(once redefine);
    local *xCAT_plugin::dhcp::getipaddr = sub {
        my ($host, %options) = @_;
        my $address = $addresses{$host} || $host;
        return unpack('N', Socket::inet_aton($address)) if $options{GetNumber};
        return $address;
    };
    local *xCAT_plugin::dhcp::inet_aton = sub {
        return if $_[0] eq 'invalid.invalid';
        return $resolve->(@_);
    };
    local *xCAT::Utils::isServiceNode = sub { return 0; };
    local *xCAT::Utils::isLinux = sub { return 1; };
    local *xCAT::NetworkUtils::determinehostname = sub { return 'controller'; };
    local *xCAT::Table::getNodeAttribs = sub { return {}; };
    local *xCAT::TableUtils::get_site_attribute = sub {
        return 'eth0' if $_[1] eq 'dhcpinterfaces';
        return 1 if $_[1] eq 'keacontrolagent';
        return;
    };
    local *xCAT::DBobjUtils::getnodetype = sub { return { map { $_ => 'osi' } @{$_[1]} }; };
    local *xCAT_plugin::dhcp::kea_build_dhcp4_intent = sub { return {}; };
    local *xCAT_plugin::dhcp::kea_build_dhcp6_intent = sub { return { subnets => [] }; };
    local *xCAT_plugin::dhcp::kea_build_ddns_intent = sub { return; };
    local *xCAT::MsgUtils::message = sub { return; };
    local *xCAT::MsgUtils::trace = sub { return; };
    local $::XCATSITEVALS{externaldhcpservers};

    my $node_classes = sub {
        my ($class_config, $class_node) = @_;
        return [grep { (($_->{'user-context'} || {})->{'xcat-node'} || '') eq $class_node }
            @{$class_config->{Dhcp4}{'client-classes'}}];
    };
    my $update = sub {
        my ($update_backend, $update_nodes) = @_;
        local *xCAT::DHCP::Backend::new_backend = sub { return $update_backend; };
        local @ARGV;
        @messages = ();
        my $mask = umask;
        xCAT_plugin::dhcp::process_request(
            { _xcatpreprocessed => [1], node => $update_nodes, arg => ['-l'] },
            sub { push @messages, @_ },
        );
        umask $mask;
        return $update_backend->load_dhcp4_config();
    };

    for my $rejection (qw(iscsi tftpserver)) {
        fixture();
        for my $node (qw(node02 node03)) {
            $xCAT::Table::rows{noderes}{$node} = { netboot => 'xnba', xcatmaster => '192.0.2.1' };
            $xCAT::Table::rows{nodetype}{$node} = { os => $node eq 'node02' ? 'rhels9' : 'freebsd15.1', arch => 'x86_64' };
            $xCAT::Table::rows{mac}{$node} = { mac => $node eq 'node02' ? '52:54:00:12:34:57' : '52:54:00:12:34:58' };
        }
        my @commands;
        my $live_backend = FreeBSDPolicyBackend->new(
            kea_version => '2.4.1', dhcp4_config_file => "$temporary/$rejection.conf",
            control_agent_handler => sub { push @commands, $_[0]; return { ok => 1 }; },
        );
        my $global = xCAT_plugin::dhcp::kea_boot_client_classes();
        my @unowned = (@$global, { name => 'unowned' }, {
            name => 'other-node', 'user-context' => { 'xcat-purpose' => 'freebsd-native-loader', 'xcat-node' => 'node04' },
        });
        my $seed_config = JSON::decode_json($live_backend->render_dhcp4_config({
            interfaces => [], subnets => [{ id => 1, subnet => '192.0.2.0/24' }],
            'client-classes' => [@{node_classes(\@nodes)}, @unowned],
        }));
        $live_backend->upsert_reservations($seed_config, xCAT_plugin::dhcp::kea_build_node_reservations($live_backend, $seed_config, \@nodes));
        my $seed = $live_backend->write_dhcp4_json($live_backend->encode_config($seed_config));
        ok(!$seed->{error}, "$rejection fixture passes the real Kea parser") or diag($seed->{error});
        my $before = $live_backend->load_dhcp4_config();
        if ($rejection eq 'iscsi') {
            $xCAT::Table::rows{iscsi}{node01} = { server => '192.0.2.2', target => 'iqn.example:disk' };
        } else {
            $xCAT::Table::rows{noderes}{node01}{tftpserver} = 'invalid.invalid';
        }
        $xCAT::Table::rows{noderes}{node02}{tftpserver} = '192.0.2.9';
        $xCAT::Table::rows{noderes}{node03}{tftpserver} = '192.0.2.8';
        my $after = $update->($live_backend, \@nodes);
        is_deeply($node_classes->($after, 'node01'), $node_classes->($before, 'node01'),
            "$rejection preserves the rejected node's existing native and xNBA classes");
        is_deeply([grep { $_->{hostname} eq 'node01' } @{$after->{Dhcp4}{subnet4}[0]{reservations}}],
            [grep { $_->{hostname} eq 'node01' } @{$before->{Dhcp4}{subnet4}[0]{reservations}}],
            "$rejection preserves the rejected node's reservation");
        my ($linux_bios) = grep { $_->{name} =~ /-bios$/ } @{$node_classes->($after, 'node02')};
        is($linux_bios->{'boot-file-name'}, 'http://192.0.2.9/tftpboot/xcat/xnba/nodes/node02',
            "$rejection still updates the valid Linux node");
        my ($updated_native) = grep { $_->{name} =~ /-freebsd$/ } @{$node_classes->($after, 'node03')};
        is($updated_native->{'option-data'}[0]{data}, 'tftp://192.0.2.8/xcat/freebsd/node03',
            "$rejection still updates the valid native node");
        my $unowned = sub {
            my $unowned_config = shift;
            return [grep { my $owner_node = ($_->{'user-context'} || {})->{'xcat-node'} || '';
                !$owner_node || $owner_node eq 'node04' } @{$unowned_config->{Dhcp4}{'client-classes'}}];
        };
        is_deeply($unowned->($after), $unowned->($before),
            "$rejection preserves global, unowned and unrelated-node classes");
        my @errors = map { @{$_->{error} || []} } @messages;
        is(scalar(@errors), $rejection eq 'iscsi' ? 2 : 3, "$rejection retains the existing diagnostics");
        is($errors[0], $errors[-1], "$rejection reports the same reservation and class validation error");
        is_deeply([map { $_->{arguments}{reservation}{hostname} }
                grep { $_->{command} eq 'reservation-add' } @commands], [qw(node02 node03)],
            "$rejection updates only valid nodes through the Control Agent boundary");
        is($live_backend->{restarts}, 1, "$rejection requests reload for the valid class changes");

        $xCAT::Table::rows{iscsi}{node01} = {};
        delete $xCAT::Table::rows{noderes}{node01}{tftpserver};
        $xCAT::Table::rows{nodetype}{node01}{os} = 'rhels9';
        my $linux = $update->($live_backend, ['node01']);
        is(scalar(grep { $_->{'user-context'}{'xcat-purpose'} eq 'xnba-second-stage' }
                @{$node_classes->($linux, 'node01')}), 2,
            "$rejection OS transition keeps Linux xNBA second-stage classes");
        is(scalar(grep { $_->{name} =~ /-freebsd$/ } @{$node_classes->($linux, 'node01')}), 0,
            "$rejection OS transition removes the native class");
        $xCAT::Table::rows{noderes}{node01}{netboot} = 'pxe';
        my $pxe = $update->($live_backend, ['node01']);
        is(scalar(grep { $_->{'user-context'}{'xcat-purpose'} =~ /\A(?:xnba-second-stage|xnba-first-stage|freebsd-native-loader)\z/x }
                @{$node_classes->($pxe, 'node01')}), 0,
            "$rejection netboot transition removes obsolete xNBA and native classes");
        is_deeply($node_classes->($pxe, 'node03'), $node_classes->($after, 'node03'),
            "$rejection transitions leave other nodes unchanged");
        is_deeply([map { @{$_->{error} || []} } @messages], [], "$rejection corrected input updates without errors");
    }
    done_testing;
};

done_testing;
