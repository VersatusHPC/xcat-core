#!/usr/bin/env perl

# makedns writes the DNSSEC lines of the named.conf options block from the bind version.
# bind 9.16 already reports "option 'dnssec-enable' is obsolete" at every load, and 9.18
# refuses the option. Validation stays off for 9.16.6 and later.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

use xCAT::DNS::NamedOptions;

sub opts { join('', xCAT::DNS::NamedOptions::dnssec_options(@_)) }

is(opts('9.11.36'), '', 'bind 9.11 gets no DNSSEC line');
is(opts('9.16.5'),  '', 'bind 9.16.5 gets no DNSSEC line');
is(opts('9.16.23'), "\tdnssec-validation no;\n", 'bind 9.16.23 (EL 9, openEuler 22.03) turns validation off, without dnssec-enable');
is(opts('9.16.6'),  "\tdnssec-validation no;\n", 'bind 9.16.6 turns validation off, without dnssec-enable');
is(opts('9.18.28'), "\tdnssec-validation no;\n", 'bind 9.18 turns validation off');
is(opts('9.20.4'),  "\tdnssec-validation no;\n", 'bind 9.20 turns validation off');
is(opts(undef), '', 'no version gets no DNSSEC line');
is(opts(''),    '', 'an empty version gets no DNSSEC line');

done_testing();
