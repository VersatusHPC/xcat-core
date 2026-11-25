#!/usr/bin/env perl

# AAsn.pm asks /usr/sbin/in.tftpd which TFTP server it is before it starts the daemon. tftp-hpa
# has no long options: it logs "Unknown option" for one, then reads a TFTP request from stdin
# and logs "recvfrom: Socket operation on non-socket". The probe ran at each xcatd start.

use strict;
use warnings;

use FindBin;
use Test::More;

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use xCAT::SvrUtils;

can_ok('xCAT::SvrUtils', 'in_tftpd_is_atftpd') or do { done_testing(); exit 1 };

# Each fake answers like the real binary for the options it knows. An option it does not know
# makes it log what the real one logs.
my @syslog;

my %tftp_hpa_options = map { $_ => 1 } qw(-4 -6 -a -B -c -l -L -m -p -P -r -R -s -t -T -u -U -v -V);

sub tftp_hpa {
    my @args = @_;
    foreach my $arg (@args) {
        return "tftp-hpa 5.2, with remap, with tcpwrappers\n" if $arg eq '-V';
        push @syslog, "in.tftpd: Unknown option: '\\0'" unless $tftp_hpa_options{$arg};
    }
    push @syslog, 'in.tftpd: recvfrom: Socket operation on non-socket';
    return '';
}

sub atftpd {
    my @args = @_;
    return "atftp-0.8.0 (server)\n" if grep { $_ eq '-V' or $_ eq '--version' } @args;
    return "Usage: tftpd [options] [directory]\n --daemon\n --group <group>\n --logfile <file>\n"
      if grep { $_ eq '--help' or $_ eq '-h' } @args;
    return '';
}

@syslog = ();
is(xCAT::SvrUtils::in_tftpd_is_atftpd(\&tftp_hpa), 0, 'tftp-hpa is not atftpd');
is_deeply(\@syslog, [], 'the probe makes tftp-hpa log nothing');

is(xCAT::SvrUtils::in_tftpd_is_atftpd(\&atftpd), 1, 'atftpd is detected');

is(xCAT::SvrUtils::in_tftpd_is_atftpd(sub { return '' }), 0,
    'a server that prints nothing is not atftpd');

done_testing();
