#!/usr/bin/env perl

# makedns gives /var/lib/named to root:named. named runs as the named user and
# writes its zone dumps and journals in that directory, so the group must keep
# write permission. Leap 42.3 ships the directory 0755 named:named.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Temp qw(tempdir);
use Test::More;

use xCAT::DNS::NamedDir;

my $tmp = tempdir(CLEANUP => 1);
my ($uid, $gid) = ($<, (split ' ', $()[0]);

sub mode_after_prepare {
    my ($start_mode) = @_;
    my $dir = "$tmp/named-" . sprintf('%04o', $start_mode);
    mkdir $dir or die "mkdir $dir: $!";
    chmod $start_mode, $dir or die "chmod $dir: $!";
    ok(xCAT::DNS::NamedDir::prepare($dir, $uid, $gid), "prepare succeeds on a $start_mode dir");
    my @st = stat $dir;
    is($st[4], $uid, 'owner is the given uid');
    is($st[5], $gid, 'group is the given gid');
    return $st[2] & 07777;
}

is(sprintf('%04o', mode_after_prepare(0755)), '1775',
    'Leap 42.3 mode 0755 gets group write and the sticky bit');
is(sprintf('%04o', mode_after_prepare(01775)), '1775',
    'Leap 15 and 16 mode 1775 stays the same');
is(sprintf('%04o', mode_after_prepare(0750)), '1770',
    'permission for other users stays the same');

ok(!xCAT::DNS::NamedDir::prepare("$tmp/absent", $uid, $gid),
    'prepare fails on a directory that does not exist');

done_testing();
