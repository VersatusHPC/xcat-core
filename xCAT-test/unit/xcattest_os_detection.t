#!/usr/bin/perl
# xcattest decides whether a case may run by matching the case's os: restriction against
# get_current_os(). A distribution it does not recognise gets an empty answer, which matches
# nothing, so every os-restricted case is skipped -- and the message blames the CASE ("has an
# invalid OS option"), which reads like the case is wrong rather than the detection.
#
# openSUSE Leap was such a distribution: /etc/os-release says ID="opensuse-leap" with no SLES
# string, and there is no /etc/SuSE-release, so the sub fell off its elsif chain. On a Leap
# management node every flat provisioning case was silently skipped.
use strict;
use warnings;
use Test::More tests => 5;
use File::Temp qw(tempdir);

my $script = -f 'xCAT-test/xcattest' ? 'xCAT-test/xcattest' : '../xcattest';
die "cannot find xcattest" unless -f $script;
my $src = do { open my $fh, '<', $script or die $!; local $/; <$fh> };

my ($sub) = $src =~ /(sub get_current_os \{.*?\n\})/s
    or die "get_current_os is not in xcattest -- renamed or removed";

# Point the routine at a scratch tree instead of the host's real release files, and give it the
# runcmd it calls. Everything else runs verbatim.
my $root = tempdir(CLEANUP => 1);
for my $f (qw(/etc/redhat-release /etc/lsb-release /etc/os-release /etc/SuSE-release)) {
    $sub =~ s{\Q"$f"\E}{"$root$f"}g;
}
$sub =~ s/&runcmd/main::t_runcmd/g;
mkdir "$root/etc";

our $RUNCMD_RC;
sub t_runcmd { my ($c) = @_; $::RUNCMD_RC = (system("$c >/dev/null 2>&1") == 0) ? 0 : 1; return (); }
eval "$sub 1" or die "cannot load get_current_os: $@";

sub detect {
    my ($content) = @_;
    unlink glob "$root/etc/*";
    open my $fh, '>', "$root/etc/os-release" or die $!; print $fh $content; close $fh;
    return get_current_os();
}

is(detect(qq{NAME="openSUSE Leap"\nID="opensuse-leap"\nVERSION_ID="15.6"\n}), 'sles',
   'openSUSE Leap is recognised, as the SLE family whose package set it shares');
is(detect(qq{NAME="openSUSE Leap"\nID="opensuse-leap"\nVERSION_ID="16.0"\n}), 'sles',
   '... at any Leap version');
is(detect(qq{NAME="SLES"\nID="sles"\nVERSION_ID="15.6"\n}), 'sles',
   'SLES is still recognised');
my $leap = detect(qq{NAME="openSUSE Leap"\nID="opensuse-leap"\n});
ok(defined $leap && $leap ne '',
   'a SUSE host never answers empty, which would match no case at all');
is(detect(qq{NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\n}), 'sles',
   'Tumbleweed answers too rather than falling through silently');
