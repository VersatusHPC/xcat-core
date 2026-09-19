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
like($r, qr/goconserver[^)]*\bor\b[^)]*conserver-xcat/,
    'goconserver is named first, with conserver-xcat as the alternative');
like($r, qr/goconserver >= /,        'the goconserver version floor is kept');

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
    like($sel // '', qr{\Q(/usr/sbin/dhcpd or kea)\E},
        '... as an alternative, dhcpd first so kea is the EL 10 fallback');
    unlike($text, qr/^Requires:.*kea-hooks/m,
        'kea-hooks is not a hard requirement: it exists only beside kea');
}

done_testing();
