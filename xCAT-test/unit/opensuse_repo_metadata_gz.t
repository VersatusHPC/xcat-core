#!/usr/bin/env perl
# zypper 1.13 on openSUSE Leap 42.3 has no zstd reader. createrepo_c on the build host writes
# primary.xml.zst by default, so Leap 42.3 refuses the published core with
# "Failed to cache repo (4)". The flat openSUSE core is built once, on the Leap 15.6 target,
# and serves Leap 42.3 as well, so every openSUSE core index must use gzip.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../build-utils/lib";
use Test::More;

use XCAT::BuildUtils ();

my $compress = XCAT::BuildUtils->can('repo_metadata_compress_args')
    or die "XCAT::BuildUtils has no repo_metadata_compress_args\n";
my $target_of = XCAT::BuildUtils->can('core_repo_target')
    or die "XCAT::BuildUtils has no core_repo_target\n";

my $gz = qr/--compress-type gz\b.*--general-compress-type gz\b/;

like($compress->('opensuse-leap-42.3-x86_64'), $gz,
    'a Leap 42.3 index uses gzip metadata');
like($compress->('opensuse-leap-15.6-x86_64'), $gz,
    'the Leap 15.6 target, which builds the flat core Leap 42.3 installs, uses gzip metadata');
like($compress->('opensuse-leap-16.0-x86_64'), $gz,
    'a Leap 16.0 index uses gzip metadata');
like($compress->('alma+epel-10-x86_64', 'opensuse-leap-15.6-x86_64'), $gz,
    'one openSUSE input is enough to index the merged repo with gzip');
is($compress->('alma+epel-10-x86_64', 'alma+epel-9-ppc64le'), '',
    'an EL index keeps the createrepo_c default');
is($compress->('openeuler-24.03sp4-x86_64'), '',
    'an openEuler index keeps the createrepo_c default');
is($compress->(), '', 'no target keeps the createrepo_c default');
is($compress->(undef), '', 'an undefined target keeps the createrepo_c default');

is($target_of->('/w/source/xcat-core/dist/opensuse-leap-15.6-x86_64/rpms'),
    'opensuse-leap-15.6-x86_64', 'a per-target tree names its target');
is($target_of->('dist/alma+epel-10-ppc64le/rpms/'),
    'alma+epel-10-ppc64le', 'a trailing slash does not hide the target');
is($target_of->('/w/repos/yum-suse/xcat-core', "VERSION=2.21.0\nBUILD_TARGET=opensuse-leap-42.3-x86_64\n"),
    'opensuse-leap-42.3-x86_64', 'buildinfo names the target of a tree outside dist/');
is($target_of->('/w/repos/core-x86_64', "VERSION=2.21.0\n"), undef,
    'a tree with no target in its path or buildinfo names none');

done_testing();
