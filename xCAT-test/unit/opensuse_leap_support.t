#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use Cwd qw(realpath);

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins";
use lib "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/imgutils";

require sles;
require genimage;
use xCAT::SvrUtils;
use xCAT::Template;
use imgutils;

# xcatd (xCAT-server/sbin/xcatd) splits a handled_commands value on ":" for the
# table and on "=" for the column, then matches the node attribute against the
# rest of the value.
sub dispatch_matches {
    my ($spec, $os) = @_;
    my (undef, $cols) = split(/:/, $spec);
    my (undef, $pattern) = split(/=/, $cols, 2);
    return ($os =~ /$pattern/) ? 1 : 0;
}

sub write_media_file {
    my ($dir, $name, $text) = @_;
    my $path = "$dir/$name";
    my $parent = $path;
    $parent =~ s{/[^/]+$}{};
    make_path($parent);
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $text;
    close($fh);
}

my $leap_compute_template_path = "$FindBin::Bin/../../xCAT-server/share/xcat/install/sles/compute.leap15.tmpl";
open(my $leap_compute_template_fh, '<', $leap_compute_template_path) or die "Cannot read Leap compute template: $!";
my $leap_compute_template = do { local $/; <$leap_compute_template_fh> };
close($leap_compute_template_fh);

like($leap_compute_template, qr/<product>Leap<\/product>/, 'Leap install template selects Leap base product');
like($leap_compute_template, qr/<self_update config:type="boolean">false<\/self_update>/, 'Leap install template disables installer self-update');
like($leap_compute_template, qr/<do_online_update config:type="boolean">false<\/do_online_update>/, 'Leap install template disables online update');

my $leap_compute_pkglist_path = "$FindBin::Bin/../../xCAT-server/share/xcat/install/sles/compute.leap15.pkglist";
open(my $leap_compute_pkglist_fh, '<', $leap_compute_pkglist_path) or die "Cannot read Leap compute pkglist: $!";
my $leap_compute_pkglist = do { local $/; <$leap_compute_pkglist_fh> };
close($leap_compute_pkglist_fh);

like($leap_compute_pkglist, qr/^\@base$/m, 'Leap compute install pkglist requests a non-empty base pattern');
unlike($leap_compute_pkglist, qr/^(?:insserv-compat|net-tools-deprecated|ntp)$/m, 'Leap compute install pkglist avoids unavailable SLE package names');

my $sle15_netboot_pkglist_path = "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/sles/compute.sle15.pkglist";
open(my $sle15_netboot_pkglist_fh, '<', $sle15_netboot_pkglist_path) or die "Cannot read SLE 15 netboot pkglist: $!";
my $sle15_netboot_pkglist = do { local $/; <$sle15_netboot_pkglist_fh> };
close($sle15_netboot_pkglist_fh);

like($sle15_netboot_pkglist, qr/^xfsprogs$/m, 'SLE 15 netboot pkglist includes xfs tools required by the xCAT dracut module');
is(xCAT::Template::_sle15_install_product_name('Product-SLES'), 'SLES', 'SLE 15 install source keeps the generic SLES product');
is(xCAT::Template::_sle15_install_product_name('Module-Basesystem'), 'sle-module-basesystem', 'SLE 15 install source keeps regular modules');
is(xCAT::Template::_sle15_install_product_name('Module-SAP-Applications'), undef, 'SLE 15 install source skips SAP application module');
is(xCAT::Template::_sle15_install_product_name('Module-SAP-Business-One'), undef, 'SLE 15 install source skips SAP Business One module');
is(xCAT::Template::_sle15_install_product_name('Product-SLES_SAP'), undef, 'SLE 15 install source skips SAP product media');

my $sle_post_common_path = "$FindBin::Bin/../../xCAT-server/share/xcat/install/scripts/post.sles.common";
open(my $sle_post_common_fh, '<', $sle_post_common_path) or die "Cannot read SLE post-install script: $!";
my $sle_post_common = do { local $/; <$sle_post_common_fh> };
close($sle_post_common_fh);

like($sle_post_common, qr/systemctl stop firewalld\.service/, 'SLE post-install script stops firewalld on systemd releases');
like($sle_post_common, qr/systemctl disable firewalld\.service/, 'SLE post-install script disables firewalld after stateful install');

my $tmpdir = tempdir(CLEANUP => 1);

open(my $treeinfo, '>', "$tmpdir/.treeinfo") or die "Cannot write .treeinfo: $!";
print {$treeinfo} <<'EOF';
[release]
name = openSUSE Leap
version = 15.6

[general]
arch = x86_64
family = openSUSE Leap
name = openSUSE Leap 15.6
version = 15.6
platforms = x86_64,xen

[images-x86_64]
kernel = boot/x86_64/loader/linux
initrd = boot/x86_64/loader/initrd
EOF
close($treeinfo);

my ($tree_dist, $tree_arch) = xCAT_plugin::sles::_detect_opensuse_leap_treeinfo($tmpdir);
is($tree_dist, 'leap15.6', 'detects openSUSE Leap distname from .treeinfo');
is($tree_arch, 'x86_64', 'detects openSUSE Leap arch from .treeinfo');

my $media = <<'EOF';
openSUSE - openSUSE-Leap-15.6-NET-x86_64-Build710.3-Media
openSUSE-Leap-15.6-NET-x86_64-Build710.3
1
EOF
my $products = "/ openSUSE-Leap 15.6-1\n";
my ($media_dist, $media_arch) = xCAT_plugin::sles::_detect_opensuse_leap_media($media, $products);
is($media_dist, 'leap15.6', 'detects openSUSE Leap distname from media files');
is($media_arch, 'x86_64', 'detects openSUSE Leap arch from media files');

my ($unsupported_dist) = xCAT_plugin::sles::_detect_opensuse_leap_media(
    "openSUSE - openSUSE-Leap-17.0-NET-x86_64-Media\n",
    "/ openSUSE-Leap 17.0-1\n"
);
is($unsupported_dist, undef, 'does not detect an unknown openSUSE Leap release as supported');
ok(xCAT_plugin::sles::_copycd_distname_supported('leap15.6'), 'copycd accepts explicit Leap distname override');
ok(!xCAT_plugin::sles::_copycd_distname_supported('leap17.0'), 'copycd rejects an unknown Leap distname override');
ok(!xCAT_plugin::sles::_copycd_distname_supported('opensuse15.6'), 'copycd does not accept generic openSUSE distname override');

my %commands = %{ xCAT_plugin::sles->handled_commands };
foreach my $command (qw(mkinstall mknetboot mkstatelite mksysclone)) {
    ok(dispatch_matches($commands{$command}, 'leap15.6'), "$command handles openSUSE Leap 15 nodes");
    ok(!dispatch_matches($commands{$command}, 'leap17.0'), "$command leaves an unknown openSUSE Leap release unhandled");
    ok(!dispatch_matches($commands{$command}, 'rhels9.4'), "$command leaves Red Hat nodes to the rh plugin");
}

my @os_search = xCAT::SvrUtils::get_os_search_list('leap15.6');
is_deeply(
    \@os_search,
    [qw(leap15.6 leap15.5 leap15.4 leap15.3 leap15.2 leap15.1 leap15.0 leap15 sle15)],
    'openSUSE Leap 15.x searches exact, minor, major, then SLE 15 fallback'
);

my @unsupported_os_search = xCAT::SvrUtils::get_os_search_list('leap17.0');
unlike(
    join(' ', @unsupported_os_search),
    qr/\bsle/,
    'an unknown openSUSE Leap release does not silently use an SLE fallback'
);

my $install_dir = tempdir(CLEANUP => 1);
open(my $tmpl, '>', "$install_dir/compute.leap15.tmpl") or die "Cannot write openSUSE template: $!";
print {$tmpl} "opensuse template\n";
close($tmpl);
open(my $compute_fallback_tmpl, '>', "$install_dir/compute.sle15.tmpl") or die "Cannot write compute SLE template: $!";
print {$compute_fallback_tmpl} "sles template\n";
close($compute_fallback_tmpl);
open(my $fallback_tmpl, '>', "$install_dir/service.sle15.tmpl") or die "Cannot write SLE template: $!";
print {$fallback_tmpl} "sles template\n";
close($fallback_tmpl);
open(my $install_pkglist, '>', "$install_dir/compute.leap15.pkglist") or die "Cannot write openSUSE install pkglist: $!";
print {$install_pkglist} "chrony\n";
close($install_pkglist);
open(my $install_fallback_pkglist, '>', "$install_dir/service.sle15.pkglist") or die "Cannot write SLE install pkglist: $!";
print {$install_fallback_pkglist} "ntp\n";
close($install_fallback_pkglist);

is(
    xCAT::SvrUtils::get_tmpl_file_name($install_dir, 'compute', 'leap15.6', 'x86_64'),
    "$install_dir/compute.leap15.tmpl",
    'openSUSE template lookup prefers leap15 over SLE 15'
);
is(
    xCAT::SvrUtils::get_tmpl_file_name($install_dir, 'service', 'leap15.6', 'x86_64'),
    "$install_dir/service.sle15.tmpl",
    'openSUSE template lookup can fall back to SLE 15'
);
is(
    xCAT::SvrUtils::get_pkglist_file_name($install_dir, 'compute', 'leap15.6', 'x86_64'),
    "$install_dir/compute.leap15.pkglist",
    'openSUSE install pkglist lookup prefers leap15 over SLE 15'
);
is(
    xCAT::SvrUtils::get_pkglist_file_name($install_dir, 'service', 'leap15.6', 'x86_64'),
    "$install_dir/service.sle15.pkglist",
    'openSUSE install pkglist lookup can fall back to SLE 15'
);

my $table_netboot_dir = tempdir(CLEANUP => 1);
open(my $table_opensuse_pkglist, '>', "$table_netboot_dir/compute.leap15.pkglist") or die "Cannot write openSUSE table pkglist: $!";
print {$table_opensuse_pkglist} "zypper\n";
close($table_opensuse_pkglist);
open(my $table_pkglist, '>', "$table_netboot_dir/compute.sle15.pkglist") or die "Cannot write table pkglist: $!";
print {$table_pkglist} "aaa_base\n";
close($table_pkglist);
open(my $table_exlist, '>', "$table_netboot_dir/compute.sle15.exlist") or die "Cannot write table exlist: $!";
print {$table_exlist} "/tmp\n";
close($table_exlist);
open(my $table_postinstall, '>', "$table_netboot_dir/compute.sle15.postinstall") or die "Cannot write table postinstall: $!";
print {$table_postinstall} "#!/bin/sh\n";
close($table_postinstall);
chmod 0755, "$table_netboot_dir/compute.sle15.postinstall";

is(
    xCAT::SvrUtils::get_pkglist_file_name($table_netboot_dir, 'compute', 'leap15.6', 'x86_64'),
    "$table_netboot_dir/compute.leap15.pkglist",
    'openSUSE diskless table lookup prefers leap15 pkglist over SLE 15'
);
unlink "$table_netboot_dir/compute.leap15.pkglist";
is(
    xCAT::SvrUtils::get_pkglist_file_name($table_netboot_dir, 'compute', 'leap15.6', 'x86_64', 'sle15'),
    "$table_netboot_dir/compute.sle15.pkglist",
    'openSUSE diskless table lookup can fall back to SLE 15 pkglist'
);
is(
    xCAT::SvrUtils::get_exlist_file_name($table_netboot_dir, 'compute', 'leap15.6', 'x86_64', 'sle15'),
    "$table_netboot_dir/compute.sle15.exlist",
    'openSUSE diskless table lookup can fall back to SLE 15 exlist'
);
is(
    xCAT::SvrUtils::get_postinstall_file_name($table_netboot_dir, 'compute', 'leap15.6', 'x86_64', 'sle15'),
    "$table_netboot_dir/compute.sle15.postinstall",
    'openSUSE diskless table lookup can fall back to SLE 15 postinstall'
);

my $netboot_dir = tempdir(CLEANUP => 1);
open(my $opensuse_pkglist, '>', "$netboot_dir/compute.leap15.pkglist") or die "Cannot write openSUSE pkglist: $!";
print {$opensuse_pkglist} "zypper\n";
close($opensuse_pkglist);
open(my $pkglist, '>', "$netboot_dir/compute.sle15.pkglist") or die "Cannot write SLE pkglist: $!";
print {$pkglist} "aaa_base\n";
close($pkglist);
my $real_netboot_dir = realpath($netboot_dir) || $netboot_dir;

is(
    imgutils::get_profile_def_filename('leap15.6', 'compute', 'x86_64', $netboot_dir, 'pkglist'),
    "$real_netboot_dir/compute.leap15.pkglist",
    'openSUSE diskless profile lookup prefers leap15 pkglist over SLE 15'
);
unlink "$netboot_dir/compute.leap15.pkglist";
is(
    imgutils::get_profile_def_filename('leap15.6', 'compute', 'x86_64', $netboot_dir, 'pkglist'),
    "$real_netboot_dir/compute.sle15.pkglist",
    'openSUSE diskless profile lookup falls back to SLE 15 pkglist'
);

# openSUSE Leap 42.3 is the SLE 12 generation. Its DVD has no .treeinfo, and
# media.1/media names no product. The files below are copied from
# openSUSE-Leap-42.3-DVD-x86_64.iso.
my $leap42_dvd = tempdir(CLEANUP => 1);
write_media_file($leap42_dvd, 'media.1/media', "openSUSE\n20170719164308\n1\n");
write_media_file($leap42_dvd, 'media.1/products', "/ openSUSE-Leap 42.3-0\n");
write_media_file($leap42_dvd, 'content', <<'EOF');
CONTENTSTYLE  11
DATADIR       suse
DESCRDIR      suse/setup/descr
DISTRO        cpe:/o:opensuse:opensuse:42.3,openSUSE Leap 42.3
LINGUAS       cs da de el en_GB en_US es fr hu it ja pl pt pt_BR ru zh zh_CN zh_TW
REPOID        obsproduct://build.opensuse.org/openSUSE:Leap:42.3/openSUSE/42.3/dvd/x86_64
VENDOR        openSUSE
EOF

my ($leap42_dist, $leap42_arch) = eval { xCAT_plugin::sles::_detect_opensuse_leap_content($leap42_dvd) };
is($leap42_dist, 'leap42.3', 'detects the openSUSE Leap 42.3 distname from the DVD content file');
is($leap42_arch, 'x86_64', 'detects the openSUSE Leap 42.3 arch from the DVD content file');

my $sle12_dvd = tempdir(CLEANUP => 1);
write_media_file($sle12_dvd, 'media.1/products', "/ SLES12-SP3 12.3-0\n");
write_media_file($sle12_dvd, 'content', <<'EOF');
CONTENTSTYLE  11
DEFAULTBASE   x86_64
DISTRO        cpe:/o:suse:sles:12:sp3,SUSE Linux Enterprise Server 12 SP3
LABEL         SUSE Linux Enterprise Server 12 SP3
EOF
my ($sle12_dist) = eval { xCAT_plugin::sles::_detect_opensuse_leap_content($sle12_dvd) };
is($sle12_dist, undef, 'leaves SLES 12 media to the SLE content parser');

is(xCAT_plugin::sles::_opensuse_leap_distname('42.3'), 'leap42.3', 'maps the Leap 42.3 media version to leap42.3');
ok(xCAT_plugin::sles::_copycd_distname_supported('leap42.3'), 'copycd accepts an explicit leap42.3 distname override');
foreach my $command (qw(mkinstall mknetboot mkstatelite mksysclone)) {
    ok(dispatch_matches($commands{$command}, 'leap42.3'), "$command handles openSUSE Leap 42 nodes");
}

is_deeply(
    [ xCAT::SvrUtils::get_os_search_list('leap42.3') ],
    [qw(leap42.3 leap42.2 leap42.1 leap42.0 leap42 sles12)],
    'openSUSE Leap 42.x searches exact, minor, major, then the SLES 12 fallback'
);

my $share_install = "$FindBin::Bin/../../xCAT-server/share/xcat/install/sles";
is(
    xCAT::SvrUtils::get_tmpl_file_name($share_install, 'compute', 'leap42.3', 'x86_64'),
    "$share_install/compute.sles12.tmpl",
    'a Leap 42 compute node reads the shipped SLES 12 autoyast template'
);

my $share_netboot = "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/sles";
my $leap42_netboot_pkglist = imgutils::get_profile_def_filename('leap42.3', 'compute', 'x86_64', $share_netboot, 'pkglist');
is(
    $leap42_netboot_pkglist,
    realpath("$share_netboot/compute.leap42.x86_64.pkglist"),
    'a Leap 42 diskless image reads the shipped Leap 42 netboot pkglist'
);
my $leap42_netboot_names = '';
if ($leap42_netboot_pkglist and open(my $fh, '<', $leap42_netboot_pkglist)) {
    $leap42_netboot_names = do { local $/; <$fh> };
    close($fh);
}
like($leap42_netboot_names, qr/^kernel-default$/m, 'the Leap 42 netboot pkglist installs a kernel');
unlike($leap42_netboot_names, qr/^(?:open-lldp|fcoe-utils)$/m, 'the Leap 42 netboot pkglist names no package that the Leap 42.3 DVD lacks');

foreach my $case ([qw(leap42.3 sles)], [qw(leap15.6 sles)], [qw(sles12.3 sles)], [qw(sles11sp1 sles)], [qw(rhels9.4 rh)]) {
    my ($osver, $family) = @$case;
    is(eval { xCAT_plugin::genimage::_netboot_osfamily($osver) }, $family, "genimage reads the $family diskless scripts for $osver");
}

is(eval { xCAT_plugin::sles::_install_kcmdline('leap42.3', 'http', '10.0.0.1', 80, '/install/leap42.3/x86_64', 'cn1') },
    'autoyast=http://10.0.0.1:80/install/autoinst/cn1 install=http://10.0.0.1:80/install/leap42.3/x86_64/1 self_update=0',
    'the Leap 42 installer does not fetch an installer update');
is(eval { xCAT_plugin::sles::_install_kcmdline('sles12.3', 'http', '10.0.0.1', 80, '/install/sles12.3/x86_64', 'cn1') },
    'autoyast=http://10.0.0.1:80/install/autoinst/cn1 install=http://10.0.0.1:80/install/sles12.3/x86_64/1',
    'the SLES 12 installer command line is unchanged');

# openSUSE Leap 16.0. The offline installer image keeps the package repository and its
# .treeinfo in install/. The .treeinfo below is copied from
# Leap-16.0-offline-installer-x86_64-Build178.27.install.iso.
my $leap16_iso = tempdir(CLEANUP => 1);
write_media_file($leap16_iso, 'install/.treeinfo', <<'EOF');
[header]
version = 1.0

[release]
name = openSUSE Leap
version = 16.0

[general]
arch = x86_64
family = openSUSE Leap
name = openSUSE Leap 16.0
version = 16.0
platforms = x86_64,xen
EOF
my ($leap16_dist, $leap16_arch) = xCAT_plugin::sles::_detect_opensuse_leap_treeinfo($leap16_iso);
is($leap16_dist, 'leap16.0', 'detects openSUSE Leap 16.0 from install/.treeinfo');
is($leap16_arch, 'x86_64', 'detects the openSUSE Leap 16.0 arch from install/.treeinfo');
ok(xCAT_plugin::sles::_copycd_distname_supported('leap16.0'), 'copycd accepts an explicit leap16.0 distname override');
foreach my $command (qw(mkinstall mknetboot mkstatelite mksysclone)) {
    ok(dispatch_matches($commands{$command}, 'leap16.0'), "$command handles openSUSE Leap 16 nodes");
}
is_deeply(
    [ xCAT::SvrUtils::get_os_search_list('leap16.0') ],
    [qw(leap16.0 leap16 sle15)],
    'openSUSE Leap 16.0 searches exact, major, then the SLE 15 assets'
);

# After copycds, the copy keeps install/ beside the installer. The media root must serve the
# repository, as on a Leap 15 DVD.
my $leap16_copy = tempdir(CLEANUP => 1);
write_media_file($leap16_copy, 'install/repodata/repomd.xml', "<repomd/>\n");
write_media_file($leap16_copy, 'install/x86_64/aaa_base-1.rpm', "rpm\n");
write_media_file($leap16_copy, 'boot/x86_64/loader/linux', "kernel\n");
eval { xCAT_plugin::sles::_link_opensuse_install_tree($leap16_copy) };
ok(-r "$leap16_copy/repodata/repomd.xml", 'the copied Leap 16 media root serves the repository metadata');
ok(-r "$leap16_copy/x86_64/aaa_base-1.rpm", 'the copied Leap 16 media root serves the packages');
is(readlink("$leap16_copy/boot") // '', '', 'the installer boot tree stays a directory');

# The Leap 16.0 offline installer image is the package source of a diskless image. It carries
# no dhcp-client, ntp, rsyslog, insserv-compat, net-tools-deprecated, open-lldp, fcoe-utils or
# kernel-firmware, so the SLE 15 netboot list cannot be installed from it.
my $leap16_netboot_pkglist = imgutils::get_profile_def_filename('leap16.0', 'compute', 'x86_64', $share_netboot, 'pkglist');
is(
    $leap16_netboot_pkglist,
    realpath("$share_netboot/compute.leap16.x86_64.pkglist"),
    'a Leap 16 diskless image reads the shipped Leap 16 netboot pkglist'
);
my $leap16_netboot_names = '';
if ($leap16_netboot_pkglist and open(my $fh, '<', $leap16_netboot_pkglist)) {
    $leap16_netboot_names = do { local $/; <$fh> };
    close($fh);
}
like($leap16_netboot_names, qr/^kernel-default$/m, 'the Leap 16 netboot pkglist installs a kernel');
like($leap16_netboot_names, qr/^chrony$/m, 'the Leap 16 netboot pkglist installs chrony');
# dracut installs its network module only when the image has ip. Leap 15 gets ip through wicked,
# and the Leap 16 image boots with NetworkManager, which does not pull it in.
like($leap16_netboot_names, qr/^iproute2$/m, 'the Leap 16 netboot pkglist installs iproute2, which the initrd network needs');
foreach my $absent (qw(dhcp-client ntp rsyslog insserv-compat net-tools-deprecated open-lldp fcoe-utils kernel-firmware)) {
    unlike($leap16_netboot_names, qr/^\Q$absent\E$/m, "the Leap 16 netboot pkglist does not name $absent, which the Leap 16.0 image lacks");
}
is(
    imgutils::get_profile_def_filename('leap16.0', 'compute', 'x86_64', $share_netboot, 'postinstall'),
    realpath("$share_netboot/compute.leap16.postinstall"),
    'a Leap 16 diskless image runs the Leap 16 postinstall, not the SLE 15 one'
);

done_testing();
