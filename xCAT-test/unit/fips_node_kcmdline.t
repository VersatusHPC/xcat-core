#!/usr/bin/env perl
# An osimage with fips=1 installs its nodes in FIPS mode. xCAT::FIPS decides
# which nodes support it and what nodeset adds to the installer kernel line.
use strict;
use warnings;

BEGIN { $ENV{XCATROOT} = '/nonexistent/xcatroot' }

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

require xCAT::FIPS;

sub kcmdline { return [ xCAT::FIPS->kcmdline_fips(@_) ] }

is_deeply(kcmdline(undef, 'alma9.8', 'x86_64', 'install'), [ '', undef ],
    'fips unset: nothing is added');
is_deeply(kcmdline('0', 'alma9.8', 'x86_64', 'install'), [ '', undef ],
    'fips=0: nothing is added');
is_deeply(kcmdline('1', 'alma9.8', 'x86_64', 'install'), [ 'fips=1', undef ],
    'EL 9 diskful: fips=1');
is_deeply(kcmdline('yes', 'rhels10.0', 'x86_64', 'install'), [ 'fips=1', undef ],
    'EL 10 diskful, fips=yes: fips=1');

foreach my $case (
    [ 'alma9.8',     'x86_64',  'netboot',   qr/diskless/ ],
    [ 'alma9.8',     'x86_64',  'statelite', qr/statelite/ ],
    [ 'rhels8.10',   'x86_64',  'install',   qr/rhels8\.10/ ],
    [ 'sles15.6',    'x86_64',  'install',   qr/sles15\.6/ ],
    [ 'ubuntu24.04', 'x86_64',  'install',   qr/ubuntu24\.04/ ],
    [ 'alma9.8',     'ppc64le', 'install',   qr/ppc64le/ ],
  )
{
    my ($os, $arch, $prov, $why) = @$case;
    my ($arg, $err) = xCAT::FIPS->kcmdline_fips('1', $os, $arch, $prov);
    is($arg, undef, "$os $arch $prov: fips=1 is refused");
    like($err // '', $why, '... and the error names the reason');
}

ok(xCAT::FIPS->wanted('1'),     '1 asks for FIPS');
ok(xCAT::FIPS->wanted('Yes'),   'Yes asks for FIPS');
ok(!xCAT::FIPS->wanted(''),     'empty does not');
ok(!xCAT::FIPS->wanted('no'),   'no does not');
ok(!xCAT::FIPS->wanted(undef),  'unset does not');

done_testing();
