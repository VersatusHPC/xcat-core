#!/usr/bin/perl
# rpm on the EL build host compresses payloads with zstd. rpm 4.11, which the SLE 12 family
# ships, cannot decompress that: it reads the header, starts the transaction, and dies part way
# through with
#
#   error: unpacking of archive failed: cpio: Bad magic
#
# which leaves the node with a half-installed set and no hint that compression is the cause. The
# MN's own rpm advertises rpmlib(PayloadIsXz) and nothing for zstd.
#
# One flat build is installed on every family, so the payload has to be one they all read. xz is
# understood by every rpm since 4.8, the builder's included.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $script = dirname(__FILE__) . '/../../buildrpms.pl';
open my $fh, '<', $script or die "cannot read $script: $!\n";
my $src = do { local $/; <$fh> };
close $fh;

my ($mock) = $src =~ /(mock -r \$chroot.*?--rebuild[^\n]*)/s
    or die "the mock --rebuild invocation is no longer recognisable in buildrpms.pl";

like($mock, qr/--define "_binary_payload \S+"/,
    'the binary payload compressor is pinned rather than left to the build host');
like($mock, qr/_binary_payload w\d+\.xzdio/,
    '... to xz, which rpm 4.11 can unpack');
unlike($mock, qr/_binary_payload \S*zstdio/,
    '... and never to zstd, which it cannot');

done_testing();
