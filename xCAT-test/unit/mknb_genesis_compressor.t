#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(mkpath);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# genesis_lzma_command says which compressor to run. pack_genesis_fs runs it, falls back to
# gzip when it fails, and renames the finished image into place. The dispatch and the fallback
# were inside process_request, which needs a management node, so no test ran either: the caller
# could ignore the command it was given and gzip everything, and this file stayed green.

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
my $plugin = File::Spec->catfile( $FindBin::Bin, '..', '..',
    'xCAT-server', 'lib', 'xcat', 'plugins', 'mknb.pm' );
plan skip_all => 'mknb.pm not found' unless -r $plugin;
eval { require $plugin; 1 } or BAIL_OUT("could not load mknb.pm: $@");

sub command { return xCAT_plugin::mknb::genesis_lzma_command(@_); }

# --- which compressor -------------------------------------------------------
# Debian and Ubuntu ship both names, and lzma is the one the plugin has always
# used, so nothing changes on those systems.
is( command( 1, 1 ), 'lzma -C crc32 -9', 'lzma is used when it is there' );

# Red Hat ships xz alone.
is( command( 0, 1 ), 'xz --format=lzma -C crc32 -9',
    'xz stands in for lzma when only xz is there' );

# The gzip path below the caller handles a system with neither.
is( command( 0, 0 ), undef, 'nothing is returned when neither program is there' );

# The container has to stay the one the file name promises. "xz" on its own
# writes the xz container, which the file name does not describe and which a
# reader of a .lzma file cannot open.
my ($xz_form) = command( 0, 1 ) =~ /--format=(\S+)/;
is( $xz_form, 'lzma', 'xz is asked for the lzma container, not its own' );

# --- what the caller does with it -------------------------------------------
# genesis_lzma_command reads /usr/bin on the host running the suite, so stand in for it and
# drive pack_genesis_fs over a scratch tftp tree. The runner records the pipeline and writes
# the file the real compressor would have written, so the rename is the real one.
my $available;
my @ran;
my $rc = 0;
{
    no warnings 'redefine', 'once';
    *xCAT_plugin::mknb::genesis_lzma_command = sub { return $available; };
}

my $root = tempdir( CLEANUP => 1 );
my $tftpdir = "$root/tftpboot";
my $tempdir = "$root/staged";
mkpath("$tftpdir/xcat");
mkpath($tempdir);

sub run_pack {
    @ran = ();
    my $runner = sub {
        my $cmd = shift;
        push @ran, $cmd;
        # A compressor that fails still leaves a partial file behind, so write it either way.
        my ($out) = $cmd =~ /> (\S+)$/;
        if ( defined($out) ) {
            open( my $fh, '>', $out ) or die $!;
            print $fh "payload\n";
            close($fh);
        }
        return $rc;
    };
    return xCAT_plugin::mknb::pack_genesis_fs( $tempdir, $tftpdir, 'x86_64',
        'SUFFIX', $runner );
}

sub clean { unlink glob("$tftpdir/xcat/*"); }

# lzma is available and works.
{
    clean();
    $available = 'lzma -C crc32 -9';
    $rc = 0;
    my $packed = run_pack();
    is( $packed->{format}, 'lzma', 'an lzma run that succeeds gives an lzma image' );
    is( $packed->{command}, 'lzma -C crc32 -9', 'built with the command the routine chose' );
    is( $packed->{path}, "$tftpdir/xcat/genesis.fs.x86_64.lzma",
        'named for the architecture, in the tftp xcat directory' );
    ok( !$packed->{fell_back}, 'and nothing fell back' );
    is( scalar @ran, 1, 'the compressor ran once' );
    like( $ran[0], qr{cd \Q$tempdir\E; find \. \| cpio -o -H newc \| lzma -C crc32 -9 > },
        'over the staged root, through cpio, into the chosen compressor' );
    like( $ran[0], qr/genesis\.fs\.x86_64\.lzma\.SUFFIX$/,
        'writing to the suffixed name, so a concurrent mknb cannot read a half-written image' );
    ok( -f $packed->{path}, 'the finished image is in place' );
    ok( !-e "$tftpdir/xcat/genesis.fs.x86_64.lzma.SUFFIX",
        'and the staged name is gone, so the rename happened' );
    ok( !-e "$tftpdir/xcat/genesis.fs.x86_64.gz", 'no gzip image was written beside it' );
}

# Only xz: the same path, a different pipeline.
{
    clean();
    $available = 'xz --format=lzma -C crc32 -9';
    $rc = 0;
    my $packed = run_pack();
    is( $packed->{format}, 'lzma', 'xz still produces the lzma image' );
    like( $ran[0], qr/\| xz --format=lzma -C crc32 -9 >/,
        'and the caller runs the command it was given, not a fixed one' );
}

# Neither: straight to gzip, with no failed run first.
{
    clean();
    $available = undef;
    $rc = 0;
    my $packed = run_pack();
    is( $packed->{format}, 'gz', 'a host with neither compressor gets a gzip image' );
    is( $packed->{path}, "$tftpdir/xcat/genesis.fs.x86_64.gz", 'named .gz' );
    ok( !$packed->{fell_back}, 'which is not a fallback -- nothing was tried and failed' );
    is( scalar @ran, 1, 'and only one command ran' );
    like( $ran[0], qr/\| gzip -9 > \S+genesis\.fs\.x86_64\.gz\.SUFFIX$/,
        'gzip, into the suffixed name' );
    ok( -f $packed->{path}, 'the gzip image is in place' );
}

# lzma is available and fails: the fallback nobody has ever run.
{
    clean();
    $available = 'lzma -C crc32 -9';
    $rc = 1;
    my $packed = run_pack();
    is( $packed->{format}, 'gz', 'a failed lzma run still produces an image' );
    ok( $packed->{fell_back}, 'reported as a fallback' );
    is( scalar @ran, 2, 'after two runs' );
    like( $ran[1], qr/\| gzip -9 >/, 'the second being gzip' );
    ok( !-e "$tftpdir/xcat/genesis.fs.x86_64.lzma.SUFFIX",
        'the half-written lzma image is removed, not left for the next run to rename' );
    ok( !-e "$tftpdir/xcat/genesis.fs.x86_64.lzma",
        'and no lzma image is put in place' );
    like( join( ' ', @{ $packed->{messages} } ), qr/falling back to gzip/,
        'and the caller is given something to report' );
}

done_testing();
