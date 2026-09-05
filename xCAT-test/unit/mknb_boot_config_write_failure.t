#!/usr/bin/env perl
use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage, TestingAndDebugging::ProhibitNoStrict, TestingAndDebugging::ProhibitNoWarnings)

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use Test::More;
use XCAT::Test::File qw(repo_path);
use xCAT::Utils;

BEGIN {
    # The real xCAT::Utils drags in the modules stubbed below.
    no warnings 'redefine';

    package xCAT::TableUtils;
    our $tftpdir;
    sub getTftpDir { return $tftpdir; }
    sub get_site_attribute { return; }
    $INC{'xCAT/TableUtils.pm'} = __FILE__;

    package xCAT::NetworkUtils;
    sub my_nets     { return { '192.0.2.0/24' => ['192.0.2.10'] }; }
    sub my_hexnets  { return { c00002 => ['192.0.2.10'] }; }
    sub getipaddr   { return '192.0.2.10'; }
    sub get_nic_ip  { return {}; }
    $INC{'xCAT/NetworkUtils.pm'} = __FILE__;

    package xCAT::NodeRange;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::noderange"} = sub { return; };
    }
    $INC{'xCAT/NodeRange.pm'} = __FILE__;
}

my $mknb_plugin = repo_path('xCAT-server/lib/xcat/plugins/mknb.pm');
require $mknb_plugin;

my $tmpdir = tempdir(CLEANUP => 1);
$::XCATROOT = "$tmpdir/xcatroot";
make_path("$::XCATROOT/share/xcat/netboot/genesis/ppc64");

$xCAT::TableUtils::tftpdir = "$tmpdir/tftpboot";
make_path("$xCAT::TableUtils::tftpdir/xcat", "$xCAT::TableUtils::tftpdir/etc");
foreach my $artifact (qw(genesis.kernel.ppc64 genesis.fs.ppc64.gz)) {
    open(my $fh, '>', "$xCAT::TableUtils::tftpdir/xcat/$artifact")
      or die "Unable to create $artifact: $!";
    close($fh);
}

my $yaboot = "$xCAT::TableUtils::tftpdir/pxelinux.cfg/p/192.0.2.0_24";

sub run_mknb {
    my @responses;
    xCAT_plugin::mknb::process_request(
        { arg => ['ppc64', '--configfileonly'] },
        sub { push @responses, @_; },
    );
    return \@responses;
}

sub failures {
    my ($responses) = @_;
    return grep { ref($_) eq 'HASH' and $_->{error} } @{$responses};
}

sub read_config {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Unable to read $path: $!";
    my $content = do { local $/; <$fh> };
    close($fh);
    return $content;
}

my $responses = run_mknb();
is(scalar(failures($responses)), 0, 'mknb reports no failure when the yaboot entry can be written');
like(read_config($yaboot), qr/^\s+kernel http:.*genesis\.kernel\.ppc64$/m,
    'the yaboot entry names the Genesis kernel');

my $good = read_config($yaboot);

# The entry cannot be replaced: mknb must not report success.
unlink($yaboot);
make_path("$yaboot/occupied");
$responses = run_mknb();
my @errors = failures($responses);
is(scalar(@errors), 1, 'mknb reports the network whose yaboot entry cannot be replaced');
like("@{ $errors[0]->{error} }", qr/\Q$yaboot\E/, 'the failure names the yaboot entry');
is($errors[0]->{errorcode}->[0], 1, 'mknb exits non-zero when a yaboot entry is not written');
remove_tree($yaboot);

# The temporary file cannot be created: same report, no partial entry left behind.
make_path("$yaboot.new.$$");
$responses = run_mknb();
@errors = failures($responses);
is(scalar(@errors), 1, 'mknb reports a yaboot entry it cannot open for write');
ok(!-f $yaboot, 'no yaboot entry is left when the write never started');
remove_tree("$yaboot.new.$$");

SKIP: {
    skip 'no /dev/full to fail a write on', 3 unless -c '/dev/full';

    # The write fails after the file is opened. The previous entry must survive
    # whole rather than be truncated, and the failure must still be reported.
    $responses = run_mknb();
    is(scalar(failures($responses)), 0, 'the yaboot entry is restored before the write test');
    symlink('/dev/full', "$yaboot.new.$$") or die "Unable to stage the write failure: $!";
    $responses = run_mknb();
    @errors = failures($responses);
    is(scalar(@errors), 1, 'mknb reports a yaboot entry whose write fails after open');
    is(read_config($yaboot), $good, 'the previous yaboot entry is left whole, not truncated');
    unlink("$yaboot.new.$$");
}

ok(!-e "$yaboot.new.$$", 'no temporary yaboot file is left behind');

done_testing();
