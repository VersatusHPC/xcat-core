#!/usr/bin/env perl
#
# getipaddr caches a resolved address in %::hostiphash and answers later calls
# from it. The cache bypass tests OnlyV6 and GetAllAddresses, and does not test
# OnlyV4, so a caller that asks for IPv4 can be handed a cached IPv6 address.
#
# The cache is filled by whichever lookup ran first. An unrestricted lookup
# passes AF_UNSPEC to getaddrinfo, and on a dual-stack management node with an
# AAAA record that answers with the IPv6 address, which is then stored. xcatd is
# long-lived and %::hostiphash is a global, so any earlier caller in the process
# poisons every OnlyV4 caller that follows.
#
# What it costs: debian.pm builds the Subiquity install command line with
# getipaddr($host, OnlyV4 => 1) and writes nfsroot=<address>:/install. With an
# IPv6 address that renders as nfsroot=2001:db8::1:/install, which is not a
# parseable nfsroot, so the installer never mounts and the node never installs.
# dhcp.pm and mknb.pm carry four more OnlyV4 callers with the same exposure.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use Test::More;

use xCAT::NetworkUtils;

# The address an unrestricted lookup left behind on a dual-stack host.
$::hostiphash{'mn.cluster'}{hostip} = '2001:db8::1';

my $only_v4 = xCAT::NetworkUtils->getipaddr('mn.cluster', OnlyV4 => 1);

ok(!defined($only_v4) || $only_v4 !~ /:/,
    'OnlyV4 does not return the IPv6 address an earlier lookup cached')
  or diag("getipaddr returned '$only_v4', which renders as nfsroot=$only_v4:/install");

# An IPv4 entry must still be served from the cache: the bypass is about the
# family of the cached answer, not about disabling the cache for OnlyV4.
$::hostiphash{'v4.cluster'}{hostip} = '10.1.2.3';
is(xCAT::NetworkUtils->getipaddr('v4.cluster', OnlyV4 => 1), '10.1.2.3',
    'an IPv4 cache entry is still served to an OnlyV4 caller');

# An OnlyV4 lookup must not rewrite the entry it skipped. It asked for IPv4 for
# itself; every unrestricted caller of the same host still gets what was cached.
# This needs a name that really resolves, or the lookup fails, nothing is written,
# and the assertion passes for the wrong reason.
$::hostiphash{'localhost'}{hostip} = '2001:db8::1';
my $resolved = xCAT::NetworkUtils->getipaddr('localhost', OnlyV4 => 1);
plan skip_all => 'localhost does not resolve to IPv4 here'
  unless defined($resolved) && $resolved !~ /:/;
is($resolved, '127.0.0.1', 'OnlyV4 resolves past the cached IPv6 entry');
is(xCAT::NetworkUtils->getipaddr('localhost'), '2001:db8::1',
    'the OnlyV4 lookup left the cached address alone for unrestricted callers');

done_testing();
