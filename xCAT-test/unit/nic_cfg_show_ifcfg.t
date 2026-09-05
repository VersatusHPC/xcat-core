#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# Regression (xcat-internal#61): nic_cfg.sh reports the NetworkManager profile of a device so
# a case can grep it. It read only the keyfile. EL8 still has the ifcfg-rh plugin and keeps
# the profile in an ifcfg file, so the dump came back with the normalized header and nothing
# else, and confignetwork_secondarynic_nicextraparams_updatenode could not see CONNECTED_MODE
# however configeth wrote it.
#
# nm_show is driven for real. nmcli is shadowed by a shell function -- bash resolves those
# ahead of PATH -- and the harness sets NMDIR/RHDIR to a scratch tree before the extracted
# unit runs, so nothing here reads the host.

my $repo_root = File::Spec->rel2abs( File::Spec->catdir( $FindBin::Bin, '..', '..' ) );
my $helper = File::Spec->catfile( $repo_root, 'xCAT-test', 'autotest', 'testcase',
    'commoncmd', 'nic_cfg.sh' );
plan skip_all => "nic_cfg.sh not found" unless -f $helper;

my $src = do { local $/; open my $fh, '<', $helper or die $!; <$fh> };

# nm_keyfile, nm_conn_for_dev and nm_show together. BAIL_OUT rather than skip: a rename that
# stops this matching must fail loudly instead of covering nothing.
my ($unit) = $src =~ /^(# Resolve a connection's on-disk keyfile path\..*?\nnm_show\(\) \{.*?\n\})\n/ms;
BAIL_OUT('could not extract nm_show from nic_cfg.sh') unless defined $unit;

my $dir = tempdir( CLEANUP => 1 );

# $backend is 'ifcfg' (EL8) or 'keyfile' (EL9+): where the profile of xcat-ib0 lives.
sub nm_show {
    my ($backend) = @_;
    my $root = File::Spec->catdir( $dir, $backend );
    mkdir $root or die $!;
    for my $d (qw(nm rh)) { mkdir File::Spec->catdir( $root, $d ) or die $!; }

    my $uuid = '11111111-2222-3333-4444-555555555555';
    if ( $backend eq 'ifcfg' ) {
        open my $f, '>', File::Spec->catfile( $root, 'rh', 'ifcfg-xcat-ib0' ) or die $!;
        print $f "NAME=xcat-ib0\nDEVICE=ib0\nUUID=$uuid\nIPADDR=192.0.2.50\nCONNECTED_MODE=yes\n";
        close $f;
    }
    else {
        open my $f, '>', File::Spec->catfile( $root, 'nm', 'xcat-ib0.nmconnection' ) or die $!;
        print $f "[connection]\nid=xcat-ib0\nuuid=$uuid\n\n[user]\nxcat.CONNECTED_MODE=yes\n";
        close $f;
    }

    my $harness = File::Spec->catfile( $root, 'harness.sh' );
    open my $fh, '>', $harness or die $!;
    print $fh <<"PRE";
#!/bin/bash
NMDIR='$root/nm'
RHDIR='$root/rh'
nmcli(){
    case "\$*" in
        *"-f NAME,DEVICE"*) echo 'xcat-ib0:ib0' ;;
        *"connection.uuid"*) echo '$uuid' ;;
        *"ipv4.method"*)     echo manual ;;
        *"ipv4.addresses"*)  echo '192.0.2.50/24' ;;
        *"802-3-ethernet.mtu"*) echo 65520 ;;
        *) echo '' ;;
    esac
}
PRE
    print $fh "$unit\n";
    print $fh "nm_show ib0\n";
    close $fh;
    my $out = `/bin/bash '$harness' 2>&1`;
    return $out;
}

my $el8 = nm_show('ifcfg');
like( $el8, qr/^IPADDR=192\.0\.2\.50$/m, 'the normalized header is emitted either way' );
like( $el8, qr/^CONNECTED_MODE=yes$/m,
    'an extra param in the EL8 ifcfg profile reaches the dump' );

my $el9 = nm_show('keyfile');
like( $el9, qr/^xcat\.CONNECTED_MODE=yes$/m,
    'the keyfile profile is still dumped' );
like( $el9, qr/^MTU=65520$/m, 'the MTU nmcli reports is still normalized' );

done_testing();
