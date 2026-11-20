#!/usr/bin/env perl
# openSUSE Leap 16.0 installs with Agama, not with linuxrc and AutoYaST. A Leap 16.0 node booted
# with the AutoYaST arguments loads the Agama initrd, which looks for its live root on a local
# medium labelled Install-Leap-16.0-x86_64, finds none, and never starts the installer.
#
# Agama needs the live root and the repository as URLs, and reads a profile from inst.auto. It
# treats a profile as JSON by its content, and as AutoYaST only when the URL path ends in .xml,
# .erb or /, which the xCAT profile path /install/autoinst/<node> does not.
use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use lib "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins";
use File::Path qw(make_path);
use File::Slurper qw(read_text write_text);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;
use XCAT::Test::File qw(repo_path);

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/db", "$dir/install");
symlink(repo_path('xCAT/postscripts'), "$dir/install/postscripts") or die "postscripts link: $!";
$ENV{XCATROOT} = repo_path('xCAT-server');
$ENV{XCATCFG}  = "SQLite:$dir/db";
require xCAT::Table;
require xCAT::Template;
require xCAT::SvrUtils;
require sles;

like($INC{'sles.pm'}, qr/\Q$FindBin::Bin\E/, 'the sles plugin comes from this checkout');

# Call a sles plugin sub that may not exist yet, so a missing sub fails its own assertion.
sub plugin {
    my ($name, @args) = @_;
    my $sub = xCAT_plugin::sles->can($name) or return;
    return $sub->(@args);
}

# ---- the installer kernel command line ----------------------------------------------------
my $media = 'http://192.0.2.1:80/install/leap16.0/x86_64/1';
is(
    eval { xCAT_plugin::sles::_install_kcmdline('leap16.0', 'http', '192.0.2.1', 80, '/install/leap16.0/x86_64', 'cn1') },
    "root=live:$media/LiveOS/squashfs.img"
      . ' inst.auto=http://192.0.2.1:80/install/autoinst/cn1'
      . " inst.install_url=$media inst.finish=reboot rd.neednet=1 ip=dhcp",
    'a Leap 16 node boots the Agama live root and profile from the management node'
);
like(
    eval { xCAT_plugin::sles::_install_kcmdline('leap16.0', 'http', 'fd00::1', 80, '/install/leap16.0/x86_64', 'cn1') } // '',
    qr{^root=live:http://\[fd00::1\]:80/install/leap16\.0/x86_64/1/LiveOS/squashfs\.img }, 'an IPv6 server is bracketed'
);
foreach my $os (qw(leap15.6 leap42.3 sles15.5)) {
    my $line = eval { xCAT_plugin::sles::_install_kcmdline($os, 'http', '192.0.2.1', 80, "/install/$os/x86_64", 'cn1') } // '';
    like($line, qr{^autoyast=http://192\.0\.2\.1:80/install/autoinst/cn1 }, "$os still boots linuxrc with AutoYaST");
    unlike($line, qr/\binst\.auto=|root=live:/, "$os gets no Agama argument");
}
ok(plugin('_uses_agama', 'leap16.0'), 'Leap 16.0 installs with Agama');
ok(defined(plugin('_uses_agama', $_)) && !plugin('_uses_agama', $_), "$_ does not install with Agama") for qw(leap15.6 leap42.3 sle15 sles12.5);

# ---- the per-node scripts the profile fetches ----------------------------------------------
is_deeply(
    [ plugin('_agama_node_scripts', '/install', 'cn1') ],
    [ [ "$ENV{XCATROOT}/share/xcat/install/scripts/pre.agama",  '/install/autoinst/cn1.pre' ],
      [ "$ENV{XCATROOT}/share/xcat/install/scripts/post.agama", '/install/autoinst/cn1.post' ] ],
    'mkinstall renders an Agama pre script and post script for the node'
);
ok(-r $_->[0], "$_->[0] is shipped") for plugin('_agama_node_scripts', '/install', 'cn1');

# ---- the profile -----------------------------------------------------------------------------
my $share = "$ENV{XCATROOT}/share/xcat/install/sles";
my $tmpl  = xCAT::SvrUtils::get_tmpl_file_name($share, 'compute', 'leap16.0', 'x86_64');
is($tmpl, "$share/compute.leap16.tmpl", 'a Leap 16 compute node reads the Agama profile template');

my %site_values = (
    installdir => "$dir/install", tftpdir => "$dir/tftpboot", master => '192.0.2.1',
    timezone => 'UTC', xcatiport => 3002, xcatdport => 3001, httpport => 80,
    xcatdebugmode => 0, nodestatus => 1,
);
my $site = xCAT::Table->new('site', -create => 1);
$site->setAttribs({ key => $_ }, { value => $site_values{$_} }) for keys %site_values;
$site->close();
%::XCATSITEVALS = (%site_values, managedaddressmode => 'dhcp');
for my $entry (
    [ 'nodelist', { groups => 'all' } ],
    [ 'nodetype', { os => 'leap16.0', arch => 'x86_64', provmethod => 'install' } ],
    [ 'noderes',  { xcatmaster => '192.0.2.1', nfsserver => '192.0.2.1', installnic => 'mac' } ],
    [ 'mac',      { mac => '52:54:00:12:34:56' } ],
) {
    my ($name, $values) = @$entry;
    my $tab = xCAT::Table->new($name, -create => 1);
    $tab->setAttribs({ node => 'cn1' }, $values);
    $tab->close();
}
my $passwd = xCAT::Table->new('passwd', -create => 1);
$passwd->setAttribs({ key => 'system', username => 'root' }, { password => 'cluster' });
$passwd->close();

my $pkglist = "$dir/compute.pkglist";
write_text($pkglist, "\@enhanced_base\n# a comment\nopenssh\nwget\n-snmpd\nchrony\n");
my $out = "$dir/cn1.json";
my $error = $tmpl && -r $tmpl
  ? xCAT::Template->subvars($tmpl, $out, 'cn1', $pkglist, '/install/leap16.0/x86_64/1', 'leap16.0', undef,
    { xcatmaster => '192.0.2.1' })
  : "no template";
ok(!$error, 'the Leap 16 profile renders') or diag($error);
my $profile = eval { decode_json(read_text($out)) };
ok($profile, 'the rendered profile is JSON, which Agama detects by content') or diag($@);
$profile ||= {};

is($profile->{product}{id}, 'openSUSE_Leap', 'the profile selects the Leap product');
ok($profile->{root}{hashedPassword}, 'the root password is a hash');
like($profile->{root}{password} // '', qr/^\$\d\$/, '... crypted from the passwd table');
is_deeply($profile->{software}{packages}, [qw(openssh wget chrony)], 'the pkglist packages are installed');
is_deeply($profile->{software}{patterns}, ['enhanced_base'], 'the pkglist patterns are installed');
my ($pre)  = @{ $profile->{scripts}{pre}  || [] };
my ($post) = @{ $profile->{scripts}{post} || [] };
is($pre->{url}  // '', 'http://192.0.2.1/install/autoinst/cn1.pre',  'the pre script is the rendered node pre script');
is($post->{url} // '', 'http://192.0.2.1/install/autoinst/cn1.post', 'the post script is the rendered node post script');
ok($post->{chroot}, 'the post script runs in the installed system');
unlike(read_text($out), qr/#[A-Z_]+(?::[^#\n]*)?#/, 'the profile leaves no template directive unresolved')
  if -r $out;

# The node scripts render with the same tables, and carry the steps the AutoYaST path runs.
foreach my $script (plugin('_agama_node_scripts', $dir, 'cn1')) {
    my ($template, $output) = @$script;
    make_path("$dir/autoinst");
    my $err = xCAT::Template->subvars($template, $output, 'cn1', '', '', '', '', { xcatmaster => '192.0.2.1' });
    ok(!$err, "$template renders") or diag($err);
    my $text = -r $output ? read_text($output) : '';
    # post.xcat names /install/postscripts literally, which only a management node has.
    unlike($text, qr{#(?:INCLUDE[A-Z_]*|TABLE|TABLEBLANKOKAY|XCATVAR|ENV):(?!cannot open /install/postscripts/)[^#\n]*#},
        "$output leaves no template directive unresolved");
}
my $pre_text  = -r "$dir/autoinst/cn1.pre"  ? read_text("$dir/autoinst/cn1.pre")  : '';
my $post_text = -r "$dir/autoinst/cn1.post" ? read_text("$dir/autoinst/cn1.post") : '';
like($pre_text, qr{^\s*/tmp/updateflag \$XCATDHOST \$XCATDPORT "installstatus installing"}m, 'the pre script reports the node installing');
like($post_text, qr/mypostscript/, 'the post script prepares the xCAT postscripts');
like($post_text, qr{^/tmp/updateflag "192\.0\.2\.1" "3002"$}m, 'the post script asks the management node to boot the node from disk');

done_testing();
