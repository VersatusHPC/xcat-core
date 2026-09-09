#!/usr/bin/env perl
# The Ubuntu Genesis build root must carry every command the Ubuntu dracut module marks
# mandatory. dracut_install reports a missing command and returns, so a command the build
# root does not supply leaves a hole in the image and the build still exits 0.
#
# The mandatory list is read by RUNNING the module: module-setup.sh is sourced with
# dracut_install shadowed, _dracut_install_opt neutralised (its callers are optional by
# construction), and install() is called. The package list is read by extracting the
# REQUIRED_PACKAGES assignment from builddeb-genesis-base and evaluating it.
use strict;
use warnings;

use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(repo_path);

my $builder = repo_path('xCAT-genesis-builder/builddeb-genesis-base');
my $module  = repo_path('xCAT-genesis-builder/dracut_105/ubuntu/module-setup.sh');
plan skip_all => 'builddeb-genesis-base not found' unless -f $builder;
plan skip_all => 'ubuntu module-setup.sh not found' unless -f $module;
plan tests => 8;

# Commands the Ubuntu dracut module marks mandatory that a minimal Ubuntu server root does
# NOT already provide, and the package that supplies each one. Every entry here has to be in
# REQUIRED_PACKAGES or the image ships without the command.
my %PACKAGE_FOR = (
    dhclient  => 'isc-dhcp-client',
    ifenslave => 'ifenslave',
    hwclock   => 'util-linux-extra',
);

my %mandatory = map { $_ => 1 } mandatory_commands($module);
my @packages  = required_packages($builder);

for my $command (sort keys %PACKAGE_FOR) {
    ok($mandatory{$command}, "the Ubuntu dracut module installs '$command' unconditionally");
    ok(scalar(grep { $_ eq $PACKAGE_FOR{$command} } @packages),
       "the build root installs $PACKAGE_FOR{$command}, which provides '$command'");
}

# doxcat asks dhclient for the provisioning lease. An image without it never gets an address,
# so the node netboots and never reports in -- the failure this test exists for.
ok($mandatory{dhclient} && scalar(grep { $_ eq 'isc-dhcp-client' } @packages),
   'the Genesis image can obtain a DHCP lease');

# dracut_install is silent about a hole, so the payload needs its own gate before it is
# packaged. This is the EL path's behaviour (xCAT-genesis-base.spec runs the same verifier).
my $text = do { open my $fh, '<', $builder or die "$builder: $!"; local $/; <$fh> };
like($text, qr{verify-genesis-payload}, 'builddeb-genesis-base verifies the payload it packages');

# mandatory_commands($module): source the dracut module with dracut_install shadowed, call
# install(), and return the bare command names it installs unconditionally. Absolute paths are
# data files, not commands, and are left out.
sub mandatory_commands {
    my ($path) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $driver = "$dir/collect.sh";
    open my $fh, '>', $driver or die "$driver: $!";
    print $fh <<"BASH";
dracut_install() { printf '%s\\n' "\$\@"; }
instmods() { :; }
inst_multiple() { :; }
inst() { :; }
dpkg-architecture() { echo x86_64-linux-gnu; }
. '$path'
# Every caller of _dracut_install_opt is optional by construction: it installs only what the
# build root already has. Neutralise it AFTER sourcing so it cannot add to the mandatory set.
_dracut_install_opt() { :; }
install
BASH
    close $fh;
    my @out = qx{bash '$driver' 2>/dev/null};
    BAIL_OUT("running install() from $path produced nothing") unless @out;
    my %seen;
    my @names = grep { !$seen{$_}++ } grep { length && !m{^/} } map { chomp; $_ } @out;
    BAIL_OUT("install() from $path named no bare commands") unless @names;
    return @names;
}

# required_packages($path): extract the REQUIRED_PACKAGES assignment from the build script and
# evaluate it, so the list comes from the value the script actually uses.
sub required_packages {
    my ($path) = @_;
    my $text = do { open my $fh, '<', $path or die "$path: $!"; local $/; <$fh> };
    my ($block) = $text =~ /^(REQUIRED_PACKAGES="[^"]*")/ms;
    BAIL_OUT("no REQUIRED_PACKAGES assignment in $path") unless $block;
    my $out = qx{bash -c 'set -u; $block; printf "%s\\n" \$REQUIRED_PACKAGES' 2>/dev/null};
    my @packages = grep { length } split /\s+/, ($out // '');
    BAIL_OUT("REQUIRED_PACKAGES in $path evaluated to nothing") unless @packages;
    return @packages;
}
