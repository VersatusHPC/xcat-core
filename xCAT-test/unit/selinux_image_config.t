#!/usr/bin/env perl
use strict;
use warnings;

# Keep modules out of an installed /opt/xcat, so the checkout is what loads.
BEGIN { $ENV{XCATROOT} = '/nonexistent/xcatroot' }

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Path qw(make_path);
use File::Slurper qw(read_lines read_text write_text);
use File::Temp qw(tempdir);
use Test::More;

use xCAT::SELinux;

like($INC{'xCAT/SELinux.pm'}, qr/\Q$FindBin::Bin\E/,
    'xCAT::SELinux comes from this checkout, not from /opt/xcat');

my $root = tempdir(CLEANUP => 1);
make_path("$root/etc/selinux");
my $config = "$root/etc/selinux/config";

# The config an old genimage postinstall left behind.
write_text($config, "# comment SELINUX=keep\nSELINUX=disabled\nSELINUXTYPE=targeted\n");
ok(xCAT::SELinux->write_image_config(root => $root), 'write_image_config changes a disabled image');
is(read_text($config), "# comment SELINUX=keep\nSELINUX=enforcing\nSELINUXTYPE=targeted\n",
    'the image boots enforcing unless the kernel command line says otherwise');
is(xCAT::SELinux->config_mode(root => $root), 'enforcing', 'config_mode of the image reads enforcing');

write_text($config, "SELINUX=permissive\nSELINUXTYPE=mls\n");
xCAT::SELinux->write_image_config(root => $root);
is(read_text($config), "SELINUX=enforcing\nSELINUXTYPE=mls\n", 'a permissive image becomes enforcing; the policy type stays');

write_text($config, "SELINUXTYPE=targeted\n");
xCAT::SELinux->write_image_config(root => $root);
is(read_text($config), "SELINUXTYPE=targeted\nSELINUX=enforcing\n", 'a config with no SELINUX line gets one');

my $bare = tempdir(CLEANUP => 1);
ok(!xCAT::SELinux->write_image_config(root => $bare), 'an image without an SELinux policy is left alone');
ok(!-e "$bare/etc/selinux/config", 'no config is created in an image without an SELinux policy');

is(xCAT::SELinux->image_file_contexts($bare), undef, 'an image without a policy has no file_contexts');
make_path("$root/etc/selinux/mls/contexts/files");
write_text($config, "SELINUX=enforcing\nSELINUXTYPE=mls\n");
write_text("$root/etc/selinux/mls/contexts/files/file_contexts", "/.* system_u:object_r:default_t:s0\n");
is(xCAT::SELinux->image_file_contexts($root), "$root/etc/selinux/mls/contexts/files/file_contexts",
    'image_file_contexts follows SELINUXTYPE of the image');

# genimage owns /etc/selinux/config of the image: it calls write_image_config
# before it runs the postinstall script, so a postinstall that writes the file
# overrides the mode xCAT resolved for the node. The postinstalls also used an
# unanchored substitution, which rewrote the stock "permissive" comment line and
# produced SELINUX=SELINUX=disabled from a permissive image. sed returned 0 for
# both.
my @postinstalls = glob("$FindBin::Bin/../../xCAT-server/share/xcat/netboot/*/*.postinstall");
cmp_ok(scalar(@postinstalls), '>', 20, 'the netboot postinstall scripts are found');
my @writers = grep {
    my @hits = grep { m{/etc/selinux/config} && !/^\s*#/ } read_lines($_);
    @hits ? 1 : 0;
} @postinstalls;
s{^.*/}{} foreach @writers;
is_deeply([ sort @writers ], [],
    'no netboot postinstall writes /etc/selinux/config of the image');

done_testing();
