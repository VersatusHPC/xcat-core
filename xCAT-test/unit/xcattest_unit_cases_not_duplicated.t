#!/usr/bin/env perl
# A unit test runs once, from the source tree.
#
# github_action_xcat_test.pl copies the checkout aside before the build and runs
# "prove -r xCAT-test/unit" in the copy, so every file under xCAT-test/unit already runs on
# every pull request. An xcattest case that proves the same file again under
# /opt/xcat/share/xcat/tools/autotest/unit runs it from a second root, where FindBin resolves
# to the installed product instead of the checkout. The same file then passes in one run and
# fails in the other, which is a report about the two roots and not about the code under test.
#
# The integration tests are not this: nothing else runs xCAT-test/integration.
use strict;
use warnings;

use File::Find ();
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use XCAT::Test::File qw(repo_path);

my $testcase = repo_path('xCAT-test/autotest/testcase');
my $installed_unit = '/opt/xcat/share/xcat/tools/autotest/unit';

my @cases;
File::Find::find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless -f $File::Find::name;
            return unless ( File::Spec->splitpath($File::Find::name) )[2] =~ /^cases/;
            push @cases, $File::Find::name;
        },
    },
    $testcase,
);
plan skip_all => 'no xcattest cases found' unless @cases;

my @duplicated;
foreach my $path ( sort @cases ) {
    my $relative = File::Spec->abs2rel( $path, $testcase );
    open( my $fh, '<', $path ) or die "Unable to open $path for reading: $!";
    while ( my $line = <$fh> ) {
        chomp $line;
        next unless $line =~ /^cmd:.*\bprove\b/;
        next unless index( $line, $installed_unit ) >= 0;
        push @duplicated, "$relative:$.: $line";
    }
    close($fh) or die "Unable to close $path: $!";
}

is_deeply( \@duplicated, [], "no xcattest case proves $installed_unit a second time" )
    or diag( join( "\n", @duplicated ) );

done_testing();
