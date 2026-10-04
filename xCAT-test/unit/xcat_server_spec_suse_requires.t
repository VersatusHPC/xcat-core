#!/usr/bin/env perl
# xCAT-server requires perl-DB_File by its EL package name. openSUSE and SLE package the same
# module as perl-core-DB_File, so on a Leap management node zypper answers:
#
#   Problem: nothing provides 'perl-DB_File' needed by the to be installed xCAT-server
#   Solution 1: do not install xCAT
#
# and the install step of the leap15.6 cell stops there -- with xCAT never installed, so every
# case in the bundle is unmeasured.
#
# This evaluates the spec's own conditionals for one macro set and asserts the Requires that set
# produces. The EL name stays in the file, in a branch SUSE does not take, so a grep for it
# cannot tell the two families apart.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path slurp_repo_file);
use XCAT::Test::Spec qw(spec_tag_values);

my $relative = 'xCAT-server/xCAT-server.spec';
plan skip_all => "$relative not found" unless -f repo_path($relative);

my $spec = slurp_repo_file($relative);
my %base = (target_cpu => 'x86_64', os => 'linux', notpcm => 1, nots390x => 1);

my %suse = map { $_ => 1 } spec_tag_values($spec, 'Requires', { %base, suse_version => 1500 });
my %el9  = map { $_ => 1 } spec_tag_values($spec, 'Requires', { %base, rhel => 9 });
my %el10 = map { $_ => 1 } spec_tag_values($spec, 'Requires', { %base, rhel => 10 });

# Controls. Without them an evaluator that returned nothing would make every absence below pass,
# and a change that moved the EL names would go unnoticed.
cmp_ok(scalar(keys %suse), '>', 10, 'control: the evaluator produces a Requires list for SUSE');
ok($suse{'perl-Net-DNS'}, 'control: the unconditional requires are in the SUSE list');
ok($el9{'perl-DB_File'}, 'control: EL 9 still requires perl-DB_File, as it did');
ok(!$el10{'perl-DB_File'},
    'control: EL 10 still asks for DB_File weakly, which is why this is not one branch');

ok($suse{'perl-core-DB_File'},
    'SUSE requires perl-core-DB_File, the name openSUSE and SLE package DB_File under');
ok(!$suse{'perl-DB_File'},
    'SUSE does not require perl-DB_File, which no openSUSE repository provides');

done_testing();
