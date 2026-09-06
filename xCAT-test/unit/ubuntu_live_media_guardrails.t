#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(slurp_repo_file);

my $debian_pm = slurp_repo_file('xCAT-server/lib/xcat/plugins/debian.pm');
like( $debian_pm, qr/sub is_ubuntu_live_media/, 'copycds can detect Ubuntu live media' );
like( $debian_pm, qr/casper\/install-sources\.yaml/, 'copycds recognizes Subiquity install source metadata' );
like( $debian_pm, qr/casper\/\*\.squashfs/, 'copycds recognizes live squashfs media' );
like( $debian_pm, qr/not a complete Ubuntu apt package mirror/, 'copycds warns that Ubuntu live media is not a complete apt mirror' );
like( $debian_pm, qr/linuximage\.pkgdir.*linuximage\.otherpkgdir.*HTTP\/HTTPS Ubuntu apt repository/s, 'copycds warning points to explicit package source attributes' );

my $genimage = slurp_repo_file('xCAT-server/share/xcat/netboot/ubuntu/genimage');
unlike( $genimage, qr{http://archive\.ubuntu\.com/ubuntu/}, 'Ubuntu genimage does not implicitly use the public amd64 archive' );
unlike( $genimage, qr{http://ports\.ubuntu\.com/ubuntu-ports/}, 'Ubuntu genimage does not implicitly use the public ports archive' );
like( $genimage, qr{\$aptcmd2 = "--verbose --arch \$uarch \$dist \$rootimg_dir file://\$srcdir"}, 'Ubuntu genimage uses copied local media when no explicit mirror is configured' );
like( $genimage, qr/copied Ubuntu media.*complete local Ubuntu apt mirror.*HTTP\/HTTPS Ubuntu apt repository/s, 'Ubuntu genimage gives an actionable package source error' );
like( $genimage, qr{\@pkgdir_internet.*?\$aptcmd2 = "--verbose --arch \$uarch \$dist \$rootimg_dir \$mirrorurl"}s, 'Ubuntu genimage still honors an explicit mirror configured in pkgdir' );

my $copycds_doc = slurp_repo_file('docs/source/guides/admin-guides/references/man8/copycds.8.rst');
like( $copycds_doc, qr/Ubuntu live-server media.*not a complete Ubuntu apt package mirror/s, 'copycds documentation explains Ubuntu live media package limits' );

my $linuximage_doc = slurp_repo_file('docs/source/guides/admin-guides/references/man5/linuximage.5.rst');
like( $linuximage_doc, qr/Ubuntu live-server media copied by copycds is not a complete apt package mirror.*HTTP\/HTTPS Ubuntu apt repository/, 'linuximage documentation explains Ubuntu live media package limits' );

my $osimage_doc = slurp_repo_file('docs/source/guides/admin-guides/references/man7/osimage.7.rst');
like( $osimage_doc, qr/Ubuntu live-server media copied by copycds is not a complete apt package mirror.*HTTP\/HTTPS Ubuntu apt repository/, 'osimage documentation explains Ubuntu live media package limits' );

# The debian.pm checks above match its text, so a detector that always answers
# no leaves them green. Extract the two routines and run them.
{
    my %block;
    foreach my $name (qw(is_ubuntu_live_media warn_ubuntu_live_media_pkg_source)) {
        ( $block{$name} ) = $debian_pm =~ /^(sub \Q$name\E\n\{\n.*?^\}\n)/ms;
        BAIL_OUT("debian.pm no longer defines sub $name") unless $block{$name};
    }

    my $code = join( "\n",
        'package XCATTest::UbuntuMedia;',
        'use strict; use warnings;',
        $block{is_ubuntu_live_media},
        $block{warn_ubuntu_live_media_pkg_source},
        '1;' );
    eval $code;    ## no critic
    BAIL_OUT("unable to compile the extracted debian.pm routines: $@") if $@;

    my $root = tempdir( CLEANUP => 1 );
    make_path("$root/plain");
    make_path("$root/empty/casper");
    make_path("$root/subiquity/casper");
    touch("$root/subiquity/casper/install-sources.yaml");
    make_path("$root/squashfs/casper");
    touch("$root/squashfs/casper/ubuntu-server-minimal.squashfs");

    is( XCATTest::UbuntuMedia::is_ubuntu_live_media("$root/plain"), 0,
        'media without a casper directory is not live media' );
    is( XCATTest::UbuntuMedia::is_ubuntu_live_media("$root/empty"), 0,
        'an empty casper directory is not live media' );
    is( XCATTest::UbuntuMedia::is_ubuntu_live_media("$root/subiquity"), 1,
        'Subiquity install-sources.yaml identifies live media' );
    is( XCATTest::UbuntuMedia::is_ubuntu_live_media("$root/squashfs"), 1,
        'a casper squashfs image identifies live media' );
    is( XCATTest::UbuntuMedia::is_ubuntu_live_media(undef), 0,
        'an undefined media path is not live media' );

    my @warnings;
    my $callback = sub { push @warnings, @{ $_[0]->{warning} || [] } };

    XCATTest::UbuntuMedia::warn_ubuntu_live_media_pkg_source( $callback, "$root/plain" );
    is( scalar(@warnings), 0, 'copycds does not warn about a full apt mirror' );

    XCATTest::UbuntuMedia::warn_ubuntu_live_media_pkg_source( $callback, "$root/subiquity" );
    is( scalar(@warnings), 1, 'copycds warns once about Ubuntu live media' );
    my $warning = $warnings[0] || '';
    like( $warning, qr/not a complete Ubuntu apt package mirror/,
        'the warning says the media is not a complete apt mirror' );
    like( $warning, qr/linuximage\.pkgdir/,
        'the warning names linuximage.pkgdir' );
    like( $warning, qr/linuximage\.otherpkgdir/,
        'the warning names linuximage.otherpkgdir' );
    like( $warning, qr{HTTP/HTTPS Ubuntu apt repository},
        'the warning names an explicit apt repository as an alternative' );
}

done_testing();

sub touch {
    my ($path) = @_;
    open( my $fh, '>', $path ) or die "Unable to create $path: $!";
    close($fh);
    return;
}
