#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

# Regression: the helpers were covered, the CALL SITE was not.
#
# subiquity_boot_params and subiquity_nfsroot_server each have tests, but putting mkinstall's
# pre-fix branch back -- getipaddr plus the inline command line -- left the entire unit suite
# green. Argument order, the error branch, and the `next` that skips the node were all
# unobservable, which is exactly where the bug this PR fixes lived.
#
# mkinstall needs a management node and a database, so the call site is lifted out and eval'd
# into the plugin's own package with report_node_error stubbed, and driven inside a real loop so
# the `next` it performs is the `next` under test. install_kcmdline itself is the real one.

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

my $repo_root = File::Spec->rel2abs(
    File::Spec->catdir( $FindBin::Bin, '..', '..' )
);
my $plugin = File::Spec->catfile(
    $repo_root, 'xCAT-server', 'lib', 'xcat', 'plugins', 'debian.pm'
);
plan skip_all => "debian.pm not found" unless -f $plugin;
eval { require $plugin; 1 } or BAIL_OUT("could not load debian.pm: $@");

my $src = do { local $/; open my $fh, '<', $plugin or die $!; <$fh> };

# Take the call site by what it contains rather than by where it sits, so adding another call
# above it does not silently swap which one is under test. BAIL_OUT rather than skip, so a
# rename fails loudly instead of covering nothing.
my ($site) = $src =~ /\n([ ]+my \(\$kcmdline, \$kcmdline_error\) = install_kcmdline\(.*?\n[ ]+\}\n)/s;
BAIL_OUT('could not find the mkinstall call site that builds the kernel command line')
  unless defined $site;
BAIL_OUT('the extracted call site does not skip the node on error')
  unless $site =~ /\bnext\b/;
BAIL_OUT('the extracted call site is implausibly large -- the match ran past its block')
  if ($site =~ tr/\n//) > 20;

my @reported;

# The call site passes no resolver, exactly as production does, so the fallback to
# xCAT::NetworkUtils->getipaddr is the seam to stand in at. That keeps the call path under test
# identical to the real one -- nothing is injected into it.
{
    no warnings 'redefine', 'once';
    *xCAT::NetworkUtils::getipaddr = sub {
        my (undef, $name) = @_;
        return $name if defined($name) && $name =~ /^\d+\.\d+\.\d+\.\d+$/;
        return '192.0.2.10' if defined($name) && $name eq 'mn.cluster';
        return undef;
    };
    *xCAT::MsgUtils::report_node_error = sub {
        shift; my ($cb, $node, $msg) = @_; push @reported, [ $node, $msg ];
    };
}

my $driver = <<"CODE";
sub drive {
    my (\$os, \$tmplfile, \$instserver, \$pkgdir, \$httpport, \$node, \$ent, \$mac) = \@_;
    my \$callback;
    my \$result;
    NODE: foreach my \$n (\$node) {
$site
        \$result = \$kcmdline;
    }
    return \$result;
}
CODE

# `next` inside the call site belongs to the loop the driver wraps around it.
$driver =~ s/\bnext;/next NODE;/g;

{
    package xCAT_plugin::debian;
    eval "$driver; 1" or main::BAIL_OUT("could not eval the mkinstall call site: $@");
}

my $SUBIQUITY = '/opt/xcat/share/xcat/install/ubuntu/compute.subiquity.tmpl';
my $PRESEED   = '/opt/xcat/share/xcat/install/ubuntu/compute.tmpl';
my $PKGDIR    = '/install/ubuntu24.04/x86_64';

# A resolvable install server on a subiquity image: the call site must produce a live command
# line built from the arguments it was given, in the order it gave them.
{
    @reported = ();
    my $out = xCAT_plugin::debian::drive( 'ubuntu24.04', $SUBIQUITY,
        'mn.cluster', $PKGDIR, '80', 'cn1', {}, undef );
    ok( defined $out, 'a resolvable install server yields a command line' );
    like( $out, qr/boot=casper/, 'the call site puts boot=casper on the command line' );
    like( $out, qr/\btoram\b/,   'and toram' );
    like( $out, qr{nfsroot=192\.0\.2\.10:\Q$PKGDIR\E},
        'and nfsroot as a literal address, in the media path' );
    like( $out, qr{ds=nocloud-net;s=http://mn\.cluster:80/install/autoinst/cn1/},
        'with the seed URL naming the node, so httpport and node are not transposed' );
    is( scalar @reported, 0, 'and nothing is reported as an error' );
}

# The same call site on a preseed image: the choice is made inside install_kcmdline, so the
# call site must not carry a second copy of it.
{
    @reported = ();
    my $out = xCAT_plugin::debian::drive( 'ubuntu24.04', $PRESEED,
        'mn.cluster', $PKGDIR, '80', 'cn1', { installnic => 'ens3' }, undef );
    like( $out, qr{url=http://mn\.cluster:80/install/autoinst/cn1},
        'a preseed image reaches the debian-installer command line through the same call' );
    like( $out, qr{netcfg/choose_interface=ens3},
        'and the noderes row the call site passes reaches gen_net_boot_params' );
    is( scalar @reported, 0, 'with nothing reported as an error' );
}

# The placeholder: this is the case the fix restored, driven through the call site rather than
# through the helper.
{
    @reported = ();
    my $out = xCAT_plugin::debian::drive( 'ubuntu24.04', $SUBIQUITY,
        '!myipfn!', $PKGDIR, '80', 'cn1', {}, undef );
    ok( defined $out, 'a node with no xcatmaster is not skipped' );
    like( $out, qr/nfsroot=!myipfn!:/,
        'and the placeholder reaches the boot config for pxe.pm/grub2.pm to substitute' );
    is( scalar @reported, 0, 'and no error is reported for it' );
}

# An install server that does not resolve must skip the node, not emit a command line naming it.
{
    @reported = ();
    my $out = xCAT_plugin::debian::drive( 'ubuntu24.04', $SUBIQUITY,
        'nosuchhost', $PKGDIR, '80', 'cn1', {}, undef );
    ok( !defined $out, 'an unresolvable install server skips the node' );
    is( scalar @reported, 1, 'and reports exactly one error' );
    like( $reported[0][1], qr/nosuchhost/, 'naming the server that failed' );
    is( $reported[0][0], 'cn1', 'and the node it happened on' );
}

done_testing();
