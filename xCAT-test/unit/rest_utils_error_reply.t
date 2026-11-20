#!/usr/bin/env perl
#
# POST /nodes/<cn>/nodeshell answered 403 with only the stderr lines when the command wrote to
# stderr and exited 0, and the stdout was lost.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More tests => 5;

use xCAT::RestUtils;

ok( !xCAT::RestUtils::error_ends_request( ['cn1: ls: cannot access x'], '0' ),
    'stderr lines with errorcode 0 are output, not an error reply' );
ok( xCAT::RestUtils::error_ends_request( ['cn1: ls: cannot access x'], '1' ), 'errorcode 1 is an error reply' );
ok( xCAT::RestUtils::error_ends_request( ['No such table'], undef ), 'an error with no errorcode is an error reply' );
ok( !xCAT::RestUtils::error_ends_request( [], '1' ), 'no error line, no error reply here' );
ok( !xCAT::RestUtils::error_ends_request( undef, undef ), 'no error at all, no error reply' );
