#!/usr/bin/env perl
use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage, TestingAndDebugging::ProhibitNoStrict)

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use File::Path qw(make_path);
use File::Slurper qw(read_text write_text);
use File::Temp qw(tempdir);
use Test::More;
use XCAT::Test::File qw(repo_path);

# mknb.pm loads these at compile time. Only _write_grub2_discovery_config is
# called here, and it reads none of them.
BEGIN {
    package xCAT::Utils;
    $INC{'xCAT/Utils.pm'} = __FILE__;

    package xCAT::TableUtils;
    $INC{'xCAT/TableUtils.pm'} = __FILE__;

    package xCAT::NodeRange;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::noderange"} = sub { return; };
    }
    $INC{'xCAT/NodeRange.pm'} = __FILE__;
}
require xCAT::NetworkUtils;
require(repo_path('xCAT-server/lib/xcat/plugins/mknb.pm'));

sub publish_genesis {
    my ($tftpdir, $arch) = @_;
    make_path("$tftpdir/xcat", "$tftpdir/boot/grub2");
    write_text("$tftpdir/xcat/genesis.kernel.$arch", '');
    write_text("$tftpdir/xcat/genesis.fs.$arch.gz",  '');
}

sub write_config {
    my ($tftpdir) = @_;
    return xCAT_plugin::mknb::_write_grub2_discovery_config(
        tftpdir       => $tftpdir,
        hexnet        => 'c0a846',
        xcatd_address => '192.168.70.1',
        xcatdport     => 3001,
        httpport      => 80,
    );
}

# An aarch64 node boots discovery through AAVMF and grub2, like riscv64.
# grubaa64.efi reports $grub_cpu as "arm64", not as the Linux name.
my $tftpdir = tempdir(CLEANUP => 1) . '/tftpboot';
publish_genesis($tftpdir, 'aarch64');

my $path = write_config($tftpdir);
is($path, "$tftpdir/boot/grub2/grub.cfg-C0A846",
    'mknb writes a grub2 discovery configuration for a network that serves aarch64 Genesis');
my $cfg = defined($path) && -f $path ? read_text($path) : '';
like($cfg, qr/^if \[ "\$grub_cpu" = "arm64" \]; then$/m,
    'the aarch64 entries are guarded by the arm64 GRUB cpu');
like($cfg,
    qr{^menuentry "xCAT Genesis aarch64" \{\n    insmod http\n    insmod tftp\n    set root=http,192\.168\.70\.1\n    linux /tftpboot/xcat/genesis\.kernel\.aarch64 xcatd=192\.168\.70\.1:3001 BOOTIF=\$net_default_mac\n    initrd /tftpboot/xcat/genesis\.fs\.aarch64\.gz\n\}$}m,
    'the default aarch64 entry loads the Genesis kernel and initrd over HTTP');
like($cfg,
    qr{^menuentry "xCAT Genesis aarch64 \(TFTP\)" \{\n    insmod tftp\n    set root=tftp,192\.168\.70\.1\n    linux /xcat/genesis\.kernel\.aarch64 xcatd=192\.168\.70\.1:3001 BOOTIF=\$net_default_mac\n    initrd /xcat/genesis\.fs\.aarch64\.gz\n\}$}m,
    'the fallback aarch64 entry loads them over TFTP');

# One network can serve both grub2 architectures. Each gets its own branch.
publish_genesis($tftpdir, 'riscv64');
$path = write_config($tftpdir);
$cfg = defined($path) && -f $path ? read_text($path) : '';
like($cfg, qr/^if \[ "\$grub_cpu" = "arm64" \]; then\n.*^elif \[ "\$grub_cpu" = "riscv64" \]; then\n.*^fi$/ms,
    'aarch64 and riscv64 share one configuration with one branch each');

done_testing();
