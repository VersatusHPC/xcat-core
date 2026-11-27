#!/usr/bin/env perl
# xCAT::FreeBSDConfig boot and console settings. The installer shell library that reads them is
# tested in xCAT-test/bats/freebsd_boot_settings.bats.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../perl-xCAT", "$FindBin::Bin/../../xCAT-server/lib/perl";
use MIME::Base64 qw(encode_base64);
use Test::More;
use xCAT::FreeBSDConfig;

my $media = { format => 'xcat-mfsbsd-2', release => '15.1-RELEASE', arch => 'x86_64',
    digest => 'a' x 64, files => { 'xcat/runtime.tsv' => 'b' x 64 }, install_contract => 'xcat-freebsd-install-3' };
my $install = { media => $media, package_plan_sha256 => 'c' x 64 };
my $network = { master => '192.0.2.1', port => '3002', mac => '52:54:00:12:34:56',
    ipv4 => '192.0.2.10', netmask => '255.255.255.0', gateway => '192.0.2.1',
    hostname => 'node1.example.test', nameservers => '192.0.2.1', install_url => 'http://192.0.2.1/install' };
my $disk = { target_disk => 'vtbd0', target_disk_ident => 'TEST_DISK', filesystem => 'ufs',
    swap_size => '0', authorized_key_base64 => encode_base64("ssh-ed25519 AAAA\n", '') };

sub rejected {
    my ($operation, $pattern, $label) = @_;
    my $ok = eval { $operation->(); 1 };
    ok(!$ok, $label);
    like($@, $pattern, "$label explains why");
    return;
}

sub render {
    my $settings = shift;
    return xCAT::FreeBSDConfig::render_pkgbase('node1', $settings, $network, $install, 'd' x 32);
}

my $settings = xCAT::FreeBSDConfig::boot_settings({ %$disk, bootstrap => 'static' },
    'hint.example=install R::hint.example=target R::boot_verbose=yes',
    { serialport => '1', serialspeed => '115200', serialflow => 'hard' }, $media);
my $bytes = render($settings);
like($bytes, qr/\Aformat=xcat-freebsd-install-3\n/x, 'enhanced configuration declares its own contract');
is(scalar(split(/\n/x, $bytes)), 27, 'enhanced wire contract has exactly 27 fields');
my $loader = xCAT::FreeBSDConfig::render_loader_settings($settings, $network);
like($loader, qr/^hint\.example="install"$/mx, 'unprefixed option reaches installer loader');
unlike($loader, qr/target|boot_verbose/mx, 'persistent options do not reach installer loader');
like($loader, qr/^xcat_bootstrap_ipv4="192\.0\.2\.10"$/mx, 'static address precedes configuration fetch');
like($loader, qr/^comconsole_port="0x2f8"$/mx, 'xCAT COM2 uses the native I/O port');
like($loader, qr/^hw\.uart\.console="io:0x2f8,br:115200"$/mx, 'kernel console pins port and speed');

subtest 'every setting enters the generation identity' => sub {
    my $original = xCAT::FreeBSDConfig::fingerprint_pkgbase('node1', $settings, $network, $install);
    my %changes = (bootstrap => 'dhcp', console_port => '0', console_speed => '19200', console_flow => 'none',
        install_boot_options_base64 => encode_base64("hint.example=\"changed\"\n", ''),
        target_boot_options_base64 => encode_base64("hint.example=\"changed\"\n", ''));
    for my $key (sort keys %changes) {
        isnt(xCAT::FreeBSDConfig::fingerprint_pkgbase('node1', { %$settings, $key => $changes{$key} }, $network, $install),
            $original, "$key changes the fingerprint");
    }
};

subtest 'capability admission and defaults' => sub {
    my %old = %$media;
    delete $old{install_contract};
    is_deeply(xCAT::FreeBSDConfig::boot_settings($disk, '', {}, \%old), $disk, 'old media keeps default wire settings');
    my $static_disk = { %$disk, bootstrap => 'static' };
    for my $request ([$disk, 'hint.example=1', {}], [$disk, 'R::hint.example=1', {}],
        [$static_disk, '', {}], [$disk, '', { serialport => '0', serialspeed => '9600' }]) {
        rejected(sub { xCAT::FreeBSDConfig::boot_settings(@$request, \%old) }, qr/require.*runtime/x, 'old runtime rejects enhanced request');
    }
    for my $console ({ serialport => '4', serialspeed => '9600' }, { serialport => '0' },
        { serialport => '0', serialspeed => '9600', serialflow => 'soft' }, { serialspeed => '9600' }) {
        rejected(sub { xCAT::FreeBSDConfig::boot_settings($disk, '', $console, $media) },
            qr/(?:console|Console|serial)/x, 'invalid console policy');
    }
};

subtest 'the controller rejects malformed and executable options' => sub {
    for my $options ("console=\"comconsole\"\n", "hint.uart.0.port=\"0x2f8\"\n", "xcat_config_url=\"bad\"\n",
        "exec=\"reboot\"\n", "foo_before=\"reboot\"\n", "hint.a=\"1\"\nhint.a=\"2\"\n",
        "hint.z=\"1\"\nhint.a=\"2\"\n", "foo_load=\"yes\"\n", "hint.a=\"\${bad}\"\n", "hint.a=\"x\"",
        "hint.a=\"x\"\n\n", "hint.a=\"x\"\0\n") {
        rejected(sub { render({ %$settings, target_boot_options_base64 => encode_base64($options, '') }) },
            qr/(?:option|assignment)/ix, 'controller rejects invalid target stream');
    }
};

subtest 'the console port selects its native I/O address' => sub {
    my @ports = qw(0x3f8 0x2f8 0x3e8 0x2e8);
    for my $port (0 .. 3) {
        my $selected = xCAT::FreeBSDConfig::boot_settings($disk, '',
            { serialport => "$port", serialspeed => '19200' }, $media);
        my $controller = xCAT::FreeBSDConfig::render_loader_settings($selected, $network);
        like($controller, qr/^comconsole_port="\Q$ports[$port]\E"$/mx, "port $port has its native I/O address");
    }
};

done_testing();
