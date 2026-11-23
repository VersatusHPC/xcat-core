# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

#This module includes some glocal table to look up the switch type via mac and vendor

package xCAT::data::switchinfo;

require Exporter;
@ISA       = qw(Exporter);
@EXPORT    = qw();
@EXPORT_OK = qw(global_mac_identity global_switch_type);

use strict;

#the hash to look up switch type with MAC
our %global_mac_identity = (
    "a8:97:dc" => "BNT G8052 switch",
    "6c:ae:8b" => "BNT G8264-T switch",
    "fc:cf:62" => "BNT G8124 switch",
    "7c:fe:90" => "Mellanox IB switch",
    "cc:37:ab" => "Edgecore Networks Switch",
    "8c:ea:1b" => "Edgecore Networks Switch",
    "a8:2b:b5" => "Edgecore Networks Switch",
    "3c:2c:99" => "Edgecore Networks Switch",
    "70:72:cf" => "Edgecore Networks Switch",
    "80:a2:35" => "Edgecore Networks Switch",
    "b8:6a:97" => "Edgecore Networks Switch",
    "6c:64:1a" => "Penguin Computing switch"
);

#the hash to lookup switch type with vendor
our %global_switch_type = (
    Juniper => "Juniper",
    juniper => "Juniper",
    Cisco => "Cisco",
    cisco => "Cisco",
    BNT => "BNT",
    Blade => "BNT",
    G8052 => "BNT",
    RackSwitch => "BNT",
    Mellanox => "Mellanox",
    mellanox => "Mellanox",
    MLNX => "Mellanox",
    MELLAN => "Mellanox",
    Cumulus => "onie",
    cumulus => "onie",
    Edgecore => "onie",
    sLEN => "irpdu",
    sIBM => "irpdu",
    coral => "crpdu",
    Dell => "Dell",
    dell => "Dell"
);

#-------------------------------------------------------------------------------

=head3 switch_type

    Descriptions: Map the sysDescr of a device to an xCAT switch type.
    Arguments:    the sysDescr string
    Returns:      the type from %global_switch_type, or undef

=cut

#-------------------------------------------------------------------------------
sub switch_type {
    my ($vendor) = @_;
    return undef unless defined $vendor;
    my $search_string = join '|', map { quotemeta } keys(%global_switch_type);
    if ($vendor =~ /($search_string)/) {
        return $global_switch_type{$1};
    }
    return undef;
}

#-------------------------------------------------------------------------------

=head3 discovered_switch_attrs

    Descriptions: The chdef attributes for a device that switchdiscover found.
    Arguments:    hash: device (switch or pdu), ip, mac, vendor, type, community
    Returns:      a list of attr=value strings

=cut

#-------------------------------------------------------------------------------
sub discovered_switch_attrs {
    my (%d) = @_;
    my @attrs = ("groups=$d{device}", "ip=$d{ip}", "mac=$d{mac}",
        "nodetype=$d{device}", "mgt=$d{device}", "usercomment=$d{vendor}");

    # chdef refuses community unless nodetype=pdu, and then writes nothing.
    # A switch keeps its SNMPv1 community in snmppassword (switches.password).
    if ($d{device} eq 'pdu') {
        push @attrs, "pdutype=$d{type}";
        push @attrs, "community=$d{community}" if defined $d{community};
    } else {
        push @attrs, "switchtype=$d{type}";
        push @attrs, "snmppassword=$d{community}" if defined $d{community};
    }
    return @attrs;
}

1;
