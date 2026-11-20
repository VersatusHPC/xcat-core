#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use Test::More;

# Perl 5.39.1 and later warn when a use line passes an import list to a
# module that has no import method. The warning reaches stderr of every
# command that loads xCAT::Scope.
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
require xCAT::Scope;

is_deeply(\@warnings, [], 'loading xCAT::Scope writes no warning');
can_ok('xCAT::Scope', 'get_broadcast_scope');

done_testing();
