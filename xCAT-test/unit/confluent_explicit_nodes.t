#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Test::More;

BEGIN {
    $ENV{XCATROOT} = "$FindBin::Bin/../../xCAT-server";
    $ENV{XCATCFG}  = 'SQLite:/tmp';
    $INC{'Confluent/Client.pm'} = __FILE__;
}

{
    package Confluent::Client;
}

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/lib/xcat";
use lib "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins";

require confluent;

{
    package StubNodehm;
    sub new { my ($class, %rows) = @_; return bless { rows => { %rows } }, $class; }
    sub getNodesAttribs {
        my ($self, $noderange) = @_;
        my %out;
        foreach my $node (@$noderange) {
            next unless exists $self->{rows}{$node};
            $out{$node} = [ { %{ $self->{rows}{$node} } } ];
        }
        return \%out;
    }
    sub getAllNodeAttribs {
        my ($self) = @_;
        return map { { %{ $self->{rows}{$_} } } } sort keys %{ $self->{rows} };
    }
}

my %rows = (
    withcons   => { node => 'withcons',   cons => 'ipmi' },
    withserial => { node => 'withserial', serialport => 0 },
    nocons     => { node => 'nocons' },
    withserver => { node => 'withserver', cons => 'ipmi', conserver => 'sn1.example' },
);
my $nodehm = StubNodehm->new(%rows);

my ($nodes, $conservers, $allnodes) =
  xCAT_plugin::confluent::_select_console_nodes(['nocons'], $nodehm, 'mn.example');
is_deeply($nodes, ['nocons'], 'an explicitly named node without console attributes is configured');
is($allnodes, 0, 'an explicit noderange is not treated as a full-table scan');

($nodes, $conservers) =
  xCAT_plugin::confluent::_select_console_nodes(['neverdefined'], $nodehm, 'mn.example');
is_deeply($nodes, ['neverdefined'], 'a node without a nodehm row keeps its explicit name');
is_deeply($conservers->{'mn.example'}{nodes}, ['neverdefined'], 'a node without a conserver is routed to the manager');

($nodes, $conservers) = xCAT_plugin::confluent::_select_console_nodes(
    [qw(withserver withcons nocons)], $nodehm, 'mn.example'
);
is_deeply([sort @$nodes], [qw(nocons withcons withserver)], 'an explicit mixed noderange retains every requested node');
is_deeply($conservers->{'sn1.example'}{nodes}, ['withserver'], 'an explicit conserver remains selected');
is_deeply($conservers->{'mn.example'}{nodes}, [qw(withcons nocons)], 'manager-owned nodes retain their routing');

($nodes, $conservers, $allnodes) =
  xCAT_plugin::confluent::_select_console_nodes(undef, $nodehm, 'mn.example');
is_deeply(
    $nodes,
    [qw(withcons withserial withserver)],
    'a full-table scan still excludes nodes without console configuration',
);
is($allnodes, 1, 'an absent noderange is identified as a full-table scan');

my @reshaped = xCAT_plugin::confluent::_flatten_node_rows(
    [
        { withcons => [ { node => 'withcons', cons => 'ipmi' } ] },
        { neverdefined => [] },
    ],
    1,
);
is(scalar(@reshaped), 2, 'both explicit lookup results survive reshaping');
my ($carried) = grep { ($_->{node} || '') eq 'neverdefined' } @reshaped;
ok($carried, 'a missing nodehm row gains the explicit node name');
ok(!grep({ !defined($_->{node}) || $_->{node} eq '' } @reshaped), 'no reshaped entry has an empty node name');

sub preprocess_nodes {
    my (@requested) = @_;
    no warnings qw(once redefine);
    local $::CONSERVER = 0;
    local $::LOCAL     = 0;
    local $::HELP      = 0;
    local $::DEBUG     = 0;
    local $::VERSION   = 0;
    local $::VERBOSE   = 0;
    local *xCAT::Utils::isServiceNode = sub { return 0; };
    local *xCAT::NetworkUtils::determinehostname = sub { return ('mn.example'); };
    local *xCAT::TableUtils::get_site_Master = sub { return 'mn.example'; };
    local *xCAT::Table::new = sub {
        my (undef, $name) = @_;
        die "Unexpected table $name" unless $name eq 'nodehm';
        return $nodehm;
    };

    return xCAT_plugin::confluent::preprocess_request(
        {
            command             => ['makeconfluentcfg'],
            node                => \@requested,
            arg                 => [],
            _xcatpreprocessed   => [0],
        },
        sub { },
    );
}

my $requests = preprocess_nodes('neverdefined');
is(scalar(@$requests), 1, 'the production preprocessor returns one manager request');
is($requests->[0]{_xcatdest}, 'mn.example', 'the production preprocessor targets the manager');
is_deeply($requests->[0]{node}, ['neverdefined'],
    'the production preprocessor keeps an explicit node without a nodehm row');

$requests = preprocess_nodes('withserver');
is(scalar(@$requests), 2, 'an external conserver adds a second production request');
my %by_destination = map { $_->{_xcatdest} => $_ } @$requests;
is_deeply($by_destination{'mn.example'}{node}, ['withserver'],
    'the manager request keeps the explicit node');
is_deeply($by_destination{'sn1.example'}{node}, ['withserver'],
    'the conserver request keeps the explicit node');

done_testing();
