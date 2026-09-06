#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

my $plugin = File::Spec->catfile( $FindBin::Bin, '..', '..',
    'xCAT-server', 'lib', 'xcat', 'plugins', 'confluent.pm' );
plan skip_all => 'confluent.pm not found' unless -r $plugin;

open( my $fh, '<', $plugin ) or die "Unable to read $plugin: $!";
my $source = do { local $/; <$fh> };
close($fh);

# confluent.pm needs a management node to load, so lift the two blocks that
# read and shape the switch rows and run them here. A copy of the logic in the
# test would stay green when the plugin stops exporting the topology.
my ($readblock) = $source =~
  /^(    if \(\(\$nodes and \@\$nodes > 0\) or \$req->\{noderange\}->\[0\]\) \{\n.*?^    \}\n)/ms;
BAIL_OUT("$plugin no longer reads the tables in the block this test extracts")
  unless $readblock;
my ($mergeblock) =
  $source =~ /^(    foreach my \$nent \(\@cfgents4\) \{\n.*?^    \}\n)/ms;
BAIL_OUT("$plugin no longer merges the switch rows in a foreach over \@cfgents4")
  unless $mergeblock;

{
    my $code = join( "\n",
        'package XCATTest::Confluent;',
        'use strict; use warnings;',
        'sub read_switch_rows {',
        '    my ( $nodes, $req, $tabs ) = @_;',
        '    my ( $hmtab, $nodepostab, $mptab, $switchtab ) =',
        '      @{$tabs}{qw(nodehm nodepos mp switch)};',
        '    my ( @cfgents1, @cfgents2, @cfgents3, @cfgents4 );',
        '    my $explicitnodes = 0;',
        $readblock,
        '    return \@cfgents4;',
        '}',
        'sub merge_switch_rows {',
        '    my @cfgents4 = @_;',
        '    my ( %cfgenthash, %cfgnichash );',
        $mergeblock,
        '    return ( \%cfgenthash, \%cfgnichash );',
        '}',
        '1;' );
    eval $code;    ## no critic
    BAIL_OUT("unable to compile the extracted confluent.pm blocks: $@") if $@;
}

# The plugin asks a table object for the rows. Record what it asks for.
{
    package XCATTest::Table;
    sub new { my ( $class, %a ) = @_; return bless { %a, calls => [] }, $class }
    sub getNodesAttribs {
        my ( $self, $nodes, $cols ) = @_;
        push @{ $self->{calls} }, [ 'getNodesAttribs', join( ',', @$cols ) ];
        return @{ $self->{bynode} || [] };
    }
    sub getAllNodeAttribs {
        my ( $self, $cols ) = @_;
        push @{ $self->{calls} }, [ 'getAllNodeAttribs', join( ',', @$cols ) ];
        return @{ $self->{all} || [] };
    }
    sub asked { my $self = shift; return join( ' ', map { "$_->[0]($_->[1])" } @{ $self->{calls} } ) }
}

sub tables {
    my (%rows) = @_;
    return {
        nodehm  => XCATTest::Table->new( bynode => [ { n1 => [ { cons => 'ipmi' } ] } ], all => [] ),
        nodepos => XCATTest::Table->new( bynode => [ { n1 => [ {} ] } ],                 all => [] ),
        mp      => XCATTest::Table->new( bynode => [ { n1 => [ {} ] } ],                 all => [] ),
        switch  => XCATTest::Table->new( %rows ),
    };
}

# A node has one switch row for each interface. The read has to carry every
# row through, not the first one only.
my $tabs = tables(
    bynode => [ {
            n1 => [
                { switch => 'sw1', port => '1', interface => 'eth0' },
                { switch => 'sw2', port => '9', interface => 'ib0' },
            ] } ] );
my $rows = XCATTest::Confluent::read_switch_rows( ['n1'], { noderange => ['n1'] }, $tabs );
is( scalar @$rows, 2, 'a node with two switch rows keeps both' );
is( $rows->[0]{node}, 'n1', 'a row with no node column takes the node it was read for' );
is( $tabs->{switch}->asked, "getNodesAttribs(node,switch,port,interface)",
    'a node range reads the switch table for those nodes' );
unlike( $tabs->{nodepos}->asked, qr/switch|port/,
    'the switch columns are never read from nodepos' );

# With no node range the whole switch table is read.
$tabs = tables( all => [ { node => 'n1', switch => 'sw1', port => '1' } ] );
$rows = XCATTest::Confluent::read_switch_rows( [], { noderange => [] }, $tabs );
is( $tabs->{switch}->asked, "getAllNodeAttribs(node,switch,port,interface)",
    'no node range reads the whole switch table' );
is( scalar @$rows, 1, 'the whole switch table read returns its rows' );

# Keeping only one row for a node loses the port of every other interface,
# which is what this export exists to carry.
my ( $flat, $pernic ) = XCATTest::Confluent::merge_switch_rows(
    { node => 'n1', switch => 'sw1', port => '1', interface => 'eth0' },
    { node => 'n1', switch => 'sw2', port => '9', interface => 'ib0' },
);
is( scalar keys %{ $pernic->{n1} }, 2, 'a node with two interfaces keeps both' );
is( $pernic->{n1}{eth0}{switch}, 'sw1', 'the first interface keeps its switch' );
is( $pernic->{n1}{eth0}{port},   '1',   'the first interface keeps its port' );
is( $pernic->{n1}{ib0}{switch},  'sw2', 'the second interface keeps its switch' );
is( $pernic->{n1}{ib0}{port},    '9',   'the second interface keeps its port' );
is( $flat->{n1}{switch}, undef, 'a row naming an interface gives no plain switch' );
is( $flat->{n1}{port},   undef, 'a row naming an interface gives no plain port' );

# The node has to reach the configuration for its interfaces to be written. A
# node whose rows all name an interface is only in the per interface data, so
# the node itself must still be recorded.
is( $flat->{n1}{node}, 'n1', 'a node known only by its interfaces is still exported' );

# A row that names no interface keeps the plain names.
( $flat, $pernic ) = XCATTest::Confluent::merge_switch_rows( { node => 'n2', switch => 'sw3', port => '4' } );
is( $flat->{n2}{switch}, 'sw3', 'a row with no interface gives the plain switch' );
is( $flat->{n2}{port},   '4',   'a row with no interface gives the plain port' );
is( $pernic->{n2}, undef, 'a row with no interface adds no interface entry' );

# An empty switch table must leave the configuration untouched.
( $flat, $pernic ) = XCATTest::Confluent::merge_switch_rows();
is_deeply( $flat,   {}, 'an empty switch table adds no node entry' );
is_deeply( $pernic, {}, 'an empty switch table adds no interface entry' );

# A row without a node name cannot be placed.
( $flat, $pernic ) = XCATTest::Confluent::merge_switch_rows( { switch => 'sw4', port => '2' } );
is_deeply( $flat,   {}, 'a row with no node is skipped' );
is_deeply( $pernic, {}, 'a row with no node adds no interface entry' );

# The read and the merge together, which is the order the command runs them in.
$tabs = tables(
    bynode => [ {
            n1 => [
                { switch => 'sw1', port => '1', interface => 'eth0' },
                { switch => 'sw2', port => '9', interface => 'ib0' },
            ] } ] );
( $flat, $pernic ) = XCATTest::Confluent::merge_switch_rows(
    @{ XCATTest::Confluent::read_switch_rows( ['n1'], { noderange => ['n1'] }, $tabs ) } );
is( $pernic->{n1}{eth0}{port}, '1', 'a switch table row reaches the interface data' );
is( $pernic->{n1}{ib0}{port},  '9', 'the second interface reaches the interface data too' );

done_testing();
