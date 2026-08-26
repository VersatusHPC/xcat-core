#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use XCAT::Test::File qw(slurp_repo_file);

my $rpm_weak_dependencies = join(
    "\n",
    '%if 0%{?fedora} || 0%{?rhel} >= 8 || 0%{?suse_version} >= 1500',
    'Recommends: xCAT-genesis-openembedded-x86_64',
    'Recommends: xCAT-genesis-openembedded-ppc64le',
    '%endif',
);

my $rpm_spec = slurp_repo_file('xCAT/xCAT.spec');
like(
    $rpm_spec,
    qr/^\Q$rpm_weak_dependencies\E$/m,
    'RPM weak dependencies stay inside their compatibility guard',
);
unlike(
    $rpm_spec,
    qr/^Requires:\s+xCAT-genesis-openembedded-/m,
    'missing OpenEmbedded images do not block an RPM upgrade',
);

my $deb_control = slurp_repo_file('xCAT/debian/control');
like(
    $deb_control,
    qr/^Recommends:.*\bxcat-genesis-openembedded-x86-64\b/m,
    'DEB installations recommend the first-class x86_64 image',
);
like(
    $deb_control,
    qr/^Recommends:.*\bxcat-genesis-openembedded-ppc64le\b/m,
    'DEB installations recommend the first-class ppc64le image',
);
unlike(
    $deb_control,
    qr/^Depends:.*\bxcat-genesis-openembedded-/m,
    'missing OpenEmbedded images do not block a DEB upgrade',
);

my $sn_rpm_spec = slurp_repo_file('xCATsn/xCATsn.spec');
like(
    $sn_rpm_spec,
    qr/^\Q$rpm_weak_dependencies\E$/m,
    'service-node weak dependencies stay inside their compatibility guard',
);

my $sn_deb_control = slurp_repo_file('xCATsn/debian/control');
like(
    $sn_deb_control,
    qr/^Recommends:.*\bxcat-genesis-openembedded-x86-64\b/m,
    'DEB service nodes recommend the first-class x86_64 image',
);
like(
    $sn_deb_control,
    qr/^Recommends:.*\bxcat-genesis-openembedded-ppc64le\b/m,
    'DEB service nodes recommend the first-class ppc64le image',
);

my $go_xcat_path =
  "$FindBin::Bin/../../xCAT-server/share/xcat/tools/go-xcat";
open(
    my $go_xcat_fh,
    '-|',
    'bash', '-c',
    'source "$1" || exit 1; printf "rpm:%s\\ndeb:%s\\n" '
      . '"${GO_XCAT_GENESIS_RPM_UNINSTALL_LIST[*]}" '
      . '"${GO_XCAT_GENESIS_DEB_UNINSTALL_LIST[*]}"',
    'bash', $go_xcat_path,
) or die "Unable to load $go_xcat_path: $!";
my $go_xcat_plan = do { local $/; <$go_xcat_fh> };
close($go_xcat_fh);
is($? >> 8, 0, 'go-xcat can be sourced without running its main program');
for my $architecture (qw(x86 x86_64 ppc64 ppc64le armv7hf aarch64 riscv64)) {
    like(
        $go_xcat_plan,
        qr/^rpm:.*\bxCAT-genesis-openembedded-\Q$architecture\E\b/m,
        "the RPM uninstall plan includes the $architecture image",
    );
    (my $deb_architecture = $architecture) =~ tr/_/-/;
    like(
        $go_xcat_plan,
        qr/^deb:.*\bxcat-genesis-openembedded-\Q$deb_architecture\E\b/m,
        "the DEB uninstall plan includes the $architecture image",
    );
}
my $mknb_pod = slurp_repo_file('xCAT-client/pods/man8/mknb.8.pod');
like(
    $mknb_pod,
    qr{/opt/xcat/share/xcat/netboot/genesis-openembedded/ARCH},
    'the mknb man page documents the OpenEmbedded install namespace',
);
like(
    $mknb_pod,
    qr/x86.*x86_64.*ppc64.*ppc64le.*armv7hf.*aarch64.*riscv64/s,
    'the mknb man page lists every exact OpenEmbedded architecture',
);
unlike(
    $mknb_pod,
    qr/For ppc64le, use the ppc64 architecture/,
    'the mknb man page no longer presents ppc64 as the ppc64le name',
);

my $offline_guide =
  slurp_repo_file('docs/source/guides/install-guides/common_sections.rst');
like(
    $offline_guide,
    qr/reposync.*--repofrompath=xcat-dep-common,https:\/\/xcat\.org\/.*\/xcat-dep\/common.*--repoid=xcat-dep-common.*--download-metadata/s,
    'the offline mirror command defines the common repository itself',
);
like(
    $offline_guide,
    qr{repodata/repomd\.xml\.asc}s,
    'the offline mirror includes the repository metadata signature',
);
like(
    $offline_guide,
    qr{repodata/repomd\.xml\.key}s,
    'the offline mirror includes its signing key',
);
like(
    $offline_guide,
    qr{baseurl=file://.*xcat-dep/common}s,
    'the offline guide points a repository file at the mirror',
);
like(
    $offline_guide,
    qr/dnf makecache.*--enablerepo=xcat-dep-common/s,
    'the offline guide verifies the mirrored common repository',
);
unlike(
    $offline_guide,
    qr/install .*xCAT-release.*local xcat-core/is,
    'the offline guide does not assume xCAT-release is in the core tarball',
);
unlike(
    $offline_guide,
    qr/Run .*mklocalrepo\.sh.*mirrored directory/is,
    'the offline guide does not depend on files reposync cannot download',
);

my $yum_guide =
  slurp_repo_file('docs/source/guides/install-guides/yum/configure_xcat.rst');
like(
    $yum_guide,
    qr/start-after: BEGIN_configure_xcat_local_repo_xcat-dep_DNF/,
    'the DNF guide includes the DNF common repository steps',
);

my $zypper_guide =
  slurp_repo_file('docs/source/guides/install-guides/zypper/configure_xcat.rst');
like(
    $zypper_guide,
    qr/start-after: BEGIN_configure_xcat_local_repo_xcat-dep_ZYPPER/,
    'the zypper guide includes its own common repository steps',
);
unlike(
    $zypper_guide,
    qr/start-after: BEGIN_configure_xcat_local_repo_xcat-dep_DNF/,
    'the zypper guide does not include DNF-only setup',
);

done_testing();
