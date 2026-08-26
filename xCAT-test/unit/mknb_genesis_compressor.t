#!/usr/bin/env perl
use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage, TestingAndDebugging::ProhibitNoStrict)

use FindBin;
use Test::More;

BEGIN {
    package xCAT::Utils;
    $INC{'xCAT/Utils.pm'} = __FILE__;

    package xCAT::TableUtils;
    $INC{'xCAT/TableUtils.pm'} = __FILE__;

    package xCAT::NetworkUtils;
    $INC{'xCAT/NetworkUtils.pm'} = __FILE__;

    package xCAT::NodeRange;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::noderange"} = sub { return; };
    }
    $INC{'xCAT/NodeRange.pm'} = __FILE__;
}

my $plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/mknb.pm";
require $plugin;

is(
    xCAT_plugin::mknb::genesis_lzma_command(1, 1),
    'lzma -C crc32 -9',
    'lzma is used when it is available',
);
is(
    xCAT_plugin::mknb::genesis_lzma_command(0, 1),
    'xz --format=lzma -C crc32 -9',
    'xz writes the lzma container when lzma is unavailable',
);
is(
    xCAT_plugin::mknb::genesis_lzma_command(0, 0),
    undef,
    'no lzma command is selected when neither program is available',
);

is_deeply(
    xCAT_plugin::mknb::_genesis_lzma_plan(0, 1, '/tftpboot', 'x86_64', 'token'),
    {
        command     => 'xz --format=lzma -C crc32 -9',
        staging     => '/tftpboot/xcat/genesis.fs.x86_64.lzma.token',
        destination => '/tftpboot/xcat/genesis.fs.x86_64.lzma',
    },
    'the compressor plan preserves the staging and final lzma paths',
);
is(
    xCAT_plugin::mknb::_genesis_lzma_plan(0, 0, '/tftpboot', 'x86_64', 'token'),
    undef,
    'the caller receives no lzma plan and can fall back to gzip',
);

my $plan = xCAT_plugin::mknb::_genesis_lzma_plan(
    0, 1, '/tftpboot', 'x86_64', 'token',
);
my (@messages, @commands, @moves, @removed);
my $created = xCAT_plugin::mknb::_create_genesis_lzma(
    $plan,
    '/tmp/genesis-build',
    'x86_64',
    '/tftpboot',
    sub { push @messages, @_ },
    sub { push @commands, $_[0]; return 0; },
    sub { push @removed, $_[0]; return 1; },
    sub { push @moves, [@_]; return 1; },
);
is($created, '/tftpboot/xcat/genesis.fs.x86_64.lzma',
    'a successful compression returns the published initrd path');
is_deeply(
    \@commands,
    ['cd /tmp/genesis-build; find . | cpio -o -H newc | xz --format=lzma -C crc32 -9 > /tftpboot/xcat/genesis.fs.x86_64.lzma.token'],
    'the selected compressor writes the unique staging path',
);
is_deeply(
    \@moves,
    [[
        '/tftpboot/xcat/genesis.fs.x86_64.lzma.token',
        '/tftpboot/xcat/genesis.fs.x86_64.lzma',
    ]],
    'a successful compression publishes the staging image atomically',
);
is_deeply(\@removed, [], 'a successful compression keeps the staging image for rename');

(@messages, @commands, @moves, @removed) = ();
$created = xCAT_plugin::mknb::_create_genesis_lzma(
    $plan,
    '/tmp/genesis-build',
    'x86_64',
    '/tftpboot',
    sub { push @messages, @_ },
    sub { push @commands, $_[0]; return 7; },
    sub { push @removed, $_[0]; return 1; },
    sub { push @moves, [@_]; return 1; },
);
is($created, undef, 'a failed compression leaves the caller on the gzip fallback');
is_deeply(
    \@removed,
    ['/tftpboot/xcat/genesis.fs.x86_64.lzma.token'],
    'a failed compression removes its staging image',
);
is_deeply(\@moves, [], 'a failed compression is never published');
like($messages[-1]->{data}[0], qr/falling back to gzip/,
    'a failed compression reports the gzip fallback');

done_testing();
