#!/usr/bin/env perl
# A SUSE diskless image names an exclusive dracut module list. On Leap 16.0 the image has
# NetworkManager and dbus-broker and no wicked. The dracut 059 dbus meta module takes dbus-broker
# only when that module is named, so with neither named, network-manager fails its dbus
# dependency, network falls back to network-legacy, which needs dhclient, and genimage fails with
# "Module 'xcat' depends on 'network', which can't be installed".
use strict;
use warnings;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";
use Test::More;
use imgutils;

# Builds an image root with the named files and dracut modules.
sub image {
    my ($files, $modules) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $moddir = "$root/usr/lib/dracut/modules.d";
    make_path($moddir, map { "$moddir/$_" } @$modules);
    foreach my $file (@$files) {
        (my $parent = "$root/$file") =~ s{/[^/]+$}{};
        make_path($parent);
        open(my $fh, '>', "$root/$file") or die "$root/$file: $!";
        close($fh);
    }
    return ($root, $moddir);
}

sub modules_for {
    my $sub = imgutils->can('sles_dracut_network_modules') or return 'no such sub';
    return join(' ', $sub->(@_));
}

my @nm_modules = qw(06dbus-broker 06dbus-daemon 09dbus 35network-manager 35network-legacy 40network);

is(modules_for(image(['usr/sbin/NetworkManager', 'usr/bin/dbus-broker'], \@nm_modules)),
    'dbus-broker network-manager', 'a Leap 16 image names dbus-broker and network-manager');
is(modules_for(image(['usr/sbin/NetworkManager', 'usr/bin/dbus-daemon'], \@nm_modules)),
    'dbus-daemon network-manager', 'an image with only dbus-daemon names dbus-daemon');
is(modules_for(image(['usr/sbin/wicked', 'usr/sbin/NetworkManager', 'usr/bin/dbus-broker'], \@nm_modules)),
    '', 'an image with wicked keeps the list it had');
is(modules_for(image(['usr/sbin/wicked'], [qw(35network-legacy 40network)])),
    '', 'a Leap 15 image keeps the list it had');
is(modules_for(image(['usr/sbin/NetworkManager', 'usr/bin/dbus-broker'], [qw(06dbus-broker 40network)])),
    '', 'a dracut without the network-manager module keeps the list it had');

done_testing();
