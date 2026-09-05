#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# Regression (xcat-internal#61): on EL8 the nicextraparams a node declares -- CONNECTED_MODE
# is the documented example -- never reach the interface configuration. configipv4 appends
# them to the ifcfg file, and the restart phase that follows runs "nmcli con modify
# $con_name ipv4.dns", which makes NetworkManager rewrite that file from its own model.
# NetworkManager has no setting for CONNECTED_MODE, so the key is dropped. EL9 and later
# keep the profile in a keyfile and configeth already re-writes the keys there as its last
# step; EL8 had no equivalent.
#
# The test drives the real configipv4, the real restart phase and the real re-persist tail,
# and asserts on the rendered ifcfg file. nmcli is shadowed by a shell function -- bash
# resolves those ahead of PATH -- that reproduces the behaviour measured on an AlmaLinux
# 8.10 node: every "con modify" regenerates the ifcfg from the properties nmcli itself set,
# and an appended key is gone afterwards.

my $repo_root = File::Spec->rel2abs( File::Spec->catdir( $FindBin::Bin, '..', '..' ) );
my $configeth = File::Spec->catfile( $repo_root, 'xCAT', 'postscripts', 'configeth' );
my $xcatlib   = File::Spec->catfile( $repo_root, 'xCAT', 'postscripts', 'xcatlib.sh' );
plan skip_all => "configeth not found" unless -f $configeth;

my $src = do { local $/; open my $fh, '<', $configeth or die $!; <$fh> };

# Three units of the real script. BAIL_OUT rather than skip: a rename that stops one of these
# matching must fail loudly, not leave the file silently covering nothing.
my ($fn_configipv4) = $src =~ /^(function configipv4\(\)\{\n.*?\n\})\n/ms;
BAIL_OUT('could not extract configipv4 from configeth') unless defined $fn_configipv4;

my ($restart) = $src =~ /^(    #restart the nic\n    if \[ \$bool_restart_flag -eq 1 \];then\n.*?\n    fi\n)/ms;
BAIL_OUT('could not extract the restart phase from configeth') unless defined $restart;

my ($persist) = $src =~ /^(# Persist nicextraparams.*?\nfi\n)exit \$error_code/ms;
BAIL_OUT('could not extract the nicextraparams persist block from configeth') unless defined $persist;

# The sentinel configeth actually uses for "unset"; a literal here would let a hard-coded
# value in the unit under test pass.
my ($token) = $src =~ /^str_default_token="([^"]+)"/m;
BAIL_OUT('could not read str_default_token from configeth') unless defined $token;

my $dir = tempdir( CLEANUP => 1 );
my $run_no = 0;

# Run one scenario. Everything the units touch is redirected into a per-run scratch tree:
# str_cfg_dir is the variable configeth itself computes for the ifcfg directory.
sub run_configeth {
    my ( $osver, $extra, $mtu ) = @_;
    $run_no++;
    my $root = File::Spec->catdir( $dir, "run$run_no" );
    mkdir $root or die $!;
    mkdir File::Spec->catdir( $root, 'net' ) or die $!;

    my $harness = File::Spec->catfile( $root, 'harness.sh' );
    open my $fh, '>', $harness or die $!;
    print $fh <<"PRE";
#!/bin/bash
. '$xcatlib'
NODE=cn1
OSVER='$osver'
str_default_token='$token'
str_os_type=redhat
str_cfg_dir='$root/net/'
networkmanager_active=1
netplan_active=0
bool_restart_flag=1
reboot_nic_bool=1
error_code=0
tmp_con_name=''
str_nic_name=ib0
NAMESERVERS=''
log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
wait_for_ifstate(){ echo 0; }
ip(){ :; }
sleep(){ :; }
is_nmcli_connection_exist(){ return 1; }
v4mask2prefix(){ echo 24; }

# NetworkManager on EL8 stores the profile as ifcfg and regenerates that file from its own
# model on every change. MODEL holds the properties nmcli was told about; anything else the
# file gained is lost on the next write, which is what this reproduces.
MODEL='$root/model'
CALLS='$root/nmcli-calls'
IFCFG='$root/net/ifcfg-xcat-ib0'
: > "\$MODEL"
nm_render(){
    {
        echo "NAME=xcat-ib0"
        echo "DEVICE=ib0"
        echo "BOOTPROTO=none"
        cat "\$MODEL"
    } > "\$IFCFG"
}
nm_set(){ sed -i "/^\$1=/d" "\$MODEL"; echo "\$1=\$2" >> "\$MODEL"; }
# The address is read by name, the way nmcli takes it: "con add" is given the properties as
# "<name> <value>" pairs in an order the caller chooses.
nm_addr_arg(){
    local prev=''
    for a in "\$@"; do
        case "\$prev" in ipv4.addresses|+ipv4.addresses) echo "\$a"; return ;; esac
        prev="\$a"
    done
}
nmcli(){
    echo "\$*" >> "\$CALLS"
    local addr
    case "\$1 \$2" in
        "con add")
            addr=\$(nm_addr_arg "\$@")
            nm_set IPADDR "\${addr%%/*}"; nm_set PREFIX "\${addr##*/}"; nm_render ;;
        "con modify")
            case "\$4" in
                +ipv4.addresses|ipv4.addresses) addr=\$(nm_addr_arg "\$@"); nm_set IPADDR "\${addr%%/*}" ;;
                mtu) nm_set MTU "\$5" ;;
                ipv4.dns) : ;;
                *) return 1 ;;
            esac
            nm_render ;;
        "-g connection") echo '' ;;
        *) : ;;
    esac
    return 0
}
PRE
    print $fh "$fn_configipv4\n";
    print $fh "con_name=xcat-ib0\n";
    # the real reader of the nics.nicextraparams attribute, called the way configeth calls it
    print $fh "NICEXTRAPARAMS='ib0!$extra'\n";
    print $fh "get_nic_extra_params ib0 \"\$NICEXTRAPARAMS\" >/dev/null\n";
    print $fh "configipv4 ib0 192.0.2.50 192.0.2.0 255.255.255.0 0 \"\${array_nic_params[0]}\" $mtu\n";
    print $fh "cp \"\$IFCFG\" '$root/ifcfg-before-restart'\n";
    print $fh "$restart\n";
    print $fh "$persist\n";
    close $fh;
    system( '/bin/bash', $harness ) == 0 or die "harness failed";
    return $root;
}

sub slurp {
    my ($p) = @_;
    return '' unless -f $p;
    local $/;
    open my $f, '<', $p or die $!;
    return <$f>;
}

# --- EL8: the declared nicextraparams survive the restart phase ---------------
my $r = run_configeth( 'alma8.10', 'CONNECTED_MODE=yes', $token );

like( slurp("$r/ifcfg-before-restart"), qr/^CONNECTED_MODE=yes$/m,
    'configipv4 writes the declared nicextraparams into the ifcfg file' );
like( slurp("$r/nmcli-calls"), qr/^con modify xcat-ib0 ipv4\.dns/m,
    'the restart phase runs the nmcli call that makes NetworkManager rewrite that file' );
unlike( slurp("$r/model"), qr/CONNECTED_MODE/,
    'NetworkManager does not model CONNECTED_MODE, so its rewrite cannot carry the key' );

like( slurp("$r/net/ifcfg-xcat-ib0"), qr/^CONNECTED_MODE=yes$/m,
    'CONNECTED_MODE is in the ifcfg file configeth leaves behind' );
like( slurp("$r/net/ifcfg-xcat-ib0"), qr/^IPADDR=192\.0\.2\.50$/m,
    'the address NetworkManager does model is still there too' );

# --- two keys, and no duplicate when a key is already present ----------------
my $r2 = run_configeth( 'alma8.10', 'CONNECTED_MODE=yes MTU=65520', 65520 );
my $c2 = slurp("$r2/net/ifcfg-xcat-ib0");
like( $c2, qr/^CONNECTED_MODE=yes$/m, 'every declared key is written, not just the first' );
is( scalar( () = $c2 =~ /^MTU=/mg ), 1,
    'a key NetworkManager already wrote is replaced, not duplicated' );
like( $c2, qr/^MTU=65520$/m, 'the declared value wins' );

# --- EL9 and later keep the keyfile arm --------------------------------------
# The ifcfg arm must not run there: EL9 has no ifcfg-rh plugin, and the keyfile arm above it
# owns those releases.
my $r3 = run_configeth( 'alma9.6', 'CONNECTED_MODE=yes', $token );
unlike( slurp("$r3/net/ifcfg-xcat-ib0"), qr/CONNECTED_MODE/,
    'on EL9 the ifcfg arm does not run' );

done_testing();
