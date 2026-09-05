#!/usr/bin/env perl
use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage)

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Spec;
use Test::More;

use XCAT::Test::File qw(repo_path);

# genimage copies usr/bin/dig into the netboot initrd and dies when the rootimg does not
# carry it. dig comes from a package the profile pkglist names, so the pkglist that wins
# the lookup for a cell decides whether genimage can finish. Ask the resolver genimage
# calls, then read the answer with the parser genimage uses, rather than listing the
# directory: a cell with no arch-specific file silently falls back to compute.pkglist.

my $share_relative   = File::Spec->catdir( 'xCAT-server', 'share', 'xcat' );
my $netboot_relative = File::Spec->catdir( $share_relative, 'netboot', 'ubuntu' );
my $netboot          = repo_path($netboot_relative);

my $imgutils = repo_path(
    File::Spec->catfile( $share_relative, 'netboot', 'imgutils', 'imgutils.pm' )
);
plan skip_all => "$imgutils not found" unless -r $imgutils;
require $imgutils;

# dig lives in dnsutils up to focal and in bind9-dnsutils from jammy on.
my %DIG_PACKAGE = (
    'ubuntu20.04' => 'dnsutils',
    'ubuntu22.04' => 'bind9-dnsutils',
    'ubuntu24.04' => 'bind9-dnsutils',
    'ubuntu26.04' => 'bind9-dnsutils',
);

# Return the package names the pkglist that wins the lookup for this cell installs.
sub packages_for {
    my ( $osver, $arch ) = @_;

    my $pkglist = imgutils::get_profile_def_filename( $osver, 'compute', $arch, $netboot, 'pkglist' );
    return ( undef, [] ) unless $pkglist;

    my %hash = imgutils::get_package_names($pkglist);
    my @names;
    foreach my $pass ( keys %hash ) {
        foreach my $dir ( keys %{ $hash{$pass} } ) {
            next if $dir eq 'PRE_REMOVE' or $dir eq 'POST_REMOVE';
            push @names, @{ $hash{$pass}{$dir} };
        }
    }
    return ( $pkglist, \@names );
}

my $generic = File::Spec->catfile( $netboot, 'compute.pkglist' );
ok( -r $generic, 'the arch-less compute.pkglist exists, so a cell with no file of its own falls back to it' );

# Every Ubuntu cell the ppc64el pipelines provision, plus the x86_64 cells that already
# pass. The x86_64 rows are the control: they hold before and after the fix.
my @cells;
foreach my $osver ( sort keys %DIG_PACKAGE ) {
    foreach my $arch (qw(x86_64 ppc64el ppc64le)) {
        push @cells, [ $osver, $arch ];
    }
}

foreach my $cell (@cells) {
    my ( $osver, $arch ) = @{$cell};
    my ( $pkglist, $packages ) = packages_for( $osver, $arch );

    ok( defined $pkglist && length $pkglist, "$osver $arch resolves a compute pkglist" )
      or next;
    isnt( $pkglist, $generic,
        "$osver $arch resolves a pkglist of its own, not the arch-less fallback" );

    my $expected = $DIG_PACKAGE{$osver};
    ok( ( grep { $_ eq $expected } @{$packages} ),
        "$osver $arch installs $expected, so the rootimg carries usr/bin/dig" );
}

# Non-vacuity: the resolver really does return the arch-less list when a cell has no file
# of its own, and that list really has no dig package. Both hold before and after the fix.
my ( $missing_pkglist, $missing_packages ) = packages_for( 'ubuntu20.04', 's390x' );
is( $missing_pkglist, $generic,
    'a cell with no pkglist of its own falls back to the arch-less compute.pkglist' );
ok( !( grep { /dnsutils$/ } @{$missing_packages} ),
    'the arch-less compute.pkglist installs no dig package' );

done_testing();
