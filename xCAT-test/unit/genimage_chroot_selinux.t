#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Slurper qw(write_text);
use File::Temp qw(tempdir);
use Test::More;

use imgutils;

my $root = '/install/netboot/alma9.8/x86_64/compute/rootimg';

# The /dev/null the chroot needs: a character device, and the type the base
# policy grants to every domain. A node that keeps the type of the rootimg tree
# moves the denial to that type instead of ending it.
my $devnull = imgutils::chroot_devnull_command($root, 1);
like($devnull, qr/\Qmknod -m 666 $root\/dev\/null c 1 3\E/,
    'the command creates /dev/null as a character device');
like($devnull, qr/\Qchcon -t null_device_t $root\/dev\/null\E/,
    'the command labels the node null_device_t');
like($devnull, qr/\Q[ -c $root\/dev\/null ]\E/,
    'an existing character device is not replaced');
like($devnull, qr/\Qrm -f $root\/dev\/null\E/,
    'a regular file left by an earlier run is replaced');
like($devnull, qr/^findmnt \Q$root\E\/dev /,
    'a bind-mounted /dev belongs to the management node and is left alone');

my $unlabelled = imgutils::chroot_devnull_command($root, 0);
like($unlabelled, qr/\Qmknod -m 666\E/,
    'a host without SELinux still gets the device node');
unlike($unlabelled, qr/chcon/,
    'a host without SELinux is not asked to label it');

is(imgutils::chroot_devnull_command('/', 1), undef,
    'the command refuses the root directory of the management node');
is(imgutils::chroot_devnull_command('', 1), undef, 'an empty rootimgdir is refused');
is(imgutils::chroot_devnull_command(undef, 1), undef, 'an undefined rootimgdir is refused');

# The relabel: rpm labels an installroot from the host contexts with the root
# prefix stripped, so setfiles -r is the same lookup over the entries rpm did
# not create.
my $relabel = imgutils::chroot_relabel_command($root, 'targeted');
like($relabel, qr/^setfiles -r \Q$root\E /, 'the relabel strips the rootimg prefix');
like($relabel, qr{\Q/etc/selinux/targeted/contexts/files/file_contexts\E},
    'the relabel reads the file contexts of the active policy');
like($relabel, qr/\Q$root\E$/, 'the relabel walks the rootimg');
for my $virtual (qw(dev proc sys)) {
    like($relabel, qr/\Q-e $root\/$virtual\E/, "the relabel excludes /$virtual");
}

is(imgutils::chroot_relabel_command($root, undef), undef,
    'no policy type means no relabel');
is(imgutils::chroot_relabel_command($root, ''), undef,
    'an empty policy type means no relabel');
is(imgutils::chroot_relabel_command('/', 'targeted'), undef,
    'the relabel refuses the root directory of the management node');

# SELINUXTYPE names the contexts to read, and a management node that carries no
# policy must not be asked for one.
my $dir = tempdir(CLEANUP => 1);
write_text("$dir/with-mls", "SELINUX=permissive\nSELINUXTYPE=mls\n");
is(imgutils::selinux_policy_type("$dir/with-mls"), 'mls',
    'the policy type comes from SELINUXTYPE');
write_text("$dir/commented", "SELINUXTYPE=targeted\n#SELINUXTYPE=mls\n");
is(imgutils::selinux_policy_type("$dir/commented"), 'targeted',
    'a commented SELINUXTYPE is not read');
write_text("$dir/spaced", "SELINUXTYPE = targeted\n");
is(imgutils::selinux_policy_type("$dir/spaced"), 'targeted',
    'spaces around the assignment are accepted');
write_text("$dir/none", "SELINUX=disabled\n");
is(imgutils::selinux_policy_type("$dir/none"), undef,
    'a config without SELINUXTYPE yields no policy type');
write_text("$dir/injected", "SELINUXTYPE=../../etc\n");
is(imgutils::selinux_policy_type("$dir/injected"), undef,
    'a policy type that is not a name is refused');
is(imgutils::selinux_policy_type("$dir/absent"), undef,
    'an absent config yields no policy type');

done_testing();
