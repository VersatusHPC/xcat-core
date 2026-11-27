package xCAT::DHCP::Backend::ISC;

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    return bless \%args, $class;
}

sub name {
    return 'isc';
}

sub implemented {
    return 1;
}

#-------------------------------------------------------------------------------

=head3 dhcp6_restart_needed

    Descriptions:
        Says whether makedhcp has to restart dhcpd6.

    Arguments:
        $class
        %args - changed: the configuration of dhcpd6 was replaced.
                ipv6:    the run serves an IPv6 network.

    Returns:
        1 when dhcpd6 has to be restarted, 0 otherwise.

=cut

#-------------------------------------------------------------------------------
sub dhcp6_restart_needed {
    my ( $class, %args ) = @_;

    # xCAT writes the dhcpd6 configuration only for an IPv6 network. Without one the file
    # stays absent, which the caller reads as a configuration to replace, and dhcpd6 has no
    # subnet to serve.
    return ( $args{changed} and $args{ipv6} ) ? 1 : 0;
}

#-------------------------------------------------------------------------------

=head3 dhcp6_stop_needed

    Descriptions:
        Says whether makedhcp has to stop dhcpd6 because no network is IPv6.
        Only Debian and Ubuntu start dhcpd6 when the package is installed.

    Arguments:
        $class
        %args - ipv6:   the run serves an IPv6 network.
                debian: the management node is Debian or Ubuntu.

    Returns:
        1 when dhcpd6 has to be stopped, 0 otherwise.

=cut

#-------------------------------------------------------------------------------
sub dhcp6_stop_needed {
    my ( $class, %args ) = @_;

    return ( $args{debian} and !$args{ipv6} ) ? 1 : 0;
}

#-------------------------------------------------------------------------------

=head3 config_declares_subnet

    Descriptions:
        Says whether a dhcpd.conf text declares a subnet. dhcpd exits at start
        with "Not configured to listen on any interfaces" when it declares none,
        which is the state before makedhcp -n runs.

    Arguments:
        $class
        $text - the content of dhcpd.conf, or undef when the file is absent.

    Returns:
        1 when the text declares a subnet, 0 otherwise.

=cut

#-------------------------------------------------------------------------------
sub config_declares_subnet {
    my ( $class, $text ) = @_;

    return 0 unless defined $text;
    return $text =~ /^\s*subnet6?\s+\S/m ? 1 : 0;
}

1;
