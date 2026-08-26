#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Test::More;
use xCAT::Genesis;

my $tmpdir = tempdir(CLEANUP => 1);
make_path(
    "$tmpdir/share/xcat/netboot/genesis/ppc64/fs",
    "$tmpdir/share/xcat/netboot/genesis/x86_64/fs",
    "$tmpdir/share/xcat/netboot/genesis-openembedded/aarch64",
    "$tmpdir/share/xcat/netboot/genesis-openembedded/ppc64le",
    "$tmpdir/share/xcat/netboot/genesis-openembedded/x86_64",
);
my $symlink_target = "$tmpdir/openembedded-riscv64";
make_path($symlink_target);
symlink(
    $symlink_target,
    "$tmpdir/share/xcat/netboot/genesis-openembedded/riscv64",
) or die "create OpenEmbedded directory symlink: $!";

is_deeply(
    [ xCAT::Genesis::installed_architectures($tmpdir) ],
    [ qw(aarch64 ppc64 ppc64le x86_64) ],
    'xcatconfig ignores linked OpenEmbedded images and finds legacy images',
);

is_deeply(
    [ xCAT::Genesis::architectures_to_build($tmpdir, 0) ],
    [ qw(aarch64 ppc64le x86_64) ],
    'an ordinary xCAT update rebuilds only installed OpenEmbedded images',
);
is_deeply(
    [ xCAT::Genesis::architectures_to_build($tmpdir, 1) ],
    [ qw(aarch64 ppc64 ppc64le x86_64) ],
    'a legacy package trigger rebuilds every installed Genesis image',
);

make_path("$tmpdir/share/xcat/netboot/genesis-openembedded/unsupported");
is_deeply(
    [ xCAT::Genesis::installed_architectures($tmpdir) ],
    [ qw(aarch64 ppc64 ppc64le x86_64) ],
    'unknown directories are not passed to mknb',
);

remove_tree("$tmpdir/share/xcat/netboot/genesis/ppc64");
my $legacy_target = "$tmpdir/legacy-ppc64";
make_path("$legacy_target/fs");
symlink($legacy_target, "$tmpdir/share/xcat/netboot/genesis/ppc64")
  or die "create legacy directory symlink: $!";
is_deeply(
    [ xCAT::Genesis::installed_architectures($tmpdir) ],
    [ qw(aarch64 ppc64 ppc64le x86_64) ],
    'legacy Genesis directory symlinks remain supported',
);

done_testing();
