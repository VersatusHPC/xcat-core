#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

# archive.ubuntu.com carries amd64 and i386 only. ppc64el, arm64, riscv64 and s390x are on
# ports.ubuntu.com under /ubuntu-ports. A request to the wrong host returns 404 for the whole
# Packages index, so the netboot rootimg build stops:
#
#     E: Couldn't download http://archive.ubuntu.com/ubuntu/dists/noble/main/binary-ppc64el/Packages
#     Error: Can not create bootstraps for rootimage.
#
# Both places that pick a default Ubuntu mirror must follow the architecture: the debootstrap
# mirror in the netboot genimage, and the Subiquity apt mirror in Template.pm. A configured
# site.ubuntu_apt_mirror still wins over both.

require xCAT::Utils;
require xCAT::Template;

my $ARCHIVE = 'http://archive.ubuntu.com/ubuntu';
my $PORTS   = 'http://ports.ubuntu.com/ubuntu-ports';

# --- the netboot genimage: the mirror debootstrap is given -----------------------------
#
# The selection is lifted out of genimage and evaluated here, so the test drives the script
# rather than a copy of it.

my $repo_root = File::Spec->rel2abs(
    File::Spec->catdir( $FindBin::Bin, '..', '..' )
);
my $genimage_path = File::Spec->catfile(
    $repo_root, 'xCAT-server', 'share', 'xcat', 'netboot', 'ubuntu', 'genimage'
);
BAIL_OUT("genimage not found at $genimage_path") unless -f $genimage_path;

my $src = do { local $/; open my $fh, '<', $genimage_path or die $!; <$fh> };

my ($select) = $src =~ /^(\s*my \s+ \$mirror \s* = .*?;)\s*$/msx;
BAIL_OUT('the mirror selection in genimage no longer matches; the extraction must be updated')
  unless defined $select;

sub genimage_mirror {
    my ( $arch, @aptmirror ) = @_;
    ## no critic
    my $chosen = eval "$select \$mirror;";
    ## use critic
    die "failed to evaluate the genimage mirror selection: $@" if $@;
    return $chosen;
}

is( genimage_mirror('ppc64el'), $PORTS,
    'genimage sends debootstrap to ports for a ppc64el image' );
is( genimage_mirror('ppc64le'), $PORTS,
    'genimage sends debootstrap to ports for the kernel spelling of the same architecture' );
is( genimage_mirror('arm64'), $PORTS,
    'genimage sends debootstrap to ports for an arm64 image' );
is( genimage_mirror('riscv64'), $PORTS,
    'genimage sends debootstrap to ports for a riscv64 image' );
is( genimage_mirror('x86_64'), $ARCHIVE,
    'genimage still sends debootstrap to the archive for x86_64' );
is( genimage_mirror('x86'), $ARCHIVE,
    'genimage still sends debootstrap to the archive for 32-bit x86' );
is( genimage_mirror( 'ppc64el', 'http://br.archive.ubuntu.com/ubuntu' ),
    'http://br.archive.ubuntu.com/ubuntu',
    'a configured site.ubuntu_apt_mirror still wins on ppc64el' );
is( genimage_mirror( 'x86_64', 'http://br.archive.ubuntu.com/ubuntu' ),
    'http://br.archive.ubuntu.com/ubuntu',
    'a configured site.ubuntu_apt_mirror still wins on x86_64' );

# --- the Subiquity diskful install: the mirror curtin is given -------------------------
#
# copycd puts the media under /install/<osvers>/<arch>, which is what Template.pm receives.
# There is no xCAT database here, so xCAT::Table->new returns nothing and Template.pm takes
# its own no-site-table path -- which is the default this test is about.

no warnings 'redefine';
local *xCAT::Table::new = sub { return; };
use warnings 'redefine';

is( xCAT::Template::ubuntu_subiquity_apt_mirror('/install/ubuntu24.04.4/ppc64el'),
    $PORTS, 'a Subiquity install of a ppc64el image uses ports' );
is( xCAT::Template::ubuntu_subiquity_apt_mirror('/install/ubuntu24.04.4/x86_64'),
    $ARCHIVE, 'a Subiquity install of an x86_64 image still uses the archive' );
is( xCAT::Template::ubuntu_subiquity_apt_mirror('/install/ubuntu22.04.5/ppc64el'),
    $PORTS, 'the release does not change which host serves ppc64el' );

done_testing();
