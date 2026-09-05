#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use File::Path qw(make_path);
use File::Slurper qw(read_text write_text);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

use XCAT::Test::File qw(repo_path);

# DHCP answers a riscv64 UEFI client with one boot file, and no xcat-dep package
# ships a riscv64 grub2 image. The Ubuntu media is the only source, so copycd must
# publish it. The Ubuntu media names the loader after the UEFI removable-media
# path, and ISO9660 gives the directory in either case, so drive the routine with
# both layouts rather than reading the table that describes them.

my $plugin = repo_path('xCAT-server/lib/xcat/plugins/debian.pm');
plan skip_all => "$plugin not found" unless -r $plugin;
$ENV{XCATROOT} ||= repo_path('xCAT-server');
eval { require $plugin; 1 } or plan skip_all => "could not load debian.pm: $@";
require xCAT::DHCP::BootPolicy;

my $tftpdir;
no warnings 'redefine';
local *xCAT::TableUtils::getTftpDir = sub { return $tftpdir; };
use warnings;

# The boot file the DHCP backends hand a riscv64 client. Publishing anything else
# is not a fix, so take the name from the backends rather than repeating it.
my $classes = xCAT::DHCP::BootPolicy->kea_client_classes();
my ($riscv_class) = grep { $_->{name} eq 'xcat-riscv64' } @{$classes};
ok( $riscv_class, 'the Kea backend answers riscv64 UEFI clients' );
my $offered = $riscv_class ? $riscv_class->{'boot-file-name'} : '';
ok( length($offered), 'the riscv64 client class carries a boot file' );

my $isc = join( '', @{ xCAT::DHCP::BootPolicy->isc_client_architecture_lines( next_server => '192.0.2.1' ) } );
like( $isc, qr/\Qfilename "$offered";\E/, 'the ISC backend hands out the same boot file' );

my $publish = xCAT_plugin::debian->can('_install_media_grub2_loader');
ok( $publish, 'debian.pm publishes the grub2 UEFI loader of the media' );
$publish ||= sub { return };

sub media {
    my ( $root, $name, $relative, $content ) = @_;
    my $path = File::Spec->catdir( $root, $name );
    make_path($path);
    if ($relative) {
        my $file = File::Spec->catfile( $path, split( m{/}, $relative ) );
        my ( undef, $dir ) = File::Spec->splitpath($file);
        make_path($dir);
        write_text( $file, $content );
    }
    return $path;
}

sub messages {
    my ($responses) = @_;
    return join( ' ', map { ref($_) eq 'HASH' && $_->{data} ? "@{[ $_->{data} ]}" : () } @{$responses} );
}

# A published loader that is missing must fail the assertion that wants it, not
# stop the run before the later layouts are driven.
sub content {
    my ($file) = @_;
    return -f $file ? read_text($file) : undef;
}

sub fresh_tftpdir {
    my ( $root, $name ) = @_;
    $tftpdir = File::Spec->catdir( $root, $name );
    make_path($tftpdir);
    return File::Spec->catfile( $tftpdir, split( m{/}, $offered ) );
}

my $root = tempdir( CLEANUP => 1 );
my $image = "riscv64 grub2 from the media\n";

# The Ubuntu riscv64 media: EFI/boot/bootriscv64.efi, lower case, named after the
# UEFI removable-media path.
my $loader = fresh_tftpdir( $root, 'tftpboot' );
my $ubuntu = media( $root, 'ubuntu24.04-riscv64', 'EFI/boot/bootriscv64.efi', $image );
my @responses;
is( $publish->( $ubuntu, 'riscv64', sub { push @responses, @_; } ),
    $loader, 'the Ubuntu riscv64 media publish the boot file DHCP offers' );
ok( -f $loader, 'the boot loader is written under the TFTP root' );
is( content($loader), $image, 'the published image is the one from the media' );
like( messages( \@responses ), qr/\QInstalled $loader from the media\E/, 'the published boot loader is reported' );

# A boot loader the management node already has is never replaced.
make_path( File::Spec->catdir( $tftpdir, 'boot', 'grub2' ) );
write_text( $loader, "installed by hand\n" );
@responses = ();
is( scalar $publish->( $ubuntu, 'riscv64', sub { push @responses, @_; } ),
    undef, 'an existing boot loader is kept' );
is( content($loader), "installed by hand\n", 'the existing boot loader is left untouched' );
is( messages( \@responses ), '', 'nothing is reported when there is nothing to do' );

# ISO9660 without Rock Ridge gives the directory in upper case.
$loader = fresh_tftpdir( $root, 'tftpboot-upper' );
my $upper = media( $root, 'ubuntu26.04-riscv64', 'EFI/BOOT/bootriscv64.efi', $image );
is( $publish->( $upper, 'riscv64', undef ), $loader, 'an upper case EFI directory is found as well' );
is( content($loader), $image, 'the upper case media publish the same image' );

# amd64 and ppc64el get their loaders from xnba-undi and grub2-xcat, so their
# media publish nothing even when they carry an EFI image.
$loader = fresh_tftpdir( $root, 'tftpboot-amd64' );
my $amd64 = media( $root, 'ubuntu24.04-x86_64', 'EFI/boot/bootx64.efi', "not for xCAT\n" );
is( scalar $publish->( $amd64, 'x86_64', undef ), undef, 'x86_64 media publish no boot loader' );
ok( !-e File::Spec->catfile( $tftpdir, 'boot', 'grub2', 'grub2.x86_64' ), 'no x86_64 boot loader is written' );
ok( !-d File::Spec->catdir( $tftpdir, 'boot' ), 'the grub2 directory is only made when there is an image for it' );

$loader = fresh_tftpdir( $root, 'tftpboot-ppc64el' );
my $ppc = media( $root, 'ubuntu24.04-ppc64el', 'EFI/boot/bootppc64.efi', "not for xCAT\n" );
is( scalar $publish->( $ppc, 'ppc64el', undef ), undef, 'ppc64el media publish no boot loader' );
ok( !-d File::Spec->catdir( $tftpdir, 'boot' ), 'no boot loader directory is made for ppc64el' );

# riscv64 media without the image are a no-op rather than an error.
$loader = fresh_tftpdir( $root, 'tftpboot-bare' );
my $bare = media( $root, 'ubuntu24.04-riscv64-bare' );
@responses = ();
is( scalar $publish->( $bare, 'riscv64', sub { push @responses, @_; } ),
    undef, 'media without a grub2 image publish nothing' );
is( messages( \@responses ), '', 'media without a grub2 image report nothing' );
ok( !-d File::Spec->catdir( $tftpdir, 'boot' ), 'media without a grub2 image create no directories' );

done_testing();
