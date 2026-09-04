#!/usr/bin/env perl
# An autotest case that runs `ping` with no count runs until something kills it. When the target
# does resolve -- which is the failure the case is there to catch -- the cell stops making progress
# and is eventually taken out by the pipeline timeout, which destroys the whole run's JUnit rather
# than reporting one failed case.
#
# The case files are data, not code: there is nothing to execute, and the text is the contract.
use strict;
use warnings;

use File::Find;
use FindBin;
use Test::More;

my $casedir = "$FindBin::Bin/../autotest/testcase";
plan skip_all => "no autotest testcase directory at $casedir" unless -d $casedir;

my @unbounded;
my $checked = 0;
find(sub {
    return unless -f $_;
    return if -B $_;                       # the tree carries binary fixtures (an rpm, tarballs)
    open(my $fh, '<', $_) or return;
    my $body = do { local $/; <$fh> };
    close($fh);
    # A case file declares cases. Anything else under testcase/ is a fixture or a template, and
    # a `ping` inside one is not a command this suite runs.
    return unless $body =~ /^start:/m;
    my $line = 0;
    open($fh, '<', \$body) or return;
    while (my $l = <$fh>) {
        $line++;
        # ping must be the command being INVOKED, not a path mentioned as an argument
        # ("ls -l /bin/ping"). It counts at the start of the command, or after a quote,
        # pipe, semicolon or && -- which also catches `xdsh <node> "ping ..."`.
        next unless $l =~ /^cmd:\s*ping6?\s/ || $l =~ /["'`;|&]\s*ping6?\s/;
        $checked++;
        # -c <n> bounds the run. -w/-W alone bound the deadline but still need a count on some
        # implementations, so require the count and accept a deadline alongside it.
        next if $l =~ /\s-c\s*\d+/;
        chomp $l;
        (my $rel = $File::Find::name) =~ s{^.*/xCAT-test/}{xCAT-test/};
        push @unbounded, "$rel:$line: $l";
    }
    close($fh);
}, $casedir);

cmp_ok($checked, '>', 0, 'the scan found ping commands to check, so it is not vacuously passing');
is_deeply(\@unbounded, [],
    'every ping in an autotest case is bounded by -c, so a resolving name cannot hang the cell')
    or diag("unbounded ping commands:\n  " . join("\n  ", @unbounded));

done_testing();
