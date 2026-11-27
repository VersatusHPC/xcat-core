#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use MIME::Base64 qw(encode_base64);
use Test::More;
use lib "$FindBin::Bin/../../xCAT-server/lib/perl", "$FindBin::Bin/../../perl-xCAT";
use xCAT::FreeBSDNetwork;
use xCAT::FreeBSDConfig;

my $planner = "$FindBin::Bin/../../xCAT/postscripts/confignetwork-freebsd.awk";
my $mac = '52:54:00:00:00:01';
my $nics = { nictypes => 'vtnet0!ethernet,vtnet1!ethernet,lagg0!lagg,vlan100!vlan,bridge0!bridge',
    nicdevices => 'lagg0!vtnet0|vtnet1,vlan100!lagg0,bridge0!vlan100',
    nicextraparams => 'lagg0!LAGGPROTO=failover,bridge0!STP=no',
    nicsadapter => "vtnet0!mac=$mac linkstate=UP,vtnet1!mac=52:54:00:00:00:02,vtnet9!mac=52:54:00:00:00:09" };
my $encoded = xCAT::FreeBSDNetwork::encode('bridge0', $mac, $nics, $planner, 9000);
my $description = xCAT::FreeBSDNetwork::decode($encoded);
is($description->{mtu}, 9000, 'the provisioning network MTU travels with the topology');
my $plan = xCAT::FreeBSDNetwork::compile($encoded, $planner);
like($plan, qr/^X\tlagg0\t.*laggproto[ ]failover[ ]laggport[ ]vtnet0[ ]laggport[ ]vtnet1/mx,
    'the producer calls the shared topology compiler');
like($plan, qr/^T\tbridge0\t9000$/mx, 'the virtual address owner inherits the network MTU');
my $loader = xCAT::FreeBSDNetwork::loader($encoded);
my @chunks = $loader =~ /^xcat_network_[0-9]+="([A-Za-z0-9+\/=]+)"$/mgx;
is(join('', @chunks), $encoded, 'loader chunks retain every network byte');
ok(!grep({ length($_) > 120 } @chunks), 'each chunk fits the native kernel environment value bound');
like($loader, qr/^xcat_network_chunks="@{[scalar @chunks]}"$/mx, 'the count describes all chunks');
my $media = { install_contract => 'xcat-freebsd-install-6', network_contract => 'xcat-freebsd-bootstrap-1' };
my $settings = xCAT::FreeBSDConfig::boot_settings({bootstrap_network_base64 => $encoded}, '', {}, $media);
like(xCAT::FreeBSDConfig::render_loader_settings($settings, {}), qr/\Q$loader\E/x,
    'normal boot publication includes the topology before HTTP is available');
for my $bad_media ({}, { install_contract => 'xcat-freebsd-install-6' },
    { install_contract => 'xcat-freebsd-install-6', network_contract => 'unknown' }) {
    my $ok = eval { xCAT::FreeBSDConfig::boot_settings({bootstrap_network_base64 => $encoded}, '', {}, $bad_media); 1 };
    ok(!$ok, 'unqualified media cannot silently ignore early virtual networking');
}
for my $bad ('', 'A' x 8193, $encoded . '\n', encode_base64("interface=bridge0\n", ''),
    encode_base64("interface=bridge0\nmac=$mac\nmtu=9000\nNICTYPES=vtnet0!ethernet\nNICDEVICES=\nNICEXTRAPARAMS=\nNICMACS=vtnet0!$mac", '')) {
    my $ok = eval { xCAT::FreeBSDNetwork::decode($bad); 1 };
    ok(!$ok, 'malformed, oversized or incomplete descriptions are rejected');
}
for my $change ({nicdevices => 'lagg0!vtnet1|vtnet0,vlan100!lagg0,bridge0!vlan100'},
    {nicextraparams => 'lagg0!LAGGPROTO=lacp,bridge0!STP=no MACADDR=52:54:00:00:00:99'},
    {nicsadapter => "vtnet0!mac=$mac"},
    {nicsadapter => "vtnet0!mac=$mac mac=$mac,vtnet1!mac=52:54:00:00:00:02"},
    {nicsadapter => "vtnet0!mac=$mac,vtnet0!mac=$mac,vtnet1!mac=52:54:00:00:00:02"}) {
    my $ok = eval { xCAT::FreeBSDNetwork::encode('bridge0', $mac, { %$nics, %$change }, $planner); 1 };
    ok(!$ok, 'invalid topology fails before loader publication');
}
my $changed = xCAT::FreeBSDNetwork::encode('bridge0', $mac,
    { %$nics, nicextraparams => 'lagg0!LAGGPROTO=lacp,bridge0!STP=no' }, $planner, 9000);
isnt($changed, $encoded, 'a topology change changes the generation-bound configuration bytes');

subtest 'installed IB policy does not change the boot-image input' => sub {
    my $with_data = xCAT::FreeBSDNetwork::encode('bridge0', $mac, {
        %$nics,
        nictypes => $nics->{nictypes} . ',ib0!Infiniband,ib1!Infiniband,lagg1!bond-infiniband,vtnet2!ethernet',
        nicdevices => $nics->{nicdevices} . ',lagg1!ib0|ib1',
        nicextraparams => $nics->{nicextraparams} . ',lagg1!LAGGPROTO=failover,ib0!IB_DRIVER=mlx5ib,vtnet2!MTU=1500',
        nicsadapter => $nics->{nicsadapter} . ',vtnet2!mac=52:54:00:00:00:03',
    }, $planner, 9000);
    is($with_data, $encoded, 'an older boot planner receives the identical supported Ethernet policy');
    is(xCAT::FreeBSDNetwork::compile($with_data, $planner), $plan,
        'the filtered description reproduces the validated bootstrap plan');
};

done_testing();
