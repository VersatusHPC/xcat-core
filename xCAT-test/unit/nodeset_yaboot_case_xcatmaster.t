#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

use Test::More;

require xCAT::Template;
require xCAT::NetworkUtils;

# nodeset renders the install template, and the template resolves xcatmaster
# from the noderes table. When the node does not carry one, xCAT::Template
# falls back to the management node address that faces the node. The nodeset
# cases put their node on 10.1.1.0/24, which no management node in the suite
# faces, so the fallback returns nothing and nodeset fails. This test resolves
# xcatmaster for the node the nodeset_yaboot case defines.

my $cases = "$FindBin::Bin/../autotest/testcase/nodeset/cases0";
open(my $fh, '<', $cases) or BAIL_OUT("cannot read $cases: $!");
my @lines = <$fh>;
close($fh);
chomp(@lines);

# Collect the attributes the case gives its node, whatever their order on the
# mkdef and chdef lines.
sub case_node_attributes {
    my ($case) = @_;

    my $in_case = 0;
    my $found   = 0;
    my %attrs;
    for my $line (@lines) {
        $in_case = 1, next if $line eq "start:$case";
        next unless $in_case;
        last if $line eq 'end';
        next unless $line =~ /^cmd:\s*(?:mk|ch)def\b(.*)$/;
        my $args = $1;
        $found = 1;
        for my $token (split(/\s+/, $args)) {
            next if $token =~ /^-/;
            next unless $token =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
            $attrs{$1} = $2 unless exists $attrs{$1};
        }
    }
    BAIL_OUT("no mkdef or chdef found in case $case of $cases") unless $found;
    return \%attrs;
}

our %ROW;
{
    no warnings 'redefine', 'once';

    *xCAT::Table::new = sub {
        my ($class, $table) = @_;
        return bless { table => $table }, 'xCAT::Table';
    };
    *xCAT::Table::getNodeAttribs = sub {
        my ($self, $node, $fields) = @_;
        my %row;
        for my $field (@{ $fields || [] }) {
            $row{$field} = $ROW{ $self->{table} }{$field}
              if defined $ROW{ $self->{table} }{$field};
        }
        return \%row;
    };
    *xCAT::Table::getAttribs = sub { return ({}) };
    *xCAT::Table::close      = sub { 1 };

    # A management node with no interface on the case's 10.1.1.0/24 network.
    *xCAT::NetworkUtils::my_ip_facing = sub { return (1, undef) };
}

my $attrs = case_node_attributes('nodeset_yaboot');
is($attrs->{ip}, '10.1.1.200',
    'nodeset_yaboot still puts its node on the unreachable 10.1.1.0/24 network');

local %ROW = (noderes => $attrs);
my $resolved = xCAT::Template::tabdb('noderes', '$NODE', 'xcatmaster');
isnt($resolved, '',
    'the node nodeset_yaboot defines resolves an xcatmaster for the template');

done_testing();
