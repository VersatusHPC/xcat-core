package xCAT::DHCP::Backend;

use strict;
use warnings;

use xCAT::CommandUtils;
use xCAT::StringUtils qw(trim);

my %valid_backend = map { $_ => 1 } qw(auto isc kea);

sub normalize {
    my ( $class, $backend ) = @_;

    $backend = 'auto' unless defined($backend) && $backend ne '';
    $backend = trim($backend);
    $backend = lc($backend);

    return $backend if $valid_backend{$backend};
    return;
}

sub choose {
    my ( $class, %args ) = @_;

    my $requested = exists $args{requested} ? $args{requested} : $class->_site_backend();
    my $normalized = $class->normalize($requested);

    unless ($normalized) {
        return {
            error => "Invalid site.dhcpbackend value '$requested'. Valid values are auto, isc, and kea.",
        };
    }

    my $selected = $normalized eq 'auto' ? $class->default_backend(%args) : $normalized;

    if ( $args{check_available} && !$class->available( $selected, %args ) ) {
        my $error = $normalized eq 'auto'
          ? "No DHCP server is installed. Install ISC DHCP (dhcpd) or Kea (kea-dhcp4)."
          : "The selected DHCP backend '$selected' is not available on this system.";
        return {
            requested => $normalized,
            name      => $selected,
            error     => $error,
        };
    }

    return {
        requested => $normalized,
        name      => $selected,
    };
}

#--------------------------------------------------------------------------------

=head3 default_backend

    Descriptions:
        Select the backend for site.dhcpbackend=auto. ISC wins whenever its server
        is installed, and Kea is used otherwise. The packages decide, not the platform:
        EL10 ships only Kea, and the Ubuntu metapackage installs ISC where the
        archive carries it.
    Arguments:
        available => { isc => 0|1 } overrides the probe for dhcpd (optional).
    Returns:
        'isc' or 'kea'.

=cut

#--------------------------------------------------------------------------------
sub default_backend {
    my ( $class, %args ) = @_;

    return $class->available( 'isc', %args ) ? 'isc' : 'kea';
}

sub available {
    my ( $class, $backend, %args ) = @_;

    if ( exists $args{available} && ref( $args{available} ) eq 'HASH' && exists $args{available}{$backend} ) {
        return $args{available}{$backend} ? 1 : 0;
    }

    if ( $backend eq 'isc' ) {
        return _command_exists('dhcpd');
    } elsif ( $backend eq 'kea' ) {
        return _command_exists('kea-dhcp4');
    }

    return 0;
}

sub backend_class {
    my ( $class, $backend ) = @_;

    return 'xCAT::DHCP::Backend::ISC' if $backend eq 'isc';
    return 'xCAT::DHCP::Backend::Kea' if $backend eq 'kea';
    return;
}

sub new_backend {
    my ( $class, %args ) = @_;

    my $selection = $class->choose(%args);
    return $selection if $selection->{error};

    my $backend_class = $class->backend_class( $selection->{name} );
    my $loaded = eval {
        if ( $selection->{name} eq 'isc' ) {
            require xCAT::DHCP::Backend::ISC;
        } elsif ( $selection->{name} eq 'kea' ) {
            require xCAT::DHCP::Backend::Kea;
        } else {
            die "Unknown DHCP backend '$selection->{name}'";
        }
        1;
    };
    if (!$loaded) {
        return {
            %$selection,
            error => "Unable to load DHCP backend '$selection->{name}': $@",
        };
    }

    return $backend_class->new( selection => $selection );
}

sub _site_backend {
    my $backend = eval {
        require xCAT::TableUtils;
        return xCAT::TableUtils->get_site_attribute('dhcpbackend', 'auto');
    };

    return $backend || 'auto';
}

sub _command_exists {
    my ($command) = @_;
    return xCAT::CommandUtils::find_executable($command) ? 1 : 0;
}

1;
