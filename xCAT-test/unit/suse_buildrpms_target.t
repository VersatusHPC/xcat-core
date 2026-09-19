#!/usr/bin/perl
# buildrpms.pl must build a SUSE target itself. The SUSE behaviour used to live in a pinned copy
# of this script in the CI repository, which the SUSE pipeline copied over buildrpms.pl at
# checkout. That copy fell 381 lines behind the original: when #7835 added
# verify-genesis-payload to the genesis build-support tarball, the SUSE build started failing in
# %install with "verify-genesis-payload: No such file or directory", because the copy did not
# stage the new file. One script cannot drift from itself.
use strict;
use warnings;
use Test::More tests => 20;
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
ok( T::is_suse_target('opensuse-leap-42.3-x86_64'),  'the Leap 42.3 target is a SUSE target');
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

# The map is release-aware: SLE 12 predates the Leap 15 package splits, so names that are correct
# on Leap resolve to nothing on the SLE 12 SP5 media. Drive the routine rather than reading it.
my ($mapsub) = $src =~ /(sub genesis_buildrequires_map \{.*?\n\})/s
    or die "genesis_buildrequires_map is not in buildrpms.pl -- the map was inlined again";
eval "package M; $mapsub; 1" or die "cannot load genesis_buildrequires_map: $@";

{
    my %leap = M::genesis_buildrequires_map('opensuse-leap-15.6-x86_64');
    is($leap{'net-tools'}, 'net-tools-deprecated', 'Leap keeps the net-tools split');
    ok(!exists $leap{'hostname'},        'Leap has a hostname package, so it is not rewritten');
    ok(!exists $leap{'openssh-server'},  'Leap has openssh-server, so it is not rewritten');
    ok(!exists $leap{'tmux'},            'Leap has tmux, so it is kept');

    my %sle12 = M::genesis_buildrequires_map('opensuse-leap-42.3-x86_64');
    ok(!exists $sle12{'net-tools'},      'Leap 42.3 never split net-tools, so it is left alone');
    is($sle12{'openssh-clients'}, 'openssh',   'Leap 42.3 ships one openssh package (clients)');
    is($sle12{'openssh-server'},  'openssh',   '... and the server is in it too');
    ok(!exists $sle12{'tmux'}, 'Leap 42.3 has tmux, so it is kept');
}
