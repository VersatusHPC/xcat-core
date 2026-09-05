#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

use xCAT::Utils;

# xcatconfig writes the value of gettimezone() into site.timezone, and the OS
# install templates put that value into the kickstart `timezone` directive. A
# lookup that fails must therefore not return a message: anaconda reads
# "timezone Could not determine timezone checksum --utc" as four arguments and
# stops the install with "One or zero arguments are expected for the timezone
# command".

plan tests => 5;

{
    no warnings 'redefine';
    local *xCAT::Utils::runcmd = sub { $::RUNCMD_RC = 1; return ""; };

    my $tz = xCAT::Utils->gettimezone();
    my $shown = defined($tz) ? "'$tz'" : 'undef';

    ok(!defined($tz) || $tz =~ m{^[\w+./:-]+$},
        "a failed lookup returns a timezone name or nothing, never a message")
      or diag("gettimezone returned $shown");

    ok(!defined($tz) || -e "/usr/share/zoneinfo/$tz",
        "a failed lookup returns a name that exists under /usr/share/zoneinfo")
      or diag("gettimezone returned $shown");
}

my $root = tempdir(CLEANUP => 1);
make_path("$root/zoneinfo/Area");
_write("$root/zoneinfo/Area/City", "scratch zone payload\n");
_write("$root/localtime",         "scratch zone payload\n");
_write("$root/other",             "a different payload\n");

if (!xCAT::Utils->can('linux_timezone')) {
    fail("xCAT::Utils::linux_timezone is not defined") for (1 .. 3);
} else {
    is(xCAT::Utils->linux_timezone("$root/localtime", "$root/zoneinfo", "$root/absent-timezone"),
        "Area/City",
        "the zone file that matches localtime names the timezone");

    is(xCAT::Utils->linux_timezone("$root/absent-localtime", "$root/zoneinfo", "$root/absent-timezone"),
        "UTC",
        "a system with no localtime file reads as UTC");

    is(xCAT::Utils->linux_timezone("$root/other", "$root/zoneinfo", "$root/absent-timezone"),
        undef,
        "a localtime file that matches no zone returns nothing");
}

sub _write {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print $fh $content;
    close($fh);
    return;
}
