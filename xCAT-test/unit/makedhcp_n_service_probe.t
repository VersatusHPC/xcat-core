#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

# The makedhcp cases ask the management node about its DHCP server through
# service(8). EL9 carries no service(8): the command lives in
# initscripts-service, which no xCAT dependency installs. These tests run the
# case commands themselves against a management node that has systemd and no
# service(8), once per DHCP server xCAT can leave running.

my $cases = "$FindBin::Bin/../autotest/testcase/makedhcp/cases0";
open(my $fh, '<', $cases) or BAIL_OUT("cannot read $cases: $!");
my @lines = <$fh>;
close($fh);
chomp(@lines);

my $probe;
my $in_case = 0;
for my $i (0 .. $#lines) {
    $in_case = 1 if $lines[$i] eq 'start:makedhcp_n';
    $in_case = 0 if $in_case && $lines[$i] eq 'end';
    next unless $in_case;
    next unless $lines[$i] =~ /^cmd:(.+)$/;
    my $cmd = $1;
    next unless defined $lines[ $i + 1 ];
    next unless $lines[ $i + 1 ] =~ /^check:output=~running$/;
    $probe = $cmd;
    last;
}
BAIL_OUT("no 'check:output=~running' probe found in case makedhcp_n of $cases")
  unless defined $probe;

my %seen;
my @restarts =
  grep { !$seen{$_}++ }
  map  { /^cmd:(.+)$/ ? $1 : () }
  grep { /^cmd:.*\brestart\b/ } @lines;
BAIL_OUT("no DHCP server restart command found in $cases") unless @restarts;

# A management node that runs systemd and has no service(8). $unit is the only
# active DHCP server. The stubs come first on PATH, so the stub service(8)
# answers the way EL9 does when the command is absent, and the stub systemctl
# records what the case asked it to do.
sub sandbox {
    my ($unit) = @_;

    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/bin");

    open(my $sc, '>', "$dir/bin/systemctl") or die "systemctl stub: $!";
    print $sc <<"STUB";
#!/bin/sh
echo "\$@" >> "$dir/calls"
action=\$1
unit=\$2
case "\$action" in
is-active)
    [ "\$unit" = "$unit" ] && { echo active; exit 0; }
    echo inactive
    exit 3
    ;;
status)
    if [ "\$unit" = "$unit" ]; then
        echo "\$unit.service - a DHCP server"
        echo "     Active: active (running) since Sat 2026-09-06 00:00:00 UTC"
        exit 0
    fi
    echo "     Active: inactive (dead)"
    exit 3
    ;;
restart)
    [ "\$unit" = "$unit" ] && exit 0
    exit 5
    ;;
esac
exit 1
STUB
    close($sc);

    open(my $sv, '>', "$dir/bin/service") or die "service stub: $!";
    print $sv <<'STUB';
#!/bin/sh
echo "sh: service: command not found" >&2
exit 127
STUB
    close($sv);
    chmod(0755, "$dir/bin/systemctl", "$dir/bin/service");
    return $dir;
}

sub run_in {
    my ($dir, $cmd) = @_;

    open(my $pf, '>', "$dir/cmd.sh") or die "command file: $!";
    print $pf $cmd . "\n";
    close($pf);

    local $ENV{PATH} = "$dir/bin:/usr/bin:/bin";
    my $out = qx{/bin/sh $dir/cmd.sh 2>&1};
    return defined($out) ? $out : '';
}

sub calls {
    my ($dir) = @_;
    open(my $cf, '<', "$dir/calls") or return '';
    local $/;
    my $all = <$cf>;
    close($cf);
    return defined($all) ? $all : '';
}

# Each of the three servers xCAT can leave running on a management node.
for my $unit (qw(kea-dhcp4 isc-dhcp-server dhcpd)) {
    my $dir = sandbox($unit);
    my $out = run_in($dir, $probe);
    like($out, qr/running/,
        "makedhcp_n reports $unit running on a node with no service(8)");
}

for my $i (0 .. $#restarts) {
    for my $unit (qw(kea-dhcp4 isc-dhcp-server dhcpd)) {
        my $dir = sandbox($unit);
        run_in($dir, $restarts[$i]);
        like(calls($dir), qr/^restart \Q$unit\E/m,
            "restart command $i restarts $unit on a node with no service(8)");
    }
}

done_testing();
