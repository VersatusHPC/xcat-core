#!/usr/bin/env perl
# Ubuntu copycd names an osimage with the Debian architecture, so a ppc64le node
# provisions from a ppc64el osimage. The flat installation cases build the osimage
# name from the node arch attribute. This test drives the real xcattest expansion
# over the real case files and checks that both halves spell the architecture the
# same way.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

use xCAT::Utils;

my $xcattest = "$FindBin::Bin/../xcattest";
my $casedir  = "$FindBin::Bin/../autotest/testcase/installation";

# The architecture token copycd puts in the osimage name for Ubuntu ppc64el media.
my $media_arch = xCAT::Utils->xcat_arch_from_debian('ppc64el');
BAIL_OUT("xCAT::Utils cannot map the ppc64el media architecture") unless $media_arch;

open(my $fh, '<', $xcattest) or BAIL_OUT("cannot read $xcattest: $!");
my $source = do { local $/; <$fh> };
close($fh);

my ($getfunc) = $source =~ /^(sub getfunc\b.*?^\})/ms;
BAIL_OUT("cannot extract getfunc from $xcattest") unless $getfunc;

# Optional: the fix adds a helper that getfunc dispatches to.
my ($helpers) = $source =~ /^(sub getosimagearch\b.*?^\})/ms;
$helpers = '' unless defined $helpers;

# Node attributes the stub answers with. The node arch is the kernel arch, the
# spelling uname reports and the spelling the confs and genesis use.
our %NODE;

my $scratch = <<"PERL";
package XCATTestScratch;
sub getnodeattr {
    my (\$node, \$attr) = \@_;
    return 'Unknown' unless exists \$main::NODE{\$node} and exists \$main::NODE{\$node}{\$attr};
    return \$main::NODE{\$node}{\$attr};
}
sub getobjectattr { die "getobjectattr must not be called\\n" }
sub gettablevalue { die "gettablevalue must not be called\\n" }
$getfunc
$helpers
1;
PERL

eval $scratch;    ## no critic
BAIL_OUT("cannot load the extracted xcattest routines: $@") if $@;

#--------------------------------------------------------
# expand_case: run one case file through the xcattest substitutions, the same
# order xcattest uses -- the $$VAR config values first, then the __FUNC()__ macros.
#--------------------------------------------------------
sub expand_case {
    my ($file, $node) = @_;
    open(my $cfh, '<', $file) or BAIL_OUT("cannot read $file: $!");
    my @out;
    while (my $line = <$cfh>) {
        $line =~ s/\$\$CN/$node/g;
        $line =~ s/\$\$\w+/placeholder/g;
        push @out, XCATTestScratch::getfunc($line);
    }
    close($cfh);
    return join('', @out);
}

#--------------------------------------------------------
# osimage_archs: every architecture token the expanded case asks an osimage for.
#--------------------------------------------------------
sub osimage_archs {
    my ($text, $osvers) = @_;
    my @found;
    while ($text =~ /\b\Q$osvers\E-([\w]+)-(?:install|netboot)-compute/g) {
        push @found, $1;
    }
    return @found;
}

my @cases = (
    ["$casedir/reg_linux_diskfull_installation_flat", 'diskfull'],
    ["$casedir/reg_linux_diskless_installation_flat", 'diskless'],
);

# An Ubuntu ppc64le node must ask for the osimage copycd creates.
%NODE = (cn1 => {
        os        => 'ubuntu24.04.4',
        arch      => 'ppc64le',
        mgt       => 'kvm',
        vmstorage => 'dir:///var/lib/libvirt/images',
});
for my $case (@cases) {
    my ($file, $label) = @{$case};
    my @archs = osimage_archs(expand_case($file, 'cn1'), 'ubuntu24.04.4');
    cmp_ok(scalar @archs, '>=', 4, "$label names an Ubuntu osimage at least four times");
    my %spelt = map { $_ => 1 } @archs;
    is_deeply([sort keys %spelt], [$media_arch],
        "$label asks a ppc64le node for the $media_arch osimage copycd creates");
}

# x86_64 keeps its own spelling: copycd names the amd64 media osimage x86_64.
%NODE = (cn1 => { os => 'ubuntu24.04.4', arch => 'x86_64', mgt => 'kvm' });
for my $case (@cases) {
    my ($file, $label) = @{$case};
    my %spelt = map { $_ => 1 } osimage_archs(expand_case($file, 'cn1'), 'ubuntu24.04.4');
    is_deeply([sort keys %spelt], ['x86_64'],
        "$label leaves the x86_64 osimage name alone");
}

# A ppc64le node that is not Debian family keeps ppc64le: copycd names the
# Red Hat osimage with the kernel architecture.
%NODE = (cn1 => { os => 'rhels9.4', arch => 'ppc64le', mgt => 'kvm' });
for my $case (@cases) {
    my ($file, $label) = @{$case};
    my %spelt = map { $_ => 1 } osimage_archs(expand_case($file, 'cn1'), 'rhels9.4');
    is_deeply([sort keys %spelt], ['ppc64le'],
        "$label leaves the Red Hat osimage name alone");
}

done_testing();
