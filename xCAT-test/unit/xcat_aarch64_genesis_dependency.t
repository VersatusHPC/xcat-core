#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(slurp_repo_file);

# mknb prefers the OpenEmbedded Genesis of an architecture when it is installed.
# An aarch64 discovery boots that image, so a management node and a service node
# recommend it like the other first-class architectures.
foreach my $spec ('xCAT/xCAT.spec', 'xCATsn/xCATsn.spec') {
    like(
        slurp_repo_file($spec),
        qr/^Recommends: xCAT-genesis-openembedded-aarch64$/m,
        "$spec recommends the aarch64 OpenEmbedded Genesis image",
    );
}

done_testing();
