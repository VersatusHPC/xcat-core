#!/usr/bin/perl
# EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::FIPS;

use strict;
use warnings;

# Node FIPS mode, set by the osimage attribute fips (linuximage.fips).
# xCAT supports it for EL 9 and EL 10 x86_64 diskful installs. The installer
# runs with fips=1 on its kernel line, and Anaconda installs the node in FIPS
# mode.

our $EL_FIPS_OS = qr/^(?:rhels|rhel|alma|rocky|ol|centos-stream|centos)(?:9|10)(?:\.\d+)?$/;

#-----------------------------------------------------------------------------

=head3 wanted

    Arguments:
        value - the osimage fips value
    Returns:
        1 when the value asks for FIPS mode (1, yes, y, true), else 0

=cut

#-----------------------------------------------------------------------------
sub wanted {
    my ($class, $value) = @_;
    return 0 unless defined $value;
    return ($value =~ /^\s*(?:1|y|yes|true)\s*$/i) ? 1 : 0;
}

#-----------------------------------------------------------------------------

=head3 node_fips_supported

    Arguments:
        osver      - the osimage osvers, such as alma9.8
        arch       - the osimage osarch
        provmethod - install, netboot or statelite
    Returns:
        (1, undef) when xCAT can install the node in FIPS mode, else
        (0, the reason)

=cut

#-----------------------------------------------------------------------------
sub node_fips_supported {
    my ($class, $osver, $arch, $provmethod) = @_;
    $osver      = '' unless defined $osver;
    $arch       = '' unless defined $arch;
    $provmethod = '' unless defined $provmethod;

    return (0, "$provmethod nodes: diskless node FIPS mode is not supported")
      if $provmethod eq 'netboot';
    return (0, "statelite nodes: node FIPS mode is not supported")
      if $provmethod eq 'statelite';
    return (0, "$osver: node FIPS mode is supported on EL 9 and EL 10 only")
      unless $osver =~ $EL_FIPS_OS;
    return (0, "$arch: node FIPS mode is supported on x86_64 only")
      unless $arch eq 'x86_64';
    return (1, undef);
}

#-----------------------------------------------------------------------------

=head3 kcmdline_fips

    Arguments:
        value      - the osimage fips value
        osver, arch, provmethod - as for node_fips_supported
    Returns:
        (the installer kernel argument, undef). The argument is '' when the
        osimage does not ask for FIPS mode.
        (undef, the reason) when the osimage asks for FIPS mode and the node
        does not support it.

=cut

#-----------------------------------------------------------------------------
sub kcmdline_fips {
    my ($class, $value, $osver, $arch, $provmethod) = @_;
    return ('', undef) unless $class->wanted($value);
    my ($ok, $why) = $class->node_fips_supported($osver, $arch, $provmethod);
    return (undef, $why) unless $ok;
    return ('fips=1', undef);
}

1;
