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

1;
