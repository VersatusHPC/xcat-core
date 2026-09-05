#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# Regression (xcat-internal#61, el9 half): the MTU a network object declares never reaches
# the link. configeth takes the no-restart path when the NIC is already up and already
# listed in xcat_history_important -- bool_restart_flag stays 0. configipv4 then creates the
# xcat-<nic> profile with the declared MTU, but nothing activates that profile, so the link
# keeps the MTU it booted with. The addresses do arrive, because that path applies them live
# with add_ip_temporary; the MTU had no equivalent.
#
# The real no-restart block is driven, with the kernel link modelled by a state file that a
# shadowed "ip" reads and writes -- bash resolves a shell function ahead of PATH. The
# assertions read that modelled link and the modelled NetworkManager profile, not the source.

my $repo_root = File::Spec->rel2abs( File::Spec->catdir( $FindBin::Bin, '..', '..' ) );
my $configeth = File::Spec->catfile( $repo_root, 'xCAT', 'postscripts', 'configeth' );
my $xcatlib   = File::Spec->catfile( $repo_root, 'xCAT', 'postscripts', 'xcatlib.sh' );
plan skip_all => "configeth not found" unless -f $configeth;

my $src = do { local $/; open my $fh, '<', $configeth or die $!; <$fh> };

# BAIL_OUT rather than skip: a rename that stops one of these matching must fail loudly
# instead of leaving the file silently covering nothing.
my ($fn_addip) = $src =~ /^(function add_ip_temporary\(\)\{\n.*?\n\})\n/ms;
BAIL_OUT('could not extract add_ip_temporary from configeth') unless defined $fn_addip;

my ($fn_configipv4) = $src =~ /^(function configipv4\(\)\{\n.*?\n\})\n/ms;
BAIL_OUT('could not extract configipv4 from configeth') unless defined $fn_configipv4;

# set_mtu_temporary is the routine this test is about, so it is extracted WITHOUT a BAIL_OUT.
# A BAIL_OUT on a missing subroutine only says the subroutine is absent; the run has to reach
# the assertion and go red on the MTU the link carries.
my ($fn_setmtu) = $src =~ /^(function set_mtu_temporary\(\)\{\n.*?\n\})\n/ms;
$fn_setmtu = '' unless defined $fn_setmtu;

# The whole linux arm of the main process: the restart decision, the live-apply block, the
# config rewrite and the restart phase. The trailing bare "fi" closes the aix/linux if and is
# left outside the capture, so the extracted text is balanced on its own.
my ($block) = $src =~ /^(    str_history=''\n    bool_restart_flag=0\n.*?\n    fi\n)fi\nif \[ \$networkmanager_active -eq 1 \]/ms;
BAIL_OUT('could not extract the no-restart block from configeth') unless defined $block;

# The sentinel configeth itself uses for "unset"; a literal here would let a hard-coded value
# in the unit under test pass.
my ($token) = $src =~ /^str_default_token="([^"]+)"/m;
BAIL_OUT('could not read str_default_token from configeth') unless defined $token;

my $dir = tempdir( CLEANUP => 1 );
my $run_no = 0;

# One run of the no-restart path. $mtu is what the networks table declares; $link_mtu is what
# the link carries before the run.
sub run_block {
    my ( $mtu, $link_mtu ) = @_;
    $run_no++;
    my $root = File::Spec->catdir( $dir, "run$run_no" );
    mkdir $root or die $!;
    mkdir File::Spec->catdir( $root, 'net' ) or die $!;

    # the NIC is already known, which is what keeps bool_restart_flag at 0
    open my $h, '>', File::Spec->catfile( $root, 'net', 'xcat_history_important' ) or die $!;
    print $h "ens4\n";
    close $h;

    my $harness = File::Spec->catfile( $root, 'harness.sh' );
    open my $fh, '>', $harness or die $!;
    print $fh <<"PRE";
#!/bin/bash
. '$xcatlib'
NODE=cn1
OSVER='alma9.6'
str_default_token='$token'
str_os_type=redhat
str_cfg_dir='$root/net/'
networkmanager_active=1
netplan_active=0
reboot_nic_bool=1
error_code=0
tmp_con_name=''
con_name=xcat-ens4
str_nic_name=ens4
str_dev_name=ens4
str_ipv6_gateway=''
NAMESERVERS=''
NICEXTRAPARAMS=''
log_info(){ :; }
log_warn(){ :; }
log_error(){ :; }
wait_for_ifstate(){ echo 0; }
sleep(){ :; }
is_nmcli_connection_exist(){ return 1; }
v4mask2prefix(){ echo 16; }

LINK='$root/link'      # the modelled kernel link
IPCALLS='$root/ip-calls'
NMCALLS='$root/nmcli-calls'
MODEL='$root/model'    # the modelled NetworkManager profile of xcat-ens4
echo 'mtu=$link_mtu' > "\$LINK"
echo 'up=1' >> "\$LINK"
: > "\$MODEL"

link_get(){ sed -n "s/^\$1=//p" "\$LINK"; }
link_set(){ sed -i "/^\$1=/d" "\$LINK"; echo "\$1=\$2" >> "\$LINK"; }

# Only the forms the block under test uses. Anything else is a change of shape this stub was
# not written for, so it fails loudly rather than returning a quiet success.
ip(){
    echo "\$*" >> "\$IPCALLS"
    case "\$*" in
        "-o link show dev ens4"|"link show dev ens4")
            echo "2: ens4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu \$(link_get mtu) qdisc fq_codel state UP"
            [ "\$(link_get up)" = 1 ] || return 1
            ;;
        "addr show dev ens4") : ;;
        "link set dev ens4 mtu "*) link_set mtu "\${!#}" ;;
        "addr add "*|"addr del "*) : ;;
        "link set dev ens4 down") link_set up 0 ;;
        -6*) : ;;
        *) echo "unexpected ip call: \$*" >&2; exit 3 ;;
    esac
    return 0
}
nm_set(){ sed -i "/^\$1=/d" "\$MODEL"; echo "\$1=\$2" >> "\$MODEL"; }
nmcli(){
    echo "\$*" >> "\$NMCALLS"
    case "\$1 \$2" in
        "con add") nm_set IPADDR 11.1.0.100 ;;
        "con modify")
            case "\$4" in
                mtu) nm_set mtu "\$5" ;;
                *) : ;;
            esac ;;
        *) : ;;
    esac
    return 0
}
PRE

    print $fh "$fn_addip\n";
    print $fh "$fn_configipv4\n";
    print $fh "$fn_setmtu\n";

    # what the parse loop above the block leaves behind for one address on one network
    print $fh "declare -a array_nic_ips=(11.1.0.100)\n";
    print $fh "declare -a array_nic_subnet=(11.1.0.0)\n";
    print $fh "declare -a array_nic_netmask=(255.255.0.0)\n";
    print $fh "declare -a array_nic_gateway=('')\n";
    print $fh "declare -a array_nic_mtu=($mtu)\n";
    print $fh "declare -a array_nic_params=()\n";
    print $fh "hashset hash_new_config '11.1.0.100_16' 'new'\n";
    print $fh "str_ip_mask_pair='11.1.0.100_16'\n";
    print $fh "$block\n";
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

sub link_mtu_of {
    my ($root) = @_;
    my ($m) = slurp("$root/link") =~ /^mtu=(\d+)$/m;
    return $m;
}

# --- a declared MTU reaches the link on the no-restart path ------------------
my $r = run_block( 1496, 1500 );

like( slurp("$r/nmcli-calls"), qr/^con add /m,
    'the no-restart path is the one under test: the profile is created, never activated' );
unlike( slurp("$r/nmcli-calls"), qr/^con up /m,
    'the NIC is not restarted' );
like( slurp("$r/model"), qr/^mtu=1496$/m,
    'the declared MTU is written to the xcat-ens4 profile' );
like( slurp("$r/ip-calls"), qr/^addr add 11\.1\.0\.100/m,
    'the declared address is applied to the live link, as it always was' );

is( link_mtu_of($r), 1496,
    'the declared MTU is applied to the live link too' );

# --- no declared MTU, no touch ----------------------------------------------
# This is what keeps the flat provisioning cases out of the new arm: their networks object
# carries no mtu, so array_nic_mtu holds the unset sentinel and nothing is set on the link.
my $r2 = run_block( $token, 1500 );
unlike( slurp("$r2/ip-calls"), qr/^link set dev ens4 mtu/m,
    'a network with no mtu makes no link change' );
is( link_mtu_of($r2), 1500, 'and the link keeps the MTU it had' );

# --- the declared MTU is already on the link --------------------------------
my $r3 = run_block( 1496, 1496 );
unlike( slurp("$r3/ip-calls"), qr/^link set dev ens4 mtu/m,
    'an MTU the link already carries is not set again' );

done_testing();
