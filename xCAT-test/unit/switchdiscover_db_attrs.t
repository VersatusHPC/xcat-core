#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use Test::More;

# switchdiscover -w writes each discovered switch with chdef. The type
# lookup and the chdef attributes live in xCAT::data::switchinfo, which
# loads without xCAT installed.

use xCAT::data::switchinfo;

my %catalyst = (
    'IOS'    => 'Cisco IOS Software, C2960X Software (C2960X-UNIVERSALK9-M), Version 15.2(7)E8, RELEASE SOFTWARE (fc1)',
    'IOS-XE' => 'Cisco IOS Software [Cupertino], Catalyst L3 Switch Software (CAT9K_IOSXE), Version 17.9.4a, RELEASE SOFTWARE (fc3)',
);
for my $os (sort keys %catalyst) {
    is(xCAT::data::switchinfo::switch_type($catalyst{$os}), 'Cisco', "a Catalyst $os sysDescr is a Cisco switch");
}
is(xCAT::data::switchinfo::switch_type('Linux xcat-mn 6.6.0-72.0.0.76.oe2403sp4.x86_64 #1 SMP x86_64'),
    undef, 'a Linux sysDescr is no switch type');

sub attrs {
    my %a = map { split /=/, $_, 2 } xCAT::data::switchinfo::discovered_switch_attrs(@_);
    return \%a;
}

my $sw = attrs(
    device    => 'switch',
    ip        => '192.0.2.250',
    mac       => '3e:cf:e0:04:eb:5b',
    vendor    => $catalyst{IOS},
    type      => 'Cisco',
    community => 'public',
);
is($sw->{switchtype}, 'Cisco', 'a switch gets switchtype');
is($sw->{nodetype},   'switch', 'a switch gets nodetype=switch');
is($sw->{ip},         '192.0.2.250', 'a switch gets its ip');
is($sw->{usercomment}, $catalyst{IOS}, 'a switch keeps its sysDescr in usercomment');
# chdef refuses community unless nodetype=pdu, and then writes no attribute
# at all. The SNMPv1 community of a switch is snmppassword (switches.password).
ok(!exists $sw->{community}, 'a switch gets no community attribute');
is($sw->{snmppassword}, 'public', 'a switch keeps its community in snmppassword');

my $pdu = attrs(
    device    => 'pdu',
    ip        => '192.0.2.251',
    mac       => '3e:cf:e0:04:eb:5c',
    vendor    => 'sLEN PDU',
    type      => 'irpdu',
    community => 'private',
);
is($pdu->{pdutype},   'irpdu',   'a pdu gets pdutype');
is($pdu->{community}, 'private', 'a pdu keeps its community');
ok(!exists $pdu->{switchtype}, 'a pdu gets no switchtype');

my $nocomm = attrs(device => 'switch', ip => '192.0.2.252', mac => ' ', vendor => 'Cisco', type => 'Cisco');
ok(!exists $nocomm->{snmppassword}, 'no community, no snmppassword attribute');

done_testing();
