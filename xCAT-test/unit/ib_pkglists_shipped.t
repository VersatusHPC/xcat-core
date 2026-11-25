#!/usr/bin/env perl
# The InfiniBand package lists for the distribution RDMA stack: what each list resolves to through
# the genimage resolver, and that the xCAT-server packages ship the directories that hold them.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";
use Test::More;
use XCAT::Test::File qw(repo_path slurp_repo_file);
use imgutils;

my $share = 'xCAT-server/share/xcat';

# The ${XCATROOT} of an installed xCAT-server holds share/xcat, so the checkout's xCAT-server
# directory stands in for it.
local $ENV{XCATROOT} = repo_path('xCAT-server');

my @el_ib = sort qw(rdma-core libibverbs-utils librdmacm-utils infiniband-diags ibacm opensm
  perftest ucx);
my @ubuntu_ib = sort qw(rdma-core ibverbs-utils rdmacm-utils infiniband-diags ibacm opensm
  perftest ucx-utils);

# resolve <list> -- the package names the list gives in its first pass, and the INCLUDE lines
# that did not resolve.
sub resolve {
    my ($relative) = @_;
    my %names = imgutils::get_package_names(repo_path($relative));
    my (@packages, @bad);
    for my $dir (keys %{ $names{1} || {} }) {
        if ($dir eq 'INCLUDEBAD') {
            push @bad, @{ $names{1}{$dir} };
        } elsif ($dir ne 'ENVLIST') {
            push @packages, @{ $names{1}{$dir} };
        }
    }
    return ([ sort @packages ], \@bad);
}

for my $release (qw(rhels9 rhels10)) {
    my $list = "$share/ib/netboot/rh/ib.$release.x86_64.pkglist";
    ok(-r repo_path($list), "$list exists") or next;
    my ($packages, $bad) = resolve($list);
    is_deeply($packages, \@el_ib, "$list gives the eight packages of the distribution stack");
    is_deeply($bad, [], "$list has no INCLUDE that does not resolve");
}

for my $release (qw(rhels9 rhels10)) {
    my $list = "$share/install/rh/ib.$release.x86_64.pkglist";
    ok(-r repo_path($list), "$list exists") or next;
    my ($packages, $bad) = resolve($list);
    is_deeply($bad, [], "$list has no INCLUDE that does not resolve");
    my %have = map { $_ => 1 } @$packages;
    is_deeply([ grep { !$have{$_} } @el_ib ], [],
        "$list installs the eight packages of the distribution stack");
    my ($compute) = resolve("$share/install/rh/compute.$release.pkglist");
    is_deeply([ grep { !$have{$_} } @$compute ], [],
        "$list keeps every package of compute.$release.pkglist");
}

{
    my $list = "$share/ib/netboot/ubuntu/ib.pkglist";
    ok(-r repo_path($list), "$list exists");
    my ($packages, $bad) = resolve($list);
    is_deeply($packages, \@ubuntu_ib, "$list gives the eight Ubuntu packages of the RDMA stack");
    is_deeply($bad, [], "$list has no INCLUDE that does not resolve");
}

# The spec and the debian install file are the artifact: they name what each package ships.
my $spec = slurp_repo_file('xCAT-server/xCAT-server.spec');
my $debian = slurp_repo_file('xCAT-server/debian/install');
for my $os (qw(rh ubuntu)) {
    like($spec, qr{^cp\s+share/xcat/ib/netboot/$os/\*\s+\$RPM_BUILD_ROOT/%\{prefix\}/share/xcat/ib/netboot/$os\s*$}m,
        "xCAT-server.spec ships ib/netboot/$os");
    like($spec, qr{^mkdir\s+-p\s+\$RPM_BUILD_ROOT/%\{prefix\}/share/xcat/ib/netboot/$os\s*$}m,
        "xCAT-server.spec creates ib/netboot/$os");
    like($debian, qr{^share/xcat/ib/netboot/$os/\*\s+opt/xcat/share/xcat/ib/netboot/$os\s*$}m,
        "the xCAT-server deb ships ib/netboot/$os");
}

done_testing();
