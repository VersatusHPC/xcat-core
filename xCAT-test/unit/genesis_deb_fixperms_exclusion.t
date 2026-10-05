#!/usr/bin/env perl
# The genesis payload under /opt/xcat/share/xcat/netboot/genesis is a root filesystem that a
# compute node boots. dh_fixperms normalises library permissions for a library directory, which
# is the wrong rule here: it strips the execute bit from ld-linux-x86-64.so.2, the kernel opens
# the ELF interpreter with MAY_EXEC, and /init cannot start. debian/rules is the only place that
# can hold the exclusion, so this reads it.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path slurp_repo_file);

my $relative = 'xCAT-genesis-base/debian/rules';
plan skip_all => "$relative not found" unless -f repo_path($relative);
plan tests => 3;

my $payload = '/opt/xcat/share/xcat/netboot/genesis';
my @lines   = split /\n/, slurp_repo_file($relative);

# The recipe body of override_dh_fixperms: every tab-indented line after the target, up to the
# next line that starts in column one.
my @recipe;
my $in_target = 0;
for my $line (@lines) {
    if ($line =~ /^override_dh_fixperms\s*:/) { $in_target = 1; next; }
    next unless $in_target;
    last if $line =~ /^\S/;
    push @recipe, $line;
}

ok($in_target, 'debian/rules overrides dh_fixperms');

my @calls = grep { /\bdh_fixperms\b/ } @recipe;
is(scalar(@calls), 1, 'the override calls dh_fixperms once')
    or diag(join "\n", @recipe);

# Accept either spelling dh_fixperms takes, with or without a separating space or equals sign,
# so reformatting the recipe cannot fail this.
my @excluding = grep { /(?:-X|--exclude)[=\s]?\Q$payload\E/ } @calls;
is(scalar(@excluding), 1, "dh_fixperms excludes $payload")
    or diag(join "\n", @calls);
