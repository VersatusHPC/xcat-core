# Render a FreeBSD installer configuration with xCAT::FreeBSDConfig, the producer the
# installer shell library consumes. The bats tests of that library take their input here.
#
#   perl freebsd-render-config.pl '<json>'
#
# json keys, all optional:
#   disk     overrides of the disk settings
#   options  the boot option string; console the serial policy hash
#   omit     disk settings removed before boot_settings
#   contract the media install contract (default xcat-freebsd-install-3, null for none)
#   media    overrides of the boot media
#   set      settings merged after boot_settings; delete settings removed after it
#   output   render (default), loader, or legacy for the distribution format
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../../perl-xCAT";
use lib "$FindBin::Bin/../../../xCAT-server/lib/perl";
use JSON;
use MIME::Base64 qw(encode_base64);
use xCAT::FreeBSDConfig;

my $spec = decode_json($ARGV[0] // '{}');
my $media = { format => 'xcat-mfsbsd-2', release => '15.1-RELEASE', arch => 'x86_64',
    digest => 'a' x 64, files => { 'xcat/runtime.tsv' => 'b' x 64 },
    install_contract => exists($spec->{contract}) ? $spec->{contract} : 'xcat-freebsd-install-3',
    %{ $spec->{media} || {} } };
delete $media->{install_contract} unless defined($media->{install_contract});
my $network = { master => '192.0.2.1', port => '3002', mac => '52:54:00:12:34:56',
    ipv4 => '192.0.2.10', netmask => '255.255.255.0', gateway => '192.0.2.1',
    hostname => 'node1.example.test', nameservers => '192.0.2.1', install_url => 'http://192.0.2.1/install' };
my $disk = { target_disk => 'vtbd0', target_disk_ident => 'TEST_DISK', filesystem => 'ufs',
    swap_size => '0', authorized_key_base64 => encode_base64("ssh-ed25519 AAAA\n", ''),
    %{ $spec->{disk} || {} } };
delete @$disk{ @{ $spec->{omit} || [] } };
if (($spec->{output} // 'render') eq 'legacy') {
    my %legacy = (%$network, dist_url => 'http://192.0.2.1/install/freebsd15.1/dist');
    delete @legacy{qw(gateway install_url)};
    print xCAT::FreeBSDConfig::render('node1', $disk, \%legacy, { release => '15.1-RELEASE', arch => 'x86_64',
        files => { 'usr/freebsd-dist/base.txz' => 'e' x 64, 'usr/freebsd-dist/kernel.txz' => 'f' x 64 } }, 'd' x 32);
    exit 0;
}
my $settings = xCAT::FreeBSDConfig::boot_settings($disk, $spec->{options} // '', $spec->{console} || {}, $media);
$settings = { %$settings, %{ $spec->{set} || {} } };
delete @$settings{ @{ $spec->{delete} || [] } };
if (($spec->{output} // 'render') eq 'loader') {
    print xCAT::FreeBSDConfig::render_loader_settings($settings, $network);
} else {
    print xCAT::FreeBSDConfig::render_pkgbase('node1', $settings, $network,
        { media => $media, package_plan_sha256 => 'c' x 64 }, 'd' x 32);
}
