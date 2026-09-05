#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

# archive.ubuntu.com carries amd64 and i386 only. ppc64el, riscv64, arm64 and s390x live on
# ports.ubuntu.com, and neither host serves the other's packages:
#
#   archive.ubuntu.com/ubuntu/dists/jammy/main/binary-ppc64el/Packages.gz -> 404
#   ports.ubuntu.com/ubuntu-ports/dists/jammy/main/binary-ppc64el/Packages.gz -> 200
#
# xCAT picked one archive for every architecture, so the default reached debootstrap on a
# ppc64el netboot image as
#
#   debootstrap --arch ppc64el jammy <rootimg> http://archive.ubuntu.com/ubuntu
#   E: Couldn't download .../binary-ppc64el/Packages
#
# and reached Subiquity as the primary apt mirror of a ppc64el diskful install.
#
# Both defaults are driven here: the genimage statement is extracted and evaluated, and
# Template.pm is loaded and called.

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use xCAT::Utils;

my $ARCHIVE = 'http://archive.ubuntu.com/ubuntu';
my $PORTS   = 'http://ports.ubuntu.com/ubuntu-ports';

my $repo_root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..'));

# --- genimage: the debootstrap mirror -------------------------------------------------
my $genimage = File::Spec->catfile(
    $repo_root, 'xCAT-server', 'share', 'xcat', 'netboot', 'ubuntu', 'genimage');
BAIL_OUT("genimage not found at $genimage") unless -f $genimage;

my $src = do { local $/; open my $fh, '<', $genimage or die $!; <$fh> };

# Take the whole statement, not the first line: the default has been written across two lines
# since it was introduced, and half of it looks like a different value.
my ($assignment) = $src =~ /^\s*(my \$mirror\s*=.*?;)\s*$/ms;
BAIL_OUT('could not extract the debootstrap mirror assignment from genimage')
  unless defined $assignment;

sub genimage_mirror {
    my ($uarch, @aptmirror) = @_;
    my $mirror;
    my $code = $assignment;
    $code =~ s/^\s*my\s+//;
    ## no critic (BuiltinFunctions::ProhibitStringyEval)
    eval "$code 1" or die "failed to evaluate the genimage mirror default: $@";
    ## use critic
    return $mirror;
}

is(genimage_mirror('amd64'), $ARCHIVE,
    'genimage bootstraps amd64 from the primary archive');
is(genimage_mirror('ppc64el'), $PORTS,
    'genimage bootstraps ppc64el from ports, the only archive that carries it');
is(genimage_mirror('riscv64'), $PORTS,
    'genimage bootstraps riscv64 from ports');
is(genimage_mirror('arm64'), $PORTS,
    'genimage bootstraps arm64 from ports');
is(genimage_mirror('i386'), $ARCHIVE,
    'i386 stays on the primary archive');
is(genimage_mirror('ppc64el', 'http://mirror.example.net/ubuntu'),
    'http://mirror.example.net/ubuntu',
    'site.ubuntu_apt_mirror still overrides the default');

# --- Template.pm: the Subiquity primary apt mirror -------------------------------------
require xCAT::Template;

sub subiquity_mirror {
    my ($arch) = @_;
    no warnings 'redefine', 'once';

    # xCAT::Table->new dies with no cluster configuration. Returning undef takes the
    # no-site-table path, which is what an unset site.ubuntu_apt_mirror means here.
    local *xCAT::Table::new = sub { return undef };
    local *xCAT::Template::ubuntu_subiquity_arch = sub { return $arch };
    return xCAT::Template::ubuntu_subiquity_apt_mirror();
}

is(subiquity_mirror('x86_64'), $ARCHIVE,
    'a Subiquity install on x86_64 uses the primary archive');
is(subiquity_mirror('ppc64el'), $PORTS,
    'a Subiquity install on ppc64el uses ports');
is(subiquity_mirror('riscv64'), $PORTS,
    'a Subiquity install on riscv64 uses ports');
is(subiquity_mirror(''), $ARCHIVE,
    'an unknown architecture keeps the archive that xCAT used before');

done_testing();
