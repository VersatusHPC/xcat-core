#!/usr/bin/env perl
# A netboot dracut.conf names an exclusive module list. The dracut 059 systemd module installs
# systemd-vconsole-setup, and only the i18n module installs the loadkeys it starts, so a list
# with systemd and without i18n gives an initrd where "Virtual Console Setup" fails.
use strict;
use warnings;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Slurper qw(write_text);
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";
use Test::More;
use imgutils;

# Builds an image root. $setup is the text of the systemd module-setup.sh.
sub image {
    my (%opt) = @_;
    my $root   = tempdir(CLEANUP => 1);
    my $moddir = "$root/usr/lib/dracut/modules.d";
    make_path("$moddir/00systemd", "$moddir/98dracut-systemd", "$root/usr/bin");
    make_path("$moddir/10i18n") unless $opt{no_i18n};
    write_text("$moddir/00systemd/module-setup.sh", $opt{setup} // "inst \"\$systemdutildir\"/systemd-vconsole-setup\n");
    foreach my $bin (@{ $opt{bins} // [qw(setfont loadkeys kbd_mode)] }) {
        write_text("$root/usr/bin/$bin", "");
        chmod(0755, "$root/usr/bin/$bin");
    }
    return ($root, $moddir);
}

sub i18n_for {
    my ($list, %opt) = @_;
    my $sub = imgutils->can('dracut_i18n_modules') or return 'no such sub';
    return join(' ', $sub->(image(%opt), $list));
}

my $list = 'xcat nfs base network kernel-modules syslog systemd systemd-initrd dracut-systemd';

is(i18n_for($list), 'i18n', 'a list with systemd gets i18n when systemd installs systemd-vconsole-setup');
is(i18n_for("$list i18n"), '', 'a list that names i18n is unchanged');
is(i18n_for('xcat nfs base network kernel-modules dracut-systemd'), '', 'a list without systemd is unchanged');
is(i18n_for($list, setup => "inst systemd-udevd\n"), '',
    'a systemd module that does not install systemd-vconsole-setup adds nothing');
is(i18n_for($list, no_i18n => 1), '', 'a dracut without the i18n module adds nothing');
is(i18n_for($list, bins => [qw(setfont kbd_mode)]), '', 'an image without loadkeys adds nothing');

done_testing();
