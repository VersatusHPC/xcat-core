#!/usr/bin/env perl
# apt installs the FIRST alternative of a Depends group when none of them is installed, and it
# does not count Recommends when it chooses. xCAT selects Kea on every Ubuntu release it builds
# for (22.04 and later), so an xcat or xcatsn install must not bring isc-dhcp-server: its units
# start with no interface configured and stay failed while Kea serves DHCP.
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
    is($dhcp[0][0], 'kea', "apt installs kea, not isc-dhcp-server, for a fresh $package install");
    ok((grep { $_ eq 'isc-dhcp-server' } @{ $dhcp[0] }),
        "$package still accepts an installed isc-dhcp-server for site.dhcpbackend=isc");
}

done_testing();
