#!/usr/bin/env perl
#
# The resolver arguments of an IPv6-only diskless node.
#
# The node takes a static ip= in the initial ramdisk, so DHCPv6 gives it no name server and no
# search list. imgurl and XCAT= name the server by its short name, and the initial ramdisk
# answered "wget: unable to resolve host address" for the root image.
use strict;
use warnings;

use FindBin;
use Test::More;

use lib "$FindBin::Bin/../../perl-xCAT";
use xCAT::NetworkUtils;

is( xCAT::NetworkUtils::dracut_resolver_args( ['2001:db8:147::1'], 'cluster.example' ),
    'nameserver=2001:db8:147::1 XCATDOMAIN=cluster.example',
    'the node is given its name server and its domain' );

is( xCAT::NetworkUtils::dracut_resolver_args( [ '2001:db8:147::1', '2001:db8:147::2' ], 'cluster.example' ),
    'nameserver=2001:db8:147::1 nameserver=2001:db8:147::2 XCATDOMAIN=cluster.example',
    'every name server gets its own argument, in order' );

is( xCAT::NetworkUtils::dracut_resolver_args( ['2001:db8:147::1'], '' ),
    'nameserver=2001:db8:147::1',
    'a node with no domain gets no domain argument' );

is( xCAT::NetworkUtils::dracut_resolver_args( [], 'cluster.example' ), '',
    'a node with no name server gets no argument, since a search list alone resolves nothing' );

is( xCAT::NetworkUtils::dracut_resolver_args( undef, undef ), '',
    'no input gives no argument' );

done_testing();
