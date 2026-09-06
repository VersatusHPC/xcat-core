#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Test::More;

# xcattest reports a failed check by printing the command that ran. A
# check:output=~PAT whose PAT is already in that command therefore matches the
# failure text and reports Passed either way. nodeset_shell_lzma checked
# "ls -l /tftpboot/xcat/genesis.fs.*.lzma" for "genesis", and
# "ls: cannot access '/tftpboot/xcat/genesis.fs.*.lzma'" carries "genesis" too.
my $CASES = "$FindBin::Bin/../autotest/testcase/genesis/cases0";

open(my $fh, '<', $CASES) or BAIL_OUT("cannot read $CASES: $!");
my @lines = <$fh>;
close($fh);
chomp @lines;

BAIL_OUT("$CASES holds no cmd: line -- the case format changed")
  unless grep { /^cmd:/ } @lines;

my $case    = '';
my $command = '';
my $checked = 0;

for my $line (@lines) {
    if ($line =~ /^start:(\S+)/) {
        $case    = $1;
        $command = '';
        next;
    }
    if ($line =~ /^cmd:(.*)$/) {
        $command = $1;
        next;
    }
    next unless $line =~ /^check:output(?:!)?=~(.*)$/;
    my $pattern = $1;
    $pattern =~ s/^\s+|\s+$//g;
    next unless length $pattern;

    $checked++;
    unlike($command, qr/\Q$pattern\E/,
        "$case: check pattern '$pattern' is absent from the command it asserts on");
}

cmp_ok($checked, '>', 0, 'the genesis cases carry at least one output check');

done_testing();
