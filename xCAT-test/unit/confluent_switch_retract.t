#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use FindBin;
use IO::Handle;
use Test::More;

my $plugin = File::Spec->catfile( $FindBin::Bin, '..', '..',
    'xCAT-server', 'lib', 'xcat', 'plugins', 'confluent.pm' );
plan skip_all => 'confluent.pm not found' unless -r $plugin;

open( my $fh, '<', $plugin ) or die "Unable to read $plugin: $!";
my $source = do { local $/; <$fh> };
close($fh);

# confluent.pm needs a management node to load, so lift the block that builds
# the payload and the block that shapes the switch rows, and run them. A copy
# of the payload in the test would stay green when the plugin stops sending
# the clears.
my ($payloadblock) = $source =~
  /^(    # Go thru all nodes specified to add them to the file\n    foreach my \$node \(sort keys \%\$cfgenthash\) \{\n.*?^    \}\n)/ms;
BAIL_OUT("$plugin no longer builds the payload in the block this test extracts")
  unless $payloadblock;
my ($mergeblock) =
  $source =~ /^(    foreach my \$nent \(\@cfgents4\) \{\n.*?^    \}\n)/ms;
BAIL_OUT("$plugin no longer merges the switch rows in a foreach over \@cfgents4")
  unless $mergeblock;

# The plugin sends the payload through a confluent handle. Record it instead.
{
    package XCATTest::Confluent::Handle;
    sub new { return bless { sent => [] }, shift }
    sub update {
        my ( $self, $path, %args ) = @_;
        push @{ $self->{sent} }, { verb => 'update', path => $path, %args };
        return 1;
    }
    sub create {
        my ( $self, $path, %args ) = @_;
        push @{ $self->{sent} }, { verb => 'create', path => $path, %args };
        return 1;
    }
    sub next_result { return undef }
}
{
    package xCAT::SvrUtils;
    sub sendmsg { die "the plugin reported a confluent error: @{[ $_[0]->[1] ]}" }
}

{
    my $code = join( "\n",
        'package XCATTest::Confluent;',
        'use strict; use warnings;',
        'sub send_payloads {',
        '    my ( $cfgenthash, $cfgnichash, $held, $confluent ) = @_;',
        '    my %currnodes = map { $_ => 1 } @$held;',
        '    my $cb = undef;',
        '    my $ipmiauthdata = { map { $_ => { username => "u", password => "p" } } keys %$cfgenthash };',
        '    my $ipmientries  = { map { $_ => [ { bmc => "192.0.2.10" } ] } keys %$cfgenthash };',
        '    my $groupdata    = { map { $_ => [ { groups => "all" } ] } keys %$cfgenthash };',
        $payloadblock,
        '    return $confluent->{sent};',
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

# A cleared attribute is named with no value. A name confluent never sees is
# also read as undef, so the name has to be there as well.
sub is_cleared {
    my ( $params, $name, $desc ) = @_;
    return ok( exists $params->{$name} && !defined $params->{$name}, $desc );
}

# Send one node and return the parameters the plugin built for it.
sub payload_for {
    my ( $flat, $pernic, $held ) = @_;
    my $handle = XCATTest::Confluent::Handle->new();
    XCATTest::Confluent::send_payloads(
        { n1 => { cons => 'ipmi', %$flat } },
        ( keys %$pernic ? { n1 => $pernic } : {} ),
        ( $held ? ['n1'] : [] ), $handle );
    is( scalar @{ $handle->{sent} }, 1, 'the plugin sends one request for one node' );
    return $handle->{sent}->[0];
}

# A node xCAT holds no topology for must name every topology attribute with no
# value, so confluent removes what it still holds.
my $req = payload_for( {}, {}, 1 );
is( $req->{verb}, 'update', 'a node confluent already holds is updated' );
my $p = $req->{parameters};
ok( exists $p->{'net.switch'},       'a node with no topology names the plain switch' );
is( $p->{'net.switch'}, undef,       'the plain switch carries no value' );
ok( exists $p->{'net.switchport'},   'a node with no topology names the plain port' );
is( $p->{'net.switchport'}, undef,   'the plain port carries no value' );
is_cleared( $p, 'net.*.switch',     'every interface switch is named with no value' );
is_cleared( $p, 'net.*.switchport', 'every interface port is named with no value' );

# A value the switch table holds must survive beside the names that clear.
$p = payload_for( { switch => 'sw1', port => '1' }, {}, 1 )->{parameters};
is( $p->{'net.switch'},     'sw1', 'a held plain switch keeps its value' );
is( $p->{'net.switchport'}, '1',   'a held plain port keeps its value' );
is_cleared( $p, 'net.*.switch', 'the interface wildcard still clears' );

# The interface case. Confluent removes what the wildcard matches before it
# sets the rest of the request, so the current interface survives.
$p = payload_for( {}, { ib0 => { switch => 'sw2', port => '9' } }, 1 )->{parameters};
is( $p->{'net.ib0.switch'},     'sw2', 'the current interface keeps its switch' );
is( $p->{'net.ib0.switchport'}, '9',   'the current interface keeps its port' );
is_cleared( $p, 'net.*.switch', 'the interface wildcard clears the rest' );
is_cleared( $p, 'net.switch', 'a node with only an interface clears the plain switch' );

# A renamed interface: only the new name carries a value, and the wildcard
# removes the old one.
$p = payload_for( {}, { ens1f0 => { switch => 'sw3', port => '4' } }, 1 )->{parameters};
is( $p->{'net.ens1f0.switch'}, 'sw3', 'the new interface name carries the switch' );
ok( !exists $p->{'net.eth0.switch'}, 'the old interface name is not named on its own' );
is_cleared( $p, 'net.*.switch', 'the old interface name is removed by the wildcard' );

# A node confluent does not hold yet is created, and a create carries no clear.
$req = payload_for( { switch => 'sw1', port => '1' }, {}, 0 );
is( $req->{verb}, 'create', 'a node confluent does not hold is created' );
is( $req->{parameters}->{name}, 'n1', 'the create names the node' );
ok( !exists $req->{parameters}->{'net.*.switch'},
    'the branch that creates a node sends no clear' );

# The switch table read, the merge and the payload in the order the command
# runs them in. A row that stops reaching the interface data is visible here.
my ( $flat, $pernic ) = XCATTest::Confluent::merge_switch_rows(
    { node => 'n1', switch => 'sw1', port => '1', interface => 'eth0' },
    { node => 'n1', switch => 'sw2', port => '9', interface => 'ib0' },
);
my $handle = XCATTest::Confluent::Handle->new();
$flat->{n1}->{cons} = 'ipmi';
XCATTest::Confluent::send_payloads( $flat, $pernic, ['n1'], $handle );
$p = $handle->{sent}->[0]->{parameters};
is( $p->{'net.eth0.switch'},     'sw1', 'a switch table row reaches the payload' );
is( $p->{'net.eth0.switchport'}, '1',   'the port of that row reaches the payload' );
is( $p->{'net.ib0.switch'},      'sw2', 'the second interface reaches the payload' );
is( $p->{'net.ib0.switchport'},  '9',   'the port of the second interface reaches the payload' );

# The wildcard cannot stand in for the names that carry no interface, so those
# have to be named separately. This is why both forms are in the payload.
SKIP: {
    eval { require File::FnMatch; 1 }
      or skip 'File::FnMatch not available', 1;
    ok( !File::FnMatch::fnmatch( 'net.*.switch', 'net.switch' ),
        'the interface wildcard does not match the plain name' );
}
# Same check without the optional module, using the rule the wildcard follows.
ok( 'net.switch' !~ /^net\..+\.switch$/,
    'the plain name needs its own clear because the wildcard cannot match it' );
ok( 'net.ib0.switch' =~ /^net\..+\.switch$/,
    'an interface name is what the wildcard matches' );

# The transport has to turn no value into a JSON null, which is what confluent
# reads as a request to remove an attribute.
my $tlv = File::Spec->catfile( $FindBin::Bin, '..', '..',
    'xCAT-server', 'lib', 'xcat', 'Confluent', 'TLV.pm' );
SKIP: {
    skip 'TLV.pm not found', 1 unless -r $tlv;
    eval { require $tlv; 1 } or skip "TLV.pm did not load: $@", 1;
    my $wire = '';
    open( my $sock, '>', \$wire ) or die "Unable to open an in memory handle: $!";
    Confluent::TLV->new($sock)->send( { 'net.switch' => undef } );
    like( $wire, qr/"net\.switch":null/,
        'a parameter with no value is sent as a JSON null' );
}

done_testing();
