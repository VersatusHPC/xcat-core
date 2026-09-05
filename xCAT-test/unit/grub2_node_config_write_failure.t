#!/usr/bin/env perl
use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage, TestingAndDebugging::ProhibitNoStrict, TestingAndDebugging::ProhibitNoWarnings)

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use Cwd qw(getcwd);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use Test::More;
use XCAT::Test::File qw(repo_path);
use xCAT::Utils;

# grub2.pm reads the xCAT configuration when it loads, so setstate is lifted out
# and run on its own.
my $plugin = repo_path('xCAT-server/lib/xcat/plugins/grub2.pm');
open(my $plugin_fh, '<', $plugin) or BAIL_OUT("Unable to read $plugin: $!");
my $source = do { local $/; <$plugin_fh> };
close($plugin_fh);

my ($setstate) = $source =~ /^(sub setstate \{.*?^\})$/ms;
BAIL_OUT('setstate is no longer a top level subroutine in grub2.pm') unless $setstate;
BAIL_OUT('setstate no longer writes the per node boot configuration')
  unless $setstate =~ /\$bootloader_root/;

{
    no warnings 'redefine';
    package xCAT::TableUtils;
    sub get_site_attribute { return; }
    package xCAT::NetworkUtils;
    sub getipaddr { return '192.0.2.20'; }
}

%::XCATSITEVALS = (xcatdebugmode => '0');

{
    no strict;
    no warnings;
    eval "package Grub2Scratch; use File::Path qw(mkpath); $setstate; 1;"
      or BAIL_OUT("Unable to run setstate outside grub2.pm: $@");
}

my $node   = 'cn1';
my $tmpdir = tempdir(CLEANUP => 1);

my %bphash = ($node => [ {
    kernel   => 'xcat/osimage/rhels9-x86_64-install-compute/vmlinuz',
    initrd   => 'xcat/osimage/rhels9-x86_64-install-compute/initrd.img',
    kcmdline => 'quiet',
} ]);
my %chainhash = ($node => [ { currstate => 'osimage=rhels9-x86_64-install-compute' } ]);
my %machash   = ($node => [ {} ]);
my %nrhash    = ($node => [ { tftpserver => '192.0.2.10', netboot => 'grub2-tftp' } ]);

sub run_setstate {
    my $cwd = getcwd();
    my @result = Grub2Scratch::setstate(
        $node, \%bphash, \%chainhash, \%machash, $tmpdir,
        \%nrhash, undef, 'x86_64', 'rhels9',
    );
    chdir($cwd) or die "Unable to return to $cwd: $!";
    return @result;
}

sub read_config {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Unable to read $path: $!";
    my $content = do { local $/; <$fh> };
    close($fh);
    return $content;
}

my $bootloader_root = "$tmpdir/boot/grub2";
make_path($bootloader_root);
open(my $loader, '>', "$bootloader_root/grub2.x86_64") or die "Unable to stage grub2.x86_64: $!";
close($loader);

my $config = "$bootloader_root/$node";

my ($rc, $err) = run_setstate();
is($rc, 0, 'setstate succeeds when the per node boot configuration can be written');
like(read_config($config), qr/^\s+linuxefi .*vmlinuz quiet /m, 'the boot configuration names the install kernel');
# The configuration cannot be replaced: nodeset must not report success.
unlink($config);
make_path("$config/occupied");
($rc, $err) = run_setstate();
is($rc, 1, 'setstate fails when the per node boot configuration cannot be replaced');
like($err, qr/\Q$config\E/, 'the failure names the boot configuration');
remove_tree($config);

# The temporary file cannot be created: same failure, and nothing is left to boot.
make_path("$config.new.$$");
($rc, $err) = run_setstate();
is($rc, 1, 'setstate fails when the boot configuration cannot be opened for write');
ok(!-f $config, 'no boot configuration is left when the write never started');
remove_tree("$config.new.$$");

SKIP: {
    skip 'no /dev/full to fail a write on', 3 unless -c '/dev/full';

    # The write fails after the file is opened. setstate removes the previous
    # configuration first, so a failed write must leave no configuration at all
    # rather than a truncated one.
    ($rc, $err) = run_setstate();
    is($rc, 0, 'the boot configuration is restored before the write test');
    symlink('/dev/full', "$config.new.$$") or die "Unable to stage the write failure: $!";
    ($rc, $err) = run_setstate();
    is($rc, 1, 'setstate fails when the write fails after open');
    ok(!-f $config, 'no truncated boot configuration is left when the write fails');
    unlink("$config.new.$$");
}

ok(!-e "$config.new.$$", 'no temporary boot configuration is left behind');

done_testing();
