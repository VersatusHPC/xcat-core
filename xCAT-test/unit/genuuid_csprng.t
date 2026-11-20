#!/usr/bin/env perl
# genUUID with no arguments produces credential material: xcatd.pm mints the
# REST API bearer token from it. Every random bit must come from the OS CSPRNG,
# never from Perl's rand.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Temp qw(tempdir);
use Test::More;

# CORE::GLOBAL only reaches code compiled after the override, so install it
# before xCAT::Utils is compiled. File::Temp and Test::More are already
# compiled and keep the real rand.
our $CORE_RNG_CALLS = 0;

BEGIN {
    *CORE::GLOBAL::rand  = sub { $main::CORE_RNG_CALLS++; return 0; };
    *CORE::GLOBAL::srand = sub { $main::CORE_RNG_CALLS++; return 0; };
}

require xCAT::Utils;

my $dir = tempdir(CLEANUP => 1);

# Sixteen known bytes. RFC 4122 fixes the version nibble of byte 6 to 4 and the
# top two bits of byte 8 to 10, so 0x06 becomes 0x46 and 0x08 becomes 0x88.
my $fixture = "$dir/uuid.fixture";
open(my $fixture_handle, '>:raw', $fixture) or die "open $fixture: $!";
print {$fixture_handle} pack('C*', 0 .. 15);
close($fixture_handle);

my $expected = '00010203-0405-4607-8809-0a0b0c0d0e0f';

{
    local $xCAT::Utils::RANDOM_DEVICE = $fixture;
    $CORE_RNG_CALLS = 0;
    my $uuid = eval { xCAT::Utils::genUUID() };
    is($uuid, $expected,
        'genUUID maps the bytes it reads from the random device');
    is($CORE_RNG_CALLS, 0, 'genUUID calls neither rand nor srand');
}

# xcatd.pm calls it as a class method, so the class name arrives in @_ and the
# routine must still take the no-argument path.
{
    local $xCAT::Utils::RANDOM_DEVICE = $fixture;
    $CORE_RNG_CALLS = 0;
    my $uuid = eval { xCAT::Utils->genUUID() };
    is($uuid, $expected,
        'genUUID called as a class method reads the random device');
    is($CORE_RNG_CALLS, 0,
        'genUUID called as a class method calls neither rand nor srand');
}

{
    my $absent = "$dir/absent";
    local $xCAT::Utils::RANDOM_DEVICE = $absent;
    my $uuid = eval { xCAT::Utils::genUUID() };
    ok(!defined $uuid,
        'genUUID returns nothing when the random device is unreadable');
    like($@, qr/\Q$absent\E/,
        'genUUID reports the random device it could not read');
}

{
    $CORE_RNG_CALLS = 0;
    my $first  = xCAT::Utils::genUUID();
    my $second = xCAT::Utils::genUUID();
    like($first,
        qr/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
        'genUUID returns an RFC 4122 version 4 UUID against the real device');
    isnt($first, $second, 'genUUID returns a different UUID on each call');
    is($CORE_RNG_CALLS, 0,
        'genUUID uses no Perl rand against the real device');
}

# The version 1 path takes its time and node from the clock and the mac, but it
# still draws the clock sequence. Bytes 0 and 1 of the fixture give 0x8001.
{
    local $xCAT::Utils::RANDOM_DEVICE = $fixture;
    $CORE_RNG_CALLS = 0;
    my $uuid = eval { xCAT::Utils::genUUID(mac => '00:11:22:33:44:55') };
    like($uuid, qr/\A[0-9a-f]{8}-[0-9a-f]{4}-1[0-9a-f]{3}-8001-001122334455\z/,
        'genUUID with a mac draws the clock sequence from the random device');
    is($CORE_RNG_CALLS, 0,
        'genUUID with a mac calls neither rand nor srand');
}

# The version 5 path is a digest of the URL. It reads no random device, so an
# unreadable one must not change its answer.
SKIP: {
    my $sha1support =
      (-f '/etc/debian_version')
      ? eval { require Digest::SHA;  1 }
      : eval { require Digest::SHA1; 1 };
    skip 'no SHA1 module, genUUID falls back to the version 4 path', 1
      unless $sha1support;

    local $xCAT::Utils::RANDOM_DEVICE = "$dir/absent";
    is(xCAT::Utils::genUUID(url => 'http://xcat.org/'),
        '79986550-c42f-5b3d-653b-1df4097ad3d2',
        'genUUID with a url returns the digest of the url, with no device read');
}

done_testing();
