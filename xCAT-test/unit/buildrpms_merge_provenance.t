#!/usr/bin/env perl
# --merge-core-repos assembles rpms an EARLIER run built. That run recorded the state of its own
# tree in each per-arch buildinfo.txt. The merge runs in the same checkout AFTER the build changed
# it (buildsources rewrites xCAT/postscripts/bmcsetup, the release stamp rewrites Release), so a
# status read during the merge calls every merged repo dirty. The merged repo must carry the
# inputs' answer instead.
#
# buildrpms.pl needs a build host to run, so the routine is lifted out and driven against real
# buildinfo files in a scratch tree.
use strict;
use warnings;

use File::Path qw(make_path);
use File::Slurper qw(write_text);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $SCRIPT = "$FindBin::Bin/../../buildrpms.pl";
BAIL_OUT("no buildrpms.pl at $SCRIPT") unless -f $SCRIPT;

my $src = do { open(my $fh, '<', $SCRIPT) or BAIL_OUT("open: $!"); local $/; <$fh> };
my ($body) = $src =~ /^(sub input_worktree_status \{.*?^\})/ms;
BAIL_OUT('buildrpms.pl no longer defines input_worktree_status') unless $body;
{
    package BR;
    ::eval_in($body);
}
sub eval_in { my ($code) = @_; eval "package BR; $code 1" or BAIL_OUT("cannot eval: $@"); }

sub repo_with {
    my ($body) = @_;
    my $dir = tempdir(CLEANUP => 1);
    write_text(File::Spec->catfile($dir, 'buildinfo.txt'), $body) if defined $body;
    return $dir;
}

my $head = "VERSION=2.19.0\nRELEASE=snap1\nCOMMIT_ID=8812ca4\n";

is( BR::input_worktree_status(repo_with($head . "WORKTREE=clean\n")), '',
    'one clean input gives a clean merged repo' );

is( BR::input_worktree_status(
        repo_with($head . "WORKTREE=clean\n"),
        repo_with($head . "WORKTREE=dirty\nDIRTY_FILE= M xCAT/plugins/kea.pm\n")),
    ' M xCAT/plugins/kea.pm',
    'one dirty input makes the merged repo dirty, and names the file' );

is( BR::input_worktree_status(repo_with(undef)), undef,
    'an input with no buildinfo is unknown, never clean' );

is( BR::input_worktree_status(repo_with($head)), undef,
    'an input built before the field existed is unknown, never clean' );

is( BR::input_worktree_status(), undef, 'and no input at all is unknown' );

# The merge takes one tree per arch. When only ONE of them records its status, the answer for the
# merged repo is still unknown: the other arch could have been built from a changed tree and the
# merged rpms would carry it. A per-input skip lets the input that DID report decide, so the merged
# repo reads clean on evidence from half of it.
is( BR::input_worktree_status(
        repo_with($head . "WORKTREE=clean\n"),
        repo_with(undef)),
    undef,
    'a clean input beside an input with no buildinfo is unknown, never clean' );

is( BR::input_worktree_status(
        repo_with(undef),
        repo_with($head . "WORKTREE=clean\n")),
    undef,
    'and the order of the inputs does not change that' );

is( BR::input_worktree_status(
        repo_with($head . "WORKTREE=clean\n"),
        repo_with($head)),
    undef,
    'a clean input beside one built before the field existed is unknown' );

# A dirty input still names its files, whatever the other input reports. Dirty is a fact about the
# rpms that are in the merged repo, and unknown must not hide it.
is( BR::input_worktree_status(
        repo_with(undef),
        repo_with($head . "WORKTREE=dirty\nDIRTY_FILE= M xCAT/plugins/kea.pm\n")),
    ' M xCAT/plugins/kea.pm',
    'a dirty input beside an unreadable one still reports dirty' );

done_testing();
