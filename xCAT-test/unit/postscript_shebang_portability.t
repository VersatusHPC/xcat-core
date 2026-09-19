#!/usr/bin/perl
# The postscripts in /install/postscripts run on COMPUTE NODES, whose distribution is chosen by
# the cluster, not by the build host. rpm on a /usr-merged builder rewrites "#!/bin/bash" to
# "#!/usr/bin/bash" and then adds "Requires: /usr/bin/bash" to the xCAT package. No pre-merge
# distribution can satisfy that: on the SLE 12 family bash is /bin/bash, and the install fails
# with "nothing provides /usr/bin/bash needed by xCAT". One flat build serves every family, so
# the builder's layout must not reach the packages.
#
# The spec IS the artifact here -- the exclusion is a packaging directive, and there is nothing
# to execute -- so this reads it, and reads the shebangs it protects.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $root = dirname(__FILE__) . '/../..';
my $spec = "$root/xCAT/xCAT.spec";

open my $fh, '<', $spec or die "cannot read $spec: $!\n";
my $text = do { local $/; <$fh> };
close $fh;

like($text, qr/^%global\s+__brp_mangle_shebangs_exclude_from\s+\S*\/install\/postscripts\//m,
    'the spec keeps rpm from rewriting the postscript shebangs to the builder layout');

# The shebangs the exclusion protects must themselves be the portable form: /bin/bash resolves on
# a merged system through the /bin symlink, and /usr/bin/bash resolves nowhere before the merge.
my $dir = "$root/xCAT/postscripts";
my @bad;
if (opendir my $dh, $dir) {
    for my $f (sort readdir $dh) {
        my $p = "$dir/$f";
        next unless -f $p;
        open my $s, '<', $p or next;
        my $first = <$s> // '';
        close $s;
        push @bad, $f if $first =~ m{^#!\s*/usr/bin/(bash|sh)\b};
    }
    closedir $dh;
} else {
    die "cannot read $dir: $!\n";
}
is(scalar(@bad), 0, 'no postscript ships a /usr/bin shell shebang')
    or diag("these would be unsatisfiable before the /usr merge: @bad");

done_testing();
