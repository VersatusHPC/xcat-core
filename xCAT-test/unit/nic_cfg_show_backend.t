#!/usr/bin/env perl
# nic_cfg.sh normalizes a NIC configuration for the confignetwork cases. It missed both shapes
# the CD nodes present (VersatusHPC/xcat-internal#61):
#
#   EL9  -- configeth adds "xcat-ens4" and does not activate it, so the connection still active
#           on the device is the installer's. Reading that one reports no MTU.
#   EL8  -- NetworkManager stores the connection in an ifcfg file, not a keyfile, so the raw
#           dump was empty and CONNECTED_MODE was invisible.
#
# The script is run as a subprocess with a stub nmcli on PATH and NIC_CFG_ROOT pointing at a
# scratch tree, so the assertions are on what the script prints, not on its text.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my $script = dirname(__FILE__) . '/../autotest/testcase/commoncmd/nic_cfg.sh';
plan skip_all => "nic_cfg.sh not found at $script" unless -r $script;
plan tests => 4;

# A stub nmcli answering from two files: CONNS holds "NAME:DEVICE" lines (a device column that
# is empty means the connection is not active), PROPS holds "NAME|PROPERTY|VALUE".
my $NMCLI = <<'SH';
#!/bin/bash
conns=$STUB_DIR/conns
props=$STUB_DIR/props
mode=""; fields=""; active=0; getprop=""; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) ;;
    -f) fields=$2; shift ;;
    -g) getprop=$2; shift ;;
    --active) active=1 ;;
    connection) ;;
    show) mode=show ;;
    *) name=$1 ;;
  esac
  shift
done
[ "$mode" = show ] || exit 1
if [ -n "$getprop" ]; then
  awk -F'|' -v n="$name" -v p="$getprop" '$1==n && $2==p {print $3}' "$props"
  exit 0
fi
while IFS=: read -r cn dev; do
  [ -n "$cn" ] || continue
  [ $active -eq 1 ] && [ -z "$dev" ] && continue
  case "$fields" in
    NAME) echo "$cn" ;;
    *)    echo "$cn:$dev" ;;
  esac
done < "$conns"
SH

sub stub_dir {
    my ( $root, $conns, $props ) = @_;
    my $bin = "$root/bin";
    make_path($bin);
    open my $n, '>', "$bin/nmcli" or die "cannot write nmcli stub: $!";
    print $n $NMCLI;
    close $n;
    chmod 0755, "$bin/nmcli";
    open my $s, '>', "$bin/systemctl" or die "cannot write systemctl stub: $!";
    print $s "#!/bin/bash\nexit 0\n";    # NetworkManager reads as active
    close $s;
    chmod 0755, "$bin/systemctl";
    write_file( "$root/conns", $conns );
    write_file( "$root/props", $props );
    return $bin;
}

sub write_file {
    my ( $path, $text ) = @_;
    make_path( dirname($path) );
    open my $fh, '>', $path or die "cannot write $path: $!";
    print $fh $text;
    close $fh;
}

sub show {
    my ( $root, $bin, $dev ) = @_;
    my $out = `STUB_DIR=\Q$root\E NIC_CFG_ROOT=\Q$root/sys\E PATH=\Q$bin\E:\$PATH bash \Q$script\E show \Q$dev\E 2>&1`;
    return $out;
}

# EL9: the installer connection is active on ens4, the xCAT one carries the MTU the case set.
{
    my $root = tempdir( CLEANUP => 1 );
    my $bin  = stub_dir(
        $root,
        "ens4:ens4\nxcat-ens4:\n",
        join( "\n",
            'ens4|ipv4.method|manual',
            'ens4|ipv4.addresses|11.1.0.100/16',
            'ens4|802-3-ethernet.mtu|auto',
            'xcat-ens4|ipv4.method|manual',
            'xcat-ens4|ipv4.addresses|11.1.0.100/16',
            'xcat-ens4|802-3-ethernet.mtu|1496',
            'xcat-ens4|connection.uuid|aaaa-1111' )
          . "\n"
    );
    write_file( "$root/sys/etc/NetworkManager/system-connections/xcat-ens4.nmconnection",
        "[connection]\nid=xcat-ens4\nuuid=aaaa-1111\n\n[802-3-ethernet]\nmtu=1496\n" );

    my $out = show( $root, $bin, 'ens4' );
    like( $out, qr/^NAME=xcat-ens4$/m, 'the xCAT connection is reported, not the active one' );
    like( $out, qr/MTU=1496/,          'the MTU the case set is reported' );
}

# EL8: NetworkManager keeps the connection in an ifcfg file, so there is no keyfile to dump.
{
    my $root = tempdir( CLEANUP => 1 );
    my $bin  = stub_dir(
        $root,
        "xcat-ens4:ens4\n",
        join( "\n",
            'xcat-ens4|ipv4.method|manual',
            'xcat-ens4|ipv4.addresses|100.168.250.10/16',
            'xcat-ens4|802-3-ethernet.mtu|auto',
            'xcat-ens4|connection.uuid|bbbb-2222' )
          . "\n"
    );
    write_file( "$root/sys/etc/sysconfig/network-scripts/ifcfg-xcat-ens4",
        "NAME=xcat-ens4\nDEVICE=ens4\nBOOTPROTO=none\nIPADDR=100.168.250.10\nCONNECTED_MODE=yes\n" );

    my $out = show( $root, $bin, 'ens4' );
    like( $out, qr/^BOOTPROTO=none$/m, 'the normalized dump is still produced' );
    like( $out, qr/CONNECTED_MODE=yes/,
        'the ifcfg file is dumped, so nicextraparams are greppable' );
}
