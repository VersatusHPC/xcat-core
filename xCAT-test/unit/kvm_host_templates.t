#!/usr/bin/env perl

# The files that the kvm profile resolves for an EL 8, 9 and 10 host. The lookup is the one
# mkinstall does: get_tmpl_file_name and get_pkglist_file_name over one platform directory.
# A host that resolves no template fails at nodeset. A host that resolves kvm.tmpl gets a
# RHEL 5 kickstart, which anaconda on EL 8 and later rejects.

use strict;
use warnings;

use File::Basename qw(basename);
use File::Slurper qw(read_text);
use FindBin;
use Test::More;

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";

use xCAT::SvrUtils;

my $SHARE = "$FindBin::Bin/../../xCAT-server/share/xcat/install";

# platform directory => osvers prefix, as copycds names them
my %OS = (rh => 'rhels', alma => 'alma', rocky => 'rocky');

foreach my $platform (sort keys %OS) {
    foreach my $major (8, 9, 10) {
        my $osvers = "$OS{$platform}$major.4";
        foreach my $arch (qw(x86_64 ppc64le)) {
            my $what = "$platform $osvers $arch";

            # The osimage path passes osvers as genos; the nodetype path passes rhelN for rhels.
            my @genos = ($osvers);
            push @genos, "rhel$major" if $platform eq 'rh';

            foreach my $genos (@genos) {
                my $tmpl = xCAT::SvrUtils::get_tmpl_file_name("$SHARE/$platform", 'kvm', $osvers, $arch, $genos);
                is(defined($tmpl) ? basename($tmpl) : undef, "kvm.$OS{$platform}$major.tmpl",
                    "$what (genos $genos) resolves the kvm template of its release");

                my $pkglist = xCAT::SvrUtils::get_pkglist_file_name("$SHARE/$platform", 'kvm', $osvers, $arch, $genos);
                is(defined($pkglist) ? basename($pkglist) : undef, "kvm.$OS{$platform}$major.pkglist",
                    "$what (genos $genos) resolves the kvm pkglist of its release");
            }

            my $tmpl = xCAT::SvrUtils::get_tmpl_file_name("$SHARE/$platform", 'kvm', $osvers, $arch, $osvers);
            my $pkglist = xCAT::SvrUtils::get_pkglist_file_name("$SHARE/$platform", 'kvm', $osvers, $arch, $osvers);
            SKIP: {
                skip "$what: no kvm files resolved", 4 unless $tmpl && $pkglist && -r $tmpl && -r $pkglist;

                my $ks = read_text($tmpl);
                like($ks, qr/^%end\s*$/m, "$what: the kickstart closes its sections with %end");
                unlike($ks, qr/^\s*(?:langsupport|mouse|key\s+--skip|auth\s+--enablemd5|install)\b/m,
                    "$what: the kickstart carries no directive that EL 8 and later anaconda removed");

                my %pkgs = map { $_ => 1 } grep { /\S/ && !/^#/ } map { s/^\s+|\s+$//gr } split(/\n/, read_text($pkglist));
                ok($pkgs{'qemu-kvm'} && $pkgs{'libvirt'}, "$what: the pkglist installs qemu-kvm and libvirt");
                ok(!grep({ $pkgs{$_} } qw(ntp bridge-utils kvm python-virtinst)),
                    "$what: the pkglist names no package that EL 8 and later do not ship");
            }
        }
    }
}

done_testing();
