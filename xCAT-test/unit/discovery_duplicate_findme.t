#!/usr/bin/perl
# A node sends findme again when xCAT answers late. The repeat must not erase the discovery.
#
# The OpenEmbedded Genesis image resends its findme every 5 seconds until the node receives
# its identity. aaadiscovery writes every findme to discoverydata with method=undef. When the
# repeat arrives, the node has already taken its new address, so the notify for the repeat
# fails. The row then must still name the method that discovered the node.
use strict;
use warnings;
use Test::More tests => 5;
use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

my %rows;

BEGIN {
    package xCAT::Table;
    sub new {
        my ($class, $name) = @_;
        return bless { name => $name }, 'Local::DiscoveryTable';
    }
    $INC{'xCAT/Table.pm'} = __FILE__;

    package Local::DiscoveryTable;
    sub setAttribs {
        my ($self, $key, $attrs) = @_;
        my $row = $rows{ $key->{uuid} } ||= {};
        @{$row}{ keys %{$attrs} } = values %{$attrs};
        return;
    }
    sub close { return; }
}

require xCAT::Table;
require xCAT::DiscoveryUtils;

my $uuid = '0c3f8d41-6a52-4e7b-9f10-2d8c54ab7731';

sub findme {
    my ($method) = @_;
    return {
        command         => ['findme'],
        uuid            => [$uuid],
        arch            => ['x86_64'],
        node            => ['seqdisc1'],
        discoverymethod => [$method],
    };
}

# aaadiscovery records each findme before a discovery method claims it.
xCAT::DiscoveryUtils->update_discovery_data(findme('undef'));
is($rows{$uuid}{method}, 'undef', 'a findme that no method claimed is recorded as undef');

my $notified = xCAT::DiscoveryUtils->complete_discovery(findme('sequential'), sub { return 1 });
is($notified, 1, 'complete_discovery reports that the node received its identity');
is($rows{$uuid}{method}, 'sequential', 'the first findme is recorded as a sequential discovery');

# The repeat: aaadiscovery resets the row, and the node no longer answers on its old address.
xCAT::DiscoveryUtils->update_discovery_data(findme('undef'));
$notified = xCAT::DiscoveryUtils->complete_discovery(findme('sequential'), sub { return 0 });
is($notified, 0, 'complete_discovery reports the failed notify');
is($rows{$uuid}{method}, 'sequential',
    'the repeated findme leaves the node recorded as discovered, so nodediscoverls still lists it');
