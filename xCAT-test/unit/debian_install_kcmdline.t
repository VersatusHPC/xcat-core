#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(mkpath);
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# mkinstall chooses between two installers -- subiquity (the Ubuntu live installer) and
# debian-installer -- and the choice changes the whole kernel command line. The choice used to
# be an if/else inside mkinstall, which needs a management node and a database, so nothing could
# run it. install_kcmdline takes the same inputs and returns the finished command line, so the
# command line itself is what this file asserts on.

use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
my $plugin = "$FindBin::Bin/../../xCAT-server/lib/xcat/plugins/debian.pm";
plan skip_all => 'debian.pm not found' unless -r $plugin;
eval { require $plugin; 1 } or BAIL_OUT("could not load debian.pm: $@");

my $SUBIQUITY = '/opt/xcat/share/xcat/install/ubuntu/compute.subiquity.tmpl';
my $PRESEED   = '/opt/xcat/share/xcat/install/ubuntu/compute.tmpl';

# TEST-NET-1, so a name that leaks into a command line cannot be dialled.
my $resolver = sub {
    my $name = shift;
    return '192.0.2.10' if defined($name) && $name eq 'mn.cluster';
    return $name if defined($name) && $name =~ /^\d+\.\d+\.\d+\.\d+$/;
    return undef;
};

my $scratch = tempdir(CLEANUP => 1);
my $pkgdir  = "$scratch/install/ubuntu24.04/x86_64";
mkpath("$pkgdir/install");

sub build {
    my (%over) = @_;
    my $tmplfile = delete $over{tmplfile};
    my $os       = delete $over{os} || 'ubuntu24.04';
    return xCAT_plugin::debian::install_kcmdline($os, $tmplfile, {
            instserver => 'mn.cluster',
            pkgdir     => $pkgdir,
            httpport   => '80',
            node       => 'cn1',
            ent        => {},
            resolver   => $resolver,
            %over,
    });
}

# --- a subiquity image gets the live-installer command line -------------------
{
    my ($cmdline, $err) = build(tmplfile => $SUBIQUITY);
    is($err, undef, 'a subiquity image with a resolvable install server reports no error');
    like($cmdline, qr/^nofb utf8 auto xcatd=mn\.cluster /,
        'the command line still opens with the settings both installers need');
    like($cmdline, qr/(?:^| )autoinstall(?: |$)/,
        'subiquity is told to run its autoinstall');
    like($cmdline, qr/(?:^| )boot=casper(?: |$)/,
        'casper is told to boot, so it processes netboot=nfs');
    like($cmdline, qr{(?:^| )nfsroot=192\.0\.2\.10:\Q$pkgdir\E(?: |$)},
        'nfsroot names the install server by address, which klibc nfsmount can parse');
    like($cmdline, qr{ds=nocloud-net;s=http://mn\.cluster:80/install/autoinst/cn1/},
        'cloud-init is pointed at the per-node seed directory');
    like($cmdline, qr/ ---$/, 'and the command line ends with the casper separator');

    unlike($cmdline, qr{(?:^| )url=http://},
        'the preseed answer-file URL is not on a subiquity command line');
    unlike($cmdline, qr/priority=critical/,
        'nor the debian-installer priority');
}

# --- a preseed image gets the debian-installer command line -------------------
{
    my ($cmdline, $err) = build(tmplfile => $PRESEED);
    is($err, undef, 'a preseed image reports no error');
    like($cmdline, qr/^nofb utf8 auto xcatd=mn\.cluster /,
        'the command line still opens with the settings both installers need');
    like($cmdline, qr{(?:^| )url=http://mn\.cluster:80/install/autoinst/cn1(?: |$)},
        'debian-installer is pointed at the per-node preseed file');
    like($cmdline, qr{(?:^| )mirror/http/hostname=mn\.cluster:80(?: |$)},
        'and at the package mirror on the management node');
    like($cmdline, qr/(?:^| )priority=critical(?: |$)/,
        'and told to ask no questions');

    unlike($cmdline, qr/autoinstall|boot=casper|netboot=nfs|nocloud-net/,
        'none of the subiquity settings reach a preseed command line');
}

# --- the installer is chosen per image, not per release ----------------------
{
    my ($old) = build(tmplfile => $SUBIQUITY, os => 'ubuntu18.04');
    like($old, qr/priority=critical/,
        'a release before 20.04 gets debian-installer even from a subiquity template');
    my ($nontmpl) = build(tmplfile => $PRESEED, os => 'ubuntu24.04');
    like($nontmpl, qr/priority=critical/,
        'and 24.04 gets debian-installer when the osimage template is the preseed one');
}

# --- the provisioning NIC reaches debian-installer ---------------------------
{
    my ($bynic) = build(tmplfile => $PRESEED, ent => { installnic => 'ens3' });
    like($bynic, qr{(?:^| )netcfg/choose_interface=ens3(?: |$)},
        'installnic names the interface debian-installer configures');

    my ($bymac) = build(tmplfile => $PRESEED, mac => 'aa:bb:cc:dd:ee:01');
    like($bymac, qr{(?:^| )netcfg/choose_interface=aa:bb:cc:dd:ee:01(?: |$)},
        'with no installnic the mac table entry names it instead');

    my ($both) = build(tmplfile => $PRESEED,
        ent => { installnic => 'ens3' }, mac => 'aa:bb:cc:dd:ee:01');
    like($both, qr{(?:^| )netcfg/choose_interface=ens3(?: |$)},
        'and installnic wins over the mac when both are set');
}

# --- squashfs media adds the live-installer image ----------------------------
{
    my ($without) = build(tmplfile => $PRESEED);
    unlike($without, qr{live-installer/net-image},
        'media with no filesystem.squashfs gets no live-installer image');

    open(my $fh, '>', "$pkgdir/install/filesystem.squashfs") or die $!;
    close($fh);
    my ($with) = build(tmplfile => $PRESEED);
    like($with, qr{(?:^| )live-installer/net-image=http://mn\.cluster:80\Q$pkgdir\E/install/filesystem\.squashfs(?: |$)},
        'and media that carries one is served over http');
    unlink("$pkgdir/install/filesystem.squashfs");
}

# --- an install server that cannot be resolved skips the node ----------------
{
    my ($cmdline, $err) = build(tmplfile => $SUBIQUITY, instserver => 'nosuchhost');
    is($cmdline, undef, 'an unresolvable install server yields no command line');
    like($err, qr/nosuchhost/, 'and the message names the server that failed');

    my ($placeholder, $noerr) = build(tmplfile => $SUBIQUITY, instserver => '!myipfn!');
    is($noerr, undef, 'the !myipfn! placeholder is not an unresolvable name');
    like($placeholder, qr/nfsroot=!myipfn!:/,
        'and reaches the boot config for pxe.pm and grub2.pm to substitute');
}

done_testing();
