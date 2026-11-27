#!/usr/bin/env perl
# genimage writes a dracut configuration file into the image before it installs the packages.
# The kernel scriptlets run dracut in a chroot without /dev, and dracut warns when it has to turn
# host-only mode off itself.
use strict;
use warnings;

use File::Slurper qw(read_text);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Test::More;

use imgutils;

my $root = tempdir(CLEANUP => 1);

my $file = imgutils::write_dracut_no_hostonly($root);
is($file, "$root/etc/dracut.conf.d/99-xcat-genimage.conf", 'the file is in the dracut.conf.d of the image');
like(read_text($file), qr/^hostonly="no"$/m, 'the file turns host-only mode off');

ok(!eval { imgutils::write_dracut_no_hostonly("$root/absent\0dir"); 1 }, 'an unwritable path dies');

done_testing();
