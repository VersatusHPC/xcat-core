#!/usr/bin/env perl
use strict;
use warnings;

use File::Spec;
use FindBin;
use Test::More;

# The Genesis payload is architecture specific, and the two worlds spell POWER LE
# differently: Debian says ppc64el, xCAT says ppc64. The deb PACKAGE NAMES follow Debian
# -- xcat-genesis-scripts-amd64 still carries Conflicts/Replaces for its old xCAT-named
# form, and xCAT-genesis-builder/builddeb-genesis-base derives both genesis package names
# from `dpkg --print-architecture`. The PATH inside the package follows xCAT, because
# mknb.pm reads share/xcat/netboot/genesis/ppc64.
#
# A scripts package that follows xCAT instead depends on xcat-genesis-base-ppc64, which no
# apt channel publishes, so the xcat deb was given a hard dependency on the amd64 scripts
# package and every ppc64el management node installed the amd64 payload. `nodeset <node>
# shell` then fails with "Could not find genesis.kernel.ppc64".

my $root = File::Spec->catdir($FindBin::Bin, '..', '..');

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Unable to read $path: $!";
    my $text = do { local $/; <$fh> };
    close($fh);
    return $text;
}

# The Depends field of a binary stanza, with its continuation lines joined.
sub depends_of {
    my ($control, $package) = @_;
    my ($stanza) = $control =~ /^Package: \Q$package\E$(.*?)(?:\n\n|\z)/ms;
    return unless defined $stanza;
    my ($depends) = $stanza =~ /^Depends:[ \t]*(.*?)(?=\n\S|\z)/ms;
    return unless defined $depends;
    $depends =~ s/\s+/ /g;
    return $depends;
}

# The command line `make` would run, expanded by make itself. Reading the recipe text
# instead would pass on a rules file that computes the name and never uses it.
sub gencontrol_command {
    my ($package, $arch) = @_;
    my $rules = File::Spec->catfile($root, $package, 'debian', 'rules');
    local $ENV{DEB_HOST_ARCH} = $arch;
    my @out = `make -n -f $rules binary-arch 2>/dev/null`;
    return join('', grep { /dh_gencontrol/ } @out);
}

my %DEB_ARCH = (amd64 => 'x86_64', ppc64el => 'ppc64');

# --- the scripts package is named for the Debian architecture ------------------
foreach my $arch (sort keys %DEB_ARCH) {
    my $path = File::Spec->catfile($root, 'xCAT-genesis-scripts', 'debian', "control-$arch");
    ok(-f $path, "xCAT-genesis-scripts has a control file for $arch")
        or next;
    my $control = read_file($path);
    like($control, qr/^Package: xcat-genesis-scripts-\Q$arch\E$/m,
        "the $arch scripts package is named for the Debian architecture");
    my $depends = depends_of($control, "xcat-genesis-scripts-$arch");
    ok(defined $depends, "the $arch scripts package declares Depends")
        or next;
    like($depends, qr/\bxcat-genesis-base-\Q$arch\E\b/,
        "the $arch scripts package depends on the published xcat-genesis-base-$arch");
    unlike($depends, qr/\bxcat-genesis-base-$DEB_ARCH{$arch}\b/,
        "the $arch scripts package does not ask for the xCAT-named genesis base");
}

# An installed xcat-genesis-scripts-ppc64 owns the same files under the same paths, so the
# renamed package has to take them over.
my $ppc_control = read_file(
    File::Spec->catfile($root, 'xCAT-genesis-scripts', 'debian', 'control-ppc64el'));
foreach my $field (qw(Conflicts Replaces)) {
    like($ppc_control, qr/^$field:.*\bxcat-genesis-scripts-ppc64\b/m,
        "the renamed ppc64el scripts package $field the xCAT-named one it replaces");
}

# --- xcat and xcatsn depend on the scripts package for their own architecture ---
foreach my $package (qw(xCAT xCATsn)) {
    my $deb = lc $package;
    my $control = read_file(File::Spec->catfile($root, $package, 'debian', 'control'));
    my $depends = depends_of($control, $deb);
    ok(defined $depends, "$deb declares Depends") or next;
    unlike($depends, qr/\bxcat-genesis-scripts-(?:amd64|ppc64el|ppc64)\b/,
        "$deb does not hard-code one architecture of xcat-genesis-scripts");
    like($depends, qr/\$\{xcat:Genesis\} \(>= 2\.13-snap000000000000\)/,
        "$deb takes the genesis scripts package from a substitution variable, pinned to this build");

    foreach my $arch (sort keys %DEB_ARCH) {
        my $command = gencontrol_command($package, $arch);
        like($command, qr/-Vxcat:Genesis=xcat-genesis-scripts-\Q$arch\E(?:\s|$)/,
            "a $arch build of $deb resolves the genesis scripts package to xcat-genesis-scripts-$arch");
    }
}

done_testing();
