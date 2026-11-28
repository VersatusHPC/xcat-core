#!/usr/bin/env perl
# mkopenhpc refuses a management node that is not EL, and a node that is not EL 9 x86_64.
# The request runs through process_request with the nodetype table stubbed, so it stops at
# those two checks and changes nothing on the host.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
    package xCAT::Table;
    sub new { return; }
    $INC{'xCAT/Table.pm'} = __FILE__;
}

require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/mkopenhpc.pm";

my $repo = tempdir(CLEANUP => 1);
mkdir("$repo/repodata") or die "mkdir $repo/repodata: $!";

# MsgUtils empties the reply after the callback returns, so the callback copies the errors.
my @errors;
my $callback = sub { push @errors, @{ $_[0]->{error} || [] } };
my $rc = eval {
    xCAT_plugin::mkopenhpc::process_request(
        { command => ['mkopenhpc'], arg => [ '-r', $repo ], node => ['cn1'] },
        $callback, sub { die "mkopenhpc ran a subcommand\n" });
};
is($@, '', 'mkopenhpc checks the management node without a die');
is($rc, 1, 'mkopenhpc returns an error');

if (-f '/etc/redhat-release') {
    is_deeply(\@errors, ['mkopenhpc supports EL 9 x86_64 nodes only: cn1'],
        'an EL management node passes the check and refuses the node with no osimage');
} else {
    is_deeply(\@errors, ['mkopenhpc runs on an EL management node.'],
        'a management node that is not EL is refused');
}

done_testing();
