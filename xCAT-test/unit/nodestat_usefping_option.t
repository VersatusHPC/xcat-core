#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Getopt::Long qw(GetOptionsFromArray);
use Test::More;

$ENV{XCATROOT} = "$FindBin::Bin/../../xCAT-server";
require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/nodestat.pm";

sub parse {
    my (@argv) = @_;
    Getopt::Long::ConfigDefaults();
    Getopt::Long::Configure('pass_through', 'bundling');
    $Getopt::Long::ignorecase = 0;
    my %opt;
    do {
        local $SIG{__WARN__} = sub { };
        GetOptionsFromArray(\@argv, \%opt, xCAT_plugin::nodestat::option_spec());
    };
    return \%opt;
}

foreach my $given (qw(-f --usefping)) {
    ok(parse($given)->{f}, "$given selects fping");
}

ok(parse('--useping')->{f}, '--useping still selects fping');

foreach my $given (qw(--use --us --usemon -m)) {
    my $opt = parse($given);
    ok($opt->{m}, "$given still selects usemon");
    ok(!$opt->{f}, "$given does not select fping");
}

foreach my $given (qw(-mf -fm)) {
    my $opt = parse($given);
    ok($opt->{m} && $opt->{f}, "$given selects usemon and fping");
}

is_deeply(
    [ map { parse($_) } qw(-u -p -q) ],
    [ { u => 1 }, { p => 1 }, { q => 1 } ],
    'the remaining options are unchanged',
);

my @usage = xCAT_plugin::nodestat::usage_lines();
is($usage[0], 'Usage:', 'the usage heading is retained');
like($usage[1], qr/\Q-f|--usefping\E/, 'the usage names the accepted fping option');
like($usage[1], qr/\Q-m|--usemon\E/, 'the usage names the monitoring option');

my @messages;
{
    no warnings qw(once redefine);
    local *xCAT::MsgUtils::message = sub {
        my ( undef, undef, $response ) = @_;
        push @messages, $response;
    };

    my $result = xCAT_plugin::nodestat::preprocess_request(
        { command => ['nodestat'], arg => [ '--usefping', '-h' ] },
        sub { },
    );
    is($result, 0, 'the real nodestat plugin accepts --usefping');
    is($::USEFPING, 1, 'the real nodestat plugin enables fping');
    is_deeply($messages[0]->{data}, [xCAT_plugin::nodestat::usage_lines()],
        'the real nodestat plugin reports the shared usage text');

    @messages = ();
    {
        local $SIG{__WARN__} = sub { };
        $result = xCAT_plugin::nodestat::preprocess_request(
            {
                command => ['nodestat'],
                node    => ['node01'],
                arg     => ['--bogus'],
            },
            sub { },
        );
    }
    is_deeply($result->[0]->{node}, ['node01'],
        'the real nodestat plugin retains the request node');
    is_deeply($result->[0]->{arg}, ['--bogus'],
        'the daemon pass-through setting leaves unknown options untouched');
}

done_testing();
