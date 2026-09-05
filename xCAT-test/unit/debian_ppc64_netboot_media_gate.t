#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# mkinstall gates a POWER node on a debian-installer netboot tree: install/netboot/initrd.gz,
# or install/netboot/ubuntu-installer/<darch>/initrd.gz. The Ubuntu live-server ISO that
# copycds imports carries neither. Its install/ directory is empty and its boot files sit
# under casper/, so nodeset reports
#
#   The network boot initrd.gz is not found in /install/ubuntu22.04.5/ppc64el/install/netboot.
#
# and skips the node, although the media can boot.
#
# The gate is lifted out of mkinstall and driven inside a real loop, so the `next` it performs
# is the `next` under test. mkinstall itself needs a management node and a database.

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

my $repo_root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..'));
my $plugin = File::Spec->catfile(
    $repo_root, 'xCAT-server', 'lib', 'xcat', 'plugins', 'debian.pm');
BAIL_OUT("debian.pm not found at $plugin") unless -r $plugin;
eval { require $plugin; 1 } or BAIL_OUT("could not load debian.pm: $@");

my $src = do { local $/; open my $fh, '<', $plugin or die $!; <$fh> };

# Selected by what the block reports, not by where it sits, so another POWER test above it
# does not silently swap which block is under test.
my @candidates = $src =~ /\n([ ]+if \(\$arch =~ [^\n]*ppc64.*?\n[ ]+\})\n/gs;
my @wanted = grep { /network boot initrd\.gz is not found/ } @candidates;
BAIL_OUT('could not find the POWER netboot media gate in mkinstall') unless @wanted == 1;
my $gate = $wanted[0];
BAIL_OUT('the extracted gate does not skip the node') unless $gate =~ /\bnext\b/;
BAIL_OUT('the extracted gate is implausibly large -- the match ran past its block')
  if ($gate =~ tr/\n//) > 12;

# debian.pm loads xCAT::MsgUtils, so the stub is installed after it, or the real routine wins
# and dies on the callback the gate does not have here.
our @reported;
{
    no warnings 'redefine', 'once';
    *xCAT::MsgUtils::report_node_error =
      sub { shift; my ($cb, $node, $msg) = @_; push @main::reported, [ $node, $msg ]; };
}

# Evaluated inside xCAT_plugin::debian so the gate reaches the helpers of its own package.
my $driver = <<"CODE";
package xCAT_plugin::debian;
sub main::drive_gate {
    my (\$arch, \$darch, \$pkgdir) = \@_;
    my \$callback;
    my \$reached = 0;
    NODE: foreach my \$node ('cn1') {
$gate
        \$reached = 1;
    }
    return \$reached;
}
1;
CODE
$driver =~ s/\bnext;/next NODE;/g;
## no critic (BuiltinFunctions::ProhibitStringyEval)
eval $driver or BAIL_OUT("could not evaluate the POWER netboot media gate: $@");
## use critic

sub media {
    my (@relative) = @_;
    my $root = tempdir(CLEANUP => 1);
    foreach my $path (@relative) {
        my $full = "$root/$path";
        ($full =~ m{^(.*)/[^/]+$}) and make_path($1);
        open(my $fh, '>', $full) or die "cannot create $full: $!";
        close($fh);
    }
    return $root;
}

sub gate {
    my ($arch, $darch, $root) = @_;
    @reported = ();
    my $reached = main::drive_gate($arch, $darch, $root);
    return ($reached, [@reported]);
}

# The 22.04.5 and 24.04.4 ppc64el live-server layout: an empty install/, boot files under casper.
my $live = media(
    'casper/vmlinux', 'casper/initrd',
    'casper/hwe-vmlinux', 'casper/hwe-initrd',
    'casper/install-sources.yaml',
    'casper/ubuntu-server-minimal.squashfs');
make_path("$live/install");

my ($reached, $errors) = gate('ppc64le', 'ppc64el', $live);
ok($reached, 'a POWER live-server image is not skipped by the netboot media gate');
is(scalar @$errors, 0, 'and no error is reported for it')
  or diag("reported: $errors->[0][1]");

# The 20.04.4 ppc64el live-server layout compresses its initrd.
my $live_gz = media('casper/vmlinux', 'casper/initrd.gz', 'casper/install-sources.yaml',
    'casper/filesystem.squashfs');
($reached, $errors) = gate('ppc64le', 'ppc64el', $live_gz);
ok($reached, 'the 20.04 POWER live-server image is not skipped either');
is(scalar @$errors, 0, 'and no error is reported for it');

# A debian-installer netboot tree still passes.
($reached, $errors) = gate('ppc64le', 'ppc64el',
    media('install/netboot/ubuntu-installer/ppc64el/vmlinux',
          'install/netboot/ubuntu-installer/ppc64el/initrd.gz'));
ok($reached, 'a POWER netboot tree still passes the gate');
is(scalar @$errors, 0, 'and reports nothing');

# Media with no installer at all is still refused, and says so.
($reached, $errors) = gate('ppc64le', 'ppc64el', media('README'));
ok(!$reached, 'media carrying no installer skips the node');
is(scalar @$errors, 1, 'and reports exactly one error');
like($errors->[0][1], qr/initrd/, 'naming the file it could not find');
is($errors->[0][0], 'cn1', 'and the node it happened on');

# x86 never enters this gate.
($reached, $errors) = gate('x86_64', 'amd64', media('README'));
ok($reached, 'the gate does not apply to x86_64');

done_testing();
