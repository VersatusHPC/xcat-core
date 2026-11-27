#!/usr/bin/env perl
# switchdiscover -s snmp runs /usr/bin/snmpwalk, so the xCAT metapackage has to install it.
#
# switchdiscover.pm tests "-x /usr/bin/snmpwalk" and otherwise answers "snmpwalk is not
# available". configMellanox and configBNT run snmpwalk too. The RPM names the file, because
# the package that carries it differs: net-snmp-utils on EL, net-snmp on openSUSE. Debian and
# Ubuntu ship it in snmp.
#
# The manifests are the artifact here, so they are read rather than executed.
use strict;
use warnings;

use File::Slurper qw(read_text);
use File::Spec;
use FindBin;
use Test::More;

my $root = File::Spec->catdir( $FindBin::Bin, '..', '..' );

my $spec = read_text( File::Spec->catfile( $root, 'xCAT', 'xCAT.spec' ) );
like( $spec, qr{^Requires:\s*/usr/bin/snmpwalk\s*$}m,
    'xCAT requires /usr/bin/snmpwalk' );

my $control = read_text( File::Spec->catfile( $root, 'xCAT', 'debian', 'control' ) );
my ($stanza) = $control =~ /^(Package:\s*xcat\s*\n.*?)(?:\n\n|\z)/ms;
ok( defined($stanza), 'debian/control has a stanza for xcat' );
my ($depends) = ( $stanza // '' ) =~ /^Depends:\s*(.*)$/m;
ok( defined($depends), 'xcat has a Depends line' );
# A Recommends is not enough: the apt 3.0 solver drops them.
like( $depends // '', qr/(?:^|,)\s*snmp\s*(?:,|$)/,
    'xcat depends on snmp, not merely recommends it' );

done_testing();
