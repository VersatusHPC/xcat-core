#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Test::More;
use xCAT::Genesis;

my $tftp = tempdir(CLEANUP => 1);
make_path("$tftp/xcat");

is(
    xCAT::Genesis::boot_arch($tftp, 'ppc64le'),
    'ppc64',
    'ppc64le keeps the legacy POWER fallback when no exact image exists',
);

open(my $marker_fh, '>', "$tftp/xcat/genesis.exact-arch.ppc64")
  or die "create exact POWER marker: $!";
close($marker_fh) or die "close exact POWER marker: $!";

is(
    xCAT::Genesis::boot_arch($tftp, 'ppc64le'),
    'ppc64le',
    'ppc64le does not fall back to a canonical big-endian ppc64 image',
);
unlink("$tftp/xcat/genesis.exact-arch.ppc64")
  or die "remove exact POWER marker: $!";

open(my $kernel_fh, '>', "$tftp/xcat/genesis.kernel.ppc64le")
  or die "create exact POWER kernel: $!";
close($kernel_fh) or die "close exact POWER kernel: $!";

is(
    xCAT::Genesis::boot_arch($tftp, 'ppc64le'),
    'ppc64le',
    'ppc64le uses the exact OpenEmbedded boot artifact',
);
is(
    xCAT::Genesis::boot_arch($tftp, 'ppc64el'),
    'ppc64le',
    'the Debian spelling resolves to the exact ppc64le artifact',
);
is(xCAT::Genesis::boot_arch($tftp, 'x86_64'), 'x86_64', 'other architectures are unchanged');

ok(xCAT::Genesis::uses_power_console('ppc64'), 'legacy POWER uses the hypervisor console');
ok(xCAT::Genesis::uses_power_console('ppc64le'), 'ppc64le uses the hypervisor console');
ok(!xCAT::Genesis::uses_power_console('x86_64'), 'x86_64 keeps the serial console path');

done_testing();
