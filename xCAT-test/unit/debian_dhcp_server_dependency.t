#!/usr/bin/env perl
# apt installs the FIRST alternative of a Depends group when none of them is installed, and it
# installs Recommends by default. site.dhcpbackend=auto selects ISC when dhcpd is installed and
# Kea otherwise, so the packages decide: isc-dhcp-server where the archive carries it, kea where
# it does not. An xcat or xcatsn install must bring exactly one DHCP server.
use strict;
use warnings;

use FindBin;
use Test::More;

my $root = "$FindBin::Bin/../..";

# Return the folded value of a control field of the binary stanza for $package.
sub binary_field {
    my ($text, $package, $name) = @_;
    for my $stanza (split /\n\s*\n/, $text) {
        next unless $stanza =~ /^Package:\s*\Q$package\E\s*$/m;
        return $1 if $stanza =~ /^\Q$name\E:[ \t]*(.*(?:\n[ \t]+.*)*)/m;
    }
    return;
}

# Return each dependency group of a field as a list of package names, in the order apt reads them.
sub dependency_groups {
    my ($field) = @_;
    $field =~ s/\n/ /g;
    my @groups;
    for my $dep (split /,/, $field) {
        my @names = map { /^\s*([A-Za-z0-9][A-Za-z0-9+.-]*)/ ? $1 : () } split /\|/, $dep;
        push @groups, \@names if @names;
    }
    return @groups;
}

for my $case ([ 'xCAT/debian/control', 'xcat' ], [ 'xCATsn/debian/control', 'xcatsn' ]) {
    my ($file, $package) = @$case;
    open my $fh, '<', "$root/$file" or die "read $file: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    my $depends = binary_field($text, $package, 'Depends');
    ok(defined $depends, "$file has a Depends field for $package") or next;

    my @dhcp = grep { my $g = $_; grep { $_ eq 'kea' || $_ eq 'isc-dhcp-server' } @$g } dependency_groups($depends);
    is(scalar @dhcp, 1, "$package names one DHCP server dependency group") or next;
    is($dhcp[0][0], 'isc-dhcp-server', "apt installs isc-dhcp-server first for a fresh $package install");
    ok((grep { $_ eq 'kea' } @{ $dhcp[0] }),
        "$package installs kea where the archive has no isc-dhcp-server");

    my $recommends = binary_field($text, $package, 'Recommends') // '';
    my @second = grep { my $g = $_; grep { $_ eq 'kea' || $_ eq 'isc-dhcp-server' } @$g }
        dependency_groups($recommends);
    is(scalar @second, 0, "$package does not recommend a second DHCP server");
}

done_testing();
