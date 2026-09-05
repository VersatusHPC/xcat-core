#!/usr/bin/env perl
use strict;
use warnings;
## no critic (Modules::RequireFilenameMatchesPackage)

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perl-xCAT";
use lib "$FindBin::Bin/../../xCAT-server/lib/perl";
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use XCAT::Test::File qw(repo_path slurp_repo_file);

# GRUB reads ";" as a command separator, so the NoCloud seed of an Ubuntu autoinstall --
# "ds=nocloud-net;s=<url>" -- ends the linux command where the ";" is and the kernel never
# sees the seed. Render the line the plugin writes and read it back, rather than matching
# the plugin source: the defect is in what reaches the boot loader.
#
# grub2.pm needs a management node to load, so lift the renderer into a scratch package.

my $plugin_relative = File::Spec->catfile(
    'xCAT-server', 'lib', 'xcat', 'plugins', 'grub2.pm'
);
my $source = slurp_repo_file($plugin_relative);

my ($routine) = $source =~ /^(sub\s+grub_linux_line\s*\{.*?^\})/ms;
BAIL_OUT("grub_linux_line is not in $plugin_relative") unless $routine;
eval "package Scratch; $routine; 1" or BAIL_OUT("could not load grub_linux_line: $@");

sub line { return Scratch::grub_linux_line(@_); }

my $seed_url  = 'http://mn1:80/install/autoinst/node1/';
my $subiquity = "nofb utf8 auto xcatd=mn1 autoinstall ip=dhcp boot=casper netboot=nfs"
  . " nfsroot=192.0.2.10:/install/ubuntu24.04.4/ppc64el toram"
  . " ds=nocloud-net;s=$seed_url ---"
  . " console=tty0 console=hvc0,115200 locale=en_US hostname=node1";

my $rendered = line( '', '/tftpboot/xcat/osimage/img/vmlinuz', $subiquity );

# --- the defect ------------------------------------------------------------
like(
    $rendered,
    qr{\Qds=nocloud-net\;s=$seed_url\E},
    'the seed datasource reaches GRUB with the separator escaped',
);
unlike(
    $rendered,
    qr/(?<!\\);/,
    'the rendered linux line carries no unescaped GRUB command separator',
);

# --- what the line must still say (holds before and after the fix) ---------
like( $rendered, qr{^\s+linux \Q/tftpboot/xcat/osimage/img/vmlinuz\E },
    'the line loads the kernel the caller named' );
like( $rendered, qr/\QBOOTIF=\E\$\Qnet_default_mac\E$/,
    'BOOTIF stays a GRUB variable, so the backslash is not applied to $' );
like( $rendered, qr/\Qboot=casper\E/, 'casper still boots the live filesystem' );
like( $rendered, qr{\Qnfsroot=192.0.2.10:/install/ubuntu24.04.4/ppc64el\E},
    'the NFS root keeps its literal address' );
like( $rendered, qr/\Qhostname=node1\E/,
    'the tail of the command line survives, so nothing is cut at the seed' );

is(
    line( 'efi', '/vmlinuz', 'quiet ro' ),
    '    linuxefi /vmlinuz quiet ro BOOTIF=' . '$' . 'net_default_mac',
    'a command line with no separator renders unchanged, on the efi variant',
);
is(
    line( '', '/vmlinuz', undef ),
    '    linux /vmlinuz BOOTIF=' . '$' . 'net_default_mac',
    'a node with no command line still gets a linux line',
);
is(
    line( '', '/vmlinuz', 'a\;b' ),
    '    linux /vmlinuz a\;b BOOTIF=' . '$' . 'net_default_mac',
    'a separator that is already escaped is left alone',
);

# --- GRUB itself reads the rendered line as one command --------------------
my ($checker) = grep { -x $_ }
  map { ( "/usr/bin/$_", "/usr/sbin/$_", "/bin/$_", "/sbin/$_" ) }
  qw(grub-script-check grub2-script-check);

SKIP: {
    skip( 'no grub-script-check on this host', 2 ) unless $checker;

    # "fi" is a GRUB reserved word. It is only a syntax error when the ";" before it ends
    # the linux command, so this tells a single command apart from two.
    my $dir = tempdir( CLEANUP => 1 );
    my $i   = 0;
    my $parses = sub {
        my ($body) = @_;
        my $path = File::Spec->catfile( $dir, 'cfg' . $i++ );
        open( my $fh, '>', $path ) or die "cannot write $path: $!";
        print $fh "menuentry \"xCAT OS Deployment\" {\n$body\n}\n";
        close($fh);
        return system( $checker, $path ) == 0 ? 1 : 0;
    };

    is( $parses->( line( '', '/vmlinuz', 'ds=nocloud-net;fi' ) ), 1,
        'GRUB parses the rendered line as one command' );
    is( $parses->( '    linux /vmlinuz ds=nocloud-net;fi BOOTIF=' . '$' . 'net_default_mac' ), 0,
        'GRUB rejects the same line unescaped, so the check tells the two apart' );
}

done_testing();
