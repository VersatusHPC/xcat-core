#!/usr/bin/env perl
#
# copycds mounted every medium with "-t udf,iso9660", so the kernel probed UDF on each ISO 9660
# DVD and logged "UDF-fs: warning (device loopN): udf_load_vrs: No VRS found".

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Test::More tests => 4;

BEGIN { $INC{'xCAT/Table.pm'} = 1; }
require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/copycds.pm";

is( xCAT_plugin::copycds::mount_types("iso9660\n"), 'iso9660', 'an ISO 9660 medium is mounted as iso9660 only' );
is( xCAT_plugin::copycds::mount_types("udf\n"), 'udf', 'a UDF medium is mounted as udf' );
is( xCAT_plugin::copycds::mount_types(''), 'udf,iso9660', 'no blkid answer keeps both types, udf first' );
is( xCAT_plugin::copycds::mount_types(undef), 'udf,iso9660', 'no blkid output keeps both types' );
