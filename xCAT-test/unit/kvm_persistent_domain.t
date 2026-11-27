#!/usr/bin/env perl
# With site.persistkvmguests set, mkvm defines the libvirt domain and rmvm undefines it.
#
# libvirt can refuse the definition, e.g. a UEFI guest on a machine type with no UEFI firmware.
# The refusal must reach the client as an error of the node. The per-hypervisor child must not
# die with it: under xcatd the die returns into the request handler, and the command hangs.
#
# libvirt refuses a plain undefine of a domain with a UEFI variable store. rmvm must give the
# flag that names the store, or the old domain survives and the next rpower boots it.
#
# The plugin runs through process_request, with a private SQLite database and a hypervisor
# connection that serves fixed domain XML in place of libvirt.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
    package Sys::Virt;
    our $VERSION = '10.0.0';
    sub new { return bless {}, 'XCATTestHypervisor'; }

    package Sys::Virt::Domain;
    use constant {
        STATE_NOSTATE   => 0,
        STATE_RUNNING   => 1,
        STATE_BLOCKED   => 2,
        STATE_PAUSED    => 3,
        STATE_SHUTOFF   => 5,
        UNDEFINE_NVRAM      => 4,
        UNDEFINE_KEEP_NVRAM => 8,
    };

    $INC{'Sys/Virt.pm'}        = __FILE__;
    $INC{'Sys/Virt/Domain.pm'} = __FILE__;

    package xCAT_monitoring::monitorctrl;
    $INC{'xCAT_monitoring/monitorctrl.pm'} = __FILE__;
}

my $db = tempdir( CLEANUP => 1 );

{
    package XCATTestHypervisor;
    our %domains;    # name => xml of the defined domains
    sub get_node_info { return { model => 'x86_64' }; }
    sub get_domain_capabilities {
        my ( undef, undef, undef, $machine ) = @_;
        $machine //= 'pc-q35-10.0';
        return "<domainCapabilities><machine>$machine</machine></domainCapabilities>";
    }
    # libvirt refuses a UEFI guest on a machine type that no firmware descriptor names.
    sub define_domain {
        my ( undef, $xml ) = @_;
        die bless { code => 9, message => "operation failed: Unable to find 'efi' firmware that is compatible with the current configuration" }, 'Sys::Virt::Error'
          if $xml =~ /machine="invalid"/;
        my ($name) = $xml =~ m{<name>([^<]+)</name>};
        $domains{$name} = $xml;
        return bless { name => $name }, 'XCATTestDomain';
    }
    sub get_domain_by_name {
        my ( undef, $name ) = @_;
        die "no domain $name\n" unless exists $domains{$name};
        return bless { name => $name }, 'XCATTestDomain';
    }

    package XCATTestDomain;
    sub get_xml_description { return $XCATTestHypervisor::domains{ $_[0]->{name} }; }
    sub get_info { return { state => Sys::Virt::Domain::STATE_SHUTOFF() }; }
    # The record outlives the forked plugin child.
    sub undefine {
        my ( $self, $flags ) = @_;
        $flags //= 0;
        die bless { code => 55, message => 'Requested operation is not valid: cannot undefine domain with nvram' }, 'Sys::Virt::Error'
          if $XCATTestHypervisor::domains{ $self->{name} } =~ /<nvram/
          and !( $flags & ( Sys::Virt::Domain::UNDEFINE_NVRAM() | Sys::Virt::Domain::UNDEFINE_KEEP_NVRAM() ) );
        open( my $fh, '>>', "$db/undefined" ) or die "Cannot write $db/undefined: $!";
        print {$fh} "$self->{name} $flags\n";
        close($fh);
    }
}

$ENV{XCATCFG}  = "SQLite:$db";
$ENV{XCATROOT} = "$FindBin::Bin/../../xCAT-server";
require xCAT::Table;

sub set_rows {
    my ( $table, %rows ) = @_;
    my $tab = xCAT::Table->new( $table, -create => 1 ) or die "Cannot open $table\n";
    $tab->setNodeAttribs( $_, $rows{$_} ) foreach sort keys %rows;
    $tab->close;
}

set_rows( 'nodelist', cn1 => { groups => 'all' }, cn2 => { groups => 'all' }, hyp1 => { groups => 'all' } );
set_rows( 'nodehm', cn1 => { mgt => 'kvm', power => 'kvm' }, cn2 => { mgt => 'kvm', power => 'kvm' }, hyp1 => { mgt => 'ipmi' } );
set_rows( 'nodetype', cn1 => { arch => 'x86_64' }, cn2 => { arch => 'x86_64' } );
set_rows( 'vm',
    cn1 => { host => 'hyp1', storage => 'phy:/dev/xcattest1', nics => 'br0', memory => '1024', cpus => '1',
             othersettings => 'firmware:efi;machine:invalid' },
    cn2 => { host => 'hyp1', storage => 'phy:/dev/xcattest2', nics => 'br0', memory => '1024', cpus => '1',
             othersettings => 'firmware:efi' } );
set_rows( 'mac', cn1 => { mac => '52:54:00:76:01:21' }, cn2 => { mac => '52:54:00:76:01:22' } );

my $plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/kvm.pm";
require $plugin;
{
    no warnings qw(once redefine);
    *xCAT_plugin::kvm::nodesockopen = sub { return 1; };
}
{ no warnings qw(once); $::XCATSITEVALS{persistkvmguests} = 1; }

sub texts {
    my ($value) = @_;
    return map { texts($_) } @$value if ref($value) eq 'ARRAY';
    return map { texts($_) } values %$value if ref($value) eq 'HASH';
    return defined($value) ? ($value) : ();
}

# Run one command and return the text of every response. The per-hypervisor child calls the
# callback too, so the responses go to a file that outlives the fork.
sub run_command {
    my ( $command, $nodes, @args ) = @_;
    my $log = "$db/$command.out";
    unlink $log;
    my $callback = sub {
        open( my $fh, '>>', $log ) or die "Cannot write $log: $!";
        print {$fh} "$_\n" foreach texts( $_[0] );
        close($fh);
    };
    xCAT_plugin::kvm::process_request( { command => [$command], node => $nodes, arg => \@args }, $callback, sub { return; } );
    open( my $fh, '<', $log ) or return ();
    chomp( my @output = <$fh> );
    close($fh);
    return @output;
}

sub undefined {
    open( my $fh, '<', "$db/undefined" ) or return ();
    chomp( my @lines = <$fh> );
    close($fh);
    unlink "$db/undefined";
    return @lines;
}

my @mkvm = run_command( 'mkvm', ['cn1'] );
ok( ( grep { /Unable to find 'efi' firmware/ } @mkvm ), 'mkvm reports the libvirt refusal of cn1 to the client' )
  or diag( join "\n", @mkvm );
ok( !exists $XCATTestHypervisor::domains{cn1}, 'and no domain of cn1 exists' );
{
    my $tab = xCAT::Table->new('kvm_nodedata');
    my $ent = $tab ? $tab->getNodeAttribs( 'cn1', ['xml'] ) : undef;
    ok( !( $ent and $ent->{xml} ), 'and mkvm keeps no domain XML of cn1 for the next mkvm' );
}

# A UEFI domain as libvirt keeps it: with the variable store of the guest.
$XCATTestHypervisor::domains{cn2} = <<'XML';
<domain type="kvm"><name>cn2</name><os firmware="efi"><type arch="x86_64" machine="pc-q35-10.0">hvm</type>
<nvram>/var/lib/libvirt/qemu/nvram/cn2_VARS.fd</nvram></os><devices/></domain>
XML
set_rows( 'kvm_nodedata', cn2 => { xml => $XCATTestHypervisor::domains{cn2} } );

my @rmvm = run_command( 'rmvm', ['cn2'], '-f', '-p' );
is_deeply( [ undefined() ], [ 'cn2 ' . Sys::Virt::Domain::UNDEFINE_NVRAM() ],
    'rmvm -p undefines the UEFI domain of cn2 and deletes its variable store' )
  or diag( join "\n", @rmvm );

set_rows( 'kvm_nodedata', cn2 => { xml => $XCATTestHypervisor::domains{cn2} } );
my @rmvm_keep = run_command( 'rmvm', ['cn2'], '-f' );
is_deeply( [ undefined() ], [ 'cn2 ' . Sys::Virt::Domain::UNDEFINE_KEEP_NVRAM() ],
    'rmvm without -p undefines the UEFI domain of cn2 and keeps its variable store' )
  or diag( join "\n", @rmvm_keep );

done_testing();
