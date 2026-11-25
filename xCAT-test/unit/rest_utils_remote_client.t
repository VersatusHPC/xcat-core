#!/usr/bin/env perl
#
# A REST client that connects over IPv6 reached xcatd with remote_client ",", so no policy row
# with a host value matched it. xcatws.cgi packed the address with inet_aton, which knows IPv4
# only.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Socket qw(AF_INET AF_INET6 inet_aton inet_pton);
use Test::More tests => 6;

use xCAT::RestUtils;

# A resolver with two entries. It answers only for the exact packed address and family.
my %hosts = (
    AF_INET() . ':' . inet_aton('192.0.2.20')         => [ 'cn4', 'cn4.lab' ],
    AF_INET6() . ':' . inet_pton(AF_INET6, '2001:db8::20') => [ 'cn6', 'cn6.lab' ],
);
my $lookup = sub {
    my ($packed, $family) = @_;
    return () unless defined $packed;
    my $hit = $hosts{"$family:$packed"};
    return $hit ? @$hit : ();
};

is(xCAT::RestUtils::remote_client('192.0.2.20', $lookup), 'cn4,cn4.lab', 'an IPv4 client resolves to its name');
is(xCAT::RestUtils::remote_client('2001:db8::20', $lookup), 'cn6,cn6.lab', 'an IPv6 client resolves to its name');
is(xCAT::RestUtils::remote_client('2001:DB8:0:0::20', $lookup), 'cn6,cn6.lab', 'an IPv6 address in another notation resolves the same');
is(xCAT::RestUtils::remote_client('::ffff:192.0.2.20', $lookup), 'cn4,cn4.lab', 'an IPv4-mapped IPv6 address resolves as the IPv4 client');
is(xCAT::RestUtils::remote_client('2001:db8::99', $lookup), ',', 'an address with no name gives empty fields');

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    xCAT::RestUtils::remote_client('2001:db8::99', $lookup);
}
is(scalar(@warnings), 0, 'an address with no name writes no warning') or diag(@warnings);
