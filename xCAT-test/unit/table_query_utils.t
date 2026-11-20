#!/usr/bin/env perl
#
# GET /tables/<t>/rows/<attr>=<value> returned only the first matching row, and a key the table
# does not have gave a Perl error (xcat-core/#5148). The getAttribs reply is a public interface,
# so the one-row form must stay the default.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More tests => 9;

use xCAT::TableQueryUtils;

my @cols = qw(netname net mask mgtifname);

is_deeply( [ xCAT::TableQueryUtils::unknown_keys( \@cols, { mask => '255.255.255.0' } ) ],
    [], 'a column of the table is a known key' );
is_deeply( [ xCAT::TableQueryUtils::unknown_keys( \@cols, { bogus_42 => 1, mask => 1, zz => 1 } ) ],
    [ 'bogus_42', 'zz' ], 'every key that is not a column is reported, sorted' );

is( xCAT::TableQueryUtils::unknown_keys_error( 'networks', 'bogus_42' ),
    'Table networks has no attribute bogus_42.', 'the error names the table and the attribute' );
is( xCAT::TableQueryUtils::unknown_keys_error('networks'), undef, 'no unknown key, no error' );

my @rows = ( { netname => 'a', mask => 'm' }, { netname => 'b', mask => 'm' } );

my $one = xCAT::TableQueryUtils::attribs_reply( 'networks', \@rows, 0 );
is_deeply( $one, { netname => ['a'], mask => ['m'] }, 'the default reply is the first row only' );

my $all = xCAT::TableQueryUtils::attribs_reply( 'networks', \@rows, 1 );
is_deeply( [ map { $_->{netname} } @{ $all->{table}[0]{row} } ],
    [ 'a', 'b' ], 'allmatches returns every matching row' );
is_deeply( $all->{table}[0]{tablename}, ['networks'], 'allmatches names the table' );

is_deeply( xCAT::TableQueryUtils::attribs_reply( 'networks', [], 1 ), {},
    'allmatches with no match is an empty reply' );
is_deeply( xCAT::TableQueryUtils::attribs_reply( 'networks', [undef], 0 ), {},
    'no row is an empty reply' );
