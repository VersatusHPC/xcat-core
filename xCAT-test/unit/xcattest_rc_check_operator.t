#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More tests => 5;

# run_case compares the exit status only for == and !=. Any other operator leaves $failflag
# at 0, so "check:rc=0" logs [Pass] on every exit status. A case file that carries one asserts
# nothing at that step.

my $XCATTEST = "$FindBin::Bin/../xcattest";
my $CASEDIR  = "$FindBin::Bin/../autotest/testcase";

ok(-f $XCATTEST, 'xcattest is present') or BAIL_OUT("$XCATTEST not found");

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/run/bin", "$tmp/cases");
copy($XCATTEST, "$tmp/run/bin/xcattest") or BAIL_OUT("cannot copy xcattest: $!");
chmod 0755, "$tmp/run/bin/xcattest";
write_file("$tmp/cfg", "[System]\n");

is(run_check('rc==0', 0), 'Passed', 'rc==0 passes on exit 0');
is(run_check('rc==0', 7), 'Failed', 'rc==0 fails on exit 7');
is(run_check('rc=0',  7), 'Failed', 'an rc operator run_case cannot compare fails the check');

my @carriers = grep { case_file_has_bad_rc_operator($_) } case_files($CASEDIR);
is_deeply(\@carriers, [],
    'no case file carries an rc check with an operator run_case cannot compare');

#---
# run_check: run one command under the real xcattest with one check, and report the verdict.
#---
sub run_check {
    my ($check, $status) = @_;

    write_file("$tmp/cases/cases0",
        "start:rccheck\nlabel:x\ncmd:sh -c 'exit $status'\ncheck:$check\nend\n");
    my @out = qx{cd $tmp/run/bin && XCATROOT=/usr XCATTEST_CASEDIR=$tmp/cases ./xcattest -f $tmp/cfg -t rccheck 2>&1};
    my ($result) = grep { /^-+END::rccheck::/ } @out;
    diag(join('', @out)) unless $result;
    return 'no result line' unless $result;
    return $result =~ /::(Passed|Failed)::/ ? $1 : 'unparsed';
}

#---
# case_files: every case file xcattest loads, which is every file under the testcase tree.
#---
sub case_files {
    my ($dir) = @_;
    my @found;
    my @todo = ($dir);
    while (my $d = shift @todo) {
        opendir(my $dh, $d) or next;
        for my $e (sort grep { $_ !~ /^\.\.?$/ } readdir($dh)) {
            my $p = "$d/$e";
            push @todo,  $p if -d $p;
            push @found, $p if -f $p;
        }
        closedir($dh);
    }
    BAIL_OUT("no case file found under $dir") unless @found;
    return @found;
}

sub case_file_has_bad_rc_operator {
    my ($path) = @_;
    open(my $fh, '<', $path) or return 0;
    while (my $line = <$fh>) {
        next unless $line =~ /^check\s*:\s*rc\s*([=!]+)\s*\d/;
        my $op = $1;
        next if $op eq '==' or $op eq '!=';
        close($fh);
        return 1;
    }
    close($fh);
    return 0;
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or BAIL_OUT("cannot write $path: $!");
    print {$fh} $text;
    close($fh);
    return;
}
