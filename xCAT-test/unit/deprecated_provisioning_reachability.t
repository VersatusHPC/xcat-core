#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use Test::More;

BEGIN {
    $ENV{XCATROOT} = "$FindBin::Bin/../../xCAT-server";
    $ENV{XCATCFG}  = 'SQLite:/tmp';
    $INC{'xCAT_monitoring/monitorctrl.pm'} = __FILE__;
}

{
    package xCAT_monitoring::monitorctrl;
}

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins";

require destiny;
require packimage;

my $deprecated = 'The options "install", "netboot", and "statelite" have been deprecated, use "osimage=<osimage_name>" instead.';
my $legacy_packimage = "-o, -p and -a options are obsoleted, please use 'packimage <osimage name>' instead.";
my $missing_image = "An image name is required, use 'packimage <osimage name>'.";

{
    package DeprecatedProvisioningTable;
    sub getNodesAttribs { return {}; }
    sub getNodeAttribs { return { netboot => 'xnba' }; }
    sub close { return; }
}

sub destiny_request {
    my ($state) = @_;
    my @responses;
    no warnings 'redefine';
    local *xCAT::Utils::isMN = sub { return 0; };
    local *xCAT::MsgUtils::trace = sub { return; };
    local *xCAT::Table::new = sub { return bless {}, 'DeprecatedProvisioningTable'; };
    xCAT_plugin::destiny::process_request(
        { command => ['setdestiny'], node => ['node01'], arg => [$state] },
        sub { push @responses, @_ },
        undef,
    );
    return \@responses;
}

foreach my $state (qw(install netboot statelite)) {
    my $responses = destiny_request($state);
    is($responses->[0]->{error}, $deprecated,
        "$state keeps the runtime deprecation error");
    is($responses->[0]->{errorcode}->[0], 1,
        "$state remains a failed provisioning request");
}

sub packimage_request {
    my (@args) = @_;
    my @responses;
    no warnings 'redefine';
    local *xCAT::TableUtils::getInstallDir = sub { return '/install'; };
    local *xCAT::TableUtils::get_site_attribute = sub { return; };
    local @ARGV;
    my $status = xCAT_plugin::packimage::process_request(
        { command => ['packimage'], arg => \@args },
        sub { push @responses, @_ },
        undef,
    );
    return ($status, \@responses);
}

my ($status, $responses) = packimage_request('-o', 'rhels9');
is($status, 1, 'packimage rejects a legacy OS option');
is($responses->[0]->{error}->[0], $legacy_packimage, 'the runtime reports the legacy-option error');

($status, $responses) = packimage_request('--method', 'cpio');
is($status, 1, 'packimage rejects a request without an image name');
is($responses->[0]->{error}->[0], $missing_image, 'the runtime reports the missing-image error');

done_testing();
