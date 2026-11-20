#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::RestUtils;

# Decisions of xcatws.cgi. This module loads no other xCAT module.

use strict;
use warnings;

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

1;
