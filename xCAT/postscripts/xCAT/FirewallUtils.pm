#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::FirewallUtils;

# The decisions of configfirewall. It ships beside the postscript, because a compute node has
# no perl-xCAT, and it loads no other xCAT module.

use strict;
use warnings;
use Socket qw(AF_INET AF_INET6 inet_pton);

our @DEFAULT_PORTS = qw(22 53 69 80 443 873 3001 3002);
our $MARKER        = '/etc/xcat/configfirewall.backend';
our $NAT_POLICY    = 'xcat-nat';

#---
# =head3 backend
# Descriptions: The firewall backend that configfirewall uses on this node.
# Arguments: hash with the booleans redhat, openeuler, suse, ubuntu, firewalld_unit
# Returns: firewalld, iptables, suse, ubuntu, or undef for an unknown OS
# =cut
#---
sub backend
{
    my (%os) = @_;
    if ($os{redhat} || $os{openeuler}) {
        return $os{firewalld_unit} ? 'firewalld' : 'iptables';
    }
    return 'suse'   if $os{suse};
    return 'ubuntu' if $os{ubuntu};
    return undef;
}

#---
# =head3 port_list
# Descriptions: The ports configfirewall opens on the public NIC: the xCAT ports, then the
#               extra ports in their order, each one once.
# Arguments: $extra -- comma-separated ports, or undef
# Returns: the list of ports
# =cut
#---
sub port_list
{
    my ($extra) = @_;
    my @ports = @DEFAULT_PORTS;
    my %seen = map { $_ => 1 } @ports;
    foreach my $p (split /,/, (defined $extra ? $extra : '')) {
        $p =~ s/^\s+|\s+$//g;
        next if $p eq '' or $seen{$p}++;
        push @ports, $p;
    }
    return @ports;
}

#---
# =head3 zone_plan
# Descriptions: The firewalld zone of each NIC. A private NIC goes to trusted, which accepts
#               DHCP, DHCPv6, ICMPv6 and router advertisements. A NIC that is both public and
#               private is the only path to the cluster, so it stays trusted.
# Arguments: $private -- array ref of NICs, $public -- the public NIC or undef
# Returns: hash ref { trusted => [NICs], public => [NICs] }
# =cut
#---
sub zone_plan
{
    my ($private, $public) = @_;
    my %seen;
    my @trusted = grep { defined && $_ ne '' && !$seen{$_}++ } @{ $private || [] };
    my @public = (defined $public && $public ne '' && !$seen{$public}) ? ($public) : ();
    return { trusted => \@trusted, public => \@public };
}

#---
# =head3 nat_plan
# Descriptions: The NAT settings: masquerade on the zone of the public NIC, and a policy that
#               forwards from trusted to that zone.
# Arguments: $plan -- the zone_plan result
# Returns: hash ref { masquerade_zone => zone, policy => name, ingress => zone, egress => zone },
#          or undef when there is no public NIC to masquerade out of
# =cut
#---
sub nat_plan
{
    my ($plan) = @_;
    return undef unless $plan && @{ $plan->{public} || [] };
    return {
        masquerade_zone => 'public',
        policy          => $NAT_POLICY,
        ingress         => 'trusted',
        egress          => 'public',
    };
}

#---
# =head3 firewalld_commands
# Descriptions: The firewall-cmd argument lists for a plan. Every change is permanent and
#               only adds, so ports and services that other tools opened stay open.
# Arguments: $plan -- the zone_plan result, $ports -- array ref of ports, $nat -- nat_plan or undef
# Returns: list of array refs, each one the arguments of one firewall-cmd call
# =cut
#---
sub firewalld_commands
{
    my ($plan, $ports, $nat) = @_;
    my @cmds;
    foreach my $zone (qw(trusted public)) {
        foreach my $nic (@{ $plan->{$zone} || [] }) {
            push @cmds, [ '--permanent', "--zone=$zone", "--change-interface=$nic" ];
        }
    }
    if (@{ $plan->{public} || [] }) {
        foreach my $p (@{ $ports || [] }) {
            push @cmds, [ '--permanent', '--zone=public', "--add-port=$p/tcp", "--add-port=$p/udp" ];
        }
    }
    if ($nat) {
        push @cmds, [ '--permanent', "--zone=$nat->{masquerade_zone}", '--add-masquerade' ];
        push @cmds, [ '--permanent', "--new-policy=$nat->{policy}" ];
        push @cmds, [ '--permanent', "--policy=$nat->{policy}", "--add-ingress-zone=$nat->{ingress}" ];
        push @cmds, [ '--permanent', "--policy=$nat->{policy}", "--add-egress-zone=$nat->{egress}" ];
        push @cmds, [ '--permanent', "--policy=$nat->{policy}", '--set-target=ACCEPT' ];
    }
    return @cmds;
}

#---
# =head3 networks_from_env
# Descriptions: The networks a postscript gets from mypostscript, NETWORKS_LINE1 to
#               NETWORKS_LINE<NETWORKS_LINES>.
# Arguments: $env -- hash ref, usually \%ENV
# Returns: list of hash refs { net => ..., mask => ... }
# =cut
#---
sub networks_from_env
{
    my ($env) = @_;
    my @nets;
    my $count = $env->{NETWORKS_LINES} || 0;
    foreach my $i (1 .. $count) {
        my $line = $env->{"NETWORKS_LINE$i"};
        next unless defined $line;
        my %f = map { my ($k, $v) = split /=/, $_, 2; ($k => $v) } split /\|\|/, $line;
        push @nets, { net => $f{net}, mask => $f{mask} } if $f{net};
    }
    return @nets;
}

#---
# =head3 networks_from_tabdump
# Descriptions: The networks in the output of "tabdump networks".
# Arguments: @lines -- the output lines, the header first
# Returns: list of hash refs { net => ..., mask => ... }
# =cut
#---
sub networks_from_tabdump
{
    my (@lines) = @_;
    my $header = shift @lines;
    return () unless defined $header;
    $header =~ s/^#//;
    my @cols = split /,/, $header;
    my ($inet)  = grep { $cols[$_] eq 'net' } 0 .. $#cols;
    my ($imask) = grep { $cols[$_] eq 'mask' } 0 .. $#cols;
    return () unless defined $inet and defined $imask;
    my @nets;
    foreach my $l (@lines) {
        chomp $l;
        next if $l =~ /^\s*$/;
        my @v = map { s/^"|"$//g; $_ } split /,/, $l;
        push @nets, { net => $v[$inet], mask => $v[$imask] } if $v[$inet];
    }
    return @nets;
}

sub _prefix_len
{
    my ($mask, $bits) = @_;
    return undef unless defined $mask and $mask ne '';
    $mask =~ s{^/}{};
    return $mask if $mask =~ /^\d+$/ and $mask <= $bits;
    my $packed = inet_pton(AF_INET, $mask) or return undef;
    my $len = unpack('%32b*', $packed);
    return $len;
}

sub _in_net
{
    my ($addr, $net, $mask) = @_;
    my $family = $addr =~ /:/ ? AF_INET6 : AF_INET;
    my $bits   = $family == AF_INET6 ? 128 : 32;
    my $netaddr = $net;
    if ($netaddr =~ m{^(.*)/(\d+)$}) {
        ($netaddr, $mask) = ($1, $2);
    }
    return 0 if ($netaddr =~ /:/ ? AF_INET6 : AF_INET) != $family;
    my $len = _prefix_len($mask, $bits);
    return 0 unless defined $len;
    my $a = inet_pton($family, $addr)    or return 0;
    my $n = inet_pton($family, $netaddr) or return 0;
    my $m = pack("B$bits", ('1' x $len) . ('0' x ($bits - $len)));
    return (($a & $m) eq ($n & $m)) ? 1 : 0;
}

#---
# =head3 private_nics
# Descriptions: The NICs with an address in one of the xCAT networks. configfirewall --auto
#               makes these the private NICs.
# Arguments: $nets -- array ref of { net, mask }, $addrs -- hash ref NIC => [addresses]
# Returns: the NICs, sorted
# =cut
#---
sub private_nics
{
    my ($nets, $addrs) = @_;
    my @nics;
    foreach my $nic (sort keys %{ $addrs || {} }) {
        next if $nic eq 'lo';
      ADDR: foreach my $a (@{ $addrs->{$nic} }) {
            foreach my $n (@{ $nets || [] }) {
                if (_in_net($a, $n->{net}, $n->{mask})) {
                    push @nics, $nic;
                    last ADDR;
                }
            }
        }
    }
    return @nics;
}

1;
