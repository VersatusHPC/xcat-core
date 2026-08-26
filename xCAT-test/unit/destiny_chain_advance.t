#!/usr/bin/env perl
use strict;
use warnings;

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

sub advance {
    my (%chain) = @_;
    my $ref = { %chain };
    my $callnodeset = xCAT_plugin::destiny::_advance_chain($ref, 1);
    return ($ref, $callnodeset);
}

my ($repeat, $repeat_nodeset) = advance(
    currchain => 'boot',
    currstate => 'boot',
    chain     => 'osimage=rhels9-x86_64-install-compute',
);
is($repeat->{currstate}, 'boot', 'advancing again from boot keeps the node booting');
is($repeat->{currchain}, 'boot', 'advancing again from boot leaves boot as the next destiny');
is($repeat_nodeset, 0, 'an already completed chain does not invoke nodeset again');

my ($twice) = advance(
    currchain => $repeat->{currchain},
    currstate => $repeat->{currstate},
    chain     => 'osimage=rhels9-x86_64-install-compute',
);
is($twice->{currstate}, 'boot', 'a third advance still leaves the node booting');
is($twice->{currchain}, 'boot', 'repeated advances from boot are idempotent');

my ($exhausted, $exhausted_nodeset) = advance(
    currchain => 'osimage=rhels9-x86_64-install-compute',
    currstate => 'osimage=rhels9-x86_64-install-compute',
    chain     => 'osimage=rhels9-x86_64-install-compute',
);
is($exhausted->{currstate}, 'standby', 'an exhausted install chain still falls to standby');
is($exhausted->{currchain}, 'standby', 'standby remains the exhausted chain state');
is($exhausted_nodeset, 0, 'an exhausted install chain suppresses the aggregate nodeset call');

my ($remaining, $remaining_nodeset) = advance(
    currchain => 'osimage=rhels9-x86_64-install-compute,boot',
    currstate => 'osimage=rhels9-x86_64-install-compute',
    chain     => 'osimage=rhels9-x86_64-install-compute,boot',
);
is($remaining->{currstate}, 'osimage=rhels9-x86_64-install-compute', 'a chain with steps left advances to its next step');
is($remaining->{currchain}, 'boot', 'a chain with steps left keeps the rest of the chain');
is($remaining_nodeset, 1, 'a chain with steps left keeps the aggregate nodeset call enabled');

my ($fresh, $fresh_nodeset) = advance(
    currchain => '',
    currstate => '',
    chain     => 'osimage=rhels9-x86_64-install-compute,boot',
);
is($fresh->{currstate}, 'osimage=rhels9-x86_64-install-compute', 'an empty currchain starts from the default chain');
is($fresh->{currchain}, 'boot', 'the unused part of the default chain is retained');
is($fresh_nodeset, 1, 'a fresh chain keeps the aggregate nodeset call enabled');

{
    package StubChainTable;
    sub new {
        my ($class, $entry) = @_;
        return bless { entry => $entry }, $class;
    }
    sub getNodesAttribs {
        my ($self, $nodes) = @_;
        return { $nodes->[0] => [ $self->{entry} ] };
    }
    sub setNodeAttribs {
        my ($self, $node, $entry) = @_;
        $self->{written} = { node => $node, entry => { %$entry } };
        return;
    }
}

sub run_nextdestiny {
    my (%chain) = @_;
    my $entry = { %chain };
    my $table = StubChainTable->new($entry);
    my @destiny;
    my @subrequests;

    no warnings qw(once redefine);
    local *xCAT::Utils::isMN = sub { return 0; };
    local *xCAT::MsgUtils::trace = sub { return; };
    local *xCAT::Table::new = sub {
        my (undef, $name) = @_;
        die "Unexpected table $name" unless $name eq 'chain';
        return $table;
    };
    local *xCAT_plugin::destiny::setdestiny = sub {
        my ($request) = @_;
        push @destiny, $request;
        return;
    };

    xCAT_plugin::destiny::process_request(
        { command => ['nextdestiny'], node => ['node01'] },
        sub { },
        sub { push @subrequests, @_ },
    );

    return ($table->{written}, \@destiny, \@subrequests);
}

my ($written, $destiny, $subrequests) = run_nextdestiny(
    currchain => 'boot',
    currstate => 'boot',
    chain     => 'osimage=rhels9-x86_64-install-compute',
);
is($written->{entry}{currstate}, 'boot', 'nextdestiny keeps a completed node in boot');
is($destiny->[0]{arg}[0], 'boot', 'nextdestiny applies the boot destiny');
is_deeply($subrequests, [], 'nextdestiny does not enact an already completed chain');

($written, $destiny, $subrequests) = run_nextdestiny(
    currchain => 'osimage=rhels9-x86_64-install-compute,boot',
    currstate => 'osimage=rhels9-x86_64-install-compute',
    chain     => 'osimage=rhels9-x86_64-install-compute,boot',
);
is($written->{entry}{currchain}, 'boot', 'nextdestiny writes the remaining chain');
is($destiny->[0]{arg}[0], 'osimage=rhels9-x86_64-install-compute',
    'nextdestiny applies the current chain step');
is_deeply(
    $subrequests,
    [{ command => ['nodeset'], node => ['node01'], arg => ['enact'] }],
    'nextdestiny enacts a chain that still has work',
);

done_testing();
