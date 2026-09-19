#!/usr/bin/perl
# xCAT needs a console backend, and which one exists depends on the family. goconserver's go.mod
# asks for Go 1.25; the SLE 12 family never had a toolchain near that, so it builds conserver-xcat
# instead. A hard "Requires: goconserver" makes xCAT uninstallable there.
#
# It cannot be a build-time %if either: one flat core is built on EL and installed on every
# family, so %{?suse_version} describes the builder rather than the node. The requirement has to
# name both and let the resolver choose, with goconserver first so it wins where it exists.
#
# The spec IS the artifact -- this is a packaging contract with nothing to execute.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $spec = dirname(__FILE__) . '/../../xCAT/xCAT.spec';
open my $fh, '<', $spec or die "cannot read $spec: $!\n";
my $text = do { local $/; <$fh> };
close $fh;

my @req = $text =~ /^(Requires:.*goconserver.*)$/mg;
is(scalar(@req), 1, 'the console backend is required exactly once');
my $r = $req[0] // '';

like($r, qr/^\QRequires: (\E/,       'it is a boolean dependency, resolved at install time');
like($r, qr{\Q(/usr/bin/goconserver or /usr/sbin/conserver)\E},
    'both backends are named by file, goconserver first');
like($text, qr/^Conflicts:\s*goconserver\s*<\s*0\.3\.3-snap/m,
    'the version floor survives as a conflict, since a file capability carries none');

# A build-time conditional would silently bake the BUILDER's family into a package installed on
# every family, which is the defect this replaces.
unlike($text, qr/%if.*suse_version.*\n\s*Requires:.*goconserver/,
    'the choice is not made by a build-time conditional');

# The DHCP backend has the same shape of problem and the same constraint: libsolv 0.6, which the
# SLE 12 family uses, parses a plain alternative but not a conditional. A conditional dependency
# is quoted whole as a package name and the install fails.
{
    my @dhcp = $text =~ /^(Requires:.*(?:dhcpd|\bkea\b).*)$/mg;
    my ($sel) = grep { /dhcpd/ } @dhcp;
    ok(defined $sel, 'the DHCP backend is required');
    unlike($sel // '', qr/\bif\b/, '... without a conditional libsolv 0.6 cannot parse');
    like($sel // '', qr{\Q(/usr/sbin/dhcpd or /usr/sbin/kea-dhcp4)\E},
        '... as a file alternative, dhcpd first so kea is the EL 10 fallback');
    unlike($text, qr/^Requires:.*kea-hooks/m,
        'kea-hooks is not a hard requirement: it exists only beside kea');
}

# The time daemon has the same constraint, found the hard way: named as package names,
# "(chrony or ntp)" is refused on the SLE 12 family even where chrony is installable, while the
# file-capability alternative in the same package resolves on the same node. Name the files.
{
    my ($ntpreq) = $text =~ /^(Requires:.*(?:chronyd|chrony\b).*)$/m;
    ok(defined $ntpreq, 'a time daemon is required');
    like($ntpreq // '', qr{\Q(/usr/sbin/chronyd or /usr/sbin/ntpd)\E},
        '... by file capability, which the SLE 12 resolver accepts');
    unlike($text, qr/^Requires:\s*\(chrony or ntp\)/m,
        '... not by package name, which it refuses');
}

# The rule this family forced: a boolean dependency whose operand is a package name that exists
# in no repository is refused there, while an absent FILE operand is merely unprovided. Every
# alternative in this spec must therefore name files on both sides.
{
    my @alts = $text =~ /^Requires:\s*(\([^)]*\bor\b[^)]*\))/mg;
    ok(scalar(@alts) >= 3, 'the spec carries the expected alternatives');
    my @named = grep { !m{^\(\s*/} || m{\bor\s+(?!/)} } @alts;
    is_deeply(\@named, [], 'no alternative names a package instead of a file')
        or diag("these would be refused on the SLE 12 family: @named");
}

done_testing();
