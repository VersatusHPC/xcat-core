#!/usr/bin/perl
# The genesis_legacy bundle runs nodeset_shell_lzma on every EL release the legacy Genesis image
# ships for. xcattest drops a case whose `os:` option does not name the management node: it prints
# "Test case nodeset_shell_lzma has an invalid OS option - rhels8", writes no result, and the case
# is then absent from the run's reports entirely. The case carried os:rhels8 because it installed
# xz-lzma-compat from a CentOS 8-Stream URL. That install is gone -- mknb compresses with
# `xz --format=lzma` when /usr/bin/lzma is absent, and xz is on every EL management node -- so the
# option is the only thing left that keeps the case off el9 and el10.
#
# The selection code is lifted out of xCAT-test/xcattest and eval'd, so this asserts what xcattest
# decides, not what the case file says. BAIL_OUT when an extraction stops matching.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $ROOT = dirname(__FILE__) . '/..';

# ---- the option the shipped case declares --------------------------------------------------
my $CASES = "$ROOT/autotest/testcase/genesis/cases0";
open my $cf, '<', $CASES or BAIL_OUT("cannot read $CASES: $!");
my ($in_case, $option);
while (my $l = <$cf>) {
    $in_case = ($1 eq 'nodeset_shell_lzma') if $l =~ /^start:(\S+)/;
    next unless $in_case;
    last if $l =~ /^end\b/;
    $option = $1 if $l =~ /^os\s*:\s*(\S.*?)\s*$/;
}
close $cf;
ok(defined $option, "nodeset_shell_lzma declares an os option ($CASES)")
    or BAIL_OUT('the case declares no os option');

# ---- xcattest's own selection, lifted out ----------------------------------------------------
open my $xf, '<', "$ROOT/xcattest" or BAIL_OUT("cannot read $ROOT/xcattest: $!");
my $src = do { local $/; <$xf> };
close $xf;

my $anchor = q{} . '} elsif ($line =~ /^os\s*:\s*(\w[\w\, ]+)/) {';
my $at = index($src, $anchor);
BAIL_OUT('cannot find the os: branch in xcattest -- has it been rewritten?') if $at < 0;
my $open = index($src, '{', $at + length($anchor) - 1);
my ($depth, $end) = (0, undef);
for (my $j = index($src, '{', $at); $j < length($src); $j++) {
    my $ch = substr($src, $j, 1);
    $depth++ if $ch eq '{';
    $depth-- if $ch eq '}';
    if ($depth == 0) { $end = $j; last }
}
BAIL_OUT('the os: branch never closes') unless defined $end;
my $body = substr($src, index($src, '{', $at) + 1, $end - index($src, '{', $at) - 1);
BAIL_OUT('the lifted os: branch does not decide validity')
    unless $body =~ /\$valid\s*=\s*1/ && $body =~ /noruncases/;

# The branch runs inside xcattest's line loop and reports through its bookkeeping hashes. Give it
# those, and a get_current_os that answers for the release under test.
my $harness = <<'CODE';
package XT;
our (%invalidcases, %invalidoptions, %case_name_index_map, %case_name_index_map_bak, $CUR);
sub get_current_os { return $CUR }
sub delete_item_from_array {
    my ($item, $aref) = @_;
    @$aref = grep { $_ ne $item } @$aref;
}
sub selects {
    my ($option, $currentos) = @_;
    local $CUR = $currentos;
    %invalidcases = (); %invalidoptions = ();
    %case_name_index_map = (nodeset_shell_lzma => 1); %case_name_index_map_bak = ();
    my $case_ref = [ { name => 'nodeset_shell_lzma' } ];
    my ($i, $skip, $run_case_flag, $newcmdstart) = (0, 0, 1, 1);
    my $case_name_index_map_ref = \%case_name_index_map;
    my $line = "os:$option";
    LINE: {
        if ($line =~ /^os\s*:\s*(\w[\w\, ]+)/) {
CODE
$harness .= $body . <<'CODE';
        }
    }
    return !grep { $_ eq 'nodeset_shell_lzma' } @{ $invalidcases{noruncases} || [] };
}
1;
CODE
$harness =~ s/\bnext if \$skip;/last LINE if \$skip;/;
eval $harness or BAIL_OUT("cannot eval the lifted os: branch: $@");

# ---- the releases the genesis_legacy bundle runs on --------------------------------------------
ok(XT::selects($option, $_), "xcattest runs nodeset_shell_lzma on $_")
    for qw(rhels8 rhels9 rhels10);

# The legacy Genesis image and mknb are EL only; the bundle has no SUSE or Ubuntu cell.
ok(!XT::selects($option, $_), "xcattest does not run nodeset_shell_lzma on $_")
    for qw(sles ubuntu);

# The option that dropped the case on the el10 ppc64le cell, so a return to it is red here.
ok(!XT::selects('rhels8', 'rhels10'), 'os:rhels8 alone drops the case on el10');

done_testing();
