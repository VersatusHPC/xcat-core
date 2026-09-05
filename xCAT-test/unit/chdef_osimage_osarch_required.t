#!/usr/bin/env perl
# chdef creates an object that does not exist. For an osimage the created row carried no
# osarch, so a misspelled image name became a real definition: nodeset accepted it and
# rinstall stopped two layers later on "'osarch' attribute not defined", naming no image.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use Test::More;

BEGIN { $ENV{XCATROOT} = $ENV{XCATROOT} || '/opt/xcat'; }
require "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/DBobjectdefs.pm";

can_ok('xCAT_plugin::DBobjectdefs', 'osimage_create_error')
    or BAIL_OUT('DBobjectdefs has no osimage_create_error to drive');

my @defined = (
    'ubuntu26.04-x86_64-netboot-compute',
    'ubuntu22.04.5-ppc64el-install-compute',
    'rhels9.4-x86_64-install-compute',
);

sub refused {
    my ($name, $attrs) = @_;
    return xCAT_plugin::DBobjectdefs::osimage_create_error($name, $attrs, \@defined);
}

# --- an osimage without osarch is refused, not created -----------------------
my $typo = refused('ubuntu26.04.4-x86_64-netboot-compute', { profile => 'compute' });
ok($typo, 'chdef refuses to create an osimage that has no osarch');
like($typo, qr/\Qubuntu26.04.4-x86_64-netboot-compute\E/,
    'and the refusal names the osimage that was asked for');
like($typo, qr/\Qubuntu26.04-x86_64-netboot-compute\E/,
    'and names the one defined osimage that differs in one field');
unlike($typo, qr/\Qrhels9.4-x86_64-install-compute\E/,
    'and does not list an osimage that differs in three fields');

# The architecture spelling is the same class of miss, one field away.
my $arch = refused('ubuntu22.04.5-ppc64le-install-compute', {});
like($arch, qr/\Qubuntu22.04.5-ppc64el-install-compute\E/,
    'a ppc64le/ppc64el disagreement is reported as the near miss');

# --- the row that carries osarch is still created ----------------------------
is(refused('ubuntu26.04-riscv64-netboot-compute', { osarch => 'riscv64' }), undef,
    'an osimage that carries osarch is created as before');
is(refused('rhels9.4-x86_64-install-compute', { osarch => 'x86_64', profile => 'compute' }), undef,
    'osarch is the only requirement chdef adds');

# An empty osarch is the same failure as a missing one.
ok(refused('ubuntu26.04-x86_65-netboot-compute', { osarch => '' }),
    'an empty osarch does not satisfy the requirement');

# --- a name with nothing like it reports the failure alone -------------------
my $lonely = refused('sles15.6-aarch64-netboot-compute', {});
ok($lonely, 'an unrelated new osimage name is refused too');
unlike($lonely, qr/similar name/,
    'and no near miss is claimed when none of the defined names is one field away');

# --- the near miss list itself ----------------------------------------------
my @near = xCAT_plugin::DBobjectdefs::osimage_name_near_misses(
    'ubuntu26.04-x86_64-netboot-compute', \@defined);
is_deeply(\@near, [], 'a name that is already defined is not its own near miss');

@near = xCAT_plugin::DBobjectdefs::osimage_name_near_misses(
    'ubuntu26.04-x86_64-netboot-service', \@defined);
is_deeply(\@near, ['ubuntu26.04-x86_64-netboot-compute'],
    'one field of difference is a near miss');

@near = xCAT_plugin::DBobjectdefs::osimage_name_near_misses(
    'ubuntu26.04-x86_64-netboot', \@defined);
is_deeply(\@near, [], 'a name with fewer fields is not reported as a near miss');

done_testing();
