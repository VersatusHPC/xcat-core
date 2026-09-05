#!/usr/bin/env perl
use strict;
use warnings;

use File::Basename qw(basename);
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path slurp_repo_file);

# A diskless rootimg runs every xdsh command in a login shell. sshd forwards the
# management node LANG, so the rootimg must carry that locale. On EL9 and later
# "@minimal-environment" resolves glibc-minimal-langpack, which provides C and
# POSIX only. EL8 still pulled the English langpack from the same group.
my $LOCALE_PKG = qr/^\s*(?:glibc-langpack-en|glibc-all-langpacks)\s*$/;

my $NETBOOT = 'xCAT-server/share/xcat/netboot';

# EL platform directories xCAT ships a netboot pkglist for.
my @PLATFORMS = qw(alma centos ol rh rocky);

# <profile>.<osname><generation>[.<arch>].pkglist -- an otherpkgs.pkglist adds
# packages from a separate repository and is not the base package set. The
# osname alternation is explicit because "compute.ppc64.pkglist" also reads as
# an osname followed by digits.
my $OSNAME = qr/alma|centos-stream|centos|ol|rhels|rocky|sl/i;

sub el_generation {
    my ($name) = @_;
    return if $name =~ /otherpkgs/;
    return unless $name =~ /^(?:compute|service)\.(?:$OSNAME)(\d+)(?:\.[^.]+)?\.pkglist$/;
    return $1;
}

my @pkglists;
foreach my $platform (@PLATFORMS) {
    my $dir = repo_path( File::Spec->catdir( $NETBOOT, $platform ) );
    next unless -d $dir;
    opendir( my $dh, $dir ) or die "Unable to read $dir: $!";
    foreach my $name ( sort readdir($dh) ) {
        my $gen = el_generation($name);
        next unless defined $gen && $gen >= 9;
        push @pkglists, File::Spec->catfile( $NETBOOT, $platform, $name );
    }
    closedir($dh);
}

if ( !@pkglists ) {
    plan skip_all => "no EL9-or-later netboot pkglist found under $NETBOOT";
}

plan tests => scalar(@pkglists);

foreach my $relative (@pkglists) {
    my @lines = split( /\n/, slurp_repo_file($relative) );
    my $found = grep { $_ =~ $LOCALE_PKG } @lines;
    ok( $found, "$relative lists a package providing the en_US.UTF-8 locale" );
}
