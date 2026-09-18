#!/usr/bin/perl
# buildrpms.pl must build a SUSE target itself. The SUSE behaviour used to live in a pinned copy
# of this script in the CI repository, which the SUSE pipeline copied over buildrpms.pl at
# checkout. That copy fell 381 lines behind the original: when #7835 added
# verify-genesis-payload to the genesis build-support tarball, the SUSE build started failing in
# %install with "verify-genesis-payload: No such file or directory", because the copy did not
# stage the new file. One script cannot drift from itself.
use strict;
use warnings;
use Test::More tests => 12;
use File::Temp qw(tempdir);

my $script = 'buildrpms.pl';
$script = "../$script" unless -f $script;
die "cannot find buildrpms.pl" unless -f $script;
my $src = do { open my $fh, '<', $script or die $!; local $/; <$fh> };

# is_suse_target decides both behaviours, so drive it rather than matching the text around it.
my ($sub) = $src =~ /(sub is_suse_target \{.*?\n\})/s
    or die "is_suse_target is not in buildrpms.pl -- the SUSE support was removed or renamed";
eval "package T; $sub; 1" or die "cannot load is_suse_target: $@";

ok( T::is_suse_target('opensuse-leap-15.6-x86_64'),  'a Leap target is a SUSE target');
ok( T::is_suse_target('opensuse-leap-15.6-ppc64le'), '... on either arch');
ok( T::is_suse_target('sles-12.5-x86_64'),           'a SLE target built from media is a SUSE target');
ok(!T::is_suse_target('alma+epel-10-x86_64'),        'an EL target is not');
ok(!T::is_suse_target('rocky-10-riscv64-xcat'),      'nor is the cross-built riscv64 target');

# The perl requires generator: openSUSE ships perllib.attr with the generator commented out, so
# without this a SUSE-built perl-xCAT carries no perl(...) requires at all and xCAT dies at load.
like($src, qr/__perllib_requires.*perl\.req/s,
    'a SUSE chroot points the perl requires generator at perl.req');
like($src, qr/chroot_additional_packages.*perl-generators/s,
    'an EL chroot still gets perl-generators');

# The genesis BuildRequires: EL names that SUSE either spells differently or already provides.
for my $pair (['kernel-core', 'kernel-default'], ['nmap-ncat', 'netcat-openbsd'],
              ['procps-ng', 'procps'], ['iproute', 'iproute2']) {
    my ($el, $suse) = @{$pair};
    like($src, qr/'\Q$el\E'\s*=>\s*'\Q$suse\E'/,
        "the genesis spec's $el becomes $suse on SUSE");
}

# verify-genesis-payload is the file whose absence broke the forked copy. The product script
# stages it, and that is the property the fork could not keep.
like($src, qr/verify-genesis-payload/,
    'buildrpms.pl stages verify-genesis-payload into the genesis build support');
