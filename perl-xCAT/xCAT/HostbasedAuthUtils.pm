#!/usr/bin/perl
# EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::HostbasedAuthUtils;

use strict;
use warnings;

# The decisions behind mkhostbased-auth: which host key types to publish, the
# names each host answers to, and the ssh_known_hosts and shosts.equiv lines.
# The subs take their inputs as arguments, so a unit test can load this module
# from the source tree without an xCAT installation.

our @KEY_TYPES = qw(rsa ecdsa ed25519);

#-------------------------------------------------------------------------------

=head3 allowed_key_types

    Descriptions:
        Selects the host key types that mkhostbased-auth publishes.
        OpenSSH in FIPS mode refuses ed25519 keys. DSA is never published:
        OpenSSH 7.0 and later turn it off by default.
    Arguments:
        $fips - true when the management node runs in FIPS mode
    Returns:
        the list of key types, in the order of @KEY_TYPES

=cut

#-------------------------------------------------------------------------------
sub allowed_key_types
{
    my ($fips) = @_;
    return grep { !($fips && $_ eq 'ed25519') } @KEY_TYPES;
}

#-------------------------------------------------------------------------------

=head3 key_type_of_file

    Descriptions:
        Returns the key type of a host public key file name.
    Arguments:
        $file - a file name such as ssh_host_ecdsa_key.pub
    Returns:
        the key type, or undef when the name is not a host public key

=cut

#-------------------------------------------------------------------------------
sub key_type_of_file
{
    my ($file) = @_;
    return undef unless defined $file;
    return $1 if $file =~ m{(?:^|/)ssh_host_([a-z0-9]+)_key\.pub\z};
    return undef;
}

#-------------------------------------------------------------------------------

=head3 host_entries

    Descriptions:
        Lists the names a node answers to: the short name, the FQDN and the IP
        addresses. sshd with UseDNS no matches the client by its address, so
        the address must be listed beside the names.
    Arguments:
        $node   - the node name
        $domain - the DNS domain, or undef
        @ips    - the IP addresses of the node
    Returns:
        the list of names, without duplicates, in that order

=cut

#-------------------------------------------------------------------------------
sub host_entries
{
    my ($node, $domain, @ips) = @_;
    my @names = ($node);
    if ($domain && $node !~ /\./) {
        push @names, "$node.$domain";
    }
    push @names, grep { defined && length } @ips;
    my %seen;
    return grep { !$seen{$_}++ } @names;
}

#-------------------------------------------------------------------------------

=head3 known_hosts_lines

    Descriptions:
        Renders the ssh_known_hosts lines for a set of hosts.
    Arguments:
        $hosts - array ref of { names => [...], keys => { type => "alg base64" } }
        $types - array ref of the key types to publish
    Returns:
        the list of lines, without a newline, one per host and key type

=cut

#-------------------------------------------------------------------------------
sub known_hosts_lines
{
    my ($hosts, $types) = @_;
    my @lines;
    foreach my $host (@$hosts) {
        my $names = join(',', @{ $host->{names} });
        foreach my $type (@$types) {
            my $key = $host->{keys}->{$type};
            next unless $key;

            # A .pub file ends with a comment; ssh_known_hosts takes the
            # algorithm and the key only.
            my ($alg, $blob) = split(/\s+/, $key);
            next unless $alg && $blob;
            push @lines, "$names $alg $blob";
        }
    }
    return @lines;
}

#-------------------------------------------------------------------------------

=head3 shosts_equiv_lines

    Descriptions:
        Renders shosts.equiv: every name of every host on its own line.
        OpenSSH ignores this file for root.
    Arguments:
        $hosts - array ref of { names => [...] }
    Returns:
        the list of lines, without duplicates

=cut

#-------------------------------------------------------------------------------
sub shosts_equiv_lines
{
    my ($hosts) = @_;
    my %seen;
    return grep { !$seen{$_}++ } map { @{ $_->{names} } } @$hosts;
}

#-------------------------------------------------------------------------------

=head3 scope_sets

    Descriptions:
        Splits nodes into trust scopes. A node in a zone belongs to the scope
        of that zone. A node in no zone belongs to the scope "default". A zone
        with sshbetweennodes set to no gives no scope.
    Arguments:
        $nodes   - array ref of node names
        $zone_of - hash ref, node => zone name
        $zone_sshbetweennodes - hash ref, zone name => sshbetweennodes value
    Returns:
        a hash ref, scope name => sorted array ref of nodes, and an array ref
        of the nodes that were left out

=cut

#-------------------------------------------------------------------------------
sub scope_sets
{
    my ($nodes, $zone_of, $zone_sshbetweennodes) = @_;
    my (%scopes, @left_out);
    foreach my $node (@$nodes) {
        my $zone = $zone_of->{$node};
        if (defined $zone && length $zone) {
            my $sbn = $zone_sshbetweennodes->{$zone};
            if (defined $sbn && $sbn =~ /^(no|0)$/i) {
                push @left_out, $node;
                next;
            }
            push @{ $scopes{$zone} }, $node;
        } else {
            push @{ $scopes{default} }, $node;
        }
    }
    $_ = [ sort @$_ ] foreach values %scopes;
    return (\%scopes, [ sort @left_out ]);
}

#-------------------------------------------------------------------------------

=head3 postbootscripts_with

    Descriptions:
        Returns a node's postbootscripts value with the confighostbasedauth
        entry set to the given scope, or removed when the scope is undef.
    Arguments:
        $current - the current postbootscripts value, or undef
        $scope   - the scope name, or undef to remove the entry
    Returns:
        the new postbootscripts value

=cut

#-------------------------------------------------------------------------------
sub postbootscripts_with
{
    my ($current, $scope) = @_;
    my @scripts = grep { length && !/^confighostbasedauth(\s|$)/ }
      map { s/^\s+|\s+$//gr } split(/,/, defined $current ? $current : '');
    push @scripts, "confighostbasedauth $scope" if defined $scope;
    return join(',', @scripts);
}

1;
