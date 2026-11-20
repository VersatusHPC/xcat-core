#!/usr/bin/env perl
# genpassword produces secret material: the DDNS TSIG key, the ISC DHCP OMAPI
# key and, when site.genpasswords is set, BMC passwords. Every byte must come
# from the OS CSPRNG, never from Perl's rand.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Temp qw(tempdir);
use Test::More;

# CORE::GLOBAL only reaches code compiled after the override, so install it
# before xCAT::Utils is compiled. File::Temp
# and Test::More are already compiled and keep the real rand.
our $CORE_RNG_CALLS = 0;

BEGIN {
    *CORE::GLOBAL::rand  = sub { $main::CORE_RNG_CALLS++; return 0; };
    *CORE::GLOBAL::srand = sub { $main::CORE_RNG_CALLS++; return 0; };
}

require xCAT::Utils;

my $dir = tempdir(CLEANUP => 1);

# 256 is not a multiple of 62, so a generator that maps every byte makes the
# first 8 letters more likely. Bytes 248 to 255 must be discarded.
my $fixture = "$dir/random.fixture";
open(my $fixture_handle, '>:raw', $fixture) or die "open $fixture: $!";
print {$fixture_handle} pack('C*', 0, 1, 61, 62, 248, 249, 255, 5);
close($fixture_handle);

# 0 -> a, 1 -> b, 61 -> 9, 62 -> a, 248/249/255 discarded, 5 -> f
my $expected = 'ab9af';

{
    local $xCAT::Utils::RANDOM_DEVICE = $fixture;
    $CORE_RNG_CALLS = 0;
    my $password = eval { xCAT::Utils::genpassword(5) };
    is($password, $expected,
        'genpassword maps the bytes it reads from the random device');
    is($CORE_RNG_CALLS, 0, 'genpassword calls neither rand nor srand');
}

{
    my $absent = "$dir/absent";
    local $xCAT::Utils::RANDOM_DEVICE = $absent;
    my $password = eval { xCAT::Utils::genpassword(8) };
    ok(!defined $password,
        'genpassword returns nothing when the random device is unreadable');
    like($@, qr/\Q$absent\E/,
        'genpassword reports the random device it could not read');
}

# A device that returns only discarded bytes must stop the routine, not spin.
# The fixture holds far more of them than a bounded run can read, so the routine
# has to stop at its own limit and not at the end of the file. The alarm makes a
# routine that never stops fail rather than hang the suite.
{
    my $rejected = "$dir/rejected.fixture";
    open(my $rejected_handle, '>:raw', $rejected) or die "open $rejected: $!";
    print {$rejected_handle} chr(0xff) x 65536;
    close($rejected_handle);

    local $xCAT::Utils::RANDOM_DEVICE = $rejected;
    my $password = eval {
        local $SIG{ALRM} = sub { die "genpassword did not stop\n" };
        alarm 30;
        my $result = xCAT::Utils::genpassword(8);
        alarm 0;
        $result;
    };
    my $error = $@;
    alarm 0;
    ok(!defined $password,
        'genpassword returns nothing when the device discards every byte');
    like($error, qr/no usable byte/,
        'genpassword stops after a bounded number of reads');
}

{
    $CORE_RNG_CALLS = 0;
    my $password = xCAT::Utils::genpassword(32);
    is(length($password), 32, 'genpassword returns the requested length');
    like($password, qr/\A[A-Za-z0-9]{32}\z/,
        'genpassword returns only alphanumeric characters');
    is(length(xCAT::Utils::genpassword()), 8,
        'genpassword defaults to 8 characters');
    is($CORE_RNG_CALLS, 0,
        'genpassword uses no Perl rand against the real device');
}

done_testing();
