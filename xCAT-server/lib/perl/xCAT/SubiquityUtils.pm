#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

# The decisions that debian.pm makes for the Ubuntu live installer (Subiquity). This module
# loads no other xCAT module, so a unit test can call it from the source tree.

package xCAT::SubiquityUtils;

use strict;
use warnings;

use MIME::Base64 qw(encode_base64);

# The netplan IDs of the catch-all definitions in the /etc/netplan/00-installer-config.yaml
# of the Ubuntu 26.04 installer. netplan merges a definition with the same ID from a later
# file, so a definition with these IDs can switch them off.
my @INSTALLER_CATCHALL = ( [ 'zz-all-en', 'en*' ], [ 'zz-all-eth', 'eth*' ] );

#-------------------------------------------------------------------------------

=head3 installer_network_config

    Descriptions:
        The netplan configuration that the Ubuntu live installer uses until it reads the
        autoinstall. Only the install NIC is configured.

        The installer of Ubuntu 26.04 ships /etc/netplan/00-installer-config.yaml, which
        starts DHCP on every en* and eth* NIC. The DHCP runs from the first boot of the live
        system until Subiquity applies the network section of the autoinstall, so the
        management node logs "no free leases" for each *NOIP* NIC. The installer of 24.04
        has no such file.

        cloud-init reads this configuration from network-config= on the kernel command line
        and writes it to /etc/netplan/50-cloud-init.yaml, before systemd-networkd starts.
        That file sorts after 00-installer-config.yaml, so its zz-all-* definitions replace
        the DHCP keys of the shipped ones. The install NIC keeps the keys that the shipped
        file gives it. systemd-networkd applies the first .network file that matches a link,
        and 10-netplan-xcat-install sorts before 10-netplan-zz-all-*.

        Subiquity renames 50-cloud-init.yaml when it applies the autoinstall, so this
        configuration does not reach the installed system.

        The value is JSON, which cloud-init reads as YAML. The keys are in a fixed order,
        so the same node always gets the same command line.
    Arguments:
        $mac   the MAC address of the install NIC
    Returns:
        the configuration as a JSON string, or undef when $mac is not a MAC address
=cut

#-------------------------------------------------------------------------------
sub installer_network_config {
    my ($mac) = @_;

    return undef unless defined($mac);
    $mac = lc($mac);
    $mac =~ tr/-/:/;
    return undef unless $mac =~ /\A(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\z/;

    my @ethernets = (
        qq("xcat-install":{"match":{"macaddress":"$mac"},)
          . qq("dhcp4":true,"dhcp6":true,"accept-ra":true})
    );
    foreach my $catchall (@INSTALLER_CATCHALL) {
        my ($id, $glob) = @$catchall;
        push @ethernets,
          qq("$id":{"match":{"name":"$glob"},"dhcp4":false,"dhcp6":false,)
          . qq("accept-ra":false,"link-local":[],"optional":true});
    }

    return '{"version":2,"ethernets":{' . join(',', @ethernets) . '}}';
}

#-------------------------------------------------------------------------------

=head3 installer_ships_catchall

    Descriptions:
        Whether the live installer of an Ubuntu release ships the catch-all DHCP definitions
        that installer_network_config switches off. 26.04 is the first release that does.
    Arguments:
        $os    the os attribute of the osimage, for example ubuntu26.04 or ubuntu26.04.1
    Returns:
        1 or 0
=cut

#-------------------------------------------------------------------------------
sub installer_ships_catchall {
    my ($os) = @_;

    return 0 unless defined($os) && $os =~ /\Aubuntu(\d+)\.(\d+)/;
    return ($1 > 26 || ($1 == 26 && $2 >= 4)) ? 1 : 0;
}

#-------------------------------------------------------------------------------

=head3 installer_network_arg

    Descriptions:
        The network-config= argument for the kernel command line of a Subiquity install, with
        a leading space, or an empty string when the installer needs none.

        The argument must come before the "---" separator. The installer copies the arguments
        after "---" to the command line of the installed system, where cloud-init would
        read it again at every boot.
    Arguments:
        $os    the os attribute of the osimage
        $mac   the MAC address of the install NIC
    Returns:
        the argument, or an empty string
=cut

#-------------------------------------------------------------------------------
sub installer_network_arg {
    my ($os, $mac) = @_;

    return '' unless installer_ships_catchall($os);
    my $config = installer_network_config($mac);
    return '' unless defined($config);
    return ' network-config=' . encode_base64($config, '');
}

1;
