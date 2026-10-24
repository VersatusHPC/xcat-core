#!/usr/bin/env perl
# mknb accepted a legacy Genesis directory that holds no payload.
#
# _select_genesis_source resolves a source by directory. That is right for the OpenEmbedded and
# exported generations, whose contents _prebuilt_genesis_requested and
# _validate_prebuilt_genesis_manifest then check, and process_request reports an incomplete one
# as "Incomplete Genesis export: <dir>". The legacy generation had no such check.
#
# The two packages split that directory. xCAT-genesis-scripts owns
# share/xcat/netboot/genesis/<arch>/ because it ships fs/ there; xCAT-genesis-base ships the
# kernel beside it. So a management node that installs the scripts without the payload carries
# the directory, mknb accepts it, generates ssh keys, makes a temporary directory, and only then
# fails on "Failed to copy /opt/xcat/share/xcat/netboot/genesis/x86_64/kernel contents" -- a path
# the reader has no reason to expect, naming neither the missing package nor the real condition.
#
# Measured 2026-10-24 on xcat20-mn, an openSUSE Leap 15.6 management node: netboot/genesis/x86_64/
# exists holding fs/ alone, rpm -qa names xCAT-genesis-scripts-x86_64 and no xCAT-genesis-base,
# and mknb failed with exactly that message.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurper qw(write_text);

BEGIN { $INC{'xCAT/Utils.pm'} = 1; $INC{'xCAT/MsgUtils.pm'} = 1;
        $INC{'xCAT/Table.pm'} = 1; $INC{'xCAT/NetworkUtils.pm'} = 1;
        $INC{'xCAT/TableUtils.pm'} = 1; $INC{'xCAT_monitoring/monitorctrl.pm'} = 1; }

require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/mknb.pm";

can_ok('xCAT_plugin::mknb', 'missing_legacy_genesis_payload')
    or die('mknb has no missing_legacy_genesis_payload to drive');

# Each case is a scratch copy of share/xcat/netboot/genesis/x86_64 as the packages leave it.
sub source {
    my (%have) = @_;
    my $dir = tempdir(CLEANUP => 1) . '/x86_64';
    make_path("$dir/fs") if $have{fs};          # xCAT-genesis-scripts
    make_path($dir) unless -d $dir;
    write_text("$dir/kernel", "vmlinuz\n") if $have{kernel};   # xCAT-genesis-base
    return $dir;
}

sub missing { return xCAT_plugin::mknb::missing_legacy_genesis_payload($_[0]); }

# xcat20-mn, exactly: the scripts installed and the payload absent.
my $scripts_only = source(fs => 1);
is(missing($scripts_only), "$scripts_only/kernel",
    'a directory holding fs/ and no kernel reports the kernel as the missing file');

my $complete = source(fs => 1, kernel => 1);
is(missing($complete), undef,
    'the same directory with the kernel in it reports nothing missing');

# stage_genesis_payload copies fs/ first, so a source missing both is reported by that copy.
my $payload_only = source(kernel => 1);
is(missing($payload_only), "$payload_only/fs",
    'a directory holding the kernel and no fs/ reports fs/, the copy that runs first');

# xCAT-genesis-base has shipped the kernel as a link to a versioned name. _select_genesis_source
# already honours a symlinked legacy directory, so the payload check must honour a linked kernel.
my $linked = source(fs => 1);
my $target = tempdir(CLEANUP => 1) . '/vmlinuz-6.4.0';
write_text($target, "vmlinuz\n");
symlink($target, "$linked/kernel") or die "cannot link the kernel: $!";
is(missing($linked), undef, 'a kernel installed as a symlink is a payload');

# Never name a path for a source that was not resolved: _select_genesis_source returns an empty
# list for an unsupported architecture, and the caller must report that, not a missing file.
is(missing(undef), undef, 'an unresolved source reports nothing missing');

done_testing();
