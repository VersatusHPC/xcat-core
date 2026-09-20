#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
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

# The routines below do not exist on a tree without openSUSE Leap 42 support.
# Report a missing routine as one failed assertion instead of dying, so the
# whole file still runs and the failure count is the real one.
sub call1 {
    my ($code) = @_;
    my $out = eval { $code->() };
    if ($@) { diag($@); return undef; }
    return $out;
}

sub calllist {
    my ($code) = @_;
    my @out = eval { $code->() };
    if ($@) { diag($@); return (); }
    return @out;
}

# imgutils::get_package_names skips blank lines and comments, so a pkglist
# assertion must skip them too.
sub pkglist_names {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @names;
    while (<$fh>) {
        chomp;
        s/\s+$//;
        next if /^\s*$/;
        next if /^\s*#/;
        push(@names, $_);
    }
    close($fh);
    return @names;
}

# xcatd (xCAT-server/sbin/xcatd, build_handlers) splits a handled_commands value
# on ":" for the table name and on "=" for the column and the pattern, then
# matches the node attribute against that pattern unanchored.
sub dispatch_matches {
    my ($spec, $os) = @_;
    return 0 unless defined $spec and defined $os;
    my ($table, $cols) = split(/:/, $spec, 2);
    my ($column, $pattern) = split(/=/, $cols, 2);
    return ($os =~ /$pattern/) ? 1 : 0;
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
    "openSUSE - openSUSE-Leap-16.0-NET-x86_64-Media\n",
    "/ openSUSE-Leap 16.0-1\n"
);
is($unsupported_dist, undef, 'does not detect unvalidated openSUSE Leap 16 media as supported');
ok(xCAT_plugin::sles::_copycd_distname_supported('leap15.6'), 'copycd accepts explicit Leap distname override');
ok(!xCAT_plugin::sles::_copycd_distname_supported('leap16.0'), 'copycd rejects unvalidated Leap 16 distname override');
ok(!xCAT_plugin::sles::_copycd_distname_supported('opensuse15.6'), 'copycd does not accept generic openSUSE distname override');

my %commands = %{ xCAT_plugin::sles->handled_commands };
foreach my $command (qw(mkinstall mknetboot mkstatelite mksysclone)) {
    ok(dispatch_matches($commands{$command}, 'leap15.6'), "$command handles openSUSE Leap 15 nodes");
}
ok(!dispatch_matches($commands{mkinstall}, 'rhels9.4'), 'mkinstall leaves Red Hat nodes to the rh plugin');

my @os_search = xCAT::SvrUtils::get_os_search_list('leap15.6');
is_deeply(
    \@os_search,
    [qw(leap15.6 leap15.5 leap15.4 leap15.3 leap15.2 leap15.1 leap15.0 leap15 sle15)],
    'openSUSE Leap 15.x searches exact, minor, major, then SLE 15 fallback'
);

my @unsupported_os_search = xCAT::SvrUtils::get_os_search_list('leap16.0');
unlike(
    join(' ', @unsupported_os_search),
    qr/\bsle16\b/,
    'openSUSE Leap 16 does not silently use an unvalidated SLE 16 fallback'
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

# openSUSE Leap 42.3 is the SLE 12 generation. Its DVD carries no .treeinfo and
# its media.1/products names no SLE product, so copycd has to read the version
# out of the "content" file.

is(call1(sub { xCAT_plugin::sles::_opensuse_leap_distname('42.3') }), 'leap42.3', 'Leap 42.3 media version maps to the leap42.3 distname');
is(call1(sub { xCAT_plugin::sles::_opensuse_leap_distname('42') }), 'leap42', 'Leap 42 media version maps to the leap42 distname');
is(call1(sub { xCAT_plugin::sles::_opensuse_leap_distname('16.0') }), undef, 'Leap 16 stays unsupported');

ok(call1(sub { xCAT_plugin::sles::_copycd_distname_supported('leap42.3') }), 'copycd accepts an explicit leap42.3 distname override');
ok(!call1(sub { xCAT_plugin::sles::_copycd_distname_supported('leap16.0') }), 'copycd rejects an unvalidated Leap 16 distname override');

my $leap42_media = tempdir(CLEANUP => 1);
open(my $leap42_content, '>', "$leap42_media/content") or die "Cannot write Leap 42 content: $!";
print {$leap42_content} <<'EOF';
CONTENTSTYLE  11
DATADIR       suse
DESCRDIR      suse/setup/descr
DISTRO        cpe:/o:opensuse:opensuse:42.3,openSUSE Leap 42.3
LINGUAS       cs da de el en_GB en_US es fr hu it ja pl pt pt_BR ru zh zh_CN zh_TW
REPOID        obsproduct://build.opensuse.org/openSUSE:Leap:42.3/openSUSE/42.3/dvd/x86_64
VENDOR        openSUSE
META SHA256 16a540894c46d297f7b37549c5afe2c4c3eee7177375cc69983c77ebc0a580ae  packages.gz
EOF
close($leap42_content);

my ($content_dist, $content_arch) = calllist(sub { xCAT_plugin::sles::_detect_opensuse_leap_content($leap42_media) });
is($content_dist, 'leap42.3', 'copycd reads the Leap 42.3 distname from the media content file');
is($content_arch, 'x86_64', 'copycd reads the Leap 42.3 arch from the media content file');

my $sle12_media = tempdir(CLEANUP => 1);
open(my $sle12_content, '>', "$sle12_media/content") or die "Cannot write SLE 12 content: $!";
print {$sle12_content} <<'EOF';
CONTENTSTYLE  11
DATADIR       suse
DESCRDIR      suse/setup/descr
DEFAULTBASE   x86_64
DISTRO        cpe:/o:suse:sles:12:sp3,SUSE Linux Enterprise Server 12 SP3
LABEL         SUSE Linux Enterprise Server 12 SP3
EOF
close($sle12_content);

my ($sle12_dist) = calllist(sub { xCAT_plugin::sles::_detect_opensuse_leap_content($sle12_media) });
is($sle12_dist, undef, 'SLE 12 media is left to the SLE parser');

foreach my $command (qw(mkinstall mknetboot mkstatelite mksysclone)) {
    ok(dispatch_matches($commands{$command}, 'leap42.3'), "$command handles openSUSE Leap 42 nodes");
}

is(call1(sub { xCAT_plugin::sles::_install_template_platform('leap42.3') }), 'sles', 'Leap 42 nodes use the SLE install templates');
is(call1(sub { xCAT_plugin::sles::_install_template_platform('leap15.6') }), 'sles', 'Leap 15 nodes use the SLE install templates');
is(call1(sub { xCAT_plugin::sles::_install_template_platform('sles12.3') }), 'sles', 'SLES 12 nodes keep the sles install templates');
is(call1(sub { xCAT_plugin::sles::_install_template_platform('sle15.6') }), 'sle', 'SLE 15 nodes keep the sle install templates');
is(call1(sub { xCAT_plugin::sles::_install_template_platform('suse11') }), 'suse', 'openSUSE 11 nodes keep the suse install templates');
is(call1(sub { xCAT_plugin::sles::_install_template_platform('rhels9.4') }), undef, 'Red Hat nodes get no SLE install template directory');

is(call1(sub { xCAT_plugin::genimage::_netboot_osfamily('leap42.3') }), 'sles', 'genimage runs the SLES diskless scripts for Leap 42');
is(call1(sub { xCAT_plugin::genimage::_netboot_osfamily('leap15.6') }), 'sles', 'genimage runs the SLES diskless scripts for Leap 15');
is(call1(sub { xCAT_plugin::genimage::_netboot_osfamily('sles12.3') }), 'sles', 'genimage keeps SLES 12 on the SLES diskless scripts');
is(call1(sub { xCAT_plugin::genimage::_netboot_osfamily('sles11sp1') }), 'sles', 'genimage keeps the s390x sles11sp1 form on the SLES diskless scripts');
is(call1(sub { xCAT_plugin::genimage::_netboot_osfamily('ubuntu24.04') }), 'ubuntu', 'genimage leaves Ubuntu on its own diskless scripts');

my @leap42_os_search = xCAT::SvrUtils::get_os_search_list('leap42.3');
is_deeply(
    \@leap42_os_search,
    [qw(leap42.3 leap42.2 leap42.1 leap42.0 leap42 sles12)],
    'openSUSE Leap 42.x searches exact, minor, major, then the SLE 12 fallback'
);

my $share_install = "$FindBin::Bin/../../xCAT-server/share/xcat/install/sles";
is(
    xCAT::SvrUtils::get_tmpl_file_name($share_install, 'compute', 'leap42.3', 'x86_64'),
    "$share_install/compute.leap42.tmpl",
    'a Leap 42 compute node gets the shipped Leap 42 autoyast template'
);
is(
    xCAT::SvrUtils::get_pkglist_file_name($share_install, 'compute', 'leap42.3', 'x86_64'),
    "$share_install/compute.leap42.pkglist",
    'a Leap 42 compute node gets the shipped Leap 42 pkglist'
);
is(
    xCAT::SvrUtils::get_tmpl_file_name($share_install, 'service', 'leap42.3', 'x86_64'),
    "$share_install/service.sles12.tmpl",
    'a Leap 42 service node falls back to the SLE 12 autoyast template'
);

my $share_netboot = "$FindBin::Bin/../../xCAT-server/share/xcat/netboot/sles";
my $leap42_netboot_pkglist_path = "$share_netboot/compute.leap42.x86_64.pkglist";
my $sles12_netboot_pkglist_path = "$share_netboot/compute.sles12.x86_64.pkglist";

is(
    imgutils::get_profile_def_filename('leap42.3', 'compute', 'x86_64', $share_netboot, 'pkglist'),
    realpath($leap42_netboot_pkglist_path) || $leap42_netboot_pkglist_path,
    'a Leap 42 diskless image gets the shipped Leap 42 netboot pkglist'
);

# imgutils::get_profile_def_filename tries every osbase with the arch before it
# tries any osbase without it, so an arch-less compute.leap42.pkglist would stay
# behind compute.sles12.x86_64.pkglist.
isnt(
    imgutils::get_profile_def_filename('leap42.3', 'compute', 'x86_64', $share_netboot, 'pkglist'),
    realpath($sles12_netboot_pkglist_path),
    'a Leap 42 diskless image does not read the SLE 12 netboot pkglist'
);

# The postinstall has no Leap 42 variant. genimage exits 1 when it finds none,
# so the SLE 12 file must keep resolving.
is(
    imgutils::get_profile_def_filename('leap42.3', 'compute', 'x86_64', $share_netboot, 'postinstall'),
    realpath("$share_netboot/compute.sles12.x86_64.postinstall"),
    'a Leap 42 diskless image keeps the SLE 12 netboot postinstall'
);

my @leap42_netboot_names = pkglist_names($leap42_netboot_pkglist_path);
ok(scalar(@leap42_netboot_names), 'the Leap 42 netboot pkglist is shipped and names packages');

# openSUSE Leap 42.3 carries neither name on its DVD. genimage installs the list
# with "zypper --non-interactive install -l --no-recommends", which abandons the
# whole transaction on one name it cannot resolve, so kernel-default never lands
# in the rootimg and genimage stops on the missing kernel file.
my %absent_from_leap42 = map { $_ => 1 } qw(open-lldp fcoe-utils);
is_deeply(
    [ grep { $absent_from_leap42{$_} } @leap42_netboot_names ],
    [],
    'the Leap 42 netboot pkglist names no package the Leap 42.3 DVD does not carry'
);

foreach my $kept (qw(kernel-default kernel-firmware xfsprogs nfs-kernel-server openssh)) {
    ok(
        scalar(grep { $_ eq $kept } @leap42_netboot_names),
        "the Leap 42 netboot pkglist keeps $kept"
    );
}

# Everything else in the SLE 12 list is on the Leap 42.3 DVD under the same name.
is_deeply(
    [ sort @leap42_netboot_names ],
    [ sort grep { !$absent_from_leap42{$_} } pkglist_names($sles12_netboot_pkglist_path) ],
    'the Leap 42 netboot pkglist drops only the two names the Leap 42.3 DVD lacks'
);

my $leap42_template_path = "$share_install/compute.leap42.tmpl";
my $leap42_template = '';
if (open(my $leap42_template_fh, '<', $leap42_template_path)) {
    $leap42_template = do { local $/; <$leap42_template_fh> };
    close($leap42_template_fh);
}
like($leap42_template, qr/<install>/, 'Leap 42 template uses the SLE 12 autoyast install section');
like($leap42_template, qr/<configure>/, 'Leap 42 template uses the SLE 12 autoyast configure section');
like($leap42_template, qr/#XCATVAR:PERSKCMDLINE#/, 'Leap 42 template passes the xCAT persistent kernel command line to the bootloader');

my $leap42_pkglist_path = "$share_install/compute.leap42.pkglist";
my $leap42_pkglist = '';
if (open(my $leap42_pkglist_fh, '<', $leap42_pkglist_path)) {
    $leap42_pkglist = do { local $/; <$leap42_pkglist_fh> };
    close($leap42_pkglist_fh);
}
like($leap42_pkglist, qr/^\@base$/m, 'Leap 42 compute pkglist requests the base pattern');
like($leap42_pkglist, qr/^ntp$/m, 'Leap 42 compute pkglist uses ntp, the time daemon on the Leap 42.3 DVD');
unlike($leap42_pkglist, qr/^chrony$/m, 'Leap 42 compute pkglist does not ask for chrony, which the Leap 42.3 DVD does not carry');

done_testing();
