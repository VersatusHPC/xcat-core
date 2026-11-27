#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT", "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
    package xCAT::Scope;
    $INC{'xCAT/Scope.pm'} = __FILE__;

    package xCAT::TableUtils;
    sub getTftpDir { return '/tftpboot'; }
    sub get_site_attribute { return; }
    $INC{'xCAT/TableUtils.pm'} = __FILE__;

    package xCAT::NetworkUtils;

    # The node has no address: the mkdef set none and no name resolves.
    sub getipaddr  { return; }
    sub my_ip_facing { return (0, '192.0.2.1'); }
    $INC{'xCAT/NetworkUtils.pm'} = __FILE__;

    package xCAT::DBobjUtils;
    sub getNetwkInfo { return (); }
    $INC{'xCAT/DBobjUtils.pm'} = __FILE__;

    package xCAT::MsgUtils;
    $INC{'xCAT/MsgUtils.pm'} = __FILE__;

    package xCAT::Table;
    sub new { return; }
    $INC{'xCAT/Table.pm'} = __FILE__;

    package xCAT::Usage;
    $INC{'xCAT/Usage.pm'} = __FILE__;

    package xCAT::InstUtils;
    sub is_me { return 0; }
    $INC{'xCAT/InstUtils.pm'} = __FILE__;
}

require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/yaboot.pm";

my $tftpdir = tempdir(CLEANUP => 1);
my $node    = 'testnode1';

my ($rc, $err) = xCAT_plugin::yaboot::setstate(
    $node,
    { $node => [ { kernel => 'rhels6.99/ppc64/vmlinuz', initrd => 'rhels6.99/ppc64/initrd.img', kcmdline => 'debug' } ] },
    { $node => [ { currstate => 'install rhels6.99-ppc64-compute' } ] },
    {},
    $tftpdir,
    {},
    undef
);

is($rc, 1, 'setstate fails for a node that has no address');
like($err, qr/unable to resolve IP/, 'the error names the unresolved address');
ok(!-e "$tftpdir/etc/$node", 'no yaboot configuration is written for the node');

done_testing();
