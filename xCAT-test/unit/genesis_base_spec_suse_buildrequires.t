#!/usr/bin/env perl
# The genesis build root is whatever the spec build-requires, and the spec was written for
# Fedora and EL. Eight of its BuildRequires do not exist on openSUSE Leap or SLE:
#
#   No matching package to install: 'dracut-network' ... 'kernel-core' ... 'vim-minimal'
#   Not all dependencies satisfied
#
# dnf builddep then fails, mock stops, and xcat-dep-build-opensuse15-x86_64 publishes nothing --
# so the leap15.6 cell has no xCAT-genesis-base and cannot install xCAT at all.
#
# This evaluates the spec's own %if conditionals, through XCAT::Test::Spec, and asserts the
# BuildRequires list one macro set actually produces. A grep for a package name cannot do that: every one of the
# eight names is still in the file, inside a branch SUSE does not take.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path slurp_repo_file);
use XCAT::Test::Spec qw(spec_tag_values);

my $relative = 'xCAT-genesis-base/xCAT-genesis-base.spec';
plan skip_all => "$relative not found" unless -f repo_path($relative);

my $spec = slurp_repo_file($relative);

# Leap 15.6 and EL 9, both x86_64. suse_version is what rpm defines on Leap and SLE.
my @suse = spec_tag_values($spec, 'BuildRequires',
    { suse_version => 1500, tarch => 'x86_64', target_cpu => 'x86_64' });
my @el9  = spec_tag_values($spec, 'BuildRequires',
    { rhel => 9, tarch => 'x86_64', target_cpu => 'x86_64' });

# Control: the evaluator must produce a real list, and the two must differ. Without this a
# function that returns nothing makes every "is not required" assertion below pass.
cmp_ok(scalar(@suse), '>', 30, 'control: the evaluator produces a build-requires list for SUSE');
ok(grep({ $_ eq 'openssl' } @suse), 'control: openssl is required on SUSE as on every release');
ok(grep({ $_ eq 'kernel-core' } @el9),
    'control: the EL branch is unchanged -- EL 9 still requires kernel-core');

# The eight names Leap and SLE do not package. Each is still in the spec, in an EL branch.
my %suse = map { $_ => 1 } @suse;
for my $pkg (qw(dracut-network kernel-core kernel-modules kernel-modules-extra
                nmap-ncat perl-interpreter procps-ng vim-minimal)) {
    ok(!$suse{$pkg}, "SUSE does not build-require $pkg, which Leap and SLE do not package");
}

# What SUSE needs instead. kernel-default carries the modules EL splits into three packages.
for my $pkg (qw(dracut kernel-default ncat perl procps vim-small)) {
    ok($suse{$pkg}, "SUSE build-requires $pkg");
}

done_testing();
