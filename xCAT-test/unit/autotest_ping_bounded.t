#!/usr/bin/env perl
# nodepurge/cases0 asserts that a purged node no longer resolves, by running ping and expecting a
# non-zero exit. An unbounded ping returns at once when the name does not resolve -- the passing
# path -- but never returns when the name DOES resolve, which is the regression the case exists to
# catch. The cell then stops on that line until the pipeline timeout kills it, and the whole run's
# JUnit is lost (VersatusHPC/xcat-internal#59).
#
# The assertion runs the ping command line the case actually carries, against a target that
# resolves AND answers, and requires it to terminate. An unbounded ping never terminates, so the
# outer timeout reaps it and the test goes red. Reading the line and matching it for "-c" would
# pass on any spelling that happens to contain those characters, so the command is executed.
#
# Nothing here can hang: every ping runs under `timeout`, with its stdio sent to /dev/null so no
# child holds the harness's output pipe open.
use strict;
use warnings;

use FindBin;
use File::Spec;
use Test::More;

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
my $cases = File::Spec->catfile( $repo_root, qw(xCAT-test autotest testcase nodepurge cases0) );

plan skip_all => "no ping binary to execute" unless grep { -x "$_/ping" } split /:/, ( $ENV{PATH} || '' );
plan skip_all => "cannot read $cases" unless -r $cases;

open( my $fh, '<', $cases ) or die "Unable to read $cases: $!";
my @ping_cmds = map { /^cmd:\s*(ping\s+.*\S)/ ? $1 : () } <$fh>;
close($fh);

# The case is the artifact under test. If it stops carrying ping lines the extraction is stale and
# this file would silently assert nothing.
BAIL_OUT("no 'cmd:ping' lines in $cases -- has the case been rewritten?") unless @ping_cmds;

plan tests => 2 * scalar(@ping_cmds);

# Loopback resolves and answers on any CI host, with no DNS involved. It is the condition under
# which an unbounded ping runs forever.
my $ANSWERS = '127.0.0.1';

# RFC 2606 reserves .invalid, so it must never resolve. This is the case's own passing path.
my $NXDOMAIN = 'xcat-purged-node.invalid';

# The bound the case must impose has to be well under this, or the guard is measuring the timeout.
my $LIMIT = 10;

sub run_bounded {
    my ($cmd) = @_;
    my $rc = system("timeout $LIMIT $cmd >/dev/null 2>&1");
    # 124 is what timeout(1) returns when it had to kill the command.
    return ( $rc >> 8 );
}

for my $cmd (@ping_cmds) {
    ( my $answering = $cmd ) =~ s/(\S+)$/$ANSWERS/;
    my $rc = run_bounded($answering);
    isnt( $rc, 124, "'$answering' terminates on its own against a host that answers" );

    ( my $unresolvable = $cmd ) =~ s/(\S+)$/$NXDOMAIN/;
    my $nx = run_bounded($unresolvable);
    ok( $nx != 0 && $nx != 124,
        "'$unresolvable' still exits non-zero, promptly, so check:rc!=0 holds" );
}
