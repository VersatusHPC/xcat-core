#!/usr/bin/env perl

# genimage writes the fstab of a diskless image, and AAsn.pm writes the NFS entries for
# /install and /tftpboot on a service node. Both go through xCAT::FstabUtils. fsck checks
# block devices only: a tmpfs or NFS entry with a non-zero pass makes systemd-fstab-generator
# log "Checking was requested for ..., but it is not a device" at each boot.

use strict;
use warnings;

use FindBin;
use File::Temp qw(tempdir);
use File::Slurper qw(read_text write_text);
use Test::More;

use lib "$FindBin::Bin/../../perl-xCAT";
use xCAT::FstabUtils;

sub fields { return [ map { [ split(' ', $_) ] } split(/\n/, $_[0]) ] }

my $image = fields(xCAT::FstabUtils::diskless_fstab('compute_x86_64', 'defaults,size=10m'));
is_deeply([ map { "$_->[1] $_->[5]" } @$image ],
    [ '/dev/pts 0', '/dev/shm 0', '/proc 0', '/sys 0', '/tmp 0', '/var/tmp 0', '/ 0' ],
    'the diskless image asks fsck to check no entry');
is_deeply($image->[-1], [ 'compute_x86_64', '/', 'tmpfs', 'rw', 0, 0 ],
    'the / entry keeps the spec and the rw option that statelite looks for');

my $systemd = fields(xCAT::FstabUtils::diskless_fstab('service_ppc64le', undef));
is_deeply([ map { $_->[1] } @$systemd ], [ '/dev/pts', '/dev/shm', '/proc', '/sys', '/' ],
    'without tmp options the image has no /tmp and /var/tmp entries');

is(xCAT::FstabUtils::entry('mn:/install', '/install', 'nfs', 'timeo=14,intr'),
    "mn:/install /install nfs timeo=14,intr 0 0\n",
    'an NFS entry has dump 0 and pass 0');
is(xCAT::FstabUtils::fsck_pass('nfs4', '/home'), 0, 'nfs4 is not checked');
is(xCAT::FstabUtils::fsck_pass('xfs',  '/'),     1, 'a local / is checked first');
is(xCAT::FstabUtils::fsck_pass('ext4', '/data'), 2, 'another local file system is checked after /');

my @old = ("UUID=1 / xfs defaults 0 0\n", "mn:/tftpboot /tftpboot nfs timeo=14,intr 1 2\n");
my ($new, $changed) = xCAT::FstabUtils::set_entry(\@old, 'mn:/tftpboot', '/tftpboot', 'nfs', 'timeo=14,intr');
is_deeply($new, [ $old[0], "mn:/tftpboot /tftpboot nfs timeo=14,intr 0 0\n" ],
    'an entry an older xCAT wrote is replaced, not duplicated');
is($changed, 1, 'the replacement is a change');

my ($again, $changed2) = xCAT::FstabUtils::set_entry($new, 'mn:/tftpboot', '/tftpboot', 'nfs', 'timeo=14,intr');
is_deeply($again, $new, 'a second update keeps one entry');
is($changed2, 0, 'a second update is no change');

my ($added) = xCAT::FstabUtils::set_entry([ "UUID=1 / xfs defaults 0 0" ], 'mn:/install', '/install', 'nfs', 'ro');
is_deeply($added, [ "UUID=1 / xfs defaults 0 0\n", "mn:/install /install nfs ro 0 0\n" ],
    'a missing entry is appended on its own line');

my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/fstab";
write_text($path, "UUID=1 / xfs defaults 0 0\nmn:/install /install nfs timeo=14,intr 1 2\n");
is(xCAT::FstabUtils::update_file($path, 'mn:/install', '/install', 'nfs', 'timeo=14,intr'), 1,
    'update_file reports the change');
is(read_text($path), "UUID=1 / xfs defaults 0 0\nmn:/install /install nfs timeo=14,intr 0 0\n",
    'update_file writes the corrected entry');
is(xCAT::FstabUtils::update_file($path, 'mn:/install', '/install', 'nfs', 'timeo=14,intr'), 0,
    'update_file leaves a correct file alone');

done_testing();
