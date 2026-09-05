#!/usr/bin/env perl
# mknb ppc64le writes the ppc64 file names when it falls back to the legacy Genesis image.
# The install of the OpenEmbedded image deleted the stale initramfs under the ppc64le name
# only, so the legacy 79 MB genesis.fs.ppc64.lzma stayed in /tftpboot for good.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Digest::SHA ();
use File::Path qw(mkpath);
use File::Temp qw(tempdir);
use Test::More;

BEGIN { $INC{'xCAT/Utils.pm'} = 1; $INC{'xCAT/TableUtils.pm'} = 1;
        $INC{'xCAT/NodeRange.pm'} = 1; }
sub xCAT::Utils::genpassword { return 'testsuffix' }

require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/mknb.pm";

can_ok('xCAT_plugin::mknb', 'superseded_genesis_initramfs')
    or BAIL_OUT('mknb has no superseded_genesis_initramfs to drive');

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "Unable to write $path: $!";
    print $fh $content;
    close($fh);
    return $content;
}

sub digest {
    my ($content) = @_;
    return Digest::SHA->new(256)->add($content)->hexdigest;
}

# Build the export tree that mknb installs from, for one architecture.
sub export_tree {
    my ($arch) = @_;
    my $source = tempdir(CLEANUP => 1);
    my %content = (
        'kernel'                => "kernel for $arch",
        'initramfs.cpio.gz'     => "initramfs for $arch",
        'xcat-genesis.manifest' => "format=xcat-genesis\nversion=1\narchitecture=$arch\n",
    );
    my $sums = '';
    foreach my $name (sort keys %content) {
        write_file("$source/$name", $content{$name});
        $sums .= digest($content{$name}) . "  $name\n";
    }
    write_file("$source/SHA256SUMS", $sums);
    return $source;
}

sub install {
    my ($arch, @stale) = @_;
    my $tftpdir = tempdir(CLEANUP => 1);
    mkpath("$tftpdir/xcat");
    foreach my $name (@stale) {
        write_file("$tftpdir/xcat/$name", 'the initramfs of the previous run');
    }
    my ($initrd, $error) =
      xCAT_plugin::mknb::_install_prebuilt_genesis(export_tree($arch), $tftpdir, $arch);
    return { dir => "$tftpdir/xcat", initrd => $initrd, error => $error };
}

# --- ppc64le: the legacy run wrote the ppc64 name ---------------------------
my $ppc = install('ppc64le', 'genesis.fs.ppc64.lzma');
is($ppc->{error}, undef, 'the OpenEmbedded ppc64le image installs');
ok(-f "$ppc->{dir}/genesis.fs.ppc64le.gz", 'and the new initramfs is in place');
ok(!-e "$ppc->{dir}/genesis.fs.ppc64.lzma",
    'the legacy ppc64 initramfs the same command wrote is removed');

# The canonical spelling must keep being removed as well.
my $both = install('ppc64le', 'genesis.fs.ppc64.lzma', 'genesis.fs.ppc64le.lzma');
ok(!-e "$both->{dir}/genesis.fs.ppc64le.lzma",
    'a stale ppc64le initramfs is still removed');
ok(!-e "$both->{dir}/genesis.fs.ppc64.lzma",
    'and the ppc64 one goes with it');

# --- x86_64 keeps its own behaviour -----------------------------------------
my $x86 = install('x86_64', 'genesis.fs.x86_64.lzma');
is($x86->{error}, undef, 'the x86_64 image installs');
ok(!-e "$x86->{dir}/genesis.fs.x86_64.lzma",
    'the stale x86_64 initramfs is removed');

# --- the file list, so each architecture states its own answer --------------
is_deeply([ xCAT_plugin::mknb::superseded_genesis_initramfs('/tftpboot/xcat', 'ppc64le') ],
    [ '/tftpboot/xcat/genesis.fs.ppc64le.lzma', '/tftpboot/xcat/genesis.fs.ppc64.lzma' ],
    'ppc64le supersedes both spellings of the initramfs');
is_deeply([ xCAT_plugin::mknb::superseded_genesis_initramfs('/tftpboot/xcat', 'ppc64') ],
    [ '/tftpboot/xcat/genesis.fs.ppc64.lzma' ],
    'an install for ppc64 touches no other architecture');
is_deeply([ xCAT_plugin::mknb::superseded_genesis_initramfs('/tftpboot/xcat', 'riscv64') ],
    [ '/tftpboot/xcat/genesis.fs.riscv64.lzma' ],
    'every other architecture keeps one name');

done_testing();
