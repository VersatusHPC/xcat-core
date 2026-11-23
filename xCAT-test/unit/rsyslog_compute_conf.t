#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(slurp_repo_file);

# xcat-compute.conf is installed as-is into /etc/rsyslog.d on the management node.
# rsyslog warns "~ action is deprecated" at every start for the legacy discard action.
my $conf = slurp_repo_file('xCAT/etc/rsyslog.d/xcat-compute.conf');

like( $conf, qr{^:fromhost-ip, !isequal, "127\.0\.0\.1" /var/log/xcat/computes\.log;xCATTraditionalFormat9$}m,
    'remote messages go to computes.log' );
like( $conf, qr/^& stop$/m, 'remote messages stop after computes.log' );
unlike( $conf, qr/^\s*&\s*~\s*$/m, 'no legacy ~ discard action' );

done_testing();
