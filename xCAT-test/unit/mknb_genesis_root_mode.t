#!/usr/bin/env perl
# The staging directory of mknb becomes / of the Genesis initramfs. File::Temp makes it 0700, so a
# daemon that drops root (chronyd, dhcpcd) cannot read /etc and resolves no name.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Temp qw(tempdir);
use Test::More;

BEGIN { $INC{'xCAT/Utils.pm'} = 1; $INC{'xCAT/MsgUtils.pm'} = 1;
        $INC{'xCAT/Table.pm'} = 1; $INC{'xCAT/NetworkUtils.pm'} = 1;
        $INC{'xCAT/TableUtils.pm'} = 1; $INC{'xCAT_monitoring/monitorctrl.pm'} = 1; }
BEGIN { no warnings 'once'; *xCAT::Utils::isSELINUX = sub { return 1 }; }

require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/mknb.pm";

foreach my $type (qw(legacy exported)) {
    my $root = tempdir('mknb-root-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    is(sprintf('%04o', (stat $root)[2] & 07777), '0700', "$type: the scratch root starts 0700");
    my ($rc) = xCAT_plugin::mknb::stage_genesis_payload(
        genesis_type => $type,
        genesis_dir  => '/opt/xcat/share/xcat/netboot/genesis/x86_64',
        tftpdir      => '/tftpboot',
        arch         => 'x86_64',
        tempdir      => $root,
        run          => sub { return 0 },
    );
    is($rc, 0, "$type: staging succeeds");
    is(sprintf('%04o', (stat $root)[2] & 07777), '0755',
        "$type: the image root is readable by a daemon that dropped root");
}

done_testing();
