#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $casefile = "$FindBin::Bin/../autotest/testcase/makedhcp/cases0";
BAIL_OUT("no makedhcp case file at $casefile") unless -f $casefile;

# The makedhcp_n probe reports whether the DHCP daemon runs. EL9 and EL10 management nodes carry
# no service(8): the shipped probe exits 127 there and the case reads that as a stopped daemon.
# Run the probe line the case ships, on a PATH with no service(8), and read what it reports.
my $probe = extract_probe($casefile, 'makedhcp_n');
BAIL_OUT("makedhcp_n has no daemon probe followed by check:output=~running") unless $probe;

my $root = tempdir(CLEANUP => 1);
make_path("$root/bin");
write_systemd_stub("$root/bin/systemctl");
write_release_stub("$root/bin/cat");

my $path = path_without_service();
BAIL_OUT("service(8) is still on the test PATH") if which_on($path, 'service');

my @shapes = (
    { name => 'EL with ISC dhcpd',      unit => 'dhcpd',           release => 'AlmaLinux 9.8 (Olive Jaguar)' },
    { name => 'EL with Kea',            unit => 'kea-dhcp4',       release => 'AlmaLinux 10.2 (Lavender Lion)' },
    { name => 'Ubuntu with ISC dhcpd',  unit => 'isc-dhcp-server', release => 'Ubuntu 24.04.1 LTS' },
);

for my $shape (@shapes) {
    local $ENV{PATH}          = "$root/bin:$path";
    local $ENV{STUB_ACTIVE}   = $shape->{unit};
    local $ENV{STUB_RELEASE}  = $shape->{release};
    my $output = `bash -c '$probe' 2>&1`;
    like($output, qr/running/, "$shape->{name}: the probe reports the daemon running");
}

done_testing();

#-----------------------------------------------------------------------------

=head3 extract_probe

    Descriptions:
        Read the command line a case runs to report the state of the DHCP daemon. The probe is
        the cmd line whose check line matches the daemon on its output.
    Arguments:
        $file the case file to read
        $case the name of the case
    Returns:
        the command line, or undef when the case does not carry such a pair

=cut

#-----------------------------------------------------------------------------
sub extract_probe {
    my ($file, $case) = @_;
    open(my $fh, '<', $file) or BAIL_OUT("open $file: $!");
    my ($in_case, $last_cmd, $probe);
    while (my $line = <$fh>) {
        chomp($line);
        $in_case = 1 if $line eq "start:$case";
        next unless $in_case;
        last if $line eq 'end';
        $last_cmd = $1 if $line =~ /^cmd:(.+)$/;
        if ($line =~ /^check:\s*output\s*=~\s*running\s*$/ and $last_cmd) {
            $probe = $last_cmd;
            last;
        }
    }
    close($fh) or BAIL_OUT("close $file: $!");
    return $probe;
}

#-----------------------------------------------------------------------------

=head3 write_systemd_stub

    Descriptions:
        Write a systemctl that reports the unit named by STUB_ACTIVE as running and every other
        unit as stopped.
    Arguments:
        $target the path to write
    Returns:
        none

=cut

#-----------------------------------------------------------------------------
sub write_systemd_stub {
    my ($target) = @_;
    open(my $fh, '>', $target) or BAIL_OUT("write $target: $!");
    print $fh <<'STUB';
#!/bin/sh
verb=$1
unit=$2
case "$verb" in
    is-active)
        if [ "$unit" = "$STUB_ACTIVE" ]; then echo active; exit 0; fi
        echo inactive
        exit 3
        ;;
    status)
        echo "* $unit.service"
        if [ "$unit" = "$STUB_ACTIVE" ]; then
            echo "     Active: active (running)"
            exit 0
        fi
        echo "     Active: inactive (dead)"
        exit 3
        ;;
esac
exit 1
STUB
    close($fh) or BAIL_OUT("close $target: $!");
    chmod 0755, $target or BAIL_OUT("chmod $target: $!");
    return;
}

#-----------------------------------------------------------------------------

=head3 write_release_stub

    Descriptions:
        Write a cat that prints the release named by STUB_RELEASE. The probe reads /etc/*release
        to tell Ubuntu from the other families, and the host running the suite is not the host
        the probe describes.
    Arguments:
        $target the path to write
    Returns:
        none

=cut

#-----------------------------------------------------------------------------
sub write_release_stub {
    my ($target) = @_;
    open(my $fh, '>', $target) or BAIL_OUT("write $target: $!");
    print $fh <<'STUB';
#!/bin/sh
echo "PRETTY_NAME=\"$STUB_RELEASE\""
exit 0
STUB
    close($fh) or BAIL_OUT("close $target: $!");
    chmod 0755, $target or BAIL_OUT("chmod $target: $!");
    return;
}

#-----------------------------------------------------------------------------

=head3 path_without_service

    Descriptions:
        Build a PATH that holds no service(8), so the probe meets the EL9 and EL10 management
        node the case fails on.
    Arguments:
        none
    Returns:
        the PATH string

=cut

#-----------------------------------------------------------------------------
sub path_without_service {
    my @keep = grep { !-x "$_/service" } split(/:/, $ENV{PATH} || '/usr/bin:/bin');
    return join(':', @keep);
}

#-----------------------------------------------------------------------------

=head3 which_on

    Descriptions:
        Report whether a command is executable on the given PATH.
    Arguments:
        $path the PATH to search
        $cmd  the command to look for
    Returns:
        1 when found, 0 when not

=cut

#-----------------------------------------------------------------------------
sub which_on {
    my ($path, $cmd) = @_;
    for my $dir (split(/:/, $path)) {
        return 1 if -x "$dir/$cmd";
    }
    return 0;
}
