use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

my $repo_root = File::Spec->catdir($FindBin::Bin, '..', '..');
my $genimage = File::Spec->catfile(
    $repo_root,
    'xCAT-server/share/xcat/netboot/ubuntu/genimage'
);

open(my $genimage_fh, '<', $genimage) or die "Unable to read $genimage: $!";
my $genimage_source = do { local $/; <$genimage_fh> };
close($genimage_fh);

unlike(
    $genimage_source,
    qr{http://(?:archive\.ubuntu\.com/ubuntu|ports\.ubuntu\.com/ubuntu-ports)/},
    'Ubuntu genimage does not silently fall back to public Ubuntu mirrors'
);

like(
    $genimage_source,
    qr{--verbose --arch \$uarch \$dist \$rootimg_dir file://\$srcdir},
    'Ubuntu genimage uses copied local media for debootstrap when no explicit mirror is configured'
);

like(
    $genimage_source,
    qr{The copied media does not contain every package required by debootstrap},
    'Ubuntu genimage explains incomplete copied media instead of implying network access is required'
);

like(
    $genimage_source,
    qr{\@pkgdir_internet.*?\$aptcmd2 = "--verbose --arch \$uarch \$dist \$rootimg_dir \$mirrorurl"}s,
    'Ubuntu genimage still honors an explicit mirror configured in osimage.pkgdir'
);

done_testing();
