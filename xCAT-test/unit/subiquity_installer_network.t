#!/usr/bin/env perl
#
# The Ubuntu 26.04 live installer starts DHCP on every en* and eth* NIC until Subiquity reads
# the autoinstall, so the management node logs "no free leases" for each *NOIP* NIC. xCAT puts a
# netplan configuration on the kernel command line that cloud-init writes before
# systemd-networkd starts. These checks merge that configuration with the file the installer
# ships, the way netplan does, and ask which NIC still runs DHCP.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

use JSON::PP;
use MIME::Base64 qw(decode_base64);
use Test::More;

use xCAT::SubiquityUtils;

my $INSTALL_MAC = '42:95:c0:a8:96:16';

# /etc/netplan/00-installer-config.yaml of ubuntu-26.04-live-server-ppc64el.iso and of the
# amd64 ISO, in the installer layer of the squashfs.
my %SHIPPED = (
    'zz-all-en'  => { match => { name => 'en*' },  dhcp4 => 1, dhcp6 => 1, 'accept-ra' => 1 },
    'zz-all-eth' => { match => { name => 'eth*' }, dhcp4 => 1, dhcp6 => 1, 'accept-ra' => 1 },
);

sub glob_match {
    my ($glob, $name) = @_;
    (my $re = quotemeta($glob)) =~ s/\\\*/.*/g;
    return $name =~ /\A$re\z/;
}

# netplan merges the definitions of one ID across files in file-name order, a later key
# replacing an earlier one. systemd-networkd then applies the first 10-netplan-<id>.network,
# in ID order, whose match fits the link.
sub effective {
    my ($link, @files) = @_;
    my %merged;
    foreach my $file (@files) {
        foreach my $id (keys %$file) {
            $merged{$id}{$_} = $file->{$id}{$_} for keys %{ $file->{$id} };
        }
    }
    foreach my $id (sort keys %merged) {
        my $m = $merged{$id}{match};
        next if defined($m->{name})       && !glob_match($m->{name}, $link->{name});
        next if defined($m->{macaddress}) && lc($m->{macaddress}) ne $link->{mac};
        return ($id, $merged{$id});
    }
    return;
}

sub runs_dhcp {
    my ($def) = @_;
    return 0 unless $def;
    return ($def->{dhcp4} || $def->{dhcp6} || $def->{'accept-ra'}) ? 1 : 0;
}

sub decoded_config {
    my ($arg) = @_;
    my ($b64) = $arg =~ /\A network-config=(\S+)\z/ or return;
    return JSON::PP->new->decode(decode_base64($b64));
}

my @links = (
    { name => 'enp0s1', mac => $INSTALL_MAC },
    { name => 'enp0s2', mac => '42:89:c0:a8:96:16' },
    { name => 'enp0s3', mac => '42:c7:c0:a8:96:16' },
    { name => 'eth0',   mac => '52:54:00:00:00:01' },
);

# The defect: with the shipped file alone, every NIC runs DHCP.
is( scalar(grep { runs_dhcp((effective($_, \%SHIPPED))[1]) } @links), scalar(@links),
    'the shipped installer config runs DHCP on every NIC' );

my $arg = xCAT::SubiquityUtils::installer_network_arg('ubuntu26.04', $INSTALL_MAC);
like( $arg, qr/\A network-config=[A-Za-z0-9+\/=]+\z/,
    'a 26.04 install gets one network-config= argument with no space or newline in its value' );

my $cfg = decoded_config($arg);
ok( $cfg, 'the argument decodes to a configuration' ) or die "no configuration\n";
is( $cfg->{version}, 2, 'the configuration is netplan version 2' );

my $cloudinit = $cfg->{ethernets};
my ($id, $def) = effective($links[0], \%SHIPPED, $cloudinit);
is( $id, 'xcat-install', 'the install NIC is configured by its own definition' );
ok( $def->{dhcp4} && $def->{dhcp6} && $def->{'accept-ra'},
    'and keeps DHCPv4, DHCPv6 and RA, as the shipped file gave it' );

foreach my $link (@links[ 1 .. $#links ]) {
    my ($lid, $ldef) = effective($link, \%SHIPPED, $cloudinit);
    ok( !runs_dhcp($ldef), "$link->{name} runs no DHCP and accepts no RA" )
      or diag("definition $lid");
    ok( $ldef->{optional}, "and the installer does not wait for $link->{name} to come online" );
}

# A NIC whose name the shipped file does not match stays unconfigured either way.
ok( !(effective({ name => 'ib0', mac => '00:00:00:00:00:02' }, \%SHIPPED, $cloudinit))[0],
    'a NIC outside en* and eth* gets no definition' );

is( xCAT::SubiquityUtils::installer_network_arg('ubuntu26.04', uc($INSTALL_MAC)), $arg,
    'an upper-case MAC gives the same argument' );
like( xCAT::SubiquityUtils::installer_network_arg('ubuntu26.04.1', $INSTALL_MAC),
    qr/network-config=/, 'a 26.04 point release gets the argument' );
like( xCAT::SubiquityUtils::installer_network_arg('ubuntu28.04', $INSTALL_MAC),
    qr/network-config=/, 'a later release gets the argument' );
is( xCAT::SubiquityUtils::installer_network_arg('ubuntu24.04', $INSTALL_MAC), '',
    'a 24.04 install, whose installer has no catch-all file, gets none' );
is( xCAT::SubiquityUtils::installer_network_arg('debian13', $INSTALL_MAC), '',
    'a Debian install gets none' );
is( xCAT::SubiquityUtils::installer_network_arg('ubuntu26.04', undef), '',
    'a node with no MAC gets none' );
is( xCAT::SubiquityUtils::installer_network_arg('ubuntu26.04', '42:95:c0:a8:96'), '',
    'a truncated MAC gets none' );

done_testing();
