#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";
use Test::More;

use imgutils;

# genimage takes the drivers of a netboot image from default_net_drivers when the osimage
# names none. A riscv64 node in the lab has a virtio NIC, so an image built without
# virtio_net has no provisioning NIC and the node never reaches the management node.
#
# The module inventory below is the one an Ubuntu riscv64 node runs: kernel 6.17.0-14-generic
# from casper/ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs on
# ubuntu-24.04.4-live-server-riscv64.iso. It is read here as the contract the driver list
# must meet, so a list copied from another architecture fails.

my $KERNELVER = '6.17.0-14-generic';

my @KERNEL_MODULES = qw(
  kernel/drivers/net/ethernet/broadcom/bnx2.ko.zst
  kernel/drivers/net/ethernet/broadcom/bnx2x/bnx2x.ko.zst
  kernel/drivers/net/ethernet/broadcom/tg3.ko.zst
  kernel/drivers/net/ethernet/cadence/macb.ko.zst
  kernel/drivers/net/ethernet/emulex/benet/be2net.ko.zst
  kernel/drivers/net/ethernet/intel/e1000/e1000.ko.zst
  kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.zst
  kernel/drivers/net/ethernet/intel/igb/igb.ko.zst
  kernel/drivers/net/ethernet/intel/ixgbe/ixgbe.ko.zst
  kernel/drivers/net/ethernet/mellanox/mlx4/mlx4_en.ko.zst
  kernel/drivers/net/ethernet/mellanox/mlx5/core/mlx5_core.ko.zst
  kernel/drivers/net/ethernet/realtek/r8169.ko.zst
  kernel/drivers/net/ethernet/stmicro/stmmac/stmmac.ko.zst
  kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-generic.ko.zst
  kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-sophgo.ko.zst
  kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-starfive.ko.zst
  kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-thead.ko.zst
  kernel/fs/overlayfs/overlay.ko.zst
);

# The riscv64 kernel builds virtio_net in. imgutils reports a builtin as available, and
# genimage needs no module for it.
my @KERNEL_BUILTINS = qw(
  kernel/drivers/virtio/virtio.ko
  kernel/drivers/virtio/virtio_pci.ko
  kernel/drivers/net/virtio_net.ko
);

sub riscv64_rootimg {
    my $root = tempdir(CLEANUP => 1);
    my $modules = "$root/lib/modules/$KERNELVER";
    make_path($modules);

    open(my $dep, '>', "$modules/modules.dep") or die "cannot write modules.dep: $!";
    foreach my $path (@KERNEL_MODULES) {
        my $full = "$modules/$path";
        ($full =~ m{^(.*)/[^/]+$}) and make_path($1);
        open(my $ko, '>', $full) or die "cannot create $full: $!";
        close($ko);
        print {$dep} "$path:\n";
    }
    close($dep);

    open(my $builtin, '>', "$modules/modules.builtin") or die "cannot write modules.builtin: $!";
    print {$builtin} "$_\n" foreach @KERNEL_BUILTINS;
    close($builtin);

    return $root;
}

my @drivers = imgutils::default_net_drivers('ubuntu', 'riscv64');

ok(scalar(@drivers), 'ubuntu riscv64 has default network drivers');

my %named = map { $_ => 1 } @drivers;
ok($named{'virtio_net'}, 'the list names virtio_net, the NIC of a riscv64 guest');
ok($named{'overlay'}, 'the list names overlay, the root of a netboot image');

my $rootimg = riscv64_rootimg();
my %available = imgutils::target_kernel_module_availability(
    $rootimg, $KERNELVER, @drivers,
);
my @missing = sort grep { !$available{$_} } keys %available;
is_deeply(\@missing, [],
    'every driver of the list is a module or a builtin of the Ubuntu riscv64 kernel');

my @resolved = imgutils::resolve_mellanox_default_net_drivers(
    $rootimg, $KERNELVER, [], @drivers,
);
my %kept = map { $_ => 1 } @resolved;
ok($kept{'virtio_net'}, 'virtio_net survives the Mellanox resolution genimage runs');
ok($kept{'overlay'}, 'overlay survives the Mellanox resolution genimage runs');

done_testing();
