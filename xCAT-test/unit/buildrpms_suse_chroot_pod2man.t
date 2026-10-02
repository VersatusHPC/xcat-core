#!/usr/bin/env perl
# Four packages fail in the openSUSE Leap 15.6 mock chroot, in %build:
#
#   ./xpod2man  -> Can't locate Pod/Man.pm in @INC ... at ./xpod2man line 12.
#   pod2man pods/man1/xcattest.1.pod -> pod2man: command not found
#
# On Leap 15.6 /usr/bin/pod2man and perl(Pod::Man) are both in the 'perl' package, while
# /usr/bin/perl is in 'perl-base'. The chroot_setup_cmd installs
# patterns-devel-base-devel_rpm_build, which brings perl-base, and the mock template sets
# install_weak_deps=0, so 'perl' never arrives. There is no perl-podlators on Leap 15.6.
#
# A BuildRequires cannot fix this: buildrpms.pl builds with rpmbuild --nodeps, so the spec's
# build dependencies install nothing. The chroot is where the package has to be named.
#
# mock_chroot_extras is pure, so this writes no /etc/mock file and runs no mock.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../build-utils/lib";
use Test::More;
use XCAT::BuildUtils qw(mock_chroot_extras);

my @suse_targets = qw(opensuse-leap-15.6-x86_64 opensuse-leap-42.3-x86_64 sles15-x86_64);
my @el_targets   = qw(alma+epel-10-x86_64 alma+epel-9-ppc64le openeuler-24.03sp4-x86_64);

# Every package that runs pod2man or xpod2man at %build.
for my $pkg (qw(xCAT-buildkit xCAT-client xCAT-vlan xCAT-test)) {
    for my $t (@suse_targets) {
        my @x = mock_chroot_extras($pkg, $t);
        ok(grep({ $_ eq 'perl' } @x), "$pkg on $t asks for perl, which carries pod2man");
    }
}

# perl-xCAT keeps perl-generators on EL and must never ask for it on SUSE.
ok(grep({ $_ eq 'perl-generators' } mock_chroot_extras('perl-xCAT', 'alma+epel-10-x86_64')),
   'perl-xCAT on EL still asks for perl-generators');
for my $t (@suse_targets) {
    ok(!grep({ $_ eq 'perl-generators' } mock_chroot_extras('perl-xCAT', $t)),
       "perl-generators is not asked for on $t, where no such package exists");
}

# An EL chroot already carries pod2man, and naming a package that is not needed would change
# every EL buildroot.
for my $t (@el_targets) {
    ok(!grep({ $_ eq 'perl' } mock_chroot_extras('xCAT-client', $t)),
       "xCAT-client on $t needs nothing extra");
}

done_testing();
