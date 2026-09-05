#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# Regression (xcat-internal#61, el9 half): nic_cfg.sh reports the MTU of the NetworkManager
# profile it resolves for a device. On the confignetwork no-restart path the device still
# runs the profile the installer left, and that profile has no MTU, so the dump named no MTU
# at all while the link carried the declared one. The dump has to name the link.
#
# nm_show is driven for real, with nmcli and ip shadowed by shell functions -- bash resolves
# those ahead of PATH -- and NMDIR pointed at a scratch tree, so nothing here reads the host.

my $repo_root = File::Spec->rel2abs( File::Spec->catdir( $FindBin::Bin, '..', '..' ) );
my $helper = File::Spec->catfile( $repo_root, 'xCAT-test', 'autotest', 'testcase',
    'commoncmd', 'nic_cfg.sh' );
plan skip_all => "nic_cfg.sh not found" unless -f $helper;

my $src = do { local $/; open my $fh, '<', $helper or die $!; <$fh> };

# BAIL_OUT rather than skip: a rename that stops this matching must fail loudly instead of
# covering nothing.
my ($unit) = $src =~ /^(# Resolve a connection's on-disk keyfile path\..*?\nnm_show\(\) \{.*?\n\})\n/ms;
BAIL_OUT('could not extract nm_show from nic_cfg.sh') unless defined $unit;

my $dir = tempdir( CLEANUP => 1 );
my $run_no = 0;

# $conn_mtu is the MTU the resolved profile declares ('' for none); $link_mtu is the MTU the
# kernel link carries.
sub nm_show {
    my ( $conn_mtu, $link_mtu ) = @_;
    $run_no++;
    my $root = File::Spec->catdir( $dir, "run$run_no" );
    mkdir $root or die $!;
    mkdir File::Spec->catdir( $root, 'nm' ) or die $!;
    mkdir File::Spec->catdir( $root, 'rh' ) or die $!;

    my $harness = File::Spec->catfile( $root, 'harness.sh' );
    open my $fh, '>', $harness or die $!;
    print $fh <<"PRE";
#!/bin/bash
NMDIR='$root/nm'
RHDIR='$root/rh'
# The device runs the connection the installer created; the xcat- profile exists but was
# never activated, which is the state the el9 no-restart path leaves behind.
nmcli(){
    case "\$*" in
        "-t -f NAME,DEVICE connection show --active") echo 'ens4:ens4' ;;
        "-g ipv4.method connection show ens4")        echo 'manual' ;;
        "-g ipv4.addresses connection show ens4")     echo '11.1.0.100/16' ;;
        "-g 802-3-ethernet.mtu connection show ens4") echo '$conn_mtu' ;;
        "-g connection.uuid connection show ens4")    echo '' ;;
        *) : ;;
    esac
    return 0
}
ip(){
    case "\$*" in
        "-o link show dev ens4"|"link show dev ens4")
            echo "2: ens4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu $link_mtu qdisc fq_codel state UP" ;;
        *) echo "unexpected ip call: \$*" >&2; exit 3 ;;
    esac
    return 0
}
PRE
    print $fh "$unit\n";
    print $fh "nm_show ens4\n";
    close $fh;

    my $out = `/bin/bash $harness 2>&1`;
    die "harness failed" if $?;
    return $out;
}

# --- the profile names no MTU, the link carries the declared one -------------
my $out = nm_show( '', 1496 );
like( $out, qr/^NAME=ens4$/m,
    'the device is on the connection the installer left, which is the state under test' );
unlike( $out, qr/^MTU=/m,
    'that connection declares no MTU, so the profile line cannot report one' );
like( $out, qr/^LINK_MTU=1496$/m,
    'the dump reports the MTU the link actually carries' );

# --- the profile does name one ----------------------------------------------
my $out2 = nm_show( 1496, 1496 );
like( $out2, qr/^MTU=1496$/m,   'a profile MTU is still reported' );
like( $out2, qr/^LINK_MTU=1496$/m, 'and the link is reported beside it' );

# --- profile and link disagree ----------------------------------------------
# Both are named, so a case can tell "declared" from "applied" instead of reading one and
# assuming the other.
my $out3 = nm_show( 1496, 1500 );
like( $out3, qr/^MTU=1496$/m,      'the declared MTU' );
like( $out3, qr/^LINK_MTU=1500$/m, 'and the applied one, which is not the same' );

done_testing();
