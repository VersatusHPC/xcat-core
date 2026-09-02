#!/usr/bin/env perl
# xCAT and xCATsn name their Debian architectures explicitly. An architecture missing from that
# list is not a build failure -- it is a package that never exists: apt on that architecture says
#
#   E: Unable to locate package xcat
#
# and the management node cannot be installed at all. riscv64 was missing while the rest of the
# tree already carried riscv64 install templates, DHCP boot policy and a Genesis machine config.
#
# The list is compared against the architectures the DEB build itself supports, taken from
# build-utils/lib/XCAT/BuildUtils or, failing that, the documented set.
use strict;
use warnings;

use FindBin;
use Test::More;

my $root = "$FindBin::Bin/../..";

# The Debian architectures xCAT ships. dpkg names, not rpm ones.
my @arches = qw(amd64 ppc64el riscv64);

my @controls = grep { -f } ("$root/xCAT/debian/control", "$root/xCATsn/debian/control");
plan skip_all => 'no Debian control files in this tree' unless @controls;

for my $ctl (@controls) {
    open my $fh, '<', $ctl or die "read $ctl: $!";
    local $/; my $text = <$fh>; close $fh;
    (my $short = $ctl) =~ s{^\Q$root\E/}{};
    my @lines = ($text =~ /^Architecture:\s*(.+)$/mg);
    my @explicit = grep { !/^(?:any|all)$/ } map { s/^\s+|\s+$//gr } @lines;
    ok(scalar(@explicit), "$short names architectures explicitly") or next;
    for my $line (@explicit) {
        my %have = map { $_ => 1 } split /\s+/, $line;
        my @missing = grep { !$have{$_} } @arches;
        is_deeply(\@missing, [], "$short covers @arches");
    }
}

# build-ubunturepo carries its own copy of the architecture list -- which arches the arch-specific
# packages are built for, the reprepro "Architectures:" line, and mklocalrepo.sh's uname-to-dpkg
# map. A control file that lists riscv64 while the builder does not produces no riscv64 deb and a
# repository whose Release says otherwise, which is what apt reports as "Unable to locate package
# xcat". The builder is a shell script with the list inline, so this checks the text.
{
    my $builder = "$root/build-ubunturepo";
    SKIP: {
        skip 'build-ubunturepo is not in this tree', scalar(@arches) unless -f $builder;
        open my $fh, '<', $builder or die "read $builder: $!";
        local $/; my $text = <$fh>; close $fh;
        for my $a (@arches) {
            ok($text =~ /\Q$a\E/, "build-ubunturepo knows the $a architecture");
        }
    }
}

done_testing();
