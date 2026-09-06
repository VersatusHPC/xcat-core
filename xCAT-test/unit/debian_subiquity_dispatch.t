#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Test::More;

# A subiquity install differs from a preseed install in four more places than the kernel command
# line: which template is read, where the answer file is written, which pre-install script runs,
# and whether the initrd keeps the xCAT overlay. Each decision used to be an if/else inside
# mkinstall, which needs a management node, so none of them could be run. Each one now returns
# its answer, and this file runs them.

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
my $plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/debian.pm";
plan skip_all => 'debian.pm not found' unless -r $plugin;
eval { require $plugin; 1 } or BAIL_OUT("could not load debian.pm: $@");

my $D = 'xCAT_plugin::debian';

my $SUBIQUITY = '/install/custom/ubuntu/compute.subiquity.tmpl';
my $PRESEED   = '/install/custom/ubuntu/compute.tmpl';

# --- install_template_path ---------------------------------------------------
# The site directory answers first; the shipped one is reached only when it has nothing.
# Record every lookup, and answer from a fake template directory.
{
    my @asked;
    my %present;
    my $lookup = sub {
        my ($dir, $profile, $osvers, $osarch, $genos_or_osvers, $genos) = @_;
        my $key = join('|', $dir, $profile, $osvers, $osarch, $genos_or_osvers,
            defined($genos) ? $genos : '');
        push @asked, $key;
        return $present{$key};
    };
    my $find = $D->can('install_template_path');
    ok($find, 'install_template_path is where mkinstall selects the template');

    %present = ("/custom|compute|ubuntu24.04|x86_64|ubuntu24.04|" => $PRESEED);
    @asked = ();
    is($find->('ubuntu24.04', '/custom', '/share', 'compute', 'ubuntu24.04', 'x86_64', $lookup),
        $PRESEED, 'a site template is used in preference to the shipped one');
    is(scalar @asked, 1, 'and the shipped directory is not searched at all');

    %present = ("/share|compute|ubuntu24.04|x86_64|ubuntu24.04|" => '/share/compute.tmpl');
    @asked = ();
    is($find->('ubuntu24.04', '/custom', '/share', 'compute', 'ubuntu24.04', 'x86_64', $lookup),
        '/share/compute.tmpl', 'with no site template the shipped one is used');
    is($asked[0], "/custom|compute|ubuntu24.04|x86_64|ubuntu24.04|",
        'and the site directory was asked first');

    %present = ();
    @asked = ();
    is($find->('ubuntu24.04', '/custom', '/share', 'compute', 'ubuntu24.04', 'x86_64', $lookup),
        undef, 'an osimage with no template anywhere gets undef, which mkinstall reports');

    # A site directory that answers with a subiquity template is searched again with
    # "subiquity" as the genos hint.
    %present = (
        "/custom|compute|ubuntu24.04|x86_64|ubuntu24.04|"          => $SUBIQUITY,
        "/custom|compute|ubuntu24.04|x86_64|ubuntu24.04|subiquity" => $SUBIQUITY,
    );
    @asked = ();
    is($find->('ubuntu24.04', '/custom', '/share', 'compute', 'ubuntu24.04', 'x86_64', $lookup),
        $SUBIQUITY, 'a subiquity site template is kept');
    is(scalar @asked, 2, 'after a second search of the same directory');
    like($asked[1], qr/\|subiquity$/, 'which names subiquity as the genos');

    @asked = ();
    is($find->('ubuntu18.04', '/custom', '/share', 'compute', 'ubuntu24.04', 'x86_64', $lookup),
        $SUBIQUITY, 'a release before 20.04 takes the site template as it found it');
    is(scalar @asked, 1, 'with no second search');
}

# --- autoinst_target ---------------------------------------------------------
{
    my ($path, $seeddir) = $D->can('autoinst_target')->('ubuntu24.04', $SUBIQUITY,
        '/install/autoinst/cn1');
    is($path, '/install/autoinst/cn1/user-data',
        'a subiquity image renders into user-data, which nocloud-net reads');
    is($seeddir, '/install/autoinst/cn1',
        'and names the seed directory the caller has to create');

    my ($ppath, $pseed) = $D->can('autoinst_target')->('ubuntu24.04', $PRESEED,
        '/install/autoinst/cn1');
    is($ppath, '/install/autoinst/cn1',
        'a preseed image renders into the plain per-node file');
    is($pseed, undef, 'and needs no seed directory');
}

# --- install_prescript -------------------------------------------------------
{
    is($D->can('install_prescript')->('ubuntu24.04', $SUBIQUITY, 'ubuntu', 'x86_64', '/s'),
        '/s/pre.ubuntu.subiquity', 'a subiquity install runs the subiquity pre script');
    is($D->can('install_prescript')->('ubuntu24.04', $PRESEED, 'ubuntu', 'x86_64', '/s'),
        '/s/pre.ubuntu', 'a preseed install runs the plain one');
    is($D->can('install_prescript')->('ubuntu24.04', $SUBIQUITY, 'ubuntu', 'ppc64le', '/s'),
        '/s/pre.ubuntu.ppc64',
        'ubuntu on ppc64 runs the ppc64 script, whatever the template says');
    is($D->can('install_prescript')->('debian12', $PRESEED, 'debian', 'x86_64', '/s'),
        '/s/pre.debian', 'debian runs its own');
}

# --- install_initrd_action ---------------------------------------------------
{
    is($D->can('install_initrd_action')->('ubuntu24.04', $SUBIQUITY), 'copy',
        'the subiquity initrd is served as it shipped, so casper can read it');
    is($D->can('install_initrd_action')->('ubuntu24.04', $PRESEED), 'customize',
        'the debian-installer initrd gets the xCAT overlay appended');
    is($D->can('install_initrd_action')->('ubuntu18.04', $SUBIQUITY), 'customize',
        'and a release before 20.04 gets the overlay even from a subiquity template');
}

done_testing();
