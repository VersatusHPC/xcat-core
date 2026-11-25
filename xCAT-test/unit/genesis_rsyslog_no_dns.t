#!/usr/bin/env perl
# Genesis runs with the hostname "(none)". rsyslogd resolves the local hostname at each start,
# and doxcat restarts it while DHCP still changes the routes and resolv.conf, so the lookup can
# fail with EAI_SYSTEM: "getaddrinfo failed obtaining local hostname ... error: System error".
# Genesis receives no remote messages, so it has no use for DNS in rsyslogd.
#
# doxcat replaces the LAST line of /etc/rsyslog.conf with the forward to the MN, so that line
# must stay the local file action.
use strict;
use warnings;

use FindBin;
use Test::More;

my $root = "$FindBin::Bin/../..";

for my $file ('xCAT-genesis-base/dracut_105/el/rsyslog.conf', 'xCAT-genesis-base/dracut_105/ubuntu/rsyslog.conf') {
    open my $fh, '<', "$root/$file" or die "read $file: $!";
    my @lines = grep { /\S/ && !/^\s*#/ } <$fh>;
    close $fh;

    ok((grep { /^\s*global\(\s*net\.enableDNS\s*=\s*"off"\s*\)\s*$/i } @lines),
        "$file turns off DNS in rsyslogd");
    is($lines[-1], "*.* /var/log/xcat.genesis\n", "$file keeps the local file action last for doxcat");
}

done_testing();
