#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::RestUtils;

# Decisions of xcatws.cgi. This module loads no other xCAT module.

use strict;
use warnings;

use Socket ();

#---
# =head3 error_ends_request
# Descriptions: Whether the errors that xcatd sent end a REST request with an error reply.
#               A command that writes to stderr and exits 0 (xdsh) sends error lines with
#               errorcode 0. Those lines are output, and the output handler gets them.
# Arguments: $errors -- array ref of error lines, or undef; $errorcode -- the errorcode, or undef
# Returns: 1 when the reply is an error, else 0
# =cut
#---
sub error_ends_request
{
    my ($errors, $errorcode) = @_;
    return 0 unless $errors && @$errors;
    return 1 unless defined $errorcode;
    return $errorcode eq '0' ? 0 : 1;
}

#---
# =head3 remote_client
# Descriptions: The value xcatws.cgi sends to xcatd as remote_client: the name and the aliases of
#               the REST client, from a reverse lookup of its address. The host column of a
#               policy row is matched against this value.
# Arguments: $addr -- the client address from the web server; $lookup -- optional code ref with
#            the gethostbyaddr interface, for a test
# Returns: "name,aliases", empty fields when the lookup finds nothing
# =cut
#---
sub remote_client
{
    my ($addr, $lookup) = @_;
    $lookup ||= sub { return gethostbyaddr($_[0], $_[1]) };
    my ($packed, $family);
    if (defined $addr) {
        # An IPv4-mapped address is the IPv4 client. /etc/hosts names it in IPv4 form only.
        $addr =~ s/^::ffff:(\d+\.\d+\.\d+\.\d+)$/$1/i;
        if ($addr =~ /:/) {
            ($packed, $family) = (Socket::inet_pton(Socket::AF_INET6(), $addr), Socket::AF_INET6());
        } else {
            ($packed, $family) = (Socket::inet_aton($addr), Socket::AF_INET());
        }
    }
    my ($name, $aliases) = defined $packed ? $lookup->($packed, $family) : ();
    return ($name // '') . ',' . ($aliases // '');
}

1;
