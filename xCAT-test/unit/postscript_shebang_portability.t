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

# Every xCAT package that ships scripts for cluster nodes needs the same exclusion, not just the
# one that was found first. Three separate packages reached a SLE 12 node with an unsatisfiable
# /usr/bin/bash before this was swept properly.
{
    my @specs = qw(
        xCAT/xCAT.spec
        xCAT-test/xCAT-test.spec
        xCAT-client/xCAT-client.spec
        xCAT-confluent/xCAT-confluent.spec
        xCAT-rmc/xCAT-rmc.spec
        xCAT-vlan/xCAT-vlan.spec
    );
    for my $rel (@specs) {
        my $p = "$root/$rel";
        unless (-f $p) { fail("$rel is missing"); next }
        open my $s, '<', $p or die "cannot read $p: $!";
        my $t = do { local $/; <$s> };
        close $s;
        my ($excl) = $t =~ /^%global\s+__brp_mangle_shebangs_exclude_from\s+(\S+)/m;
        ok(defined $excl, "$rel keeps rpm from rewriting its shebangs to the builder layout")
            or next;
        # The pattern has to cover where THIS package ships scripts. xCAT-confluent installs to
        # /opt/confluent, not /opt/xcat, and was missed by a pattern that only named the latter.
        my %needs = ('xCAT-confluent/xCAT-confluent.spec' => qr{/opt/confluent/});
        if (my $re = $needs{$rel}) {
            like($excl, $re, "$rel covers the directory it actually ships scripts to");
        }
    }
}

done_testing();
