#!/usr/bin/env perl
use strict;
use warnings;

# Keep modules out of an installed /opt/xcat, so the checkout is what loads.
BEGIN { $ENV{XCATROOT} = '/nonexistent/xcatroot' }

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

use xCAT::Schema;

like($INC{'xCAT/Schema.pm'}, qr/\Q$FindBin::Bin\E/,
    'xCAT::Schema comes from this checkout, not from /opt/xcat');

my $linuximage = $xCAT::Schema::tabspec{linuximage};
ok((grep { $_ eq 'fips' } @{ $linuximage->{cols} }), 'linuximage has a fips column');
my $coldoc = $linuximage->{descriptions}{fips};
ok(defined $coldoc, '... and the column has a description');
like($coldoc // '', qr/fips=1/, '... that names the kernel argument');

my @attrs = grep { $_->{attr_name} eq 'fips' } @{ $xCAT::Schema::defspec{osimage}{attrs} };
is(scalar(@attrs), 1, 'an osimage has one fips attribute');
is($attrs[0] && $attrs[0]{tabentry}, 'linuximage.fips',
    '... stored in linuximage.fips');
is($attrs[0] && $attrs[0]{access_tabentry}, 'linuximage.imagename=attr:imagename',
    '... and found by the imagename column');

done_testing();
