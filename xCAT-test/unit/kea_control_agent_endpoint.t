#!/usr/bin/env perl
#
# makedhcp restarted Kea instead of using the Control Agent on a management node whose only IPv4
# address is 127.0.0.1: the client resolved 127.0.0.1 with AI_ADDRCONFIG, and glibc returns no
# IPv4 address there.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More tests => 12;

use xCAT::DHCP::Backend::Kea;

my $backend = xCAT::DHCP::Backend::Kea->new();

my $ep = $backend->control_agent_endpoint();
is( $ep->{host}, '127.0.0.1', 'the default endpoint is the IPv4 loopback' );
is( $ep->{port}, 8000, 'the default port is 8000' );
is( $ep->{socket_args}{PeerHost}, '127.0.0.1', 'the socket connects to the endpoint' );
ok( exists $ep->{socket_args}{GetAddrInfoFlags} && !$ep->{socket_args}{GetAddrInfoFlags},
    'the socket resolves without AI_ADDRCONFIG' );

my $v6 = $backend->control_agent_endpoint( host => '2001:db8::1', port => 8001 );
is_deeply( [ @{$v6}{qw(host port authority)} ], [ '2001:db8::1', 8001, '[2001:db8::1]:8001' ],
    'an IPv6 endpoint keeps its brackets only in the Host header' );

my $url = $backend->control_agent_endpoint( url => 'http://ca.example:8080/kea' );
is_deeply( [ @{$url}{qw(host port path)} ], [ 'ca.example', 8080, '/kea' ], 'a URL gives host, port and path' );
is( $backend->control_agent_endpoint( url => 'https://x/' ), undef, 'a URL the client cannot use gives no endpoint' );

my $ok = $backend->parse_http_response(
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 14\r\n\r\n[{\"result\":0}]trailing");
ok( $ok->{success}, 'a 200 response is a success' );
is( $ok->{content}, '[{"result":0}]', 'the body stops at Content-Length' );

my $bad = $backend->parse_http_response("HTTP/1.1 403 Forbidden\r\n\r\nno");
ok( !$bad->{success}, 'a 403 response is a failure' );
is( $bad->{reason}, '403 Forbidden', 'the failure carries the status line' );
ok( !$backend->parse_http_response('')->{success}, 'an empty response is a failure' );
