#!/usr/bin/perl
# rpm 4.11, which the SLE 12 family ships, cannot parse a boolean dependency at all:
#
#   error: Dependency tokens must begin with alpha-numeric, '_' or '/':
#          Requires: (/bin/bash or /usr/sbin/nosuchthing)
#
# So no "one of these two" requirement can be expressed in this spec, in any form, and the three
# that were written that way each have to be solved a different way. This test pins all three and
# refuses any new boolean dependency.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $spec = dirname(__FILE__) . '/../../xCAT/xCAT.spec';
open my $fh, '<', $spec or die "cannot read $spec: $!\n";
my $text = do { local $/; <$fh> };
close $fh;

# No boolean dependency anywhere. This is the rule the whole file exists for.
my @boolean = $text =~ /^(?:Requires|Recommends|Suggests|Conflicts):\s*(\(.*\))$/mg;
is_deeply(\@boolean, [],
    'no dependency in this spec is boolean: rpm 4.11 cannot parse one')
    or diag("these are unparseable on the SLE 12 family: @boolean");

# The time daemon needs no alternative: chrony ships on every rpm family this spec serves.
like($text, qr{^Requires:\s*/usr/sbin/chronyd\s*$}m,
    'the time daemon is a plain file requirement');

# The console backend keeps a HARD requirement through a capability both xcat-dep packages
# declare -- goconserver everywhere it can be built, conserver-xcat on the SLE 12 family.
like($text, qr{^Requires:\s*xcat-console-backend\s*$}m,
    'the console backend is required through a shared capability');

# The capability alone leaves the resolver free to pick either backend, and on the sles15 cell it
# picked conserver-xcat: makeconservercf ran /etc/init.d/conserver stop, which hung the run for
# 24 minutes. goconserver is the default everywhere it exists; a Recommends names it without
# making xCAT uninstallable on the SLE 12 family, where it is absent.
like($text, qr{^Recommends:\s*goconserver\s*$}m,
     'goconserver is recommended, so it is the backend wherever it exists');
unlike($text, qr{^Requires:.*\bgoconserver\b}m,
    '... and no longer names goconserver, which one family cannot build');
like($text, qr{^Conflicts:\s*goconserver\s*<\s*0\.3\.3-snap}m,
    '... while the version floor survives as a conflict');

# The DHCP server is the one guarantee that had to weaken, and it must stay visible as such.
like($text, qr{^Recommends:\s*/usr/sbin/dhcpd\s*$}m,  'dhcpd is recommended');
like($text, qr{^Recommends:\s*/usr/sbin/kea-dhcp4\s*$}m, 'kea is recommended for EL 10');
unlike($text, qr{^Requires:.*(?:dhcpd|kea-dhcp4)}m,
    '... and neither is a hard requirement, which no single family could satisfy');
like($text, qr/DELIBERATE WEAKENING/,
    'the weakening is marked in the spec so it is not mistaken for an oversight');

done_testing();
