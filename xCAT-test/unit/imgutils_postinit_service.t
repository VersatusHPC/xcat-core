#!/usr/bin/env perl
# A diskless Ubuntu image runs its postbootscripts from xcatpostinit at boot. systemd 255 and later
# warn that SysV support is deprecated, and a systemd without it never starts an /etc/init.d
# script, so the image must carry xcatpostinit as a native unit.
use strict;
use warnings;
use FindBin;
use File::Path qw(make_path);
use File::Slurper qw(read_text write_text);
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";
use Test::More;
use imgutils;

my $postscripts = tempdir(CLEANUP => 1);
write_text("$postscripts/xcatpostinit",         "#!/bin/sh\n# script\n");
write_text("$postscripts/xcatpostinit.service", "[Unit]\n# unit\n");

sub image_root {
    my (@dirs) = @_;
    my $root = tempdir(CLEANUP => 1) . '/rootimg';
    make_path(map { "$root/$_" } 'etc', @dirs);
    return $root;
}

{
    my $root = image_root('usr/lib/systemd/system', 'etc/init.d', 'etc/rc2.d');
    # A root image that an older genimage built carries the SysV script and its rc2.d link.
    write_text("$root/etc/init.d/xcatpostinit", "old\n");
    symlink('../init.d/xcatpostinit', "$root/etc/rc2.d/S61xcatpostinit") or die "symlink: $!";

    imgutils::install_postinit_service($root, $postscripts);

    is(read_text("$root/opt/xcat/xcatpostinit"), "#!/bin/sh\n# script\n",
        'the unit runs the xcatpostinit script from /opt/xcat');
    ok(-x "$root/opt/xcat/xcatpostinit", 'the script is executable');
    is(read_text("$root/etc/systemd/system/xcatpostinit.service"), "[Unit]\n# unit\n",
        'a systemd image gets the native xcatpostinit unit');
    is(readlink("$root/etc/systemd/system/multi-user.target.wants/xcatpostinit.service"),
        '../xcatpostinit.service', 'the unit is enabled for multi-user.target');
    ok(!-e "$root/etc/init.d/xcatpostinit", 'the SysV script is gone, so systemd generates no second unit');
    ok(!-l "$root/etc/rc2.d/S61xcatpostinit", 'the rc2.d link is gone');

    imgutils::install_postinit_service($root, $postscripts);
    is(readlink("$root/etc/systemd/system/multi-user.target.wants/xcatpostinit.service"),
        '../xcatpostinit.service', 'a second genimage run on the same root keeps the unit enabled');
}

{
    my $root = image_root('etc/init.d', 'etc/rc2.d');
    imgutils::install_postinit_service($root, $postscripts);
    is(readlink("$root/etc/rc2.d/S61xcatpostinit"), '../init.d/xcatpostinit',
        'an image without systemd keeps the SysV script in rc2.d');
    ok(-x "$root/etc/init.d/xcatpostinit", 'and the SysV script is executable');
    ok(!-e "$root/etc/systemd/system/xcatpostinit.service", 'and gets no unit');
}

done_testing();
