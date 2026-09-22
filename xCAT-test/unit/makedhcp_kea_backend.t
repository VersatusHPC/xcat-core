#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(mkpath);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# Regression: two makedhcp cases probe the ISC layout on a management node that runs Kea, so
# they report a failure while DHCP works.
#
#   makedhcp_n         asks systemctl for kea-dhcp4. On Ubuntu the unit is kea-dhcp4-server,
#                      so the case fell through to isc-dhcp-server -- the daemon xCAT does
#                      not use there -- and reported it failed.
#   makedhcp_a_ubuntu  greps the Kea leases CSV for the reservation. dhcp.pm writes a
#                      reservation into the Kea configuration; a reservation is not a lease.
#
# Both commands are shell, so they are driven here with systemctl and service shadowed and
# every path pointed at a scratch tree.

my $repo_root = File::Spec->rel2abs(
    File::Spec->catdir( $FindBin::Bin, '..', '..' )
);
my $case_file = File::Spec->catfile(
    $repo_root, 'xCAT-test', 'autotest', 'testcase', 'makedhcp', 'cases0'
);
plan skip_all => "makedhcp/cases0 not found" unless -f $case_file;

my $src = do { local $/; open my $fh, '<', $case_file or die $!; <$fh> };

# die when a case or its command stops matching, so a rename fails loudly instead of
# silently covering nothing.
sub case_command {
    my ( $case, $needle ) = @_;
    my ($block) = $src =~ /^start:\Q$case\E$(.*?)^end$/ms;
    die "could not find case $case in makedhcp/cases0\n" unless defined $block;
    my @cmds = grep { index( $_, $needle ) >= 0 } ( $block =~ /^cmd:(.*)$/mg );
    die "expected one command matching '$needle' in $case, found " . scalar(@cmds) . "\n"
      unless @cmds == 1;
    return $cmds[0];
}

# CI runs as root. A command that still names /etc or /var after the rewrite would act on
# the host, so refuse to run one.
sub sandbox {
    my ( $cmd, $root, $node ) = @_;
    $cmd =~ s{(?<![\w/])/etc/}{$root/etc/}g;
    $cmd =~ s{(?<![\w/])/var/lib/}{$root/var/lib/}g;
    $cmd =~ s/\$\$CN/$node/g;
    die "sandbox left a real path in: $cmd\n"
      if $cmd =~ m{(?<!\Q$root\E)(/etc/|/var/lib/)};
    return $cmd;
}

sub run_shell {
    my ( $prelude, $cmd ) = @_;
    my $out = qx{bash -c '$prelude $cmd' 2>&1};
    return $out;
}

# A systemctl and a service that know exactly which units are active on this fake node.
# bash resolves a function ahead of PATH, and the case only asks is-active and status.
sub fake_units {
    my (@active) = @_;
    my $list = join( ' ', @active );
    return qq{
      active_units="$list";
      systemctl() {
        local verb="\$1" unit="\$2";
        case " \$active_units " in *" \$unit "*) ;; *) return 3;; esac;
        if [ "\$verb" = "is-active" ]; then echo active; return 0; fi;
        if [ "\$verb" = "status" ]; then echo "     Active: active (running) since now"; return 0; fi;
        return 0;
      };
      service() {
        local unit="\$1";
        case " \$active_units " in
          *" \$unit "*) echo "     Active: active (running) since now"; return 0;;
          *) echo "     Active: failed (Result: exit-code)"; return 3;;
        esac;
      };
    };
}

sub write_release {
    my ( $root, $text ) = @_;
    mkpath("$root/etc");
    open my $fh, '>', "$root/etc/os-release" or die $!;
    print {$fh} $text;
    close $fh;
}

my $UBUNTU = qq{NAME="Ubuntu"\nVERSION="24.04.4 LTS (Noble Numbat)"\nID=ubuntu\n};
my $ALMA   = qq{NAME="AlmaLinux"\nVERSION="9.4 (Seafoam Ocelot)"\nID="almalinux"\n};

# ---- makedhcp_n: the case must report the DHCP daemon xCAT actually runs ----------------
{
    my $cmd = case_command( 'makedhcp_n', 'is-active' );

    my @nodes = (
        [ 'a Kea management node on Ubuntu', $UBUNTU, ['kea-dhcp4-server'] ],
        [ 'a Kea management node whose unit is kea-dhcp4', $UBUNTU, ['kea-dhcp4'] ],
        [ 'an ISC management node on Ubuntu', $UBUNTU, ['isc-dhcp-server'] ],
        [ 'an ISC management node on EL',     $ALMA,   ['dhcpd'] ],
    );

    for my $n (@nodes) {
        my ( $what, $release, $active ) = @$n;
        my $root = tempdir( CLEANUP => 1 );
        write_release( $root, $release );
        my $out = run_shell( fake_units(@$active), sandbox( $cmd, $root, 'testnode' ) );
        like( $out, qr/running/, "makedhcp_n reports the daemon running on $what" );
    }
}

# ---- makedhcp_a_ubuntu: the reservation is in the Kea config, not in the leases ---------
{
    my $cmd  = case_command( 'makedhcp_a_ubuntu', 'dhcpd.leases' );
    my $mac  = '11:22:33:44:55:66';
    my $node = 'testnode';

    # A Kea management node: makedhcp -a wrote the reservation into the Kea configuration.
    # The leases file exists and holds no lease for this node, which is the state the live
    # cells were in.
    my $root = tempdir( CLEANUP => 1 );
    write_release( $root, $UBUNTU );
    mkpath("$root/etc/kea");
    mkpath("$root/var/lib/kea");
    open my $kc, '>', "$root/etc/kea/kea-dhcp4.conf" or die $!;
    print {$kc} qq[{ "Dhcp4": { "subnet4": [ { "id": 1, "reservations": [\n];
    print {$kc} qq[  { "hw-address": "$mac", "ip-address": "192.0.2.22", "hostname": "$node" }\n];
    print {$kc} qq[] } ] } }\n];
    close $kc;
    open my $kl, '>', "$root/var/lib/kea/kea-leases4.csv" or die $!;
    print {$kl} "address,hwaddr,client_id,valid_lifetime,expire,subnet_id\n";
    close $kl;

    my $out = run_shell( '', sandbox( $cmd, $root, $node ) );
    like( $out, qr/\Q$mac\E/, 'the Kea reservation MAC is read back on a Kea node' );
    like( $out, qr/\Q$node\E/, 'the Kea reservation hostname is read back on a Kea node' );

    # An ISC management node still reads its leases file.
    my $root2 = tempdir( CLEANUP => 1 );
    write_release( $root2, $UBUNTU );
    mkpath("$root2/var/lib/dhcp");
    open my $il, '>', "$root2/var/lib/dhcp/dhcpd.leases" or die $!;
    print {$il} qq[host $node {\n  hardware ethernet $mac;\n  fixed-address 192.0.2.22;\n}\n];
    close $il;
    my $out2 = run_shell( '', sandbox( $cmd, $root2, $node ) );
    like( $out2, qr/\Q$mac\E/,  'the ISC lease MAC is read back on an ISC node' );
    like( $out2, qr/\Q$node\E/, 'the ISC lease hostname is read back on an ISC node' );
}

done_testing();
