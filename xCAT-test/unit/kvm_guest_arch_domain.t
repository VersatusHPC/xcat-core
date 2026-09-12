#!/usr/bin/env perl
# mkvm builds the libvirt domain in build_xmldesc, which starts from an x86 domain and changes it
# for a pseries guest from the cpu model of the HYPERVISOR. Nothing reads nodetype.arch, so a
# riscv64 node on an x86_64 host is defined as an x86_64 guest. In build 113 of xcat-core-devel-cd
# xcat56-cn came up as pc-i440fx with iPXE, fetched its riscv64 grub2 over tftp and reported
# "Could not boot image: Exec format error", then "No bootable device".
#
# _apply_guest_arch is the last thing build_xmldesc does before it serialises the domain. This test
# extracts it, runs it over a domain hash of the shape build_xmldesc holds at that point, and reads
# the XML that XML::Simple then emits -- the same text libvirt receives.
use strict;
use warnings;

use FindBin;
use Test::More;
use XML::Simple;

my $source = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/kvm.pm";
open(my $source_fh, '<', $source) or die "open $source: $!";
my $content = do { local $/; <$source_fh> };
close($source_fh) or die "close $source: $!";

my ($routine) = $content =~ /^(sub _apply_guest_arch\s*\{.*?^\})/ms;
BAIL_OUT('could not extract _apply_guest_arch from kvm.pm') unless $routine;
eval $routine;    ## no critic (BuiltinFunctions::ProhibitStringyEval)
BAIL_OUT("could not load _apply_guest_arch: $@") if $@;

#-----------------------------------------------------------------------------------------------
=head3 x86_domain

Descriptions:
    A domain hash of the shape build_xmldesc holds just before it serialises: the x86 defaults it
    builds for every guest that is not a pseries one.
Arguments:
    None.
Returns:
    A hash reference.
=cut
#-----------------------------------------------------------------------------------------------
sub x86_domain {
    return {
        type => 'kvm',
        name => { content => 'cn1' },
        os   => {
            type => { content => 'hvm' },
            bios => { useserial => 'yes' },
            boot => [ { dev => 'network' }, { dev => 'hd' } ],
        },
        features => { pae => {}, acpi => {}, apic => {}, content => "\n" },
        devices  => {
            disk      => [ { type => 'file', device => 'disk',
                             target => { dev => 'sda', bus => 'scsi' } } ],
            interface => [ { type => 'bridge', source => { bridge => 'br0' },
                             model => { type => 'virtio' } } ],
            sound    => { model => 'ich6' },
            video    => [ { content => '', model => { type => 'vga', vram => 8192 } } ],
            graphics => { type => 'vnc', autoport => 'yes' },
            input    => { type => 'tablet', bus => 'usb' },
            console  => { type => 'pty', target => { port => '1' } },
        },
    };
}

sub domain_xml {
    my ($arch) = @_;
    my $tree = x86_domain();
    _apply_guest_arch($tree, $arch);
    return XMLout($tree, RootName => 'domain');
}

# riscv64: the guest QEMU must emulate, on the machine and firmware that boot it.
my $riscv = domain_xml('riscv64');
like($riscv, qr/<domain[^>]*\btype="qemu"/,
    'a riscv64 guest is a qemu domain, because no host in this project runs riscv64 KVM');
like($riscv, qr/<type\b[^>]*\barch="riscv64"/, 'the domain declares the riscv64 guest arch');
like($riscv, qr/<type\b[^>]*\bmachine="virt"/, 'the domain declares the riscv64 virt machine');
like($riscv, qr/<os\b[^>]*\bfirmware="efi"/,
    'the domain boots through EDK2, which is what loads the riscv64 grub2');
unlike($riscv, qr/<bios\b/, 'the riscv64 virt machine has no BIOS element');
unlike($riscv, qr/<(?:pae|acpi|apic)\b/, 'the x86 cpu features are gone');
unlike($riscv, qr/<(?:sound|video|graphics|input)\b/,
    'the x86 devices with no riscv64 counterpart are gone');
like($riscv, qr/<console\b/, 'the serial console stays, it is the only console this guest has');
like($riscv, qr/<boot\b[^>]*\bdev="network"/, 'the guest still boots from the network first');

# Every other architecture keeps the domain build_xmldesc already produced.
for my $arch (qw(x86_64 ppc64le), undef) {
    my $name = defined $arch ? $arch : 'an undefined arch';
    my $xml  = domain_xml($arch);
    is($xml, XMLout(x86_domain(), RootName => 'domain'), "$name leaves the domain unchanged");
}

done_testing();
