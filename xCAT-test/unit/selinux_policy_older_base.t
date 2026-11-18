#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Slurper qw(read_lines);
use Test::More;

# The policy source is the artifact: checkmodule compiles it as written, and
# semodule loads the result into the base policy of the management node.
#
# The module is built against the selinux-policy-devel of the build chroot, and
# the management node can run an older base policy. An interface that assigns an
# attribute only the newer base declares compiles cleanly and then fails to load:
# "Failed to resolve typeattributeset statement". The xCAT-selinux %post ignores
# the failure, so xCAT runs with no module and httpd cannot read /tftpboot.
#
# corecmd_exec_bin assigns sys_resource_type from selinux-policy 42.1.27
# (EL 10.3), and init_telinit calls corecmd_exec_bin. The EL 10.2 base, 42.1.18,
# has no such attribute.
my %NEWER_ATTRIBUTE = (
    corecmd_exec_bin => 'sys_resource_type',
    init_telinit     => 'sys_resource_type',
);

my $te = "$FindBin::Bin/../../xCAT-selinux/xcat.te";
my @lines = read_lines($te);
cmp_ok(scalar(@lines), '>', 100, 'xcat.te was read');

my %calls;
for my $i (0 .. $#lines) {
    my $line = $lines[$i];
    next if $line =~ /^\s*#/;
    while ($line =~ /\b(\w+)\(/g) {
        push @{ $calls{$1} }, $i + 1;
    }
}
ok($calls{corecmd_exec_shell}, 'control: the scan finds the interface calls of xcat.te');

for my $iface (sort keys %NEWER_ATTRIBUTE) {
    is_deeply($calls{$iface} || [], [],
        "xcat.te does not call $iface, which assigns $NEWER_ATTRIBUTE{$iface} on a newer base only");
}

done_testing();
